//! Parallel directory walker.
//!
//! Every directory is a rayon task that reads its entries and spawns tasks
//! for its sub-directories, so slow directories (network shares, cold disks)
//! never stall the whole walk. Directory ids are allocated when a task is
//! spawned, which guarantees `child id > parent id` — later stages rely on
//! that to process trees bottom-up without recursion.

use std::collections::HashSet;
use std::ffi::OsStr;
use std::fs::{self, Metadata};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use parking_lot::Mutex;

use crate::config::{FileCategory, ScanConfig};
use crate::control::ScanControl;
use crate::error::{EngineError, Result};
use crate::filters::Filters;
use crate::junk::{self, JunkKind};
use crate::model::{DirRecord, FileRecord, JunkEntry, ScanIssue, SymlinkEntry, NO_ID};
use crate::paths;
use crate::platform::{self, FileIdentity};
use crate::progress::ProgressTracker;

const MAX_ISSUE_SAMPLES: usize = 1000;
/// Most junk items kept per scan (the largest).
const JUNK_LIMIT: usize = 100_000;

pub struct WalkOutput {
    pub roots: Vec<PathBuf>,
    pub dirs: Vec<DirRecord>,
    pub files: Vec<FileRecord>,
    pub junk: Vec<JunkEntry>,
}

/// Thread-safe, capped log of non-fatal problems.
#[derive(Default)]
pub struct IssueLog {
    count: AtomicU64,
    samples: Mutex<Vec<ScanIssue>>,
}

impl IssueLog {
    pub fn push(&self, path: &Path, message: impl std::fmt::Display) {
        self.count.fetch_add(1, Ordering::Relaxed);
        let mut samples = self.samples.lock();
        if samples.len() < MAX_ISSUE_SAMPLES {
            samples.push(ScanIssue {
                path: path.to_string_lossy().into_owned(),
                message: message.to_string(),
            });
        }
    }

    pub fn count(&self) -> u64 {
        self.count.load(Ordering::Relaxed)
    }

    pub fn into_samples(self) -> Vec<ScanIssue> {
        self.samples.into_inner()
    }
}

pub fn system_time_ns(t: SystemTime) -> i64 {
    match t.duration_since(UNIX_EPOCH) {
        Ok(d) => d.as_nanos().min(i64::MAX as u128) as i64,
        Err(e) => -(e.duration().as_nanos().min(i64::MAX as u128) as i64),
    }
}

struct DirBatch {
    id: u32,
    parent: u32,
    path: PathBuf,
    depth: u32,
    is_root: bool,
    complete: bool,
    modified_ns: i64,
    files: Vec<FileRecord>,
    subdirs: Vec<u32>,
    symlinks: Vec<SymlinkEntry>,
    junk: u32,
    /// Junk found here; `file` is an index into `files`.
    junk_entries: Vec<(JunkEntry, Option<usize>)>,
}

struct Walker<'a> {
    cfg: &'a ScanConfig,
    filters: &'a Filters,
    control: &'a ScanControl,
    progress: &'a ProgressTracker,
    issues: &'a IssueLog,
    /// Keep files that fail the filters, because folder comparison must see
    /// every file of a tree.
    keep_ineligible: bool,
    roots: Vec<PathBuf>,
    next_id: AtomicU32,
    batches: Mutex<Vec<DirBatch>>,
    /// Canonical targets of followed directory symlinks (loop protection).
    followed: Mutex<HashSet<PathBuf>>,
    /// Scan start, for the age rules of junk detection.
    now_ns: i64,
}

/// Normalises roots and drops any root nested inside another, which would
/// otherwise make every file inside it look like its own duplicate.
pub fn prepare_roots(roots: &[PathBuf]) -> Vec<PathBuf> {
    let mut normalized: Vec<PathBuf> = roots.iter().map(|r| paths::normalize(r)).collect();
    normalized.sort_by_key(|p| p.components().count());
    let mut out: Vec<PathBuf> = Vec::new();
    for root in normalized {
        if !out.iter().any(|kept| paths::starts_with(&root, kept)) {
            out.push(root);
        }
    }
    out
}

pub fn walk(
    cfg: &ScanConfig,
    filters: &Filters,
    control: &ScanControl,
    progress: &ProgressTracker,
    issues: &IssueLog,
    pool: &rayon::ThreadPool,
) -> Result<WalkOutput> {
    let walker = Walker {
        cfg,
        filters,
        control,
        progress,
        issues,
        // Every file is recorded: storage views need the whole picture.
        // Filters only decide what is compared as a duplicate.
        keep_ineligible: true,
        roots: prepare_roots(&cfg.roots),
        next_id: AtomicU32::new(0),
        batches: Mutex::new(Vec::new()),
        followed: Mutex::new(HashSet::new()),
        now_ns: system_time_ns(SystemTime::now()),
    };

    pool.scope(|scope| {
        for root in &walker.roots {
            match fs::metadata(root) {
                Ok(meta) if meta.is_dir() => {
                    let id = walker.next_id.fetch_add(1, Ordering::Relaxed);
                    let root = root.clone();
                    let w = &walker;
                    scope.spawn(move |s| w.visit(s, id, NO_ID, root, 0, true));
                }
                Ok(meta) if meta.is_file() => walker.add_loose_file(root, &meta),
                Ok(_) => issues.push(root, "not a regular file or folder"),
                Err(e) => issues.push(root, e),
            }
        }
    });

    control.checkpoint()?;
    let Walker {
        roots,
        batches,
        next_id,
        ..
    } = walker;
    assemble(roots, batches.into_inner(), next_id.into_inner())
}

fn assemble(roots: Vec<PathBuf>, mut batches: Vec<DirBatch>, count: u32) -> Result<WalkOutput> {
    batches.sort_unstable_by_key(|b| b.id);
    if batches.len() != count as usize {
        return Err(EngineError::Other(format!(
            "directory walk incomplete ({} of {count} folders)",
            batches.len()
        )));
    }
    let total_files: usize = batches.iter().map(|b| b.files.len()).sum();
    let mut files: Vec<FileRecord> = Vec::with_capacity(total_files);
    let mut dirs: Vec<DirRecord> = Vec::with_capacity(batches.len());
    let mut junk: Vec<JunkEntry> = Vec::new();
    for batch in batches {
        let mut ids = Vec::with_capacity(batch.files.len());
        for file in batch.files {
            ids.push(files.len() as u32);
            files.push(file);
        }
        for (mut entry, local) in batch.junk_entries {
            entry.file = local.map(|i| ids[i]).unwrap_or(NO_ID);
            junk.push(entry);
        }
        dirs.push(DirRecord {
            parent: batch.parent,
            path: batch.path,
            depth: batch.depth,
            complete: batch.complete,
            is_root: batch.is_root,
            modified_ns: batch.modified_ns,
            files: ids,
            subdirs: batch.subdirs,
            symlinks: batch.symlinks,
            junk_files: batch.junk,
        });
    }
    // Biggest first; a pathological tree cannot grow the list without bound.
    junk.sort_unstable_by_key(|j| std::cmp::Reverse(j.size));
    junk.truncate(JUNK_LIMIT);
    Ok(WalkOutput {
        roots,
        dirs,
        files,
        junk,
    })
}

impl<'a> Walker<'a> {
    fn visit<'s>(
        &'s self,
        scope: &rayon::Scope<'s>,
        id: u32,
        parent: u32,
        path: PathBuf,
        depth: u32,
        is_root: bool,
    ) {
        if self.control.checkpoint().is_err() {
            return;
        }
        self.progress
            .dirs_discovered
            .fetch_add(1, Ordering::Relaxed);
        self.progress.set_current(&path);

        let modified_ns = fs::metadata(&path)
            .and_then(|m| m.modified())
            .map(system_time_ns)
            .unwrap_or(0);
        let mut batch = DirBatch {
            id,
            parent,
            path,
            depth,
            is_root,
            complete: true,
            modified_ns,
            files: Vec::new(),
            subdirs: Vec::new(),
            symlinks: Vec::new(),
            junk: 0,
            junk_entries: Vec::new(),
        };

        match fs::read_dir(&batch.path) {
            Err(e) => {
                self.issue(&batch.path, e);
                batch.complete = false;
            }
            Ok(entries) => {
                for entry in entries {
                    let entry = match entry {
                        Ok(entry) => entry,
                        Err(e) => {
                            self.issue(&batch.path, e);
                            batch.complete = false;
                            continue;
                        }
                    };
                    let name = entry.file_name();
                    let child = entry.path();
                    let file_type = match entry.file_type() {
                        Ok(t) => t,
                        Err(e) => {
                            self.issue(&child, e);
                            batch.complete = false;
                            continue;
                        }
                    };

                    if file_type.is_symlink() {
                        self.on_symlink(scope, &mut batch, &name, child);
                    } else if file_type.is_dir() {
                        // Windows exposes attributes for free from the directory listing.
                        let meta = if cfg!(windows) {
                            entry.metadata().ok()
                        } else {
                            None
                        };
                        let hidden = platform::is_hidden(&name, meta.as_ref());
                        self.on_dir(scope, &mut batch, &name, child, hidden);
                    } else if file_type.is_file() {
                        match entry.metadata() {
                            Ok(meta) => self.on_file(&mut batch, &name, &child, &meta, None),
                            Err(e) => {
                                self.issue(&child, e);
                                batch.complete = false;
                            }
                        }
                    } else {
                        // Sockets, FIFOs, devices: not comparable content.
                        batch.complete = false;
                    }
                }
            }
        }
        self.batches.lock().push(batch);
    }

    fn on_dir<'s>(
        &'s self,
        scope: &rayon::Scope<'s>,
        batch: &mut DirBatch,
        name: &OsStr,
        child: PathBuf,
        hidden: bool,
    ) {
        if !self.filters.allow_dir(&child, name, hidden) {
            batch.complete = false;
            return;
        }
        let depth = batch.depth + 1;
        if !self.cfg.recursive || self.cfg.max_depth.is_some_and(|max| depth > max) {
            batch.complete = false;
            return;
        }
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        batch.subdirs.push(id);
        let parent = batch.id;
        scope.spawn(move |s| self.visit(s, id, parent, child, depth, false));
    }

    fn on_symlink<'s>(
        &'s self,
        scope: &rayon::Scope<'s>,
        batch: &mut DirBatch,
        name: &OsStr,
        child: PathBuf,
    ) {
        if !self.cfg.follow_symlinks {
            let target = fs::read_link(&child).unwrap_or_default();
            if junk::link_is_broken(&child) {
                self.add_broken_link(batch, name, &child);
            }
            batch.symlinks.push(SymlinkEntry {
                name: name.into(),
                target,
            });
            return;
        }
        match fs::metadata(&child) {
            Ok(meta) if meta.is_dir() => {
                let target = paths::normalize(&child);
                // Targets inside a scan root are scanned anyway; others are
                // visited once to break cycles.
                let inside_root = self.roots.iter().any(|r| paths::starts_with(&target, r));
                if inside_root || !self.followed.lock().insert(target) {
                    batch.complete = false;
                    return;
                }
                let hidden = platform::is_hidden(name, Some(&meta));
                self.on_dir(scope, batch, name, child, hidden);
            }
            Ok(meta) if meta.is_file() => {
                let identity = platform::identity_from_metadata(&meta);
                self.on_file(batch, name, &child, &meta, identity);
            }
            Ok(_) => batch.complete = false,
            Err(e) => {
                if e.kind() == std::io::ErrorKind::NotFound {
                    self.add_broken_link(batch, name, &child);
                }
                // Dangling link: still part of the folder's structure.
                batch.symlinks.push(SymlinkEntry {
                    name: name.into(),
                    target: fs::read_link(&child).unwrap_or_default(),
                });
            }
        }
    }

    fn on_file(
        &self,
        batch: &mut DirBatch,
        name: &OsStr,
        path: &Path,
        meta: &Metadata,
        identity_override: Option<FileIdentity>,
    ) {
        if platform::is_junk_file(name) {
            batch.junk += 1;
            if junk::is_system_cache(name) {
                batch.junk_entries.push((
                    self.junk_entry(batch, name, meta.len(), meta, JunkKind::SystemCache),
                    None,
                ));
            }
            return;
        }
        if self.filters.file_excluded(path)
            || (self.cfg.skip_cloud_placeholders && platform::is_cloud_placeholder(meta))
            || (self.cfg.skip_system_folders && platform::is_system_file(meta))
        {
            batch.complete = false;
            return;
        }

        let size = meta.len();
        let hidden = platform::is_hidden(name, Some(meta));
        let ext = paths::extension_lower(name);
        let eligible = self.filters.file_eligible(ext.as_deref(), size, hidden);
        self.progress
            .files_discovered
            .fetch_add(1, Ordering::Relaxed);
        self.progress
            .bytes_discovered
            .fetch_add(size, Ordering::Relaxed);

        let modified_ns = meta.modified().map(system_time_ns).unwrap_or(0);
        let junk_kind = junk::classify(name, size, modified_ns, self.now_ns).or_else(|| {
            (cfg!(windows) && ext.as_deref() == Some("lnk") && junk::shortcut_is_broken(path))
                .then_some(JunkKind::BrokenLink)
        });
        let junk_entry = junk_kind.map(|k| self.junk_entry(batch, name, size, meta, k));

        if !eligible && !self.keep_ineligible {
            // Not needed later, but the folder is not empty and not fully known.
            batch.complete = false;
            if let Some(entry) = junk_entry {
                batch.junk_entries.push((entry, None));
            }
            return;
        }
        if let Some(entry) = junk_entry {
            batch.junk_entries.push((entry, Some(batch.files.len())));
        }
        batch.files.push(FileRecord {
            dir: batch.id,
            name: name.into(),
            size,
            modified_ns,
            created_ns: meta.created().ok().map(system_time_ns),
            identity: identity_override.or_else(|| platform::identity_from_metadata(meta)),
            hidden,
            eligible,
            category: ext
                .as_deref()
                .map(FileCategory::from_extension)
                .unwrap_or(FileCategory::Other),
        });
    }

    fn junk_entry(
        &self,
        batch: &DirBatch,
        name: &OsStr,
        size: u64,
        meta: &Metadata,
        kind: JunkKind,
    ) -> JunkEntry {
        JunkEntry {
            dir: batch.id,
            name: name.into(),
            size,
            modified_ns: meta.modified().map(system_time_ns).unwrap_or(0),
            kind,
            file: NO_ID,
        }
    }

    fn add_broken_link(&self, batch: &mut DirBatch, name: &OsStr, link: &Path) {
        if let Ok(meta) = fs::symlink_metadata(link) {
            let entry = self.junk_entry(batch, name, 0, &meta, JunkKind::BrokenLink);
            batch.junk_entries.push((entry, None));
        }
    }

    /// A root that is a single file: tracked under a synthetic, incomplete
    /// parent so it can never be part of a folder comparison.
    fn add_loose_file(&self, path: &Path, meta: &Metadata) {
        let parent = path.parent().map(Path::to_path_buf).unwrap_or_default();
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let mut batch = DirBatch {
            id,
            parent: NO_ID,
            path: parent,
            depth: 0,
            is_root: true,
            complete: false,
            modified_ns: 0,
            files: Vec::new(),
            subdirs: Vec::new(),
            symlinks: Vec::new(),
            junk: 0,
            junk_entries: Vec::new(),
        };
        let name = path.file_name().unwrap_or_default().to_owned();
        self.on_file(&mut batch, &name, path, meta, None);
        batch.complete = false;
        self.batches.lock().push(batch);
    }

    fn issue(&self, path: &Path, e: impl std::fmt::Display) {
        self.progress.error();
        self.issues.push(path, e);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nested_roots_are_collapsed() {
        let dir = tempfile::tempdir().unwrap();
        let inner = dir.path().join("a").join("b");
        fs::create_dir_all(&inner).unwrap();
        let roots = prepare_roots(&[inner.clone(), dir.path().to_path_buf(), inner]);
        assert_eq!(roots, vec![paths::normalize(dir.path())]);
    }

    #[test]
    fn walk_records_tree() {
        let dir = tempfile::tempdir().unwrap();
        fs::create_dir_all(dir.path().join("sub/deeper")).unwrap();
        fs::write(dir.path().join("a.txt"), b"a").unwrap();
        fs::write(dir.path().join("sub/b.txt"), b"bb").unwrap();
        fs::write(dir.path().join("sub/deeper/c.txt"), b"ccc").unwrap();
        fs::write(dir.path().join("sub/Thumbs.db"), b"junk").unwrap();

        let cfg = ScanConfig {
            roots: vec![dir.path().to_path_buf()],
            ..Default::default()
        };
        let filters = Filters::new(&cfg).unwrap();
        let pool = rayon::ThreadPoolBuilder::new()
            .num_threads(2)
            .build()
            .unwrap();
        let issues = IssueLog::default();
        let out = walk(
            &cfg,
            &filters,
            &ScanControl::new(),
            &ProgressTracker::default(),
            &issues,
            &pool,
        )
        .unwrap();
        assert_eq!(out.dirs.len(), 3);
        assert_eq!(out.files.len(), 3);
        assert!(out.dirs.iter().all(|d| d.complete));
        assert_eq!(out.dirs.iter().map(|d| d.junk_files).sum::<u32>(), 1);
        for (id, d) in out.dirs.iter().enumerate() {
            for &child in &d.subdirs {
                assert!(child as usize > id);
            }
        }
    }

    #[test]
    fn depth_limit_marks_incomplete() {
        let dir = tempfile::tempdir().unwrap();
        fs::create_dir_all(dir.path().join("x/y")).unwrap();
        fs::write(dir.path().join("x/y/f"), b"f").unwrap();
        let cfg = ScanConfig {
            roots: vec![dir.path().to_path_buf()],
            max_depth: Some(1),
            ..Default::default()
        };
        let filters = Filters::new(&cfg).unwrap();
        let pool = rayon::ThreadPoolBuilder::new()
            .num_threads(1)
            .build()
            .unwrap();
        let out = walk(
            &cfg,
            &filters,
            &ScanControl::new(),
            &ProgressTracker::default(),
            &IssueLog::default(),
            &pool,
        )
        .unwrap();
        assert_eq!(out.dirs.len(), 2);
        assert_eq!(out.files.len(), 0);
        let x = out.dirs.iter().find(|d| d.path.ends_with("x")).unwrap();
        assert!(!x.complete);
    }
}
