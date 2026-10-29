//! Locate APK-installed executable code, never code downloaded into app data.
use std::ffi::{c_void, CStr};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

// Preparation is serialized, but stop never waits behind a cold model load.
pub(crate) static PREPARE_LOCK: Mutex<()> = Mutex::new(());
static STOP_GENERATION: AtomicU64 = AtomicU64::new(0);
pub(crate) fn generation() -> u64 {
    STOP_GENERATION.load(Ordering::SeqCst)
}
pub(crate) fn cancel_startup() {
    STOP_GENERATION.fetch_add(1, Ordering::SeqCst);
}

pub(crate) fn executable() -> Option<PathBuf> {
    bundled("libedge_llama_server.so")
}

/// An engine shipped in the APK: the chat engine, the 听书 engine
/// (`libedge_tts_server.so`) or the picture engine (`libedge_sd_cli.so`).
pub(crate) fn bundled(name: &str) -> Option<PathBuf> {
    let mut info = std::mem::MaybeUninit::<libc::Dl_info>::zeroed();
    // The Rust bridge and engine are extracted together by PackageManager.
    // dladdr handles both split APK paths and a changed install directory.
    unsafe {
        if libc::dladdr(bundled as *const () as *const c_void, info.as_mut_ptr()) == 0 {
            return None;
        }
        let info = info.assume_init();
        if info.dli_fname.is_null() {
            return None;
        }
        let library = PathBuf::from(CStr::from_ptr(info.dli_fname).to_str().ok()?);
        let engine = library.parent()?.join(name);
        engine.is_file().then_some(engine)
    }
}

/// The GPU (Vulkan) failed this run: it would not start, or an engine on it
/// died. Every engine goes on on the CPU until the app is started again, so a
/// phone whose driver cannot run it still reads, speaks and draws.
static GPU_FAILED: AtomicBool = AtomicBool::new(false);

pub(crate) fn gpu_failed() -> bool {
    GPU_FAILED.load(Ordering::SeqCst)
}

pub(crate) fn mark_gpu_failed() {
    GPU_FAILED.store(true, Ordering::SeqCst);
}

/// Whether an engine starting now runs on the GPU.
pub(crate) fn use_gpu() -> bool {
    !crate::api::ai::cpu_only() && !gpu_failed()
}

pub(crate) fn api_key() -> Result<&'static str, String> {
    static KEY: OnceLock<Result<String, String>> = OnceLock::new();
    KEY.get_or_init(|| {
        use std::io::Read;
        let mut bytes = [0u8; 32];
        std::fs::File::open("/dev/urandom")
            .and_then(|mut f| f.read_exact(&mut bytes))
            .map_err(|e| format!("无法创建本地引擎密钥: {e}"))?;
        Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
    })
    .as_deref()
    .map_err(Clone::clone)
}
