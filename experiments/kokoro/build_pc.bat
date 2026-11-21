@echo off
rem Build kokoro-cli.exe for checking the engine on this PC.
rem usage: build_pc.bat <ggml source dir> <build dir> [vulkan]
setlocal
if "%~2"=="" (echo usage: build_pc.bat ^<ggml source dir^> ^<build dir^> [vulkan] & exit /b 2)
set "SRC=%~dp0"
set "PATH=C:\Windows\system32;C:\Windows;C:\Windows\System32\Wbem;C:\Windows\System32\WindowsPowerShell\v1.0;C:\Program Files (x86)\Microsoft Visual Studio\Installer;C:\Program Files\Git\cmd"
set "VS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools"
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
if not defined VULKAN_SDK set "VULKAN_SDK=C:\VulkanSDK\1.4.363.0"
set "PATH=%VULKAN_SDK%\Bin;%VS%\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin;%VS%\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja;%PATH%"
set "VK=OFF"
if "%~3"=="vulkan" set "VK=ON"
if not exist "%~2\build.ninja" cmake -S "%SRC%." -B "%~2" -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_DIR="%~1" -DGGML_VULKAN=%VK% -DGGML_NATIVE=ON || exit /b 1
cmake --build "%~2" --target kokoro-cli -j 16 || exit /b 1
echo built %~2\kokoro-cli.exe
