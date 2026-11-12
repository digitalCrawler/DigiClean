//! The background check that the system scheduler runs while the app is
//! closed: scan the user's locations, save the results for the app to
//! reopen, look at free space, and say whether a notification is worth it.
//!
//! The app writes a [`CheckJob`] file; `digiclean-cli check --job <file>`
//! runs it. Nothing is ever removed here.

use std::collections::HashSet;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::config::ScanConfig;
use crate::control::ScanControl;
use crate::error::{EngineError, Result};
use crate::hashing::Digest;
use crate::session::Session;

fn default_notify_min_bytes() -> u64 {
    100 << 20
}

fn default_low_space_percent() -> u8 {
    10
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CheckJob {
    pub config: ScanConfig,
    /// Where the app reopens its results from; `None` keeps them as they are.
    #[serde(default)]
    pub snapshot: Option<PathBuf>,
    /// Summary for the app (see [`CheckResult`]).
    pub result: PathBuf,
    /// Content hashes (hex) of groups marked "not duplicates".
    #[serde(default)]
    pub ignored_files: Vec<String>,
    #[serde(default)]
    pub ignored_folders: Vec<String>,
    /// Notify only when at least this much can be freed.
    #[serde(default = "default_notify_min_bytes")]
    pub notify_min_bytes: u64,
    /// A drive with less free space than this (percent) is "almost full".
    #[serde(default = "default_low_space_percent")]
    pub low_space_percent: u8,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct LowSpace {
    pub path: PathBuf,
    pub free: u64,
    pub total: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Notice {
    pub title: String,
    pub body: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CheckResult {
    pub checked_at_ms: i64,
    /// Space duplicates take up (keeping one copy of each).
    pub duplicate_bytes: u64,
    pub duplicate_groups: u64,
    pub junk_bytes: u64,
    pub low_space: Vec<LowSpace>,
    /// What to tell the user, if anything.
    pub notice: Option<Notice>,
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn digests(hex_list: &[String]) -> HashSet<Digest> {
    hex_list
        .iter()
        .filter_map(|h| hex::decode(h).ok()?.try_into().ok())
        .collect()
}

/// Binary units, as shown in the app.
fn human(bytes: u64) -> String {
    crate::report::human(bytes)
}

/// Runs a job: scans, saves results and the summary. Returns the summary.
pub fn run_check(job: &CheckJob, control: &ScanControl) -> Result<CheckResult> {
    if job.config.roots.is_empty() {
        return Err(EngineError::InvalidConfig("no locations to check".into()));
    }
    // Free space on each location's drive, once per drive.
    let mut seen = HashSet::new();
    let mut low_space = Vec::new();
    for root in &job.config.roots {
        let Some(usage) = crate::volumes::disk_usage(root) else {
            continue;
        };
        if !seen.insert((usage.total, usage.free)) {
            continue;
        }
        if usage.free * 100 < usage.total * u64::from(job.low_space_percent) {
            low_space.push(LowSpace {
                path: root.clone(),
                free: usage.free,
                total: usage.total,
            });
        }
    }

    let result = crate::run_scan(&job.config, control, None)?;
    let mut session = Session::new(result);
    session.set_ignored_content(&digests(&job.ignored_files), &digests(&job.ignored_folders));
    let summary = session.summary();
    let checked_at_ms = now_ms();
    if let Some(path) = &job.snapshot {
        crate::snapshot::save(&session, checked_at_ms, path)?;
    }

    let freeable = summary.file_wasted + summary.remaining_junk_bytes;
    let notice = if let Some(low) = low_space.first() {
        Some(Notice {
            title: "Your drive is almost full".into(),
            body: format!(
                "{} free of {}. DigiClean found {} you can free up.",
                human(low.free),
                human(low.total),
                human(freeable)
            ),
        })
    } else if freeable >= job.notify_min_bytes {
        Some(Notice {
            title: "Space to free up".into(),
            body: format!(
                "DigiClean found {} of duplicates and junk in your folders.",
                human(freeable)
            ),
        })
    } else {
        None
    };
    let out = CheckResult {
        checked_at_ms,
        duplicate_bytes: summary.file_wasted,
        duplicate_groups: summary.active_file_groups,
        junk_bytes: summary.remaining_junk_bytes,
        low_space,
        notice,
    };
    let json = serde_json::to_vec_pretty(&out).map_err(|e| EngineError::Other(e.to_string()))?;
    crate::snapshot::write_bytes(&json, &job.result)?;
    Ok(out)
}

/// Shows a system notification. Uses what each desktop already has:
/// Windows toasts through PowerShell, `osascript` on macOS, `notify-send`
/// on Linux. Text is passed through the environment, never a command line.
pub fn notify(notice: &Notice) -> std::result::Result<(), String> {
    use std::process::Command;
    let mut cmd = if cfg!(windows) {
        const SCRIPT: &str = "\
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null;\
$t = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02);\
$x = $t.GetElementsByTagName('text');\
$x.Item(0).AppendChild($t.CreateTextNode($env:DC_TITLE)) | Out-Null;\
$x.Item(1).AppendChild($t.CreateTextNode($env:DC_BODY)) | Out-Null;\
$id = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe';\
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($id).Show([Windows.UI.Notifications.ToastNotification]::new($t))";
        let mut c = Command::new("powershell.exe");
        c.args([
            "-NoProfile",
            "-NonInteractive",
            "-WindowStyle",
            "Hidden",
            "-Command",
            SCRIPT,
        ]);
        c
    } else if cfg!(target_os = "macos") {
        let mut c = Command::new("osascript");
        c.args([
            "-e",
            "display notification (system attribute \"DC_BODY\") with title (system attribute \"DC_TITLE\")",
        ]);
        c
    } else {
        let mut c = Command::new("notify-send");
        c.args(["--app-name=DigiClean", &notice.title, &notice.body]);
        c
    };
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    let status = cmd
        .env("DC_TITLE", &notice.title)
        .env("DC_BODY", &notice.body)
        .status()
        .map_err(|e| e.to_string())?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("notifier exited with {status}"))
    }
}
