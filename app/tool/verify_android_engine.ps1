param(
    [string]$Apk = "$PSScriptRoot/../build/app/outputs/flutter-apk/app-release.apk",
    [string]$StrippedLibraries = "$PSScriptRoot/../build/app/intermediates/stripped_native_libs/release/stripReleaseDebugSymbols/out/lib",
    [string]$NativeLibraries = "$PSScriptRoot/../build/app/native-engine-output/release",
    [string]$RustLibraries = "$PSScriptRoot/../build/rust_lib_novel/jniLibs/release",
    [string]$MergedLibraries = "$PSScriptRoot/../build/app/intermediates/merged_native_libs/release/mergeReleaseNativeLibs/out/lib"
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Read-ZipBytes($Entry) {
    $source = $Entry.Open()
    $memory = [IO.MemoryStream]::new()
    try {
        $source.CopyTo($memory)
        return ,$memory.ToArray()
    } finally {
        $source.Dispose()
        $memory.Dispose()
    }
}

function Get-ByteHash([byte[]]$Bytes) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hash.ComputeHash($Bytes)).Replace('-', '') }
    finally { $hash.Dispose() }
}

function Assert-EngineElf([byte[]]$Bytes, [int]$Machine) {
    if ($Bytes.Length -lt 64 -or [BitConverter]::ToUInt32($Bytes, 0) -ne 0x464c457f -or
        $Bytes[4] -ne 2 -or $Bytes[5] -ne 1 -or
        [BitConverter]::ToUInt16($Bytes, 16) -ne 3 -or
        [BitConverter]::ToUInt16($Bytes, 18) -ne $Machine) {
        throw 'Engine must be a little-endian 64-bit PIE for the requested ABI'
    }
    $offset = [BitConverter]::ToUInt64($Bytes, 32)
    $entrySize = [BitConverter]::ToUInt16($Bytes, 54)
    $count = [BitConverter]::ToUInt16($Bytes, 56)
    $loads = @()
    $dynamic = $null
    $interpreter = $null
    for ($i = 0; $i -lt $count; $i++) {
        $p = [int]($offset + $entrySize * $i)
        $type = [BitConverter]::ToUInt32($Bytes, $p)
        $segment = @{
            Offset = [BitConverter]::ToUInt64($Bytes, $p + 8)
            Address = [BitConverter]::ToUInt64($Bytes, $p + 16)
            Size = [BitConverter]::ToUInt64($Bytes, $p + 32)
        }
        if ($type -eq 1) {
            if ([BitConverter]::ToUInt64($Bytes, $p + 48) -lt 16384) {
                throw 'Engine LOAD segment is not 16 KB page aligned'
            }
            $loads += $segment
        } elseif ($type -eq 2) {
            $dynamic = $segment
        } elseif ($type -eq 3) {
            $interpreter = [Text.Encoding]::ASCII.GetString($Bytes, [int]$segment.Offset, [int]$segment.Size - 1)
        }
    }
    if ($interpreter -ne '/system/bin/linker64' -or !$dynamic -or !$loads) {
        throw 'Missing Android interpreter or dynamic segments'
    }
    $needed = @()
    $stringAddress = 0
    for ($p = [int]$dynamic.Offset; $p -lt $dynamic.Offset + $dynamic.Size; $p += 16) {
        $tag = [BitConverter]::ToInt64($Bytes, $p)
        $value = [BitConverter]::ToUInt64($Bytes, $p + 8)
        if ($tag -eq 0) { break }
        if ($tag -eq 1) { $needed += $value }
        if ($tag -eq 5) { $stringAddress = $value }
    }
    $strings = $loads | Where-Object {
        $stringAddress -ge $_.Address -and $stringAddress -lt $_.Address + $_.Size
    } | Select-Object -First 1
    if (!$strings) { throw 'Missing ELF dynamic string table' }
    $dependencies = foreach ($nameOffset in $needed) {
        $start = [int]($strings.Offset + $stringAddress - $strings.Address + $nameOffset)
        $end = $start
        while ($end -lt $Bytes.Length -and $Bytes[$end] -ne 0) { $end++ }
        $name = [Text.Encoding]::ASCII.GetString($Bytes, $start, $end - $start)
        if ($name -notin @('libc.so', 'libm.so', 'libdl.so', 'liblog.so', 'libandroid.so')) {
            throw "Unbundled/non-system dependency: $name"
        }
        $name
    }
    return ($dependencies -join ', ')
}

$zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Apk))
try {
    foreach ($abi in @('arm64-v8a', 'x86_64')) {
        foreach ($name in @('libedge_llama_server.so', 'librust_lib_novel.so')) {
            $entry = $zip.GetEntry("lib/$abi/$name")
            if (!$entry) { throw "APK missing lib/$abi/$name" }
            $bytes = Read-ZipBytes $entry
            $hash = Get-ByteHash $bytes
            $built = Join-Path $StrippedLibraries "$abi/$name"
            if (!(Test-Path -LiteralPath $built) -or (Get-FileHash -LiteralPath $built).Hash -ne $hash) {
                throw "APK differs from this build's stripped library: $abi/$name"
            }
            $dependencies = ''
            $sourceDirectory = if ($name -eq 'libedge_llama_server.so') { $NativeLibraries } else { $RustLibraries }
            $nativeHash = (Get-FileHash -LiteralPath (Join-Path $sourceDirectory "$abi/$name")).Hash
            $mergedHash = (Get-FileHash -LiteralPath (Join-Path $MergedLibraries "$abi/$name")).Hash
            if ($nativeHash -ne $mergedHash) {
                throw "Native build changed but packaging reused stale bytes: $abi/$name"
            }
            if ($name -eq 'libedge_llama_server.so') {
                $machine = if ($abi -eq 'arm64-v8a') { 183 } else { 62 }
                $dependencies = Assert-EngineElf $bytes $machine
                $text = [Text.Encoding]::ASCII.GetString($bytes)
                if (!$text.Contains('License for llama.cpp') -or
                    !$text.Contains('License for Android NDK toolchain')) {
                    throw 'Engine is missing bundled third-party license notices'
                }
            }
            [pscustomobject]@{ ABI=$abi; File=$name; Bytes=$entry.Length; SHA256=$hash; Dependencies=$dependencies }
        }
    }
    if ($zip.Entries.FullName -match '\.gguf$') { throw 'Models must remain on-demand, not bundled' }
} finally {
    $zip.Dispose()
}
