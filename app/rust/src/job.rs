//! Children that die with us.
//!
//! `llama-server` is a separate OS process holding gigabytes of RAM and VRAM.
//! Killing it on the way out is not enough, because the way out is not always
//! taken: an app that crashes, or that the user ends from Task Manager, or that
//! Windows closes without delivering a lifecycle event, never runs its cleanup —
//! and the engine outlives it, still holding the memory of an app that is gone.
//! One was found in the wild holding 4.8 GB with `novel.exe` no longer running,
//! and it quietly halved the speed of everything that came after it.
//!
//! So this does not rely on running any code at exit. Every child is put in a
//! Windows job object marked KILL_ON_JOB_CLOSE, and the kernel tears the job
//! down when the last handle to it closes — which happens when our process ends,
//! for any reason at all, including the ones that skip destructors.
//!
//! Failure here is silent on purpose. A job object is a safety net; if it cannot
//! be created, the app should still be able to speak and summarize.

use std::process::Child;

#[cfg(windows)]
mod imp {
    use std::ffi::c_void;
    use std::os::windows::io::AsRawHandle;
    use std::process::Child;
    use std::sync::OnceLock;

    type Handle = *mut c_void;

    #[repr(C)]
    #[derive(Default)]
    struct BasicLimit {
        per_process_user_time_limit: i64,
        per_job_user_time_limit: i64,
        limit_flags: u32,
        minimum_working_set_size: usize,
        maximum_working_set_size: usize,
        active_process_limit: u32,
        affinity: usize,
        priority_class: u32,
        scheduling_class: u32,
    }

    #[repr(C)]
    #[derive(Default)]
    struct IoCounters {
        read_ops: u64,
        write_ops: u64,
        other_ops: u64,
        read_bytes: u64,
        write_bytes: u64,
        other_bytes: u64,
    }

    /// JOBOBJECT_EXTENDED_LIMIT_INFORMATION. The whole struct has to be passed
    /// even though only `basic.limit_flags` is set — the kernel checks the size.
    #[repr(C)]
    #[derive(Default)]
    struct ExtendedLimit {
        basic: BasicLimit,
        io: IoCounters,
        process_memory_limit: usize,
        job_memory_limit: usize,
        peak_process_memory_used: usize,
        peak_job_memory_used: usize,
    }

    const KILL_ON_JOB_CLOSE: u32 = 0x2000;
    const EXTENDED_LIMIT_INFORMATION: u32 = 9;

    #[link(name = "kernel32")]
    extern "system" {
        fn CreateJobObjectW(attrs: *mut c_void, name: *const u16) -> Handle;
        fn SetInformationJobObject(job: Handle, class: u32, info: *const c_void, len: u32) -> i32;
        fn AssignProcessToJobObject(job: Handle, process: Handle) -> i32;
    }

    /// The one job every child joins. Stored as a `usize` because a raw handle is
    /// neither `Send` nor `Sync`, and this is read from whichever thread happens
    /// to be starting an engine. Deliberately never closed: the handle closing is
    /// exactly what kills the children, so it must outlive everything.
    fn job() -> Option<Handle> {
        static JOB: OnceLock<usize> = OnceLock::new();
        let h = *JOB.get_or_init(|| unsafe {
            let job = CreateJobObjectW(std::ptr::null_mut(), std::ptr::null());
            if job.is_null() {
                return 0;
            }
            let mut info = ExtendedLimit::default();
            info.basic.limit_flags = KILL_ON_JOB_CLOSE;
            let ok = SetInformationJobObject(
                job,
                EXTENDED_LIMIT_INFORMATION,
                &info as *const _ as *const c_void,
                std::mem::size_of::<ExtendedLimit>() as u32,
            );
            if ok == 0 {
                return 0;
            }
            job as usize
        });
        (h != 0).then_some(h as Handle)
    }

    pub fn adopt(child: &Child) {
        let Some(job) = job() else { return };
        // Nested jobs have been allowed since Windows 8, so this holds even when
        // the app itself was launched inside someone else's job.
        unsafe { AssignProcessToJobObject(job, child.as_raw_handle() as Handle) };
    }
}

#[cfg(not(windows))]
mod imp {
    use std::process::Child;
    pub fn adopt(_child: &Child) {}
}

/// Tie `child`'s lifetime to this process. Call it immediately after spawning
/// anything long-lived; it is cheap and idempotent per child.
pub(crate) fn adopt(child: &Child) {
    imp::adopt(child);
}
