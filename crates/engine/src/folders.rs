//! Duplicate-folder and empty-folder detection.
//!
//! Two folders are duplicates when their complete trees are identical:
//! the same relative names, the same structure and byte-identical files.
//! This is decided with Merkle hashes, in two passes:
//!
//! 1. A *structure signature* (names, sizes, sub-signatures) computed from
//!    metadata alone. Folders with a unique signature cannot be duplicates.
//! 2. A *content hash* (names + file digests) for the remaining candidates.
//!    Only files inside candidate folders that were not already hashed by
//!    the file pipeline are read here.
//!
//! Directory ids satisfy `child > parent`, so iterating ids in descending
//! order visits every child before its parent.

use std::collections::{HashMap, HashSet};
use std::path::Path;

use rayon::prelude::*;

use crate::cache::{CacheEntry, HashCache};
use crate::config::ScanConfig;
use crate::control::ScanControl;
use crate::error::{EngineError, Result};
use crate::hashing::{self, Digest};
use crate::model::{DirRecord, FileRecord, FolderGroup, NO_ID};
use crate::paths;
use crate::progress::{ProgressTracker, ScanPhase};
use crate::walker::IssueLog;

const KIND_FILE: u8 = 1;
const KIND_DIR: u8 = 2;
const KIND_LINK: u8 = 3;

pub struct FolderAnalysis {
    pub groups: Vec<FolderGroup>,
    pub empty: Vec<u32>,
    /// Hashes computed here, to be written to the cache.
    pub new_cache_entries: Vec<(std::path::PathBuf, CacheEntry)>,
    pub files_hashed: u64,
    pub bytes_hashed: u64,
}

/// Recursive aggregates for every directory.
pub struct TreeStats {
    pub complete: Vec<bool>,
    pub empty: Vec<bool>,
    pub files: Vec<u64>,
    pub bytes: Vec<u64>,
    pub dirs: Vec<u64>,
}

pub fn tree_stats(dirs: &[DirRecord], files: &[FileRecord]) -> TreeStats {
    let n = dirs.len();
    let mut s = TreeStats {
        complete: vec![false; n],
        empty: vec![false; n],
        files: vec![0; n],
        bytes: vec![0; n],
        dirs: vec![0; n],
    };
    for d in (0..n).rev() {
        let dir = &dirs[d];
        let mut complete = dir.complete;
        let mut empty = dir.files.is_empty() && dir.symlinks.is_empty();
        let mut fcount = dir.files.len() as u64;
        let mut bytes: u64 = dir.files.iter().map(|&f| files[f as usize].size).sum();
        let mut dcount = dir.subdirs.len() as u64;
        for &sub in &dir.subdirs {
            let sub = sub as usize;
            complete &= s.complete[sub];
            empty &= s.empty[sub];
            fcount += s.files[sub];
            bytes += s.bytes[sub];
            dcount += s.dirs[sub];
        }
        s.complete[d] = complete;
        s.empty[d] = empty && complete;
        s.files[d] = fcount;
        s.bytes[d] = bytes;
        s.dirs[d] = dcount;
    }
    s
}

/// Top-most empty folders (excluding scan roots).
pub fn empty_folders(dirs: &[DirRecord], stats: &TreeStats) -> Vec<u32> {
    (0..dirs.len())
        .filter(|&d| {
            let dir = &dirs[d];
            if dir.is_root || !stats.empty[d] {
                return false;
            }
            let parent = dir.parent;
            // Report the outermost empty folder only; deleting it removes the rest.
            !(parent != NO_ID && !dirs[parent as usize].is_root && stats.empty[parent as usize])
        })
        .map(|d| d as u32)
        .collect()
}

struct Entry<'a> {
    kind: u8,
    name: Vec<u8>,
    payload: std::borrow::Cow<'a, [u8]>,
}

fn merkle(mut entries: Vec<Entry<'_>>) -> Digest {
    entries.sort_unstable_by(|a, b| a.name.cmp(&b.name).then(a.kind.cmp(&b.kind)));
    let mut h = blake3::Hasher::new();
    h.update(&(entries.len() as u64).to_le_bytes());
    for e in &entries {
        h.update(&[e.kind]);
        h.update(&(e.name.len() as u64).to_le_bytes());
        h.update(&e.name);
        h.update(&(e.payload.len() as u64).to_le_bytes());
        h.update(&e.payload);
    }
    *h.finalize().as_bytes()
}

fn name_bytes(name: &std::ffi::OsStr) -> Vec<u8> {
    paths::path_bytes(Path::new(name))
}

fn link_payload(target: &Path) -> Vec<u8> {
    blake3::hash(&paths::path_bytes(target)).as_bytes().to_vec()
}

#[allow(clippy::too_many_arguments)]
pub fn analyze(
    cfg: &ScanConfig,
    dirs: &[DirRecord],
    files: &[FileRecord],
    digests: &mut HashMap<u32, Digest>,
    cache: Option<&HashCache>,
    control: &ScanControl,
    progress: &ProgressTracker,
    issues: &IssueLog,
    pool: &rayon::ThreadPool,
) -> Result<FolderAnalysis> {
    let stats = tree_stats(dirs, files);
    let mut out = FolderAnalysis {
        groups: Vec::new(),
        empty: if cfg.detect_empty_folders {
            empty_folders(dirs, &stats)
        } else {
            Vec::new()
        },
        new_cache_entries: Vec::new(),
        files_hashed: 0,
        bytes_hashed: 0,
    };
    if !cfg.folder_analysis_enabled() {
        return Ok(out);
    }

    // Pass 1: structure signatures from metadata.
    let n = dirs.len();
    let mut signature: Vec<Option<Digest>> = vec![None; n];
    for d in (0..n).rev() {
        if !stats.complete[d] {
            continue;
        }
        let dir = &dirs[d];
        let mut entries = Vec::with_capacity(dir.files.len() + dir.subdirs.len());
        for &f in &dir.files {
            let file = &files[f as usize];
            entries.push(Entry {
                kind: KIND_FILE,
                name: name_bytes(&file.name),
                payload: file.size.to_le_bytes().to_vec().into(),
            });
        }
        for link in &dir.symlinks {
            entries.push(Entry {
                kind: KIND_LINK,
                name: name_bytes(&link.name),
                payload: link_payload(&link.target).into(),
            });
        }
        for &sub in &dir.subdirs {
            let sig = signature[sub as usize].expect("complete subtree has a signature");
            entries.push(Entry {
                kind: KIND_DIR,
                name: name_bytes(dirs[sub as usize].name()),
                payload: sig.to_vec().into(),
            });
        }
        signature[d] = Some(merkle(entries));
    }

    let mut by_signature: HashMap<Digest, Vec<u32>> = HashMap::new();
    for (d, sig) in signature.iter().enumerate() {
        if let (Some(sig), true) = (sig, stats.files[d] > 0) {
            by_signature.entry(*sig).or_default().push(d as u32);
        }
    }
    let candidates: Vec<u32> = by_signature
        .into_values()
        .filter(|g| g.len() > 1)
        .flatten()
        .collect();
    if candidates.is_empty() {
        return Ok(out);
    }

    // Every directory inside a candidate needs a content hash.
    let mut in_scope = vec![false; n];
    let mut stack: Vec<u32> = candidates.clone();
    while let Some(d) = stack.pop() {
        if std::mem::replace(&mut in_scope[d as usize], true) {
            continue;
        }
        stack.extend(dirs[d as usize].subdirs.iter().copied());
    }

    // Pass 2a: hash files in scope that the file pipeline did not hash.
    let algo = cfg.hash_algorithm;
    let empty = hashing::empty_digest(algo);
    let mut needed: Vec<u32> = Vec::new();
    for d in 0..n {
        if !in_scope[d] {
            continue;
        }
        for &f in &dirs[d].files {
            if digests.contains_key(&f) {
                continue;
            }
            if files[f as usize].size == 0 {
                digests.insert(f, empty);
            } else {
                needed.push(f);
            }
        }
    }

    if !needed.is_empty() {
        let path_of = |f: u32| {
            let file = &files[f as usize];
            dirs[file.dir as usize].path.join(&*file.name)
        };
        let lookups: Vec<_> = needed
            .iter()
            .map(|&f| {
                let file = &files[f as usize];
                (path_of(f), file.size, file.modified_ns, file.identity)
            })
            .collect();
        let hits = cache.map(|c| c.lookup_many(&lookups));
        let mut work: Vec<(u32, usize)> = Vec::new();
        for (i, &f) in needed.iter().enumerate() {
            match hits
                .as_ref()
                .and_then(|h| h[i])
                .and_then(|e| e.full_for(algo))
            {
                Some(d) => {
                    progress
                        .cache_hits
                        .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    digests.insert(f, d);
                }
                None => work.push((f, i)),
            }
        }
        work.sort_unstable_by_key(|&(f, _)| std::cmp::Reverse(files[f as usize].size));
        let total_bytes: u64 = work.iter().map(|&(f, _)| files[f as usize].size).sum();
        progress.set_phase(ScanPhase::AnalyzingFolders, work.len() as u64, total_bytes);

        let computed: Vec<Option<Digest>> = pool.install(|| {
            work.par_iter()
                .map(|&(f, i)| {
                    let file = &files[f as usize];
                    let path = &lookups[i].0;
                    progress.set_current(path);
                    match hashing::full_hash(path, file.size, algo, control, progress) {
                        Ok(d) => {
                            progress
                                .items_done
                                .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                            Ok(Some(d))
                        }
                        Err(EngineError::Cancelled) => Err(EngineError::Cancelled),
                        Err(e) => {
                            progress.error();
                            issues.push(path, e);
                            Ok(None)
                        }
                    }
                })
                .collect::<Result<Vec<_>>>()
        })?;

        for (&(f, i), digest) in work.iter().zip(computed) {
            if let Some(d) = digest {
                let file = &files[f as usize];
                digests.insert(f, d);
                out.files_hashed += 1;
                out.bytes_hashed += file.size;
                let previous = hits.as_ref().and_then(|h| h[i]);
                out.new_cache_entries.push((
                    lookups[i].0.clone(),
                    CacheEntry {
                        size: file.size,
                        modified_ns: file.modified_ns,
                        identity: file.identity,
                        partial: previous.and_then(|p| p.partial),
                        full: Some((algo, d)),
                    },
                ));
            }
        }
    }
    control.checkpoint()?;

    // Pass 2b: content Merkle hashes, bottom-up.
    let mut content: Vec<Option<Digest>> = vec![None; n];
    for d in (0..n).rev() {
        if !in_scope[d] {
            continue;
        }
        let dir = &dirs[d];
        let mut entries = Vec::with_capacity(dir.files.len() + dir.subdirs.len());
        let mut ok = true;
        for &f in &dir.files {
            match digests.get(&f) {
                Some(digest) => entries.push(Entry {
                    kind: KIND_FILE,
                    name: name_bytes(&files[f as usize].name),
                    payload: digest.to_vec().into(),
                }),
                None => {
                    ok = false;
                    break;
                }
            }
        }
        if !ok {
            continue;
        }
        for link in &dir.symlinks {
            entries.push(Entry {
                kind: KIND_LINK,
                name: name_bytes(&link.name),
                payload: link_payload(&link.target).into(),
            });
        }
        for &sub in &dir.subdirs {
            match content[sub as usize] {
                Some(c) => entries.push(Entry {
                    kind: KIND_DIR,
                    name: name_bytes(dirs[sub as usize].name()),
                    payload: c.to_vec().into(),
                }),
                None => {
                    ok = false;
                    break;
                }
            }
        }
        if ok {
            content[d] = Some(merkle(entries));
        }
    }

    let mut by_content: HashMap<Digest, Vec<u32>> = HashMap::new();
    for &d in &candidates {
        if let Some(c) = content[d as usize] {
            by_content.entry(c).or_default().push(d);
        }
    }
    let groups: Vec<(Digest, Vec<u32>)> = by_content
        .into_iter()
        .filter(|(_, g)| g.len() > 1)
        .collect();

    // Hide groups that are implied by a duplicate parent: if every member's
    // parent is itself a reported duplicate, the parents already cover them.
    let members: HashSet<u32> = groups.iter().flat_map(|(_, g)| g.iter().copied()).collect();
    for (digest, mut group) in groups {
        let implied = group.iter().all(|&d| {
            let parent = dirs[d as usize].parent;
            parent != NO_ID && members.contains(&parent)
        });
        if implied {
            continue;
        }
        group.sort_by(|a, b| dirs[*a as usize].path.cmp(&dirs[*b as usize].path));
        let first = group[0] as usize;
        out.groups.push(FolderGroup {
            digest,
            total_bytes: stats.bytes[first],
            file_count: stats.files[first],
            dir_count: stats.dirs[first],
            dirs: group,
        });
    }
    out.groups.sort_by(|a, b| {
        b.wasted().cmp(&a.wasted()).then_with(|| {
            dirs[a.dirs[0] as usize]
                .path
                .cmp(&dirs[b.dirs[0] as usize].path)
        })
    });
    Ok(out)
}
