//! Recovery bin, hash cache and platform information.

use anyhow::Result;
use digiclean_engine as engine;
use flutter_rust_bridge::frb;

use crate::api::types::*;
use crate::convert::lossy;

fn bin(roots: Vec<String>) -> Result<engine::RecoveryBin> {
    Ok(engine::RecoveryBin::new(
        roots.into_iter().map(Into::into).collect(),
    )?)
}

fn restore_dto(r: engine::recovery::RestoreReport) -> RestoreReportDto {
    RestoreReportDto {
        restored: r.restored,
        failed: r.failed,
        errors: r
            .errors
            .into_iter()
            .map(|(path, message)| IssueDto { path, message })
            .collect(),
    }
}

pub fn recovery_list(roots: Vec<String>) -> Result<Vec<RecoveryItemDto>> {
    Ok(bin(roots)?.list().into_iter().map(Into::into).collect())
}

pub fn recovery_restore(roots: Vec<String>, ids: Vec<String>) -> Result<RestoreReportDto> {
    Ok(restore_dto(bin(roots)?.restore(&ids)))
}

pub fn recovery_restore_batch(roots: Vec<String>, batch_id: String) -> Result<RestoreReportDto> {
    Ok(restore_dto(bin(roots)?.restore_batch(&batch_id)))
}

/// Permanently deletes items; returns bytes freed.
pub fn recovery_purge(roots: Vec<String>, ids: Vec<String>) -> Result<i64> {
    Ok(i(bin(roots)?.purge(&ids)))
}

pub fn recovery_purge_older_than(roots: Vec<String>, days: u32) -> Result<i64> {
    Ok(i(bin(roots)?.purge_older_than(days)))
}

pub fn recovery_purge_all(roots: Vec<String>) -> Result<i64> {
    Ok(i(bin(roots)?.purge_all()))
}

pub fn recovery_total_size(roots: Vec<String>) -> Result<i64> {
    Ok(i(bin(roots)?.total_size()))
}

/// Folders that scans must skip so the bin never scans itself.
#[frb(sync)]
pub fn recovery_protected_paths(roots: Vec<String>) -> Vec<String> {
    match bin(roots) {
        Ok(b) => b.protected_paths().iter().map(|p| lossy(p)).collect(),
        Err(_) => Vec::new(),
    }
}

pub fn cache_info(dir: String) -> Result<CacheInfo> {
    let cache = engine::HashCache::open(dir.as_ref())?;
    Ok(CacheInfo {
        entries: i(cache.entry_count()),
        size_bytes: i(cache.size_on_disk()),
        path: lossy(cache.path()),
    })
}

pub fn cache_clear(dir: String) -> Result<()> {
    let mut cache = engine::HashCache::open(dir.as_ref())?;
    cache.clear()?;
    cache.compact()?;
    Ok(())
}

pub fn cache_prune(dir: String, max_age_days: u32) -> Result<i64> {
    let cache = engine::HashCache::open(dir.as_ref())?;
    Ok(i(cache.prune(max_age_days)?))
}

/// What is in the system Recycle Bin / Trash, or `None` where there is none
/// (Android, iOS).
pub fn system_trash_info() -> Result<Option<TrashInfoDto>> {
    let info = engine::platform::system_trash_info().map_err(anyhow::Error::msg)?;
    Ok(info.map(|t| TrashInfoDto {
        items: i(t.items),
        bytes: t.bytes.map(i),
    }))
}

/// Permanently deletes everything in the system Recycle Bin / Trash.
pub fn empty_system_trash() -> Result<()> {
    engine::platform::empty_system_trash().map_err(anyhow::Error::msg)
}

/// Hashes a single file (used by the compare view to re-verify contents).
pub fn hash_file(path: String, algorithm: HashAlgo) -> Result<String> {
    let digest = engine::hashing::hash_file(path.as_ref(), algorithm.into())?;
    Ok(digest.iter().map(|b| format!("{b:02x}")).collect())
}

#[frb(sync)]
pub fn platform_capabilities() -> PlatformCapabilities {
    PlatformCapabilities {
        system_trash: engine::platform::supports_system_trash(),
        hardlinks: engine::platform::supports_hardlinks(),
        os: std::env::consts::OS.to_owned(),
        cores: engine::ScanConfig::cores() as u32,
        engine_version: env!("CARGO_PKG_VERSION").to_owned(),
    }
}

fn i(v: u64) -> i64 {
    v.min(i64::MAX as u64) as i64
}

// ── Storage ────────────────────────────────────────────────────────────

/// Drives with their capacity (desktop; empty on Android and iOS).
pub fn storage_volumes() -> Vec<VolumeDto> {
    engine::volumes::list()
        .into_iter()
        .map(|v| VolumeDto {
            path: lossy(&v.path),
            label: v.label,
            kind: v.kind.into(),
            total: crate::convert::i(v.usage.total),
            free: crate::convert::i(v.usage.free),
        })
        .collect()
}

/// Capacity of the volume holding `path`.
pub fn disk_usage(path: String) -> Option<DiskUsageDto> {
    engine::volumes::disk_usage(std::path::Path::new(&path)).map(|u| DiskUsageDto {
        total: crate::convert::i(u.total),
        free: crate::convert::i(u.free),
    })
}

/// Compresses `sources` into a verified `.zip` at `dest` (renamed if it
/// exists). The originals are not touched.
pub fn create_archive(sources: Vec<String>, dest: String) -> Result<ArchiveReportDto> {
    let sources: Vec<std::path::PathBuf> = sources.into_iter().map(Into::into).collect();
    let r = engine::archive::create_zip(
        &sources,
        std::path::Path::new(&dest),
        &engine::ScanControl::new(),
        &|_, _| {},
    )?;
    Ok(ArchiveReportDto {
        archive: lossy(&r.archive),
        files: crate::convert::i(r.files),
        folders: crate::convert::i(r.folders),
        original_bytes: crate::convert::i(r.original_bytes),
        archive_bytes: crate::convert::i(r.archive_bytes),
    })
}

/// Files and bytes below `path` (the path itself if it is a file).
fn tree_size(path: &std::path::Path) -> (u64, u64) {
    match std::fs::symlink_metadata(path) {
        Ok(m) if m.is_dir() => std::fs::read_dir(path)
            .map(|entries| {
                entries.flatten().fold((0, 0), |(n, b), e| {
                    let (en, eb) = tree_size(&e.path());
                    (n + en, b + eb)
                })
            })
            .unwrap_or((0, 0)),
        Ok(m) => (1, m.len()),
        Err(_) => (0, 0),
    }
}

/// Removes whole files or folders chosen outside a scan's lists (for
/// example originals after archiving): to the system trash, the recovery
/// bin or permanently, as `action` says.
pub fn remove_paths(
    paths: Vec<String>,
    action: ActionType,
    recovery_roots: Vec<String>,
) -> Result<PathsReportDto> {
    let caps = platform_capabilities();
    let system_trash = action == ActionType::Trash && caps.system_trash;
    let use_bin = matches!(action, ActionType::RecoveryBin)
        || (action == ActionType::Trash && !caps.system_trash);
    let bin = if use_bin {
        Some(bin(recovery_roots)?)
    } else {
        None
    };
    let batch_id = engine::recovery::new_id();
    let mut report = PathsReportDto {
        done: Vec::new(),
        bytes: 0,
        issues: Vec::new(),
        used_system_trash: system_trash,
        batch_id: None,
    };
    for p in paths {
        let path = std::path::PathBuf::from(&p);
        let (files, bytes) = tree_size(&path);
        let result: std::result::Result<(), String> = if system_trash {
            engine::platform::move_to_system_trash(std::slice::from_ref(&path))
        } else if let Some(bin) = &bin {
            bin.store(&path, &batch_id, bytes, files.max(1), None)
                .map(|_| ())
                .map_err(|e| e.to_string())
        } else if path.is_dir() {
            std::fs::remove_dir_all(&path).map_err(|e| e.to_string())
        } else {
            std::fs::remove_file(&path).map_err(|e| e.to_string())
        };
        match result {
            Ok(()) => {
                report.bytes += crate::convert::i(bytes);
                report.done.push(p);
            }
            Err(message) => report.issues.push(IssueDto { path: p, message }),
        }
    }
    if bin.is_some() && !report.done.is_empty() {
        report.batch_id = Some(batch_id);
    }
    Ok(report)
}

/// Moves files or folders into `dest_dir` (for example another drive),
/// keeping their names (made unique when taken). Across drives the data is
/// copied and checked before the original is removed.
pub fn move_paths(paths: Vec<String>, dest_dir: String) -> PathsReportDto {
    let dest_dir = std::path::PathBuf::from(dest_dir);
    let mut report = PathsReportDto {
        done: Vec::new(),
        bytes: 0,
        issues: Vec::new(),
        used_system_trash: false,
        batch_id: None,
    };
    for p in paths {
        let path = std::path::PathBuf::from(&p);
        let Some(name) = path.file_name() else {
            report.issues.push(IssueDto {
                path: p,
                message: "cannot move a drive root".into(),
            });
            continue;
        };
        let dest = engine::paths::unique_destination(&dest_dir.join(name));
        if engine::paths::starts_with(&dest, &path) {
            report.issues.push(IssueDto {
                path: p,
                message: "the destination is inside this folder".into(),
            });
            continue;
        }
        let (_, bytes) = tree_size(&path);
        match engine::recovery::move_path(&path, &dest) {
            Ok(()) => {
                report.bytes += crate::convert::i(bytes);
                report.done.push(p);
            }
            Err(e) => report.issues.push(IssueDto {
                path: p,
                message: e.to_string(),
            }),
        }
    }
    report
}

/// Whether the drive holding `path` can make copy-on-write clones:
/// `Some(false)` when it cannot, `None` when only trying tells.
#[frb(sync)]
pub fn clone_support(path: String) -> Option<bool> {
    engine::platform::clone_support(std::path::Path::new(&path))
}

/// The job file for the scheduled background check (`digiclean-check`):
/// the same scan the app runs, where to save results for the app, and the
/// "not duplicates" list. Returns JSON.
pub fn background_job_json(
    options: ScanOptions,
    snapshot: Option<String>,
    result: String,
    ignored: Vec<IgnoreKeyDto>,
) -> Result<String> {
    let algorithm = options.hash_algorithm;
    let digests = |kind: ResultKind| -> Vec<String> {
        ignored
            .iter()
            .filter(|k| k.kind == kind && k.algorithm == algorithm)
            .map(|k| k.digest.clone())
            .collect()
    };
    let job = engine::background::CheckJob {
        ignored_files: digests(ResultKind::Files),
        ignored_folders: digests(ResultKind::Folders),
        config: options.into(),
        snapshot: snapshot.filter(|s| !s.is_empty()).map(Into::into),
        result: result.into(),
        notify_min_bytes: 100 << 20,
        low_space_percent: 10,
    };
    Ok(serde_json::to_string_pretty(&job)?)
}

/// Groups similar images and flags blurry, dark and screenshot ones, for
/// image files outside a scan (previews of the iOS Photos library).
pub fn analyze_image_set(
    images: Vec<ImageInputDto>,
    cache_dir: Option<String>,
) -> Result<ImageSetAnalysisDto> {
    let inputs: Vec<engine::photos::ImageInput> = images
        .into_iter()
        .map(|i| engine::photos::ImageInput {
            path: i.path.into(),
            width: i.width,
            height: i.height,
            screenshot: i.screenshot,
        })
        .collect();
    let cache = cache_dir
        .filter(|d| !d.is_empty())
        .and_then(|d| engine::HashCache::open(std::path::Path::new(&d)).ok());
    let threads = std::thread::available_parallelism().map_or(2, |n| n.get());
    let pool = engine::priority::background_pool(threads, "digiclean-photos").map_err(|e| anyhow::anyhow!("{e}"))?;
    let out =
        engine::photos::analyze_set(&inputs, cache.as_ref(), &engine::ScanControl::new(), &pool)?;
    Ok(ImageSetAnalysisDto {
        groups: out
            .groups
            .into_iter()
            .map(|(members, best)| ImageGroupDto { members, best })
            .collect(),
        issues: out
            .issues
            .into_iter()
            .map(|(index, issues)| ImageIssuesDto {
                index,
                issues: issues.into_iter().map(Into::into).collect(),
            })
            .collect(),
        failed: out.failed as i64,
    })
}
