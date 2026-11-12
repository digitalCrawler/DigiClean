//! Compact in-memory representation of a scan. Files store only their name
//! and a directory index; full paths are rebuilt on demand, which keeps
//! memory proportional to the number of entries rather than path lengths.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::config::{FileCategory, ScanConfig};
use crate::hashing::Digest;
use crate::junk::JunkKind;
use crate::platform::FileIdentity;

pub const NO_ID: u32 = u32::MAX;

#[derive(Debug, Clone)]
pub struct FileRecord {
    pub dir: u32,
    pub name: Box<OsStr>,
    pub size: u64,
    /// Nanoseconds since the Unix epoch.
    pub modified_ns: i64,
    pub created_ns: Option<i64>,
    /// Known after the walk on Unix, after the first open on Windows.
    pub identity: Option<FileIdentity>,
    pub hidden: bool,
    /// Passes the user's filters and is reported as a duplicate candidate.
    /// Ineligible files are still recorded when folder analysis needs them.
    pub eligible: bool,
    pub category: FileCategory,
}

/// A junk item (see [`crate::junk`]). Kept apart from [`FileRecord`]s:
/// system caches and broken links have no record, while temporary or empty
/// files may also be regular scanned files (`file`).
#[derive(Debug, Clone)]
pub struct JunkEntry {
    pub dir: u32,
    pub name: Box<OsStr>,
    pub size: u64,
    pub modified_ns: i64,
    pub kind: JunkKind,
    /// The same file's [`FileRecord`], or [`NO_ID`].
    pub file: u32,
}

#[derive(Debug, Clone)]
pub struct SymlinkEntry {
    pub name: Box<OsStr>,
    pub target: PathBuf,
}

#[derive(Debug, Clone)]
pub struct DirRecord {
    pub parent: u32,
    pub path: PathBuf,
    pub depth: u32,
    /// Every entry of this directory was examined (no read errors, nothing
    /// skipped by filters, depth limits or hidden rules). Only complete trees
    /// can be compared as folders or reported as empty.
    pub complete: bool,
    /// The directory is a scan root (never reported or modified as a folder).
    pub is_root: bool,
    pub modified_ns: i64,
    pub files: Vec<u32>,
    pub subdirs: Vec<u32>,
    pub symlinks: Vec<SymlinkEntry>,
    /// Ignored OS metadata files (Thumbs.db, .DS_Store…) present here.
    pub junk_files: u32,
}

impl DirRecord {
    pub fn name(&self) -> &OsStr {
        self.path.file_name().unwrap_or(self.path.as_os_str())
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct FileGroup {
    pub size: u64,
    #[serde(serialize_with = "hex_digest")]
    pub digest: Digest,
    pub files: Vec<u32>,
    pub category: FileCategory,
}

impl FileGroup {
    /// Bytes reclaimable by keeping one copy.
    pub fn wasted(&self) -> u64 {
        self.size * (self.files.len().saturating_sub(1) as u64)
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct FolderGroup {
    #[serde(serialize_with = "hex_digest")]
    pub digest: Digest,
    pub dirs: Vec<u32>,
    pub total_bytes: u64,
    pub file_count: u64,
    pub dir_count: u64,
}

impl FolderGroup {
    pub fn wasted(&self) -> u64 {
        self.total_bytes * (self.dirs.len().saturating_sub(1) as u64)
    }
}

fn hex_digest<S: serde::Serializer>(d: &Digest, s: S) -> Result<S::Ok, S::Error> {
    s.serialize_str(&hex::encode(d))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScanIssue {
    pub path: String,
    pub message: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct ScanStats {
    pub files_seen: u64,
    pub dirs_seen: u64,
    pub bytes_seen: u64,
    pub eligible_files: u64,
    pub candidates_after_size: u64,
    pub candidates_after_partial: u64,
    pub files_fully_hashed: u64,
    pub bytes_hashed: u64,
    pub cache_hits: u64,
    pub hardlinks_skipped: u64,
    pub duplicate_groups: u64,
    pub duplicate_files: u64,
    pub wasted_bytes: u64,
    pub folder_groups: u64,
    pub folder_wasted_bytes: u64,
    pub empty_folders: u64,
    pub large_files: u64,
    /// Reported images that photo analysis can read.
    pub photos: u64,
    pub junk_items: u64,
    pub junk_bytes: u64,
    pub errors: u64,
    pub elapsed_ms: u64,
    pub hash_algorithm: String,
    pub cancelled: bool,
}

#[derive(Debug)]
pub struct ScanResult {
    pub config: ScanConfig,
    pub roots: Vec<PathBuf>,
    pub dirs: Vec<DirRecord>,
    pub files: Vec<FileRecord>,
    pub file_groups: Vec<FileGroup>,
    pub folder_groups: Vec<FolderGroup>,
    pub empty_folders: Vec<u32>,
    /// Biggest eligible files, largest first (capped).
    pub large_files: Vec<u32>,
    /// Junk found during the walk, largest first (capped).
    pub junk: Vec<JunkEntry>,
    pub stats: ScanStats,
    /// A capped sample of problems (unreadable files, permission errors).
    pub issues: Vec<ScanIssue>,
}

impl ScanResult {
    pub fn file_path(&self, id: u32) -> PathBuf {
        let f = &self.files[id as usize];
        self.dirs[f.dir as usize].path.join(&*f.name)
    }

    pub fn junk_path(&self, id: u32) -> PathBuf {
        let j = &self.junk[id as usize];
        self.dirs[j.dir as usize].path.join(&*j.name)
    }

    pub fn dir_path(&self, id: u32) -> &Path {
        &self.dirs[id as usize].path
    }

    /// The scan root containing a directory.
    pub fn root_of_dir(&self, mut id: u32) -> u32 {
        while !self.dirs[id as usize].is_root && self.dirs[id as usize].parent != NO_ID {
            id = self.dirs[id as usize].parent;
        }
        id
    }

    /// Visits `dir` and every directory below it.
    pub fn for_each_descendant(&self, dir: u32, mut f: impl FnMut(u32)) {
        let mut stack = vec![dir];
        while let Some(d) = stack.pop() {
            f(d);
            stack.extend(self.dirs[d as usize].subdirs.iter().copied());
        }
    }
}
