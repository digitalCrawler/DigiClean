use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use digiclean_engine as engine;
use flutter_rust_bridge::frb;
use parking_lot::Mutex;

use crate::api::results::ScanResults;
use crate::api::types::*;
use crate::frb_generated::StreamSink;

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// Drives one scan at a time. Pause/resume/cancel are safe to call from the
/// UI thread while [`ScanController::start`] runs on a worker thread.
#[frb(opaque)]
pub struct ScanController {
    control: Mutex<engine::ScanControl>,
    running: AtomicBool,
    result: Mutex<Option<engine::ScanResult>>,
}

impl ScanController {
    #[frb(sync)]
    pub fn new() -> ScanController {
        ScanController {
            control: Mutex::new(engine::ScanControl::new()),
            running: AtomicBool::new(false),
            result: Mutex::new(None),
        }
    }

    /// Runs a scan, streaming progress events. The final event is
    /// `Completed`, `Cancelled` or `Failed`; after `Completed` the results
    /// are available from [`ScanController::take_results`].
    pub fn start(&self, options: ScanOptions, sink: StreamSink<ScanEvent>) -> anyhow::Result<()> {
        if self.running.swap(true, Ordering::SeqCst) {
            anyhow::bail!("a scan is already running");
        }
        let control = engine::ScanControl::new();
        *self.control.lock() = control.clone();
        *self.result.lock() = None;

        let progress_sink = sink.clone();
        let progress: Arc<dyn engine::ProgressSink> =
            Arc::new(move |snapshot: &engine::ProgressSnapshot| {
                let _ = progress_sink.add(ScanEvent {
                    kind: ScanEventKind::Progress,
                    progress: Some(snapshot.into()),
                    error: None,
                });
            });

        let config: engine::ScanConfig = options.into();
        let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            engine::run_scan(&config, &control, Some(progress))
        }));
        self.running.store(false, Ordering::SeqCst);

        let event = match outcome {
            Ok(Ok(result)) => {
                *self.result.lock() = Some(result);
                ScanEvent {
                    kind: ScanEventKind::Completed,
                    progress: None,
                    error: None,
                }
            }
            Ok(Err(engine::EngineError::Cancelled)) => ScanEvent {
                kind: ScanEventKind::Cancelled,
                progress: None,
                error: None,
            },
            Ok(Err(e)) => ScanEvent {
                kind: ScanEventKind::Failed,
                progress: None,
                error: Some(e.to_string()),
            },
            Err(_) => ScanEvent {
                kind: ScanEventKind::Failed,
                progress: None,
                error: Some("the scan engine stopped unexpectedly".into()),
            },
        };
        let _ = sink.add(event);
        Ok(())
    }

    #[frb(sync)]
    pub fn pause(&self) {
        self.control.lock().pause();
    }

    #[frb(sync)]
    pub fn resume(&self) {
        self.control.lock().resume();
    }

    #[frb(sync)]
    pub fn cancel(&self) {
        self.control.lock().cancel();
    }

    #[frb(sync)]
    pub fn is_paused(&self) -> bool {
        self.control.lock().is_paused()
    }

    #[frb(sync)]
    pub fn is_running(&self) -> bool {
        self.running.load(Ordering::SeqCst)
    }

    /// Hands over the results of the last completed scan (once).
    #[frb(sync)]
    pub fn take_results(&self) -> Option<ScanResults> {
        self.result.lock().take().map(ScanResults::from_result)
    }
}
