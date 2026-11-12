//! Checks files that appeared after a scan (new downloads) against the
//! scanned files: a new file whose content already exists is reported with
//! the copy it duplicates.

use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

use crate::cache::{CacheEntry, HashCache};
use crate::hashing::{self, Digest};
use crate::session::{ItemState, Session};

/// Most existing files compared per new file (same size is rare enough).
const MAX_CANDIDATES: usize = 16;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CopyMatch {
    pub path: PathBuf,
    /// A scanned file with the same content.
    pub existing: PathBuf,
    pub size: u64,
}

/// Full hash of a scanned file, from the cache when it is unchanged.
fn existing_digest(
    session: &Session,
    f: u32,
    cache: Option<&HashCache>,
    memo: &mut HashMap<u32, Option<Digest>>,
) -> Option<Digest> {
    if let Some(d) = memo.get(&f) {
        return *d;
    }
    let algo = session.result.config.hash_algorithm;
    let record = &session.result.files[f as usize];
    let path = session.result.file_path(f);
    let cached = cache.and_then(|c| {
        c.lookup_many(&[(path.clone(), record.size, record.modified_ns, None)])
            .pop()
            .flatten()
            .and_then(|e: CacheEntry| e.full_for(algo))
    });
    let digest = cached.or_else(|| hashing::hash_file(&path, algo).ok());
    memo.insert(f, digest);
    digest
}

/// Returns the new files in `paths` that are byte-identical (by content
/// hash) to a file present in the scan. Paths that are part of the scan,
/// folders, empty and unreadable files are ignored.
pub fn find_copies(
    session: &Session,
    paths: &[PathBuf],
    cache: Option<&HashCache>,
) -> Vec<CopyMatch> {
    // Canonical form, as scanned paths are (short names, case, `..`).
    let wanted: Vec<(&PathBuf, PathBuf, u64)> = paths
        .iter()
        .filter_map(|p| {
            let m = fs::metadata(p).ok()?;
            (m.is_file() && m.len() > 0).then(|| (p, crate::paths::normalize(p), m.len()))
        })
        .collect();
    if wanted.is_empty() {
        return Vec::new();
    }
    let sizes: std::collections::HashSet<u64> = wanted.iter().map(|w| w.2).collect();
    let mut by_size: HashMap<u64, Vec<u32>> = HashMap::new();
    for (f, file) in session.result.files.iter().enumerate() {
        if file.eligible
            && sizes.contains(&file.size)
            && session.file_state(f as u32) == ItemState::Present
        {
            by_size.entry(file.size).or_default().push(f as u32);
        }
    }
    let algo = session.result.config.hash_algorithm;
    let mut memo = HashMap::new();
    let mut out = Vec::new();
    for (original, path, size) in wanted {
        let path = path.as_path();
        let Some(candidates) = by_size.get(&size) else {
            continue;
        };
        // A path that is itself in the scan is not new.
        if candidates.iter().any(|&f| {
            crate::paths::starts_with(&session.result.file_path(f), path)
                && crate::paths::starts_with(path, &session.result.file_path(f))
        }) {
            continue;
        }
        let Ok(digest) = hashing::hash_file(path, algo) else {
            continue;
        };
        let hit = candidates
            .iter()
            .take(MAX_CANDIDATES)
            .copied()
            .find(|&f| existing_digest(session, f, cache, &mut memo) == Some(digest));
        if let Some(f) = hit {
            out.push(CopyMatch {
                path: original.clone(),
                existing: session.result.file_path(f),
                size,
            });
        }
    }
    out
}
