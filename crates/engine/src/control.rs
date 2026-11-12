//! Cooperative cancellation and pause/resume shared between the caller and
//! every worker thread of a running scan or action.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use parking_lot::{Condvar, Mutex};

use crate::error::{EngineError, Result};

#[derive(Clone, Default)]
pub struct ScanControl {
    inner: Arc<Inner>,
}

#[derive(Default)]
struct Inner {
    cancelled: AtomicBool,
    paused: AtomicBool,
    lock: Mutex<()>,
    wake: Condvar,
}

impl ScanControl {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        self.inner.cancelled.store(true, Ordering::SeqCst);
        // Paused workers must observe cancellation too.
        let _guard = self.inner.lock.lock();
        self.inner.wake.notify_all();
    }

    pub fn is_cancelled(&self) -> bool {
        self.inner.cancelled.load(Ordering::Relaxed)
    }

    pub fn pause(&self) {
        self.inner.paused.store(true, Ordering::SeqCst);
    }

    pub fn resume(&self) {
        self.inner.paused.store(false, Ordering::SeqCst);
        let _guard = self.inner.lock.lock();
        self.inner.wake.notify_all();
    }

    pub fn is_paused(&self) -> bool {
        self.inner.paused.load(Ordering::Relaxed)
    }

    /// Called by workers between units of work. Blocks while paused and
    /// returns [`EngineError::Cancelled`] once cancellation is requested.
    /// The fast path is two relaxed atomic loads.
    #[inline]
    pub fn checkpoint(&self) -> Result<()> {
        if self.is_cancelled() {
            return Err(EngineError::Cancelled);
        }
        if self.is_paused() {
            let mut guard = self.inner.lock.lock();
            while self.is_paused() && !self.is_cancelled() {
                // Timed wait guards against a missed notification.
                self.inner
                    .wake
                    .wait_for(&mut guard, Duration::from_millis(250));
            }
            if self.is_cancelled() {
                return Err(EngineError::Cancelled);
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    #[test]
    fn pause_blocks_until_resume() {
        let control = ScanControl::new();
        control.pause();
        let worker = {
            let control = control.clone();
            thread::spawn(move || control.checkpoint())
        };
        thread::sleep(Duration::from_millis(50));
        assert!(!worker.is_finished());
        control.resume();
        assert!(worker.join().unwrap().is_ok());
    }

    #[test]
    fn cancel_releases_paused_workers() {
        let control = ScanControl::new();
        control.pause();
        let worker = {
            let control = control.clone();
            thread::spawn(move || control.checkpoint())
        };
        control.cancel();
        assert!(matches!(
            worker.join().unwrap(),
            Err(EngineError::Cancelled)
        ));
    }
}
