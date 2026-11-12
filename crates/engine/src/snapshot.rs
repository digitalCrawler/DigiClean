//! Saves a finished scan, together with what actions and the user changed
//! since (removed items, selection), so results survive an app restart.
//!
//! A compact, versioned binary format private to this machine: paths are
//! stored in the platform's native encoding. Any layout change bumps
//! [`VERSION`]; snapshots of another version are rejected and the caller
//! simply rescans. Saving encodes into memory first, so the session is only
//! borrowed briefly; the file is replaced atomically.

use std::ffi::{OsStr, OsString};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use crate::config::FileCategory;
use crate::error::{EngineError, Result};
use crate::junk::JunkKind;
use crate::model::{
    DirRecord, FileGroup, FileRecord, FolderGroup, JunkEntry, ScanResult, ScanStats, SymlinkEntry,
};
use crate::session::{ItemState, Session};

const MAGIC: &[u8; 8] = b"DCSNAP\0\0";
const VERSION: u32 = 3;

/// When the scan behind a snapshot finished, as given to [`encode`].
pub type FinishedMs = i64;

/// Serialises a session into snapshot bytes.
pub fn encode(session: &Session, finished_ms: FinishedMs) -> Vec<u8> {
    let r = &session.result;
    let mut w = Writer(Vec::with_capacity(
        64 + r.files.len() * 48 + r.dirs.len() * 64,
    ));
    w.raw(MAGIC);
    w.u32(VERSION);
    w.i64(finished_ms);
    w.json(&r.config);
    w.json(&r.stats);
    w.json(&r.issues);
    w.len(r.roots.len());
    for root in &r.roots {
        w.path(root);
    }
    w.len(r.dirs.len());
    for d in &r.dirs {
        w.u32(d.parent);
        w.path(&d.path);
        w.u32(d.depth);
        w.bool(d.complete);
        w.bool(d.is_root);
        w.i64(d.modified_ns);
        w.ids(&d.files);
        w.ids(&d.subdirs);
        w.len(d.symlinks.len());
        for s in &d.symlinks {
            w.os(&s.name);
            w.path(&s.target);
        }
        w.u32(d.junk_files);
    }
    w.len(r.files.len());
    for f in &r.files {
        w.u32(f.dir);
        w.os(&f.name);
        w.u64(f.size);
        w.i64(f.modified_ns);
        w.opt_i64(f.created_ns);
        match f.identity {
            Some((a, b)) => {
                w.bool(true);
                w.u64(a);
                w.u64(b);
            }
            None => w.bool(false),
        }
        w.bool(f.hidden);
        w.bool(f.eligible);
        w.category(f.category);
    }
    w.len(r.file_groups.len());
    for g in &r.file_groups {
        w.u64(g.size);
        w.raw(&g.digest);
        w.ids(&g.files);
        w.category(g.category);
    }
    w.len(r.folder_groups.len());
    for g in &r.folder_groups {
        w.raw(&g.digest);
        w.ids(&g.dirs);
        w.u64(g.total_bytes);
        w.u64(g.file_count);
        w.u64(g.dir_count);
    }
    w.ids(&r.empty_folders);
    w.ids(&r.large_files);
    w.len(r.junk.len());
    for j in &r.junk {
        w.u32(j.dir);
        w.os(&j.name);
        w.u64(j.size);
        w.i64(j.modified_ns);
        let kind = JunkKind::ALL.iter().position(|&k| k == j.kind).unwrap_or(0);
        w.0.push(kind as u8);
        w.u32(j.file);
    }

    // What changed after the scan.
    w.states(&session.file_state);
    w.states(&session.dir_state);
    w.bools(&session.dir_modified);
    w.bools(&session.dir_partial);
    w.bools(&session.file_selected);
    w.bools(&session.dir_selected);
    w.bools(&session.large_selected);
    w.bools(&session.old_selected);
    w.states(&session.junk_state);
    w.bools(&session.junk_selected);
    w.0
}

/// Writes a snapshot to `path`, replacing any previous one atomically.
pub fn save(session: &Session, finished_ms: FinishedMs, path: &Path) -> Result<()> {
    write_bytes(&encode(session, finished_ms), path)
}

/// Writes bytes from [`encode`] to `path` atomically, so a session lock is
/// not needed while the disk is written.
pub fn write_bytes(bytes: &[u8], path: &Path) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| EngineError::io(parent, e))?;
    }
    let tmp = path.with_extension("tmp");
    let mut file = fs::File::create(&tmp).map_err(|e| EngineError::io(&tmp, e))?;
    file.write_all(bytes)
        .and_then(|_| file.sync_all())
        .map_err(|e| EngineError::io(&tmp, e))?;
    drop(file);
    fs::rename(&tmp, path).map_err(|e| EngineError::io(path, e))
}

/// Reads a snapshot. Fails on damaged files or other format versions.
pub fn load(path: &Path) -> Result<(Session, FinishedMs)> {
    let bytes = fs::read(path).map_err(|e| EngineError::io(path, e))?;
    decode(&bytes).ok_or_else(|| EngineError::Other("saved results are unreadable".into()))
}

/// Parses snapshot bytes; `None` if they are damaged or of another version.
pub fn decode(bytes: &[u8]) -> Option<(Session, FinishedMs)> {
    let mut r = Reader { b: bytes, at: 0 };
    if r.raw(MAGIC.len())? != MAGIC || r.u32()? != VERSION {
        return None;
    }
    let finished_ms = r.i64()?;
    let config = r.json()?;
    let stats: ScanStats = r.json()?;
    let issues = r.json()?;
    let roots = (0..r.len()?)
        .map(|_| r.path())
        .collect::<Option<Vec<_>>>()?;
    let n_dirs = r.len()?;
    let mut dirs = Vec::with_capacity(n_dirs);
    for _ in 0..n_dirs {
        dirs.push(DirRecord {
            parent: r.u32()?,
            path: r.path()?,
            depth: r.u32()?,
            complete: r.bool()?,
            is_root: r.bool()?,
            modified_ns: r.i64()?,
            files: r.ids()?,
            subdirs: r.ids()?,
            symlinks: (0..r.len()?)
                .map(|_| {
                    Some(SymlinkEntry {
                        name: r.os()?.into_boxed_os_str(),
                        target: r.path()?,
                    })
                })
                .collect::<Option<Vec<_>>>()?,
            junk_files: r.u32()?,
        });
    }
    let n_files = r.len()?;
    let mut files = Vec::with_capacity(n_files);
    for _ in 0..n_files {
        files.push(FileRecord {
            dir: r.u32()?,
            name: r.os()?.into_boxed_os_str(),
            size: r.u64()?,
            modified_ns: r.i64()?,
            created_ns: r.opt_i64()?,
            identity: if r.bool()? {
                Some((r.u64()?, r.u64()?))
            } else {
                None
            },
            hidden: r.bool()?,
            eligible: r.bool()?,
            category: r.category()?,
        });
    }
    let file_groups = (0..r.len()?)
        .map(|_| {
            Some(FileGroup {
                size: r.u64()?,
                digest: r.digest()?,
                files: r.ids()?,
                category: r.category()?,
            })
        })
        .collect::<Option<Vec<_>>>()?;
    let folder_groups = (0..r.len()?)
        .map(|_| {
            Some(FolderGroup {
                digest: r.digest()?,
                dirs: r.ids()?,
                total_bytes: r.u64()?,
                file_count: r.u64()?,
                dir_count: r.u64()?,
            })
        })
        .collect::<Option<Vec<_>>>()?;
    let empty_folders = r.ids()?;
    let large_files = r.ids()?;
    let junk = (0..r.len()?)
        .map(|_| {
            Some(JunkEntry {
                dir: r.u32()?,
                name: r.os()?.into_boxed_os_str(),
                size: r.u64()?,
                modified_ns: r.i64()?,
                kind: *JunkKind::ALL.get(r.raw(1)?[0] as usize)?,
                file: r.u32()?,
            })
        })
        .collect::<Option<Vec<_>>>()?;

    // Every id must point inside the tables, or the session would panic.
    let (nd, nf) = (dirs.len(), files.len());
    let dir_ok = |d: u32| (d as usize) < nd;
    let file_ok = |f: u32| (f as usize) < nf;
    let ids_ok = dirs.iter().all(|d| {
        (d.parent == crate::model::NO_ID || dir_ok(d.parent))
            && d.files.iter().all(|&f| file_ok(f))
            && d.subdirs.iter().all(|&s| dir_ok(s))
    }) && files.iter().all(|f| dir_ok(f.dir))
        && file_groups
            .iter()
            .all(|g| !g.files.is_empty() && g.files.iter().all(|&f| file_ok(f)))
        && folder_groups
            .iter()
            .all(|g| !g.dirs.is_empty() && g.dirs.iter().all(|&d| dir_ok(d)))
        && empty_folders.iter().all(|&d| dir_ok(d))
        && large_files.iter().all(|&f| file_ok(f))
        && junk
            .iter()
            .all(|j| dir_ok(j.dir) && (j.file == crate::model::NO_ID || file_ok(j.file)));
    if !ids_ok {
        return None;
    }

    let result = ScanResult {
        config,
        roots,
        dirs,
        files,
        file_groups,
        folder_groups,
        empty_folders,
        large_files,
        junk,
        stats,
        issues,
    };
    let mut session = Session::new(result);
    let file_state = r.states(nf)?;
    let dir_state = r.states(nd)?;
    let dir_modified = r.bools(nd)?;
    let dir_partial = r.bools(nd)?;
    let file_selected = r.bools(nf)?;
    let dir_selected = r.bools(nd)?;
    let large_selected = r.bools(nf)?;
    let old_selected = r.bools(nf)?;
    let nj = session.result.junk.len();
    let junk_state = r.states(nj)?;
    let junk_selected = r.bools(nj)?;
    if r.at != bytes.len() {
        return None;
    }
    session.file_state = file_state;
    session.dir_state = dir_state;
    session.dir_modified = dir_modified;
    session.dir_partial = dir_partial;
    session.file_selected = file_selected;
    session.dir_selected = dir_selected;
    session.large_selected = large_selected;
    session.old_selected = old_selected;
    session.junk_state = junk_state;
    session.junk_selected = junk_selected;
    session.bump_generation();
    Some((session, finished_ms))
}

// ── Encoding ───────────────────────────────────────────────────────────

fn state_code(s: ItemState) -> u8 {
    match s {
        ItemState::Present => 0,
        ItemState::Removed => 1,
        ItemState::Moved => 2,
        ItemState::Linked => 3,
        ItemState::Ignored => 4,
    }
}

fn state_from(code: u8) -> Option<ItemState> {
    Some(match code {
        0 => ItemState::Present,
        1 => ItemState::Removed,
        2 => ItemState::Moved,
        3 => ItemState::Linked,
        4 => ItemState::Ignored,
        _ => return None,
    })
}

struct Writer(Vec<u8>);

impl Writer {
    fn raw(&mut self, b: &[u8]) {
        self.0.extend_from_slice(b);
    }
    fn u32(&mut self, v: u32) {
        self.raw(&v.to_le_bytes());
    }
    fn u64(&mut self, v: u64) {
        self.raw(&v.to_le_bytes());
    }
    fn i64(&mut self, v: i64) {
        self.raw(&v.to_le_bytes());
    }
    fn bool(&mut self, v: bool) {
        self.0.push(v as u8);
    }
    fn len(&mut self, n: usize) {
        self.u64(n as u64);
    }
    fn opt_i64(&mut self, v: Option<i64>) {
        self.bool(v.is_some());
        if let Some(v) = v {
            self.i64(v);
        }
    }
    fn bytes(&mut self, b: &[u8]) {
        self.len(b.len());
        self.raw(b);
    }
    fn os(&mut self, s: &OsStr) {
        self.bytes(&crate::paths::path_bytes(Path::new(s)));
    }
    fn path(&mut self, p: &Path) {
        self.bytes(&crate::paths::path_bytes(p));
    }
    fn ids(&mut self, ids: &[u32]) {
        self.len(ids.len());
        for &id in ids {
            self.u32(id);
        }
    }
    fn category(&mut self, c: FileCategory) {
        let i = FileCategory::ALL.iter().position(|&x| x == c).unwrap_or(0);
        self.0.push(i as u8);
    }
    fn json<T: serde::Serialize>(&mut self, v: &T) {
        self.bytes(&serde_json::to_vec(v).unwrap_or_default());
    }
    fn states(&mut self, s: &[ItemState]) {
        self.0.extend(s.iter().map(|&x| state_code(x)));
    }
    fn bools(&mut self, b: &[bool]) {
        self.0.extend(b.iter().map(|&x| x as u8));
    }
}

struct Reader<'a> {
    b: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    fn raw(&mut self, n: usize) -> Option<&'a [u8]> {
        let end = self.at.checked_add(n)?;
        let s = self.b.get(self.at..end)?;
        self.at = end;
        Some(s)
    }
    fn array<const N: usize>(&mut self) -> Option<[u8; N]> {
        self.raw(N)?.try_into().ok()
    }
    fn u32(&mut self) -> Option<u32> {
        Some(u32::from_le_bytes(self.array()?))
    }
    fn u64(&mut self) -> Option<u64> {
        Some(u64::from_le_bytes(self.array()?))
    }
    fn i64(&mut self) -> Option<i64> {
        Some(i64::from_le_bytes(self.array()?))
    }
    fn bool(&mut self) -> Option<bool> {
        match self.raw(1)?[0] {
            0 => Some(false),
            1 => Some(true),
            _ => None,
        }
    }
    /// A count, refused when larger than the bytes left could hold.
    fn len(&mut self) -> Option<usize> {
        let n = usize::try_from(self.u64()?).ok()?;
        (n <= self.b.len() - self.at).then_some(n)
    }
    fn opt_i64(&mut self) -> Option<Option<i64>> {
        Some(if self.bool()? {
            Some(self.i64()?)
        } else {
            None
        })
    }
    fn bytes(&mut self) -> Option<&'a [u8]> {
        let n = self.len()?;
        self.raw(n)
    }
    fn os(&mut self) -> Option<OsString> {
        os_from_bytes(self.bytes()?)
    }
    fn path(&mut self) -> Option<PathBuf> {
        self.os().map(PathBuf::from)
    }
    fn ids(&mut self) -> Option<Vec<u32>> {
        let n = self.len()?;
        (0..n).map(|_| self.u32()).collect()
    }
    fn digest(&mut self) -> Option<crate::hashing::Digest> {
        self.array()
    }
    fn category(&mut self) -> Option<FileCategory> {
        FileCategory::ALL.get(self.raw(1)?[0] as usize).copied()
    }
    fn json<T: serde::de::DeserializeOwned>(&mut self) -> Option<T> {
        serde_json::from_slice(self.bytes()?).ok()
    }
    fn states(&mut self, n: usize) -> Option<Vec<ItemState>> {
        self.raw(n)?.iter().map(|&c| state_from(c)).collect()
    }
    fn bools(&mut self, n: usize) -> Option<Vec<bool>> {
        self.raw(n)?
            .iter()
            .map(|&c| match c {
                0 => Some(false),
                1 => Some(true),
                _ => None,
            })
            .collect()
    }
}

/// Inverse of [`crate::paths::path_bytes`].
fn os_from_bytes(b: &[u8]) -> Option<OsString> {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        Some(OsStr::from_bytes(b).to_os_string())
    }
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStringExt;
        if b.len() % 2 != 0 {
            return None;
        }
        let wide: Vec<u16> = b
            .chunks_exact(2)
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .collect();
        Some(OsString::from_wide(&wide))
    }
    #[cfg(not(any(unix, windows)))]
    {
        String::from_utf8(b.to_vec()).ok().map(OsString::from)
    }
}
