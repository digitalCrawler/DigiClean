//! Keeps DigiClean's heavy work from slowing down the rest of the computer.
//!
//! Scans, hashing and photo/media analysis run on worker threads at
//! *background* priority. The operating system then serves the user's other
//! programs (and DigiClean's own interface) first and gives the workers
//! whatever is left, so a scan uses idle capacity instead of competing for
//! it. It costs little speed on an idle machine.
//!
//! * Windows: background mode, which lowers CPU, disk and memory priority.
//! * Linux and Android: nice +10, plus the lowest best-effort disk priority.
//! * macOS and iOS: the "utility" quality-of-service class, which lowers CPU
//!   priority and throttles disk access.
//!
//! Everything here is best effort: when the system refuses, work simply runs
//! at normal priority.

/// Lowers the calling thread to background priority for the rest of its life.
///
/// Only call this on threads DigiClean owns: on Linux the change cannot be
/// undone without privileges.
pub fn lower_current_thread() {
    #[cfg(windows)]
    {
        use windows_sys::Win32::System::Threading::{
            GetCurrentThread, SetThreadPriority, THREAD_MODE_BACKGROUND_BEGIN,
        };
        // SAFETY: the pseudo-handle of the calling thread is always valid.
        unsafe {
            SetThreadPriority(GetCurrentThread(), THREAD_MODE_BACKGROUND_BEGIN);
        }
    }
    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        // SAFETY: plain syscalls on the calling thread; failures are ignored.
        unsafe {
            let tid = libc::syscall(libc::SYS_gettid) as libc::id_t;
            // On Linux, PRIO_PROCESS with a thread id changes just that thread.
            libc::setpriority(libc::PRIO_PROCESS, tid, 10);
            const IOPRIO_WHO_PROCESS: libc::c_long = 1;
            const IOPRIO_CLASS_BE: libc::c_long = 2;
            const IOPRIO_CLASS_SHIFT: libc::c_long = 13;
            libc::syscall(
                libc::SYS_ioprio_set,
                IOPRIO_WHO_PROCESS,
                tid as libc::c_long,
                (IOPRIO_CLASS_BE << IOPRIO_CLASS_SHIFT) | 7,
            );
        }
    }
    #[cfg(target_vendor = "apple")]
    {
        // Declared here because the libc crate does not export it publicly.
        unsafe extern "C" {
            fn pthread_set_qos_class_self_np(
                qos_class: u32,
                relative_priority: libc::c_int,
            ) -> libc::c_int;
        }
        const QOS_CLASS_UTILITY: u32 = 0x11;
        // SAFETY: affects only the calling thread; failures are ignored.
        unsafe {
            pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
        }
    }
}

/// Lowers the whole process. For short-lived helper processes such as the
/// background checker; call it first thing, before other threads start, so
/// that threads created later inherit the lower priority where the system
/// supports inheritance.
pub fn lower_current_process() {
    #[cfg(windows)]
    {
        use windows_sys::Win32::System::Threading::{
            GetCurrentProcess, SetPriorityClass, PROCESS_MODE_BACKGROUND_BEGIN,
        };
        // SAFETY: the pseudo-handle of the current process is always valid.
        unsafe {
            SetPriorityClass(GetCurrentProcess(), PROCESS_MODE_BACKGROUND_BEGIN);
        }
    }
    #[cfg(not(windows))]
    lower_current_thread();
}

/// A thread pool whose workers run at background priority.
pub fn background_pool(
    threads: usize,
    name: &'static str,
) -> Result<rayon::ThreadPool, rayon::ThreadPoolBuildError> {
    rayon::ThreadPoolBuilder::new()
        .num_threads(threads.max(1))
        .thread_name(move |i| format!("{name}-{i}"))
        .start_handler(|_| lower_current_thread())
        .build()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn background_pool_runs_work() {
        let pool = background_pool(2, "test").unwrap();
        let sum: u64 = pool.install(|| {
            use rayon::prelude::*;
            (1..=100u64).into_par_iter().sum()
        });
        assert_eq!(sum, 5050);
    }

    /// Windows refuses to enter background mode twice
    /// (ERROR_THREAD_MODE_ALREADY_BACKGROUND), which proves a thread is in it.
    #[cfg(windows)]
    fn in_background_mode() -> bool {
        use windows_sys::Win32::Foundation::{GetLastError, ERROR_THREAD_MODE_ALREADY_BACKGROUND};
        use windows_sys::Win32::System::Threading::{
            GetCurrentThread, SetThreadPriority, THREAD_MODE_BACKGROUND_BEGIN,
            THREAD_MODE_BACKGROUND_END,
        };
        // SAFETY: changes and restores the calling thread only.
        unsafe {
            if SetThreadPriority(GetCurrentThread(), THREAD_MODE_BACKGROUND_BEGIN) != 0 {
                SetThreadPriority(GetCurrentThread(), THREAD_MODE_BACKGROUND_END);
                return false;
            }
            GetLastError() == ERROR_THREAD_MODE_ALREADY_BACKGROUND
        }
    }

    #[cfg(windows)]
    #[test]
    fn workers_really_run_at_background_priority() {
        let pool = background_pool(1, "test").unwrap();
        assert!(
            pool.install(in_background_mode),
            "worker threads are in background mode"
        );
        assert!(!in_background_mode(), "the calling thread is untouched");
    }
}
