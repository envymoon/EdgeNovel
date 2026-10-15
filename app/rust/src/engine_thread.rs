//! iOS lets an app start no process of its own, so the llama-server that is an
//! executable elsewhere is compiled into the app (build.rs, ios_engine/) and
//! runs on a thread, one per model. It still listens on loopback, so everything
//! that talks to it is the same code as on the other platforms. A Mac builds it
//! the same way, which is how CI runs the engine test on Apple's GPU.
use std::ffi::{c_char, c_int, CString};
use std::io;
use std::sync::{Mutex, OnceLock};
use std::thread::JoinHandle;
use std::time::Duration;

extern "C" {
    fn edge_llama_run(argc: c_int, argv: *mut *mut c_char) -> c_int;
    fn edge_llama_stop(port: c_int) -> c_int;
}

/// llama.cpp's Metal backend wants iOS 16.4. An older iOS runs the app
/// without AI: the engine is there but is never started.
pub(crate) fn supported() -> bool {
    #[cfg(target_os = "ios")]
    {
        static OK: OnceLock<bool> = OnceLock::new();
        return *OK.get_or_init(|| {
            let version = std::env::var("SIMULATOR_RUNTIME_VERSION")
                .ok()
                .or_else(ios_version)
                .unwrap_or_default();
            let mut parts = version.split('.').map(|p| p.parse::<u32>().unwrap_or(0));
            (parts.next().unwrap_or(0), parts.next().unwrap_or(0)) >= (16, 4)
        });
    }
    #[cfg(not(target_os = "ios"))]
    return true;
}

#[cfg(target_os = "ios")]
fn ios_version() -> Option<String> {
    extern "C" {
        fn sysctlbyname(
            name: *const c_char,
            oldp: *mut std::ffi::c_void,
            oldlenp: *mut usize,
            newp: *mut std::ffi::c_void,
            newlen: usize,
        ) -> c_int;
    }
    let mut buf = [0u8; 32];
    let mut len = buf.len();
    let r = unsafe {
        sysctlbyname(
            c"kern.osproductversion".as_ptr(),
            buf.as_mut_ptr().cast(),
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    if r != 0 {
        return None;
    }
    let s = std::str::from_utf8(&buf[..len.min(buf.len())]).ok()?;
    Some(s.trim_end_matches('\0').to_string())
}

/// One start at a time: two callers that both find a port silent would both
/// start a server on it.
pub(crate) static PREPARE_LOCK: Mutex<()> = Mutex::new(());

/// A server on a thread of this process. It stands where a `Child` stands on
/// the other platforms and answers the same three calls.
pub(crate) struct Engine {
    port: u16,
    thread: Option<JoinHandle<i32>>,
    exit: Option<i32>,
}

impl Engine {
    pub(crate) fn start(port: u16, args: &[&std::ffi::OsStr]) -> io::Result<Engine> {
        let argv = std::iter::once("llama-server")
            .chain(args.iter().map(|a| a.to_str().unwrap_or_default()))
            .map(|a| CString::new(a).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e)))
            .collect::<io::Result<Vec<_>>>()?;
        let thread = std::thread::Builder::new()
            .name(format!("llama-server-{port}"))
            .stack_size(8 << 20)
            .spawn(move || {
                let mut ptrs: Vec<*mut c_char> =
                    argv.iter().map(|a| a.as_ptr() as *mut c_char).collect();
                ptrs.push(std::ptr::null_mut());
                unsafe { edge_llama_run(argv.len() as c_int, ptrs.as_mut_ptr()) }
            })?;
        Ok(Engine {
            port,
            thread: Some(thread),
            exit: None,
        })
    }

    /// The server's exit code once it has returned.
    pub(crate) fn try_wait(&mut self) -> io::Result<Option<i32>> {
        if self.thread.as_ref().is_some_and(|t| t.is_finished()) {
            self.wait()?;
        }
        Ok(self.exit)
    }

    /// Stop the server. One still loading its model cannot be stopped until it
    /// has loaded, so this waits for that.
    pub(crate) fn kill(&mut self) -> io::Result<()> {
        while self.thread.as_ref().is_some_and(|t| !t.is_finished()) {
            if unsafe { edge_llama_stop(self.port as c_int) } != 0 {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        Ok(())
    }

    pub(crate) fn wait(&mut self) -> io::Result<i32> {
        if let Some(t) = self.thread.take() {
            self.exit = Some(t.join().unwrap_or(-1));
        }
        Ok(self.exit.unwrap_or(0))
    }
}

/// Loopback is shared by every app on the device; only this one may talk to
/// its engine.
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

/// This process's memory as the kernel accounts it, in bytes: now and the most
/// since it started. It is the number iOS ends an app by.
#[cfg(test)]
pub(crate) fn footprint() -> (u64, u64) {
    extern "C" {
        static mach_task_self_: u32;
        fn task_info(task: u32, flavor: c_int, info: *mut c_int, count: *mut u32) -> c_int;
    }
    const TASK_VM_INFO: c_int = 22;
    // task_vm_info as 64-bit words: phys_footprint is word 18 and
    // ledger_phys_footprint_peak word 21. The kernel fills what it has.
    let mut info = [0u64; 64];
    let mut count = (std::mem::size_of_val(&info) / 4) as u32;
    let r = unsafe {
        task_info(
            mach_task_self_,
            TASK_VM_INFO,
            info.as_mut_ptr().cast(),
            &mut count,
        )
    };
    if r != 0 {
        return (0, 0);
    }
    (info[18], info[21])
}
