//! Lock-free progress counters updated by workers and sampled at a fixed
//! interval by a reporter thread, so UI update frequency is independent of
//! how fast files are processed.

use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use parking_lot::Mutex;
use serde::Serialize;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
#[repr(u8)]
pub enum ScanPhase {
    Discovering = 0,
    GroupingBySize = 1,
    PartialHashing = 2,
    FullHashing = 3,
    Verifying = 4,
    AnalyzingFolders = 5,
    Finalizing = 6,
    Done = 7,
}

impl ScanPhase {
    fn from_u8(v: u8) -> Self {
        match v {
            0 => ScanPhase::Discovering,
            1 => ScanPhase::GroupingBySize,
            2 => ScanPhase::PartialHashing,
            3 => ScanPhase::FullHashing,
            4 => ScanPhase::Verifying,
            5 => ScanPhase::AnalyzingFolders,
            6 => ScanPhase::Finalizing,
            _ => ScanPhase::Done,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            ScanPhase::Discovering => "Discovering files",
            ScanPhase::GroupingBySize => "Grouping by size",
            ScanPhase::PartialHashing => "Quick fingerprinting",
            ScanPhase::FullHashing => "Hashing contents",
            ScanPhase::Verifying => "Verifying byte-by-byte",
            ScanPhase::AnalyzingFolders => "Comparing folders",
            ScanPhase::Finalizing => "Finalizing",
            ScanPhase::Done => "Done",
        }
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct ProgressSnapshot {
    pub phase: ScanPhase,
    pub files_discovered: u64,
    pub dirs_discovered: u64,
    pub bytes_discovered: u64,
    pub phase_items_done: u64,
    pub phase_items_total: u64,
    pub phase_bytes_done: u64,
    pub phase_bytes_total: u64,
    pub candidates: u64,
    pub cache_hits: u64,
    pub errors: u64,
    pub elapsed_ms: u64,
    /// Smoothed read throughput of the current phase.
    pub bytes_per_second: u64,
    pub eta_ms: Option<u64>,
    pub current_path: Option<String>,
    pub paused: bool,
}

pub trait ProgressSink: Send + Sync {
    fn on_progress(&self, snapshot: &ProgressSnapshot);
}

impl<F: Fn(&ProgressSnapshot) + Send + Sync> ProgressSink for F {
    fn on_progress(&self, snapshot: &ProgressSnapshot) {
        self(snapshot)
    }
}

#[derive(Default)]
pub struct ProgressTracker {
    phase: AtomicU8,
    pub files_discovered: AtomicU64,
    pub dirs_discovered: AtomicU64,
    pub bytes_discovered: AtomicU64,
    pub items_done: AtomicU64,
    pub items_total: AtomicU64,
    pub bytes_done: AtomicU64,
    pub bytes_total: AtomicU64,
    pub candidates: AtomicU64,
    pub cache_hits: AtomicU64,
    pub errors: AtomicU64,
    paused: AtomicBool,
    current: Mutex<Option<String>>,
}

impl ProgressTracker {
    pub fn set_phase(&self, phase: ScanPhase, items_total: u64, bytes_total: u64) {
        self.items_done.store(0, Ordering::Relaxed);
        self.bytes_done.store(0, Ordering::Relaxed);
        self.items_total.store(items_total, Ordering::Relaxed);
        self.bytes_total.store(bytes_total, Ordering::Relaxed);
        self.phase.store(phase as u8, Ordering::SeqCst);
    }

    pub fn phase(&self) -> ScanPhase {
        ScanPhase::from_u8(self.phase.load(Ordering::Relaxed))
    }

    #[inline]
    pub fn item_done(&self, bytes: u64) {
        self.items_done.fetch_add(1, Ordering::Relaxed);
        self.bytes_done.fetch_add(bytes, Ordering::Relaxed);
    }

    #[inline]
    pub fn add_bytes(&self, bytes: u64) {
        self.bytes_done.fetch_add(bytes, Ordering::Relaxed);
    }

    #[inline]
    pub fn error(&self) {
        self.errors.fetch_add(1, Ordering::Relaxed);
    }

    /// Records the path being worked on. Uses `try_lock` so contention never
    /// slows workers down; a skipped update is harmless.
    #[inline]
    pub fn set_current(&self, path: &Path) {
        if let Some(mut guard) = self.current.try_lock() {
            *guard = Some(path.to_string_lossy().into_owned());
        }
    }

    pub fn set_paused(&self, paused: bool) {
        self.paused.store(paused, Ordering::Relaxed);
    }

    fn snapshot(&self, elapsed: Duration, bytes_per_second: u64) -> ProgressSnapshot {
        let phase = self.phase();
        let bytes_done = self.bytes_done.load(Ordering::Relaxed);
        let bytes_total = self.bytes_total.load(Ordering::Relaxed);
        let eta_ms = if bytes_per_second > 0 && bytes_total > bytes_done {
            Some((bytes_total - bytes_done) * 1000 / bytes_per_second)
        } else {
            None
        };
        ProgressSnapshot {
            phase,
            files_discovered: self.files_discovered.load(Ordering::Relaxed),
            dirs_discovered: self.dirs_discovered.load(Ordering::Relaxed),
            bytes_discovered: self.bytes_discovered.load(Ordering::Relaxed),
            phase_items_done: self.items_done.load(Ordering::Relaxed),
            phase_items_total: self.items_total.load(Ordering::Relaxed),
            phase_bytes_done: bytes_done,
            phase_bytes_total: bytes_total,
            candidates: self.candidates.load(Ordering::Relaxed),
            cache_hits: self.cache_hits.load(Ordering::Relaxed),
            errors: self.errors.load(Ordering::Relaxed),
            elapsed_ms: elapsed.as_millis() as u64,
            bytes_per_second,
            eta_ms,
            current_path: self.current.lock().clone(),
            paused: self.paused.load(Ordering::Relaxed),
        }
    }
}

/// Background thread that periodically publishes snapshots.
pub struct Reporter {
    stop: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
}

impl Reporter {
    pub fn start(
        tracker: Arc<ProgressTracker>,
        sink: Arc<dyn ProgressSink>,
        interval: Duration,
        is_paused: impl Fn() -> bool + Send + 'static,
    ) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let stop_flag = stop.clone();
        let handle = std::thread::Builder::new()
            .name("digiclean-progress".into())
            .spawn(move || {
                let start = Instant::now();
                let mut last_phase = tracker.phase();
                let mut last_bytes = 0u64;
                let mut last_at = Instant::now();
                let mut rate = 0f64;
                loop {
                    let stopping = stop_flag.load(Ordering::SeqCst);
                    tracker.set_paused(is_paused());
                    let phase = tracker.phase();
                    let bytes = tracker.bytes_done.load(Ordering::Relaxed);
                    let now = Instant::now();
                    if phase != last_phase {
                        last_phase = phase;
                        last_bytes = bytes;
                        last_at = now;
                        rate = 0.0;
                    } else {
                        let dt = now.duration_since(last_at).as_secs_f64();
                        if dt > 0.0 {
                            let instant = bytes.saturating_sub(last_bytes) as f64 / dt;
                            // Exponential moving average keeps the ETA stable.
                            rate = if rate == 0.0 {
                                instant
                            } else {
                                rate * 0.7 + instant * 0.3
                            };
                            last_bytes = bytes;
                            last_at = now;
                        }
                    }
                    sink.on_progress(&tracker.snapshot(start.elapsed(), rate as u64));
                    if stopping {
                        break;
                    }
                    std::thread::park_timeout(interval);
                }
            })
            .expect("failed to spawn progress thread");
        Self {
            stop,
            handle: Some(handle),
        }
    }

    /// Stops the reporter after publishing one final snapshot.
    pub fn finish(mut self) {
        self.stop_inner();
    }

    fn stop_inner(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(handle) = self.handle.take() {
            handle.thread().unpark();
            let _ = handle.join();
        }
    }
}

impl Drop for Reporter {
    fn drop(&mut self) {
        self.stop_inner();
    }
}
