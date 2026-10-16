//! iOS: build the llama.cpp server from ios_engine/ and the 听书 engine from
//! ios_tts/ and link them into this library (see src/engine_thread.rs and
//! src/api/tts.rs), because iOS lets an app start no process of its own. A Mac
//! builds them the same way for the engine test in CI. Every other platform
//! runs the engines as executables, and nothing is built here.
use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

/// The app's own floor. The engine only starts from iOS 16.4 (checked at run
/// time), but what it links must not stop the app launching on older systems.
const MIN_IOS: &str = "13.0";

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo::rustc-check-cfg=cfg(in_process_engine)");
    let os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if os != "ios" && os != "macos" {
        return;
    }
    println!("cargo:rustc-cfg=in_process_engine");
    let src = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap()).join("ios_engine");
    println!("cargo:rerun-if-changed={}", src.display());
    let target = env::var("TARGET").unwrap();
    let arch = if target.starts_with("x86_64") { "x86_64" } else { "arm64" };
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let build = out.join("llama");

    let cmake = cmake();
    let simulator = os == "ios" && (target.ends_with("-sim") || arch == "x86_64");
    let sdk = match (os.as_str(), simulator) {
        ("ios", true) => "iphonesimulator",
        ("ios", false) => "iphoneos",
        _ => "macosx",
    };
    run(&mut configure(&cmake, &src, &build, sdk, arch));
    let jobs = env::var("NUM_JOBS").unwrap_or_else(|_| "4".into());
    run(Command::new(&cmake)
        .arg("--build")
        .arg(&build)
        .args(["--target", "edge_llama", "--parallel", &jobs]));

    // CMake leaves one archive per target; the linker gets them as one.
    let mut archives = Vec::new();
    collect(&build, &mut archives);
    let merged = out.join("libedge_llama_all.a");
    let _ = std::fs::remove_file(&merged);
    run(Command::new("xcrun")
        .args(["libtool", "-static", "-no_warning_for_no_symbols", "-o"])
        .arg(&merged)
        .args(&archives));
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=edge_llama_all");
    // What the engine itself links against. The app gets the same from the
    // podspec; this is for what rustc links on its own (the test, the dylib).
    for framework in ["Metal", "MetalKit", "Foundation", "Accelerate"] {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
    println!("cargo:rustc-link-lib=c++");

    build_tts(&cmake, sdk, arch, &out, &jobs);
}

/// qwentts.cpp and the ggml fork it needs, as one object in which everything
/// but `edge_tts_*` is local: linked beside llama.cpp's own ggml, the two would
/// otherwise meet symbol for symbol.
fn build_tts(cmake: &Path, sdk: &str, arch: &str, out: &Path, jobs: &str) {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let src = manifest.join("ios_tts");
    println!("cargo:rerun-if-changed={}", src.display());
    println!(
        "cargo:rerun-if-changed={}",
        manifest.join("../../experiments/qwen-tts/qwentts.patch").display()
    );
    let build = out.join("tts");
    run(&mut configure(cmake, &src, &build, sdk, arch));
    run(Command::new(cmake)
        .arg("--build")
        .arg(&build)
        .args(["--target", "edge_tts", "--parallel", jobs]));

    let mut archives = Vec::new();
    collect(&build, &mut archives);
    let object = out.join("edge_tts.o");
    let min = match sdk {
        "iphoneos" => format!("-mios-version-min={MIN_IOS}"),
        "iphonesimulator" => format!("-mios-simulator-version-min={MIN_IOS}"),
        _ => "-mmacosx-version-min=13.0".into(),
    };
    run(Command::new("xcrun")
        .args(["-sdk", sdk, "clang++", "-r", "-nostdlib", "-arch", arch])
        .arg(min)
        .arg("-Wl,-all_load")
        .arg(format!("-Wl,-exported_symbols_list,{}", src.join("exports.txt").display()))
        .arg("-o")
        .arg(&object)
        .args(&archives));
    let merged = out.join("libedge_tts_all.a");
    let _ = std::fs::remove_file(&merged);
    run(Command::new("xcrun")
        .args(["libtool", "-static", "-o"])
        .arg(&merged)
        .arg(&object));
    println!("cargo:rustc-link-lib=static=edge_tts_all");

    // The compiled Metal library, which src/api/tts.rs writes out for the
    // engine to load, under a name that changes with its content.
    let metallib = std::fs::read(build.join("bin/default.metallib"))
        .expect("the TTS Metal library was not built");
    std::fs::write(out.join("tts.metallib"), &metallib).unwrap();
    let hash = metallib
        .iter()
        .fold(0xcbf2_9ce4_8422_2325u64, |h, b| (h ^ *b as u64).wrapping_mul(0x100_0000_01b3));
    println!("cargo:rustc-env=EDGE_TTS_METALLIB=tts-{hash:016x}.metallib");
}

/// Release even in a debug app: an unoptimised engine is unusably slow.
fn configure(cmake: &Path, src: &Path, build: &Path, sdk: &str, arch: &str) -> Command {
    let mut c = Command::new(cmake);
    c.arg("-S")
        .arg(src)
        .arg("-B")
        .arg(build)
        .arg("-DCMAKE_BUILD_TYPE=Release")
        .arg(format!("-DCMAKE_OSX_ARCHITECTURES={arch}"));
    if sdk != "macosx" {
        c.arg("-DCMAKE_SYSTEM_NAME=iOS")
            .arg(format!("-DCMAKE_OSX_SYSROOT={sdk}"))
            .arg(format!("-DCMAKE_OSX_DEPLOYMENT_TARGET={MIN_IOS}"))
            .arg("-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY");
    }
    c
}

/// Xcode runs this with a short PATH that may not reach Homebrew's cmake.
fn cmake() -> PathBuf {
    if let Ok(p) = env::var("CMAKE") {
        return p.into();
    }
    for p in ["/opt/homebrew/bin/cmake", "/usr/local/bin/cmake"] {
        if Path::new(p).is_file() {
            return p.into();
        }
    }
    "cmake".into()
}

fn collect(dir: &Path, found: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for e in entries.flatten() {
        let p = e.path();
        if p.is_dir() {
            collect(&p, found);
        } else if p.extension().is_some_and(|x| x == "a") {
            found.push(p);
        }
    }
}

fn run(cmd: &mut Command) {
    let status = cmd
        .status()
        .unwrap_or_else(|e| panic!("could not run {cmd:?}: {e}"));
    assert!(status.success(), "{cmd:?} failed: {status}");
}
