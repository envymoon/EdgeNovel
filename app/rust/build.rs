//! iOS only: build the llama.cpp server from ios_engine/ and link it into this
//! library (see src/ios_engine.rs). Every other platform runs the engine as an
//! executable of its own, and nothing is built here.
use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

/// llama.cpp's own iOS floor for its Metal backend.
const ENGINE_MIN_IOS: &str = "16.4";

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("ios") {
        return;
    }
    let src = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap()).join("ios_engine");
    println!("cargo:rerun-if-changed={}", src.display());
    let target = env::var("TARGET").unwrap();
    let simulator = target.ends_with("-sim") || target.starts_with("x86_64");
    let arch = if target.starts_with("x86_64") { "x86_64" } else { "arm64" };
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let build = out.join("llama");

    let cmake = cmake();
    // Release even in a debug app: an unoptimised engine is unusably slow.
    run(Command::new(&cmake)
        .arg("-S")
        .arg(&src)
        .arg("-B")
        .arg(&build)
        .arg("-DCMAKE_BUILD_TYPE=Release")
        .arg("-DCMAKE_SYSTEM_NAME=iOS")
        .arg(format!(
            "-DCMAKE_OSX_SYSROOT={}",
            if simulator { "iphonesimulator" } else { "iphoneos" }
        ))
        .arg(format!("-DCMAKE_OSX_ARCHITECTURES={arch}"))
        .arg(format!("-DCMAKE_OSX_DEPLOYMENT_TARGET={ENGINE_MIN_IOS}"))
        .arg("-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY"));
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
