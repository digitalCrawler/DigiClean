//! Executes user actions on the current selection.
//!
//! Safety rules, checked against the live file system for every item and in
//! order, so that earlier operations in the same run are taken into account:
//!
//! * A file is only removed if a *kept* copy of its group (present and not
//!   selected) still exists with the size and mtime seen during the scan.
//! * A folder is only removed if a kept member of its group is present,
//!   unselected and *intact* — nothing inside it has been removed since the
//!   scan — and both folders still have the scanned file count and size.
//! * The target itself must be unchanged since the scan.
//! * Optionally, contents are re-hashed before removal.

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::control::ScanControl;
use crate::error::{EngineError, Result};
use crate::hashing;
use crate::junk;
use crate::model::NO_ID;
use crate::paths;
use crate::platform;
use crate::recovery::{self, RecoveryBin};
use crate::session::{ItemState, Session};
use crate::walker::system_time_ns;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActionKind {
    /// System trash on desktop; the app recovery bin on mobile.
    Trash,
    RecoveryBin,
    DeletePermanently,
    MoveTo,
    /// Replace duplicates with hard links to the kept copy (same volume only).
    ReplaceWithHardlink,
    /// Replace each duplicate by a copy-on-write clone of the kept copy:
    /// separate files that share their data until one is changed.
    ReplaceWithClone,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActionTarget {
    Files,
    Folders,
    EmptyFolders,
    /// Files picked from the large-files list. These are not duplicates: no
    /// kept copy is required, so the UI must make that explicit.
    LargeFiles,
    /// Files picked from the old-files list (no kept copy either).
    OldFiles,
    /// Similar photos: an unchanged photo of each set must remain.
    SimilarPhotos,
    /// Blurry, dark or screenshot images picked one by one.
    PhotoIssues,
    /// Items from the junk list (no kept copy either).
    Junk,
    /// Songs and videos with the same soundtrack: an unchanged copy of
    /// each set must remain.
    SimilarMedia,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ActionRequest {
    pub kind: ActionKind,
    pub target: ActionTarget,
    pub destination: Option<PathBuf>,
    /// For `MoveTo`: recreate the path relative to the scan root.
    pub keep_structure: bool,
    /// Re-hash targets and kept copies before removing anything.
    pub verify_content: bool,
}

#[derive(Clone, Debug, Serialize)]
pub struct ActionIssue {
    pub path: String,
    pub message: String,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct ActionReport {
    pub succeeded: u64,
    pub failed: u64,
    pub skipped: u64,
    /// Space released right away (permanent deletion, hard links).
    pub bytes_freed: u64,
    /// Moved to the system trash or the recovery bin: the space is released
    /// only when that bin is emptied.
    pub bytes_in_bin: u64,
    /// Moved to another folder (released on this drive only if the
    /// destination is on another drive).
    pub bytes_moved: u64,
    pub batch_id: Option<String>,
    pub used_system_trash: bool,
    pub issues: Vec<ActionIssue>,
    /// Paths that were removed, moved or linked (capped), so callers can
    /// refresh media indexes or undo.
    pub affected_paths: Vec<String>,
}

const MAX_AFFECTED: usize = 100_000;

impl ActionReport {
    fn success(&mut self, path: &Path, bytes: u64, kind: ActionKind) {
        self.succeeded += 1;
        match kind {
            ActionKind::DeletePermanently
            | ActionKind::ReplaceWithHardlink
            | ActionKind::ReplaceWithClone => self.bytes_freed += bytes,
            ActionKind::Trash | ActionKind::RecoveryBin => self.bytes_in_bin += bytes,
            ActionKind::MoveTo => self.bytes_moved += bytes,
        }
        if self.affected_paths.len() < MAX_AFFECTED {
            self.affected_paths
                .push(path.to_string_lossy().into_owned());
        }
    }

    fn issue(&mut self, path: &Path, message: impl Into<String>, skipped: bool) {
        if skipped {
            self.skipped += 1;
        } else {
            self.failed += 1;
        }
        if self.issues.len() < 500 {
            self.issues.push(ActionIssue {
                path: path.to_string_lossy().into_owned(),
                message: message.into(),
            });
        }
    }
}

const TRASH_BATCH: usize = 64;

/// `(done, total)` callback.
pub type ProgressFn<'a> = &'a (dyn Fn(u64, u64) + Sync);

fn unchanged(path: &Path, size: u64, modified_ns: i64) -> bool {
    match fs::symlink_metadata(path) {
        Ok(m) => {
            m.is_file()
                && m.len() == size
                && m.modified().map(system_time_ns).unwrap_or(0) == modified_ns
        }
        Err(_) => false,
    }
}

/// Counts regular non-junk files and their bytes below `dir`.
fn tree_summary(dir: &Path) -> Option<(u64, u64)> {
    let mut files = 0u64;
    let mut bytes = 0u64;
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        for entry in fs::read_dir(&d).ok()? {
            let entry = entry.ok()?;
            let ft = entry.file_type().ok()?;
            if ft.is_dir() {
                stack.push(entry.path());
            } else if ft.is_file() {
                if platform::is_junk_file(&entry.file_name()) {
                    continue;
                }
                files += 1;
                bytes += entry.metadata().ok()?.len();
            }
        }
    }
    Some((files, bytes))
}

/// True if `dir` contains nothing but folders and OS junk files.
fn still_empty(dir: &Path) -> bool {
    matches!(tree_summary(dir), Some((0, _)))
        && walk_all(dir)
            .iter()
            .all(|(p, is_dir)| *is_dir || platform::is_junk_file(p.file_name().unwrap_or_default()))
}

fn walk_all(dir: &Path) -> Vec<(PathBuf, bool)> {
    let mut out = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(entries) = fs::read_dir(&d) else {
            continue;
        };
        for entry in entries.flatten() {
            let is_dir = entry.file_type().map(|t| t.is_dir()).unwrap_or(false);
            if is_dir {
                stack.push(entry.path());
            }
            out.push((entry.path(), is_dir));
        }
    }
    out
}

/// Deletes an empty tree bottom-up, refusing anything but junk files.
fn remove_empty_tree(dir: &Path) -> std::io::Result<()> {
    let mut entries = walk_all(dir);
    // Deepest first.
    entries.sort_by_key(|(p, _)| std::cmp::Reverse(p.components().count()));
    for (path, is_dir) in entries {
        if is_dir {
            fs::remove_dir(&path)?;
        } else if platform::is_junk_file(path.file_name().unwrap_or_default()) {
            fs::remove_file(&path)?;
        } else {
            return Err(std::io::Error::other("folder is no longer empty"));
        }
    }
    fs::remove_dir(dir)
}

fn replace_with_clone(keeper: &Path, target: &Path) -> std::io::Result<()> {
    let name = target.file_name().unwrap_or_default().to_string_lossy();
    let tmp = target.with_file_name(format!(".{name}.digiclean-clone"));
    let _ = fs::remove_file(&tmp);
    if let Err(e) = reflink_copy::reflink(keeper, &tmp) {
        let _ = fs::remove_file(&tmp);
        return Err(e);
    }
    if let Err(e) = fs::rename(&tmp, target) {
        let _ = fs::remove_file(&tmp);
        return Err(e);
    }
    Ok(())
}

fn replace_with_hardlink(keeper: &Path, target: &Path) -> std::io::Result<()> {
    let name = target.file_name().unwrap_or_default().to_string_lossy();
    let tmp = target.with_file_name(format!(".{name}.digiclean-link"));
    let _ = fs::remove_file(&tmp);
    fs::hard_link(keeper, &tmp)?;
    if let Err(e) = fs::rename(&tmp, target) {
        let _ = fs::remove_file(&tmp);
        return Err(e);
    }
    Ok(())
}

struct Executor<'a> {
    session: &'a mut Session,
    request: &'a ActionRequest,
    bin: Option<&'a RecoveryBin>,
    control: &'a ScanControl,
    report: ActionReport,
    batch_id: String,
    use_system_trash: bool,
}

pub fn execute(
    session: &mut Session,
    request: &ActionRequest,
    bin: Option<&RecoveryBin>,
    control: &ScanControl,
    progress: ProgressFn<'_>,
) -> Result<ActionReport> {
    match request.kind {
        ActionKind::MoveTo if request.destination.is_none() => {
            return Err(EngineError::InvalidConfig(
                "choose a destination folder".into(),
            ))
        }
        ActionKind::ReplaceWithHardlink if request.target != ActionTarget::Files => {
            return Err(EngineError::InvalidConfig(
                "hard links can only replace files".into(),
            ))
        }
        ActionKind::ReplaceWithClone if request.target != ActionTarget::Files => {
            return Err(EngineError::InvalidConfig(
                "clones can only replace files".into(),
            ))
        }
        ActionKind::ReplaceWithClone
            if session
                .selected_files()
                .first()
                .map(|&f| {
                    session
                        .result
                        .dir_path(session.result.files[f as usize].dir)
                })
                .and_then(platform::clone_support)
                == Some(false) =>
        {
            return Err(EngineError::InvalidConfig(
                "this drive cannot make copy-on-write clones (APFS, Btrfs, XFS and ReFS can)"
                    .into(),
            ))
        }
        ActionKind::ReplaceWithHardlink if !platform::supports_hardlinks() => {
            return Err(EngineError::InvalidConfig(
                "hard links are not supported on this device".into(),
            ))
        }
        _ => {}
    }
    let use_system_trash = request.kind == ActionKind::Trash && platform::supports_system_trash();
    let needs_bin = request.kind == ActionKind::RecoveryBin
        || (request.kind == ActionKind::Trash && !use_system_trash);
    if needs_bin && bin.is_none() {
        return Err(EngineError::Recovery(
            "recovery bin is not configured".into(),
        ));
    }

    let mut exec = Executor {
        session,
        request,
        bin,
        control,
        report: ActionReport {
            used_system_trash: use_system_trash,
            ..Default::default()
        },
        batch_id: recovery::new_id(),
        use_system_trash,
    };
    match request.target {
        ActionTarget::Files => exec.run_files(progress)?,
        ActionTarget::Folders => exec.run_folders(progress)?,
        ActionTarget::EmptyFolders => exec.run_empty(progress)?,
        ActionTarget::LargeFiles => {
            let picked = exec.session.selected_large_files();
            exec.run_picked(picked, progress)?
        }
        ActionTarget::OldFiles => {
            let picked = exec.session.selected_old_files();
            exec.run_picked(picked, progress)?
        }
        ActionTarget::PhotoIssues => {
            let picked = exec.session.selected_photo_issues();
            exec.run_picked(picked, progress)?
        }
        ActionTarget::SimilarPhotos => exec.run_similar(false, progress)?,
        ActionTarget::SimilarMedia => exec.run_similar(true, progress)?,
        ActionTarget::Junk => exec.run_junk(progress)?,
    }
    exec.session.bump_generation();
    let mut report = exec.report;
    if needs_bin && report.succeeded > 0 {
        report.batch_id = Some(exec.batch_id);
    }
    Ok(report)
}

impl<'a> Executor<'a> {
    /// Performs the removal/move of one path. Returns the state to record.
    fn apply(
        &mut self,
        path: &Path,
        is_dir: bool,
        size: u64,
        file_count: u64,
        digest: Option<&[u8]>,
        keeper: Option<&Path>,
    ) -> std::result::Result<ItemState, String> {
        match self.request.kind {
            ActionKind::Trash if self.use_system_trash => {
                platform::move_to_system_trash(&[path.to_path_buf()])?;
                Ok(ItemState::Removed)
            }
            ActionKind::Trash | ActionKind::RecoveryBin => {
                let bin = self.bin.expect("checked in execute");
                bin.store(
                    path,
                    &self.batch_id,
                    size,
                    file_count,
                    digest.map(hex::encode),
                )
                .map(|_| ItemState::Removed)
                .map_err(|e| e.to_string())
            }
            ActionKind::DeletePermanently => {
                let r = if is_dir {
                    fs::remove_dir_all(path)
                } else {
                    fs::remove_file(path)
                };
                r.map(|_| ItemState::Removed).map_err(|e| e.to_string())
            }
            ActionKind::MoveTo => {
                let dest_root = self
                    .request
                    .destination
                    .as_ref()
                    .expect("checked in execute");
                let dest = if self.request.keep_structure {
                    self.structured_destination(dest_root, path)
                } else {
                    dest_root.join(path.file_name().unwrap_or_default())
                };
                if paths::starts_with(&dest, path) {
                    return Err("destination is inside the item being moved".into());
                }
                let dest = paths::unique_destination(&dest);
                recovery::move_path(path, &dest)
                    .map(|_| ItemState::Moved)
                    .map_err(|e| e.to_string())
            }
            ActionKind::ReplaceWithHardlink => {
                let keeper = keeper.ok_or("no copy to link to")?;
                replace_with_hardlink(keeper, path)
                    .map(|_| ItemState::Linked)
                    .map_err(|e| e.to_string())
            }
            ActionKind::ReplaceWithClone => {
                let keeper = keeper.ok_or("no copy to clone")?;
                replace_with_clone(keeper, path)
                    .map(|_| ItemState::Linked)
                    .map_err(|e| match e.kind() {
                        std::io::ErrorKind::Unsupported => {
                            "this drive cannot make copy-on-write clones".to_string()
                        }
                        _ => e.to_string(),
                    })
            }
        }
    }

    /// `<dest>/<root folder name>/<path relative to the root>`.
    fn structured_destination(&self, dest_root: &Path, path: &Path) -> PathBuf {
        let roots = &self.session.result.roots;
        for root in roots {
            if let Ok(rel) = path.strip_prefix(root) {
                let root_name = root
                    .file_name()
                    .map(|n| n.to_os_string())
                    .unwrap_or_else(|| "root".into());
                return dest_root.join(root_name).join(rel);
            }
        }
        dest_root.join(path.file_name().unwrap_or_default())
    }

    fn run_files(&mut self, progress: ProgressFn<'_>) -> Result<()> {
        let selected = self.session.selected_files();
        let total = selected.len() as u64;
        let algo = self.session.result.config.hash_algorithm;
        let mut done = 0u64;
        let mut pending: Vec<(u32, PathBuf, u64)> = Vec::new();
        progress(0, total);

        for f in selected {
            self.control.checkpoint()?;
            done += 1;
            let group = self.session.file_group_of(f);
            let path = self.session.result.file_path(f);
            let record = self.session.result.files[f as usize].clone();
            if group == NO_ID || self.session.file_state(f) != ItemState::Present {
                continue;
            }
            let digest = self.session.result.file_groups[group as usize].digest;

            // Find a kept copy that is verifiably still there.
            let keepers: Vec<u32> = self
                .session
                .present_files(group)
                .filter(|&m| !self.session.file_selected[m as usize])
                .collect();
            let keeper = keepers.into_iter().find(|&k| {
                let r = &self.session.result.files[k as usize];
                let kp = self.session.result.file_path(k);
                unchanged(&kp, r.size, r.modified_ns)
                    && (!self.request.verify_content
                        || hashing::hash_file(&kp, algo).is_ok_and(|d| d == digest))
            });
            let Some(keeper) = keeper else {
                self.report
                    .issue(&path, "skipped: no verified copy would remain", true);
                progress(done, total);
                continue;
            };
            if !unchanged(&path, record.size, record.modified_ns) {
                self.report.issue(
                    &path,
                    "skipped: file changed or missing since the scan",
                    true,
                );
                progress(done, total);
                continue;
            }
            if self.request.verify_content
                && !hashing::hash_file(&path, algo).is_ok_and(|d| d == digest)
            {
                self.report
                    .issue(&path, "skipped: content no longer matches", true);
                progress(done, total);
                continue;
            }

            if self.use_system_trash {
                // Keepers are never selected, so batching cannot remove one.
                pending.push((f, path, record.size));
                if pending.len() >= TRASH_BATCH {
                    self.flush_trash(&mut pending);
                    progress(done, total);
                }
                continue;
            }
            let keeper_path = self.session.result.file_path(keeper);
            match self.apply(
                &path,
                false,
                record.size,
                1,
                Some(&digest),
                Some(&keeper_path),
            ) {
                Ok(state) => {
                    self.session.mark_file(f, state);
                    self.report.success(&path, record.size, self.request.kind);
                }
                Err(message) => self.report.issue(&path, message, false),
            }
            progress(done, total);
        }
        self.flush_trash(&mut pending);
        progress(total, total);
        Ok(())
    }

    /// Sends files to the system trash in one call (much faster than one
    /// shell operation per file); on failure retries individually so each
    /// error is attributed to the right file.
    fn flush_trash(&mut self, pending: &mut Vec<(u32, PathBuf, u64)>) {
        self.flush_trash_with(pending, Session::mark_file);
    }

    /// Moves `pending` items to the system trash in one call, falling back
    /// to one at a time; `mark` records each success in the session.
    fn flush_trash_with(
        &mut self,
        pending: &mut Vec<(u32, PathBuf, u64)>,
        mark: fn(&mut Session, u32, ItemState),
    ) {
        if pending.is_empty() {
            return;
        }
        let paths: Vec<PathBuf> = pending.iter().map(|(_, p, _)| p.clone()).collect();
        if platform::move_to_system_trash(&paths).is_ok() {
            for (f, path, size) in pending.drain(..) {
                mark(self.session, f, ItemState::Removed);
                self.report.success(&path, size, self.request.kind);
            }
            return;
        }
        for (f, path, size) in pending.drain(..) {
            if fs::symlink_metadata(&path).is_err() {
                // Trashed by the batch call before it failed.
                mark(self.session, f, ItemState::Removed);
                self.report.success(&path, size, self.request.kind);
                continue;
            }
            match platform::move_to_system_trash(std::slice::from_ref(&path)) {
                Ok(()) => {
                    mark(self.session, f, ItemState::Removed);
                    self.report.success(&path, size, self.request.kind);
                }
                Err(message) => self.report.issue(&path, message, false),
            }
        }
    }

    /// Removes or moves files picked from the large-files list. There is no
    /// kept copy to verify; each file must still be exactly as scanned.
    fn run_picked(&mut self, selected: Vec<u32>, progress: ProgressFn<'_>) -> Result<()> {
        let total = selected.len() as u64;
        let mut pending: Vec<(u32, PathBuf, u64)> = Vec::new();
        progress(0, total);
        for (i, f) in selected.into_iter().enumerate() {
            self.control.checkpoint()?;
            let path = self.session.result.file_path(f);
            let record = self.session.result.files[f as usize].clone();
            if !unchanged(&path, record.size, record.modified_ns) {
                self.report.issue(
                    &path,
                    "skipped: file changed or missing since the scan",
                    true,
                );
            } else if self.use_system_trash {
                pending.push((f, path, record.size));
                if pending.len() >= TRASH_BATCH {
                    self.flush_trash(&mut pending);
                }
            } else {
                match self.apply(&path, false, record.size, 1, None, None) {
                    Ok(state) => {
                        self.session.mark_file(f, state);
                        self.report.success(&path, record.size, self.request.kind);
                    }
                    Err(message) => self.report.issue(&path, message, false),
                }
            }
            progress(i as u64 + 1, total);
        }
        self.flush_trash(&mut pending);
        progress(total, total);
        Ok(())
    }

    /// Removes or moves junk items. Each must still be what was scanned:
    /// the same size and time, and a broken link must still be broken.
    fn run_junk(&mut self, progress: ProgressFn<'_>) -> Result<()> {
        let selected = self.session.selected_junk();
        let total = selected.len() as u64;
        let mut pending: Vec<(u32, PathBuf, u64)> = Vec::new();
        progress(0, total);
        for (i, j) in selected.into_iter().enumerate() {
            self.control.checkpoint()?;
            let path = self.session.result.junk_path(j);
            let entry = self.session.result.junk[j as usize].clone();
            let is_link = fs::symlink_metadata(&path).is_ok_and(|m| m.file_type().is_symlink());
            let still_junk = if is_link {
                junk::link_is_broken(&path)
            } else {
                unchanged(&path, entry.size, entry.modified_ns)
            };
            if !still_junk {
                self.report
                    .issue(&path, "skipped: changed or missing since the scan", true);
            } else if self.use_system_trash {
                pending.push((j, path, entry.size));
                if pending.len() >= TRASH_BATCH {
                    self.flush_trash_with(&mut pending, Session::mark_junk);
                }
            } else {
                let result = if is_link && self.request.kind == ActionKind::DeletePermanently {
                    // A link to a folder is removed like a folder on Windows;
                    // either way only the link goes, never a target.
                    fs::remove_file(&path)
                        .or_else(|_| fs::remove_dir(&path))
                        .map(|_| ItemState::Removed)
                        .map_err(|e| e.to_string())
                } else {
                    self.apply(&path, false, entry.size, 1, None, None)
                };
                match result {
                    Ok(state) => {
                        self.session.mark_junk(j, state);
                        self.report.success(&path, entry.size, self.request.kind);
                    }
                    Err(message) => self.report.issue(&path, message, false),
                }
            }
            progress(i as u64 + 1, total);
        }
        self.flush_trash_with(&mut pending, Session::mark_junk);
        progress(total, total);
        Ok(())
    }

    /// Removes ticked similar photos while an unticked, unchanged photo of
    /// the same set stays.
    /// Removes ticked similar photos (`media` false) or songs and videos
    /// while an unticked, unchanged member of the same set stays.
    fn run_similar(&mut self, media: bool, progress: ProgressFn<'_>) -> Result<()> {
        let selected = if media {
            self.session.selected_media()
        } else {
            self.session.selected_similar()
        };
        let total = selected.len() as u64;
        progress(0, total);
        for (i, f) in selected.into_iter().enumerate() {
            self.control.checkpoint()?;
            let path = self.session.result.file_path(f);
            let record = self.session.result.files[f as usize].clone();
            let group = if media {
                self.session.media_group_of(f)
            } else {
                self.session.similar_group_of(f)
            };
            let keeper = group.and_then(|g| {
                let members = if media {
                    self.session.media_members(g)
                } else {
                    self.session.similar_members(g)
                };
                members.into_iter().find(|&m| {
                    let ticked = if media {
                        self.session.media_selected[m as usize]
                    } else {
                        self.session.similar_selected[m as usize]
                    };
                    m != f && !ticked && {
                        let r = &self.session.result.files[m as usize];
                        unchanged(&self.session.result.file_path(m), r.size, r.modified_ns)
                    }
                })
            });
            if keeper.is_none() {
                self.report.issue(
                    &path,
                    "skipped: no unchanged copy of this set would remain",
                    true,
                );
            } else if !unchanged(&path, record.size, record.modified_ns) {
                self.report.issue(
                    &path,
                    "skipped: file changed or missing since the scan",
                    true,
                );
            } else {
                match self.apply(&path, false, record.size, 1, None, None) {
                    Ok(state) => {
                        self.session.mark_file(f, state);
                        self.report.success(&path, record.size, self.request.kind);
                    }
                    Err(message) => self.report.issue(&path, message, false),
                }
            }
            progress(i as u64 + 1, total);
        }
        progress(total, total);
        Ok(())
    }

    fn folder_unchanged(&self, d: u32) -> bool {
        let path = self.session.result.dir_path(d);
        let expected = (self.session.tree_files(d), self.session.tree_bytes(d));
        tree_summary(path) == Some(expected)
    }

    fn run_folders(&mut self, progress: ProgressFn<'_>) -> Result<()> {
        let selected: Vec<u32> = (0..self.session.dir_selected.len() as u32)
            .filter(|&d| {
                self.session.dir_selected[d as usize]
                    && self.session.dir_state(d) == ItemState::Present
                    && self.session.folder_group_of(d) != NO_ID
            })
            .collect();
        let total = selected.len() as u64;
        progress(0, total);
        for (i, d) in selected.into_iter().enumerate() {
            self.control.checkpoint()?;
            let done = i as u64 + 1;
            if self.session.dir_state(d) != ItemState::Present {
                progress(done, total);
                continue;
            }
            let path = self.session.result.dir_path(d).to_path_buf();
            let group = self.session.folder_group_of(d);
            let keeper = self
                .session
                .present_dirs(group)
                .filter(|&m| {
                    !self.session.dir_selected[m as usize] && !self.session.dir_modified[m as usize]
                })
                .find(|&m| self.folder_unchanged(m));
            if keeper.is_none() {
                self.report.issue(
                    &path,
                    "skipped: no unchanged copy of this folder would remain",
                    true,
                );
                progress(done, total);
                continue;
            }
            if self.session.dir_modified[d as usize] || !self.folder_unchanged(d) {
                self.report
                    .issue(&path, "skipped: folder changed since the scan", true);
                progress(done, total);
                continue;
            }
            let size = self.session.tree_bytes(d);
            let count = self.session.tree_files(d);
            match self.apply(&path, true, size, count, None, None) {
                Ok(state) => {
                    self.session.mark_dir_tree(d, state);
                    self.report.success(&path, size, self.request.kind);
                }
                Err(message) => self.report.issue(&path, message, false),
            }
            progress(done, total);
        }
        Ok(())
    }

    fn run_empty(&mut self, progress: ProgressFn<'_>) -> Result<()> {
        let selected: Vec<u32> = (0..self.session.dir_selected.len() as u32)
            .filter(|&d| {
                self.session.dir_selected[d as usize]
                    && self.session.dir_state(d) == ItemState::Present
                    && self.session.is_empty_entry[d as usize]
            })
            .collect();
        let total = selected.len() as u64;
        progress(0, total);
        for (i, d) in selected.into_iter().enumerate() {
            self.control.checkpoint()?;
            let path = self.session.result.dir_path(d).to_path_buf();
            if !still_empty(&path) {
                self.report
                    .issue(&path, "skipped: folder is no longer empty", true);
            } else {
                let result = if self.request.kind == ActionKind::DeletePermanently {
                    remove_empty_tree(&path)
                        .map(|_| ItemState::Removed)
                        .map_err(|e| e.to_string())
                } else {
                    self.apply(&path, true, 0, 0, None, None)
                };
                match result {
                    Ok(state) => {
                        self.session.mark_dir_tree(d, state);
                        self.report.success(&path, 0, self.request.kind);
                    }
                    Err(message) => self.report.issue(&path, message, false),
                }
            }
            progress(i as u64 + 1, total);
        }
        Ok(())
    }
}
