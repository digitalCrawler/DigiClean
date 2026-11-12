//! App-managed recovery bin, available on every platform (Android and iOS
//! have no system trash for arbitrary files).
//!
//! Layout per bin root:
//! ```text
//! <root>/DigiCleanRecovery/items/<id>.json      metadata sidecar
//! <root>/DigiCleanRecovery/items/<id>/<name>    the moved file or folder
//! ```
//! A bin root is chosen on the same volume as the item whenever possible, so
//! "deleting" is an instant rename instead of a copy. The sidecar is written
//! before the move (state `pending`) and finalised after, so an interrupted
//! operation never loses track of a file.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::error::{EngineError, Result};
use crate::paths;

const BIN_DIR: &str = "DigiCleanRecovery";
const ITEMS_DIR: &str = "items";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ItemState {
    Pending,
    Stored,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecoveryItem {
    pub id: String,
    pub batch_id: String,
    pub original_path: String,
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
    pub file_count: u64,
    /// Seconds since the Unix epoch.
    pub deleted_at: u64,
    pub content_hash: Option<String>,
    pub state: ItemState,
    #[serde(skip)]
    pub bin_root: PathBuf,
}

impl RecoveryItem {
    pub fn payload_path(&self) -> PathBuf {
        items_dir(&self.bin_root).join(&self.id).join(&self.name)
    }

    fn sidecar_path(&self) -> PathBuf {
        items_dir(&self.bin_root).join(format!("{}.json", self.id))
    }

    fn container(&self) -> PathBuf {
        items_dir(&self.bin_root).join(&self.id)
    }
}

fn items_dir(root: &Path) -> PathBuf {
    root.join(BIN_DIR).join(ITEMS_DIR)
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

static COUNTER: AtomicU64 = AtomicU64::new(0);

/// Unique, sortable id: time, process and a counter.
pub fn new_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!(
        "{nanos:024x}-{:x}-{:x}",
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    )
}

#[derive(Debug, Clone)]
pub struct RecoveryBin {
    /// Candidate bin roots; the first is the fallback for items on volumes
    /// without a dedicated root.
    roots: Vec<PathBuf>,
}

#[derive(Debug, Default, Clone, Serialize)]
pub struct RestoreReport {
    pub restored: u32,
    pub failed: u32,
    pub errors: Vec<(String, String)>,
}

impl RecoveryBin {
    pub fn new(roots: Vec<PathBuf>) -> Result<Self> {
        if roots.is_empty() {
            return Err(EngineError::Recovery(
                "no recovery location configured".into(),
            ));
        }
        Ok(Self { roots })
    }

    pub fn roots(&self) -> &[PathBuf] {
        &self.roots
    }

    /// Directories that scans must never enter.
    pub fn protected_paths(&self) -> Vec<PathBuf> {
        self.roots.iter().map(|r| r.join(BIN_DIR)).collect()
    }

    fn root_for(&self, path: &Path) -> &Path {
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            if let Ok(meta) = fs::symlink_metadata(path) {
                for root in &self.roots {
                    if fs::create_dir_all(root).is_ok() {
                        if let Ok(rm) = fs::metadata(root) {
                            if rm.dev() == meta.dev() {
                                return root;
                            }
                        }
                    }
                }
            }
        }
        #[cfg(not(unix))]
        {
            let key = paths::volume_key(path);
            if key.is_some() {
                if let Some(root) = self.roots.iter().find(|r| paths::volume_key(r) == key) {
                    return root;
                }
            }
        }
        &self.roots[0]
    }

    /// Moves `path` into the bin and returns its record.
    pub fn store(
        &self,
        path: &Path,
        batch_id: &str,
        size: u64,
        file_count: u64,
        content_hash: Option<String>,
    ) -> Result<RecoveryItem> {
        let original = path
            .to_str()
            .ok_or_else(|| {
                EngineError::Recovery(format!("unsupported file name: {}", path.display()))
            })?
            .to_owned();
        let meta = fs::symlink_metadata(path).map_err(|e| EngineError::io(path, e))?;
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| "item".into());
        let mut item = RecoveryItem {
            id: new_id(),
            batch_id: batch_id.to_owned(),
            original_path: original,
            name,
            is_dir: meta.is_dir(),
            size,
            file_count,
            deleted_at: now_secs(),
            content_hash,
            state: ItemState::Pending,
            bin_root: self.root_for(path).to_path_buf(),
        };
        let container = item.container();
        fs::create_dir_all(&container).map_err(|e| EngineError::io(&container, e))?;
        write_sidecar(&item)?;

        match move_path(path, &item.payload_path()) {
            Ok(()) => {}
            Err(MoveError::Failed(e)) => {
                let _ = fs::remove_file(item.sidecar_path());
                let _ = fs::remove_dir_all(&container);
                return Err(EngineError::io(path, e));
            }
            Err(e @ MoveError::SourceRemains(_)) => {
                // Keep the complete copy recoverable.
                item.state = ItemState::Stored;
                write_sidecar(&item)?;
                return Err(EngineError::Recovery(format!("{}: {e}", path.display())));
            }
        }
        item.state = ItemState::Stored;
        write_sidecar(&item)?;
        Ok(item)
    }

    /// All items across every root, newest first. Interrupted operations
    /// are reconciled: a pending item with its payload present is kept, one
    /// without a payload is discarded.
    pub fn list(&self) -> Vec<RecoveryItem> {
        let mut out = Vec::new();
        for root in &self.roots {
            let dir = items_dir(root);
            let Ok(entries) = fs::read_dir(&dir) else {
                continue;
            };
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) != Some("json") {
                    continue;
                }
                let Ok(text) = fs::read_to_string(&path) else {
                    continue;
                };
                let Ok(mut item) = serde_json::from_str::<RecoveryItem>(&text) else {
                    continue;
                };
                item.bin_root = root.clone();
                if fs::symlink_metadata(item.payload_path()).is_err() {
                    if item.state == ItemState::Pending {
                        let _ = fs::remove_file(&path);
                        let _ = fs::remove_dir_all(item.container());
                    }
                    continue;
                }
                out.push(item);
            }
        }
        out.sort_by(|a, b| b.deleted_at.cmp(&a.deleted_at).then(b.id.cmp(&a.id)));
        out
    }

    fn find(&self, ids: &[String]) -> Vec<RecoveryItem> {
        let wanted: std::collections::HashSet<&str> = ids.iter().map(String::as_str).collect();
        self.list()
            .into_iter()
            .filter(|i| wanted.contains(i.id.as_str()))
            .collect()
    }

    /// Restores items to their original location. If something now occupies
    /// that path, the item is restored next to it with a numbered name.
    pub fn restore(&self, ids: &[String]) -> RestoreReport {
        let mut report = RestoreReport::default();
        for item in self.find(ids) {
            let target = paths::unique_destination(Path::new(&item.original_path));
            let result = (|| -> std::result::Result<(), String> {
                if let Some(parent) = target.parent() {
                    fs::create_dir_all(parent).map_err(|e| e.to_string())?;
                }
                // On SourceRemains the restored copy is complete but the bin
                // still holds data; keep the record so nothing is lost.
                move_path(&item.payload_path(), &target).map_err(|e| e.to_string())?;
                let _ = fs::remove_file(item.sidecar_path());
                let _ = fs::remove_dir_all(item.container());
                Ok(())
            })();
            match result {
                Ok(()) => report.restored += 1,
                Err(e) => {
                    report.failed += 1;
                    report.errors.push((item.original_path.clone(), e));
                }
            }
        }
        report
    }

    pub fn restore_batch(&self, batch_id: &str) -> RestoreReport {
        let ids: Vec<String> = self
            .list()
            .into_iter()
            .filter(|i| i.batch_id == batch_id)
            .map(|i| i.id)
            .collect();
        self.restore(&ids)
    }

    /// Permanently deletes items. Returns bytes freed.
    pub fn purge(&self, ids: &[String]) -> u64 {
        self.find(ids).iter().map(purge_item).sum()
    }

    pub fn purge_older_than(&self, days: u32) -> u64 {
        let cutoff = now_secs().saturating_sub(days as u64 * 86_400);
        self.list()
            .iter()
            .filter(|i| i.deleted_at < cutoff)
            .map(purge_item)
            .sum()
    }

    pub fn purge_all(&self) -> u64 {
        self.list().iter().map(purge_item).sum()
    }

    pub fn total_size(&self) -> u64 {
        self.list().iter().map(|i| i.size).sum()
    }
}

fn purge_item(item: &RecoveryItem) -> u64 {
    let payload = item.payload_path();
    let removed = if item.is_dir {
        fs::remove_dir_all(&payload)
    } else {
        fs::remove_file(&payload)
    };
    if removed.is_ok() || fs::symlink_metadata(&payload).is_err() {
        let _ = fs::remove_dir_all(item.container());
        let _ = fs::remove_file(item.sidecar_path());
        item.size
    } else {
        0
    }
}

fn write_sidecar(item: &RecoveryItem) -> Result<()> {
    let path = item.sidecar_path();
    let tmp = path.with_extension("json.tmp");
    let json = serde_json::to_vec_pretty(item).map_err(|e| EngineError::Recovery(e.to_string()))?;
    fs::write(&tmp, json).map_err(|e| EngineError::io(&tmp, e))?;
    fs::rename(&tmp, &path).map_err(|e| EngineError::io(&path, e))
}

#[derive(Debug)]
pub enum MoveError {
    /// Nothing changed; the destination holds no data.
    Failed(io::Error),
    /// The destination holds a complete copy but the source could not be
    /// (fully) removed. The destination must be kept — the source may be
    /// partially deleted already.
    SourceRemains(io::Error),
}

impl std::fmt::Display for MoveError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MoveError::Failed(e) => write!(f, "{e}"),
            MoveError::SourceRemains(e) => {
                write!(
                    f,
                    "copied, but the original could not be fully removed: {e}"
                )
            }
        }
    }
}

/// Renames when possible; falls back to copy + verify + delete across volumes.
pub fn move_path(from: &Path, to: &Path) -> std::result::Result<(), MoveError> {
    if let Some(parent) = to.parent() {
        fs::create_dir_all(parent).map_err(MoveError::Failed)?;
    }
    match fs::rename(from, to) {
        Ok(()) => return Ok(()),
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Err(MoveError::Failed(e)),
        Err(_) => {}
    }
    let meta = fs::symlink_metadata(from).map_err(MoveError::Failed)?;
    let copied = if meta.is_dir() {
        copy_dir(from, to)
    } else {
        fs::copy(from, to).and_then(|n| {
            if n == meta.len() {
                Ok(())
            } else {
                Err(io::Error::other("incomplete copy"))
            }
        })
    };
    if let Err(e) = copied {
        if meta.is_dir() {
            let _ = fs::remove_dir_all(to);
        } else {
            let _ = fs::remove_file(to);
        }
        return Err(MoveError::Failed(e));
    }
    let removed = if meta.is_dir() {
        fs::remove_dir_all(from)
    } else {
        fs::remove_file(from)
    };
    removed.map_err(MoveError::SourceRemains)
}

fn copy_dir(from: &Path, to: &Path) -> io::Result<()> {
    fs::create_dir_all(to)?;
    for entry in fs::read_dir(from)? {
        let entry = entry?;
        let ft = entry.file_type()?;
        let dest = to.join(entry.file_name());
        if ft.is_dir() {
            copy_dir(&entry.path(), &dest)?;
        } else if ft.is_file() {
            let len = entry.metadata()?.len();
            if fs::copy(entry.path(), &dest)? != len {
                return Err(io::Error::other("incomplete copy"));
            }
        } else {
            return Err(io::Error::other(format!(
                "cannot copy special file {}",
                entry.path().display()
            )));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn store_list_restore() {
        let data = tempfile::tempdir().unwrap();
        let bin_root = tempfile::tempdir().unwrap();
        let bin = RecoveryBin::new(vec![bin_root.path().to_path_buf()]).unwrap();

        let file = data.path().join("report.pdf");
        fs::write(&file, b"content").unwrap();
        let item = bin.store(&file, "b1", 7, 1, None).unwrap();
        assert!(!file.exists());
        assert!(item.payload_path().exists());

        let listed = bin.list();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].original_path, file.to_str().unwrap());

        let report = bin.restore_batch("b1");
        assert_eq!(report.restored, 1);
        assert_eq!(fs::read(&file).unwrap(), b"content");
        assert!(bin.list().is_empty());
    }

    #[test]
    fn restore_does_not_overwrite() {
        let data = tempfile::tempdir().unwrap();
        let bin_root = tempfile::tempdir().unwrap();
        let bin = RecoveryBin::new(vec![bin_root.path().to_path_buf()]).unwrap();
        let file = data.path().join("a.txt");
        fs::write(&file, b"old").unwrap();
        let item = bin.store(&file, "b", 3, 1, None).unwrap();
        fs::write(&file, b"new").unwrap();
        bin.restore(&[item.id]);
        assert_eq!(fs::read(&file).unwrap(), b"new");
        assert_eq!(fs::read(data.path().join("a (1).txt")).unwrap(), b"old");
    }

    #[test]
    fn folders_and_purge() {
        let data = tempfile::tempdir().unwrap();
        let bin_root = tempfile::tempdir().unwrap();
        let bin = RecoveryBin::new(vec![bin_root.path().to_path_buf()]).unwrap();
        let dir = data.path().join("album");
        fs::create_dir_all(dir.join("inner")).unwrap();
        fs::write(dir.join("inner/x.jpg"), b"xx").unwrap();
        let item = bin.store(&dir, "b", 2, 1, None).unwrap();
        assert!(item.is_dir);
        assert!(!dir.exists());
        assert_eq!(bin.total_size(), 2);
        assert_eq!(bin.purge(&[item.id]), 2);
        assert!(bin.list().is_empty());
    }

    #[test]
    fn copy_fallback_moves_directories() {
        let a = tempfile::tempdir().unwrap();
        let src = a.path().join("src");
        fs::create_dir_all(src.join("d")).unwrap();
        fs::write(src.join("d/f"), b"1").unwrap();
        let dst = a.path().join("dst");
        copy_dir(&src, &dst).unwrap();
        assert_eq!(fs::read(dst.join("d/f")).unwrap(), b"1");
    }
}
