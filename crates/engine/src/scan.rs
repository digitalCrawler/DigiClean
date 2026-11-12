//! The scan pipeline: walk → size → partial hash → full hash → (verify) →
//! folders. See the crate documentation for the rationale of each stage.

use std::collections::{HashMap, HashSet};
use std::hash::Hash;
use std::path::PathBuf;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};

use rayon::prelude::*;

use crate::cache::{CacheEntry, HashCache};
use crate::config::ScanConfig;
use crate::control::ScanControl;
use crate::error::{EngineError, Result};
use crate::filters::Filters;
use crate::folders;
use crate::hashing::{self, Digest};
use crate::model::{FileGroup, FileRecord, ScanResult, ScanStats};
use crate::progress::{ProgressSink, ProgressTracker, Reporter, ScanPhase};
use crate::walker::{self, IssueLog, WalkOutput};

const PROGRESS_INTERVAL: Duration = Duration::from_millis(150);
/// Files smaller than this are not worth listing as "large".
const LARGE_FILE_MIN: u64 = 1 << 20;
/// Cap for the large-files list; the UI pages through it.
const LARGE_FILE_LIMIT: usize = 5_000;

/// Runs a complete scan. Blocks the calling thread; work is spread over
/// internal thread pools sized from [`ScanConfig::performance`].
pub fn run_scan(
    cfg: &ScanConfig,
    control: &ScanControl,
    sink: Option<Arc<dyn ProgressSink>>,
) -> Result<ScanResult> {
    cfg.validate()?;
    let started = Instant::now();
    let tracker = Arc::new(ProgressTracker::default());
    let reporter = sink.map(|sink| {
        let control = control.clone();
        Reporter::start(tracker.clone(), sink, PROGRESS_INTERVAL, move || {
            control.is_paused()
        })
    });

    let result = Pipeline::new(cfg, control, &tracker).and_then(|p| p.run(started));
    tracker.set_phase(ScanPhase::Done, 0, 0);
    if let Some(reporter) = reporter {
        reporter.finish();
    }
    result
}

struct Pipeline<'a> {
    cfg: &'a ScanConfig,
    control: &'a ScanControl,
    progress: &'a ProgressTracker,
    filters: Filters,
    cache: Option<HashCache>,
    issues: IssueLog,
    walk_pool: rayon::ThreadPool,
    hash_pool: rayon::ThreadPool,
}

/// Workers run at background priority so a scan does not slow down the
/// rest of the computer (see [`crate::priority`]).
fn build_pool(threads: usize, name: &'static str) -> Result<rayon::ThreadPool> {
    crate::priority::background_pool(threads, name)
        .map_err(|e| EngineError::Other(format!("cannot start worker threads: {e}")))
}

/// Splits every group by `key`, dropping files whose key is `None` and
/// sub-groups that end up with a single member.
fn refine<K: Hash + Eq>(
    groups: Vec<Vec<u32>>,
    mut key: impl FnMut(u32) -> Option<K>,
) -> Vec<Vec<u32>> {
    let mut out = Vec::new();
    for group in groups {
        let mut buckets: HashMap<K, Vec<u32>> = HashMap::with_capacity(group.len());
        for id in group {
            if let Some(k) = key(id) {
                buckets.entry(k).or_default().push(id);
            }
        }
        out.extend(buckets.into_values().filter(|g| g.len() > 1));
    }
    out
}

/// Hard links share storage, so deleting one frees nothing. Keep one path
/// per physical file.
fn collapse_hardlinks(
    groups: Vec<Vec<u32>>,
    files: &[FileRecord],
    skipped: &mut u64,
) -> Vec<Vec<u32>> {
    groups
        .into_iter()
        .filter_map(|group| {
            let mut seen = HashSet::with_capacity(group.len());
            let kept: Vec<u32> = group
                .into_iter()
                .filter(|&id| match files[id as usize].identity {
                    Some(identity) if !seen.insert(identity) => {
                        *skipped += 1;
                        false
                    }
                    _ => true,
                })
                .collect();
            (kept.len() > 1).then_some(kept)
        })
        .collect()
}

impl<'a> Pipeline<'a> {
    fn new(
        cfg: &'a ScanConfig,
        control: &'a ScanControl,
        progress: &'a ProgressTracker,
    ) -> Result<Self> {
        let cache = cfg
            .cache_dir
            .as_ref()
            .and_then(|dir| match HashCache::open(dir) {
                Ok(cache) => Some(cache),
                Err(e) => {
                    log::warn!("hash cache disabled: {e}");
                    None
                }
            });
        Ok(Self {
            cfg,
            control,
            progress,
            filters: Filters::new(cfg)?,
            cache,
            issues: IssueLog::default(),
            walk_pool: build_pool(cfg.effective_walk_threads(), "digiclean-walk")?,
            hash_pool: build_pool(cfg.effective_hash_threads(), "digiclean-hash")?,
        })
    }

    fn path_of(out: &WalkOutput, id: u32) -> PathBuf {
        let f = &out.files[id as usize];
        out.dirs[f.dir as usize].path.join(&*f.name)
    }

    fn store_cache(&self, entries: &[(PathBuf, CacheEntry)]) {
        if let Some(cache) = &self.cache {
            if let Err(e) = cache.store_many(entries) {
                log::warn!("could not update hash cache: {e}");
            }
        }
    }

    fn run(self, started: Instant) -> Result<ScanResult> {
        let cfg = self.cfg;
        let algo = cfg.hash_algorithm;
        let mut stats = ScanStats {
            hash_algorithm: algo.name().into(),
            ..Default::default()
        };

        // ── 1. Discover ────────────────────────────────────────────────
        self.progress.set_phase(ScanPhase::Discovering, 0, 0);
        let mut out = walker::walk(
            cfg,
            &self.filters,
            self.control,
            self.progress,
            &self.issues,
            &self.walk_pool,
        )?;
        stats.files_seen = self.progress.files_discovered.load(Ordering::Relaxed);
        stats.dirs_seen = out.dirs.len() as u64;
        stats.bytes_seen = self.progress.bytes_discovered.load(Ordering::Relaxed);

        // ── 2. Group by size ───────────────────────────────────────────
        self.progress.set_phase(ScanPhase::GroupingBySize, 0, 0);
        let mut by_size: HashMap<u64, Vec<u32>> = HashMap::new();
        let mut empty_files: Vec<u32> = Vec::new();
        for (id, f) in out.files.iter().enumerate() {
            if !f.eligible {
                continue;
            }
            stats.eligible_files += 1;
            if f.size == 0 {
                if cfg.include_empty_files {
                    empty_files.push(id as u32);
                }
                continue;
            }
            by_size.entry(f.size).or_default().push(id as u32);
        }
        let groups: Vec<Vec<u32>> = by_size.into_values().filter(|g| g.len() > 1).collect();
        // On Unix the identity is already known from the walk.
        let groups = collapse_hardlinks(groups, &out.files, &mut stats.hardlinks_skipped);
        stats.candidates_after_size = groups.iter().map(|g| g.len() as u64).sum();
        self.progress
            .candidates
            .store(stats.candidates_after_size, Ordering::Relaxed);

        // ── 3. Partial fingerprint ─────────────────────────────────────
        let mut partial: HashMap<u32, u128> = HashMap::new();
        let mut full: HashMap<u32, Digest> = HashMap::new();
        let mut cache_writes: Vec<(PathBuf, CacheEntry)> = Vec::new();
        {
            let mut ids: Vec<u32> = groups.iter().flatten().copied().collect();
            ids.sort_unstable_by_key(|&id| std::cmp::Reverse(out.files[id as usize].size));
            let lookups: Vec<_> = ids
                .iter()
                .map(|&id| {
                    let f = &out.files[id as usize];
                    (Self::path_of(&out, id), f.size, f.modified_ns, f.identity)
                })
                .collect();
            let hits = match &self.cache {
                Some(cache) => cache.lookup_many(&lookups),
                None => vec![None; ids.len()],
            };
            let sample_bytes: u64 = ids
                .iter()
                .map(|&id| {
                    out.files[id as usize]
                        .size
                        .min(3 * hashing::SAMPLE_SIZE as u64)
                })
                .sum();
            self.progress
                .set_phase(ScanPhase::PartialHashing, ids.len() as u64, sample_bytes);

            let probes: Vec<Option<(hashing::Probe, bool)>> = self.hash_pool.install(|| {
                lookups
                    .par_iter()
                    .zip(hits.par_iter())
                    .map(|((path, size, _, walk_identity), hit)| {
                        self.control.checkpoint()?;
                        let sampled = (*size).min(3 * hashing::SAMPLE_SIZE as u64);
                        if let Some(hit) = hit.filter(|h| h.partial.is_some()) {
                            self.progress.cache_hits.fetch_add(1, Ordering::Relaxed);
                            self.progress.item_done(sampled);
                            let probe = hashing::Probe {
                                partial: hit.partial.unwrap(),
                                full: hit.full_for(algo),
                                identity: walk_identity.or(hit.identity),
                            };
                            return Ok(Some((probe, false)));
                        }
                        self.progress.set_current(path);
                        let result = hashing::probe_file(path, *size, algo);
                        self.progress.item_done(sampled);
                        match result {
                            Ok(mut probe) => {
                                probe.identity = walk_identity.or(probe.identity);
                                Ok(Some((probe, true)))
                            }
                            Err(e) => {
                                self.progress.error();
                                self.issues.push(path, e);
                                Ok(None)
                            }
                        }
                    })
                    .collect::<Result<Vec<_>>>()
            })?;

            for (i, probe) in probes.into_iter().enumerate() {
                let Some((probe, fresh)) = probe else {
                    continue;
                };
                let id = ids[i];
                let file = &mut out.files[id as usize];
                file.identity = probe.identity;
                partial.insert(id, probe.partial);
                if let Some(d) = probe.full {
                    full.insert(id, d);
                }
                if fresh {
                    cache_writes.push((
                        lookups[i].0.clone(),
                        CacheEntry {
                            size: file.size,
                            modified_ns: file.modified_ns,
                            identity: probe.identity,
                            partial: Some(probe.partial),
                            full: probe.full.map(|d| (algo, d)),
                        },
                    ));
                }
            }
            stats.cache_hits = self.progress.cache_hits.load(Ordering::Relaxed);
        }
        self.store_cache(&cache_writes);
        cache_writes.clear();

        // Identity is now known on every platform.
        let groups = collapse_hardlinks(groups, &out.files, &mut stats.hardlinks_skipped);
        let groups = refine(groups, |id| partial.get(&id).copied());
        stats.candidates_after_partial = groups.iter().map(|g| g.len() as u64).sum();
        self.progress
            .candidates
            .store(stats.candidates_after_partial, Ordering::Relaxed);

        // ── 4. Full content hash ───────────────────────────────────────
        {
            let mut need: Vec<u32> = groups
                .iter()
                .flatten()
                .copied()
                .filter(|id| !full.contains_key(id))
                .collect();
            // Largest first: long files start early instead of forming a tail.
            need.sort_unstable_by_key(|&id| std::cmp::Reverse(out.files[id as usize].size));
            let total: u64 = need.iter().map(|&id| out.files[id as usize].size).sum();
            self.progress
                .set_phase(ScanPhase::FullHashing, need.len() as u64, total);

            let digests: Vec<Option<Digest>> = self.hash_pool.install(|| {
                need.par_iter()
                    .map(|&id| {
                        let f = &out.files[id as usize];
                        let path = Self::path_of(&out, id);
                        self.progress.set_current(&path);
                        match hashing::full_hash(&path, f.size, algo, self.control, self.progress) {
                            Ok(d) => {
                                self.progress.items_done.fetch_add(1, Ordering::Relaxed);
                                Ok(Some(d))
                            }
                            Err(EngineError::Cancelled) => Err(EngineError::Cancelled),
                            Err(e) => {
                                self.progress.error();
                                self.issues.push(&path, e);
                                Ok(None)
                            }
                        }
                    })
                    .collect::<Result<Vec<_>>>()
            })?;

            for (&id, digest) in need.iter().zip(digests) {
                let Some(d) = digest else { continue };
                let f = &out.files[id as usize];
                full.insert(id, d);
                stats.files_fully_hashed += 1;
                stats.bytes_hashed += f.size;
                cache_writes.push((
                    Self::path_of(&out, id),
                    CacheEntry {
                        size: f.size,
                        modified_ns: f.modified_ns,
                        identity: f.identity,
                        partial: partial.get(&id).copied(),
                        full: Some((algo, d)),
                    },
                ));
            }
        }
        self.store_cache(&cache_writes);
        cache_writes.clear();

        let mut groups = refine(groups, |id| full.get(&id).copied());

        // ── 5. Optional byte-by-byte verification ──────────────────────
        if cfg.verify_byte_by_byte && !groups.is_empty() {
            let total: u64 = groups
                .iter()
                .map(|g| out.files[g[0] as usize].size * g.len() as u64)
                .sum();
            self.progress
                .set_phase(ScanPhase::Verifying, groups.len() as u64, total);
            groups = self
                .hash_pool
                .install(|| {
                    groups
                        .into_par_iter()
                        .map(|group| self.verify_group(&out, group))
                        .collect::<Result<Vec<_>>>()
                })?
                .into_iter()
                .flatten()
                .collect();
        }

        // ── 6. Folders ─────────────────────────────────────────────────
        let analysis = folders::analyze(
            cfg,
            &out.dirs,
            &out.files,
            &mut full,
            self.cache.as_ref(),
            self.control,
            self.progress,
            &self.issues,
            &self.hash_pool,
        )?;
        stats.files_fully_hashed += analysis.files_hashed;
        stats.bytes_hashed += analysis.bytes_hashed;
        self.store_cache(&analysis.new_cache_entries);

        // ── 7. Assemble ────────────────────────────────────────────────
        self.progress.set_phase(ScanPhase::Finalizing, 0, 0);
        let mut file_groups: Vec<FileGroup> = groups
            .into_iter()
            .map(|mut ids| {
                ids.sort_by_cached_key(|&id| Self::path_of(&out, id));
                let first = &out.files[ids[0] as usize];
                FileGroup {
                    size: first.size,
                    digest: full[&ids[0]],
                    category: first.category,
                    files: ids,
                }
            })
            .collect();
        if empty_files.len() > 1 {
            empty_files.sort_by_cached_key(|&id| Self::path_of(&out, id));
            file_groups.push(FileGroup {
                size: 0,
                digest: hashing::empty_digest(algo),
                category: crate::config::FileCategory::Other,
                files: empty_files,
            });
        }
        file_groups.sort_by(|a, b| {
            b.wasted()
                .cmp(&a.wasted())
                .then(b.files.len().cmp(&a.files.len()))
                .then(a.digest.cmp(&b.digest))
        });

        stats.duplicate_groups = file_groups.len() as u64;
        stats.duplicate_files = file_groups.iter().map(|g| g.files.len() as u64 - 1).sum();
        stats.wasted_bytes = file_groups.iter().map(FileGroup::wasted).sum();
        stats.folder_groups = analysis.groups.len() as u64;
        stats.folder_wasted_bytes = analysis.groups.iter().map(|g| g.wasted()).sum();
        stats.empty_folders = analysis.empty.len() as u64;

        // Biggest files the user's filters allow, for the large-files view.
        let mut large: Vec<u32> = (0..out.files.len() as u32)
            .filter(|&f| {
                let file = &out.files[f as usize];
                file.eligible && file.size >= LARGE_FILE_MIN
            })
            .collect();
        large.sort_unstable_by_key(|&f| std::cmp::Reverse(out.files[f as usize].size));
        large.truncate(LARGE_FILE_LIMIT);
        stats.large_files = large.len() as u64;
        stats.photos = out
            .files
            .iter()
            .filter(|f| {
                f.eligible
                    && crate::photos::is_supported(
                        crate::paths::extension_lower(&f.name).as_deref(),
                    )
            })
            .count() as u64;
        stats.cache_hits = self.progress.cache_hits.load(Ordering::Relaxed);
        stats.errors = self.issues.count();
        stats.elapsed_ms = started.elapsed().as_millis() as u64;

        stats.junk_items = out.junk.len() as u64;
        stats.junk_bytes = out.junk.iter().map(|j| j.size).sum();
        let WalkOutput {
            roots,
            dirs,
            files,
            junk,
        } = out;
        Ok(ScanResult {
            config: cfg.clone(),
            roots,
            dirs,
            files,
            file_groups,
            folder_groups: analysis.groups,
            empty_folders: analysis.empty,
            large_files: large,
            junk,
            stats,
            issues: self.issues.into_samples(),
        })
    }

    /// Splits a hash group into classes of byte-identical files. With a
    /// cryptographic hash this practically never splits anything; it exists
    /// for users who want certainty independent of hash assumptions.
    fn verify_group(&self, out: &WalkOutput, group: Vec<u32>) -> Result<Vec<Vec<u32>>> {
        let mut classes: Vec<Vec<u32>> = Vec::new();
        'members: for id in group {
            let path = Self::path_of(out, id);
            self.progress.set_current(&path);
            for class in classes.iter_mut() {
                let rep = Self::path_of(out, class[0]);
                match hashing::files_identical(&rep, &path, self.control) {
                    Ok(true) => {
                        class.push(id);
                        continue 'members;
                    }
                    Ok(false) => {}
                    Err(EngineError::Cancelled) => return Err(EngineError::Cancelled),
                    Err(e) => {
                        self.progress.error();
                        self.issues.push(&path, e);
                        continue 'members;
                    }
                }
            }
            classes.push(vec![id]);
        }
        let size = out.files[classes.first().map(|c| c[0]).unwrap_or(0) as usize].size;
        self.progress.item_done(size);
        Ok(classes.into_iter().filter(|c| c.len() > 1).collect())
    }
}
