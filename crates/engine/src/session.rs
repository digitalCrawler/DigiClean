//! A finished scan plus everything the UI does with it: paged and sorted
//! group queries, selection with safety invariants, and per-item state after
//! actions. Results stay in Rust so very large scans never need to be
//! materialised in the UI layer.
//!
//! Selection invariant: in every duplicate group at least one present copy
//! is *not* selected. All selection entry points enforce it, and actions
//! re-check it against the file system before touching anything.

use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use parking_lot::Mutex;
use serde::{Deserialize, Serialize};

use crate::config::FileCategory;
use crate::folders::{self, TreeStats};
use crate::hashing::Digest;
use crate::junk::JunkKind;
use crate::model::{ScanResult, NO_ID};
use crate::paths;
use crate::photos::{PhotoFeatures, PhotoIssue};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ItemState {
    Present,
    Removed,
    Moved,
    /// Replaced by a hard link to the kept copy: still readable, no longer
    /// occupying extra space.
    Linked,
    /// Inside a folder the user chose to ignore: hidden from every list
    /// and never acted on.
    Ignored,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GroupKind {
    Files,
    Folders,
    EmptyFolders,
    /// The biggest files of the scan (each "group" is a single file id).
    LargeFiles,
    /// Junk items (each "group" is a single junk id).
    Junk,
    /// Files not changed for a long time (each "group" is a file id).
    OldFiles,
    /// Photos that look alike (needs [`Session::set_photo_analysis`]).
    SimilarPhotos,
    /// Blurry, dark and screenshot images (each "group" is a file id).
    PhotoIssues,
    /// Songs and videos with the same soundtrack (after
    /// [`Session::set_media_analysis`]).
    SimilarMedia,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum SortKey {
    #[default]
    Wasted,
    Size,
    Count,
    Name,
    Path,
    Modified,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(default)]
pub struct GroupFilter {
    pub category: Option<FileCategory>,
    /// Case-insensitive substring matched against member paths.
    pub search: Option<String>,
    pub min_size: Option<u64>,
    /// Junk view only: one kind of junk.
    pub junk_kind: Option<JunkKind>,
    /// Old-files view: last modified before this time (ns since epoch).
    pub modified_before_ns: Option<i64>,
    /// Old-files view: only below these folders (empty = anywhere).
    pub within: Vec<PathBuf>,
    /// Old-files view: only these lower-case extensions (empty = any).
    pub extensions: Vec<String>,
    /// Photo-issues view: one kind (empty = any).
    pub photo_issue: Option<PhotoIssue>,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct ViewKey {
    kind: GroupKind,
    sort: SortKey,
    descending: bool,
    filter: GroupFilter,
    generation: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum KeepStrategy {
    #[default]
    Newest,
    Oldest,
    ShortestPath,
    LongestPath,
    ShallowestPath,
    FirstAlphabetical,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct SelectionRule {
    pub strategy: KeepStrategy,
    /// Copies inside these folders are kept in preference to others.
    pub prefer_keep_in: Vec<PathBuf>,
    /// When non-empty, only copies inside these folders are selected.
    pub only_select_in: Vec<PathBuf>,
    /// Restrict the rule to groups matching this filter.
    pub filter: GroupFilter,
}

#[derive(Clone, Debug)]
pub struct FileItem {
    pub id: u32,
    pub path: PathBuf,
    pub size: u64,
    pub modified_ns: i64,
    pub created_ns: Option<i64>,
    pub hidden: bool,
    pub selected: bool,
}

#[derive(Clone, Debug)]
pub struct CategoryUsage {
    pub category: FileCategory,
    pub files: u64,
    pub bytes: u64,
}

/// One tile of the space map: a folder, or (`dir == NO_ID`) the files
/// directly inside the folder being shown (`path`).
#[derive(Clone, Debug)]
pub struct SpaceNode {
    pub dir: u32,
    pub path: PathBuf,
    pub bytes: u64,
    pub files: u64,
    pub folders: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum RecommendationKind {
    /// Thumbnail caches the OS recreates.
    SystemCaches,
    /// Unfinished downloads and temporary files at least a day old.
    LeftoverFiles,
    /// Copies in the download folders of files kept elsewhere.
    DownloadDuplicates,
    EmptyFolders,
}

#[derive(Clone, Copy, Debug)]
pub struct Recommendation {
    pub kind: RecommendationKind,
    pub items: u64,
    pub bytes: u64,
}

/// Result of analysing the scan's photos.
#[derive(Clone, Debug, Default)]
pub struct PhotoAnalysis {
    pub features: HashMap<u32, PhotoFeatures>,
    /// Similar photos, each group in a stable order.
    pub groups: Vec<Vec<u32>>,
    pub issues: HashMap<u32, Vec<PhotoIssue>>,
    pub analyzed: u64,
    pub failed: u64,
}

#[derive(Clone, Debug)]
pub struct PhotoItem {
    pub id: u32,
    pub path: PathBuf,
    pub size: u64,
    pub modified_ns: i64,
    pub width: u32,
    pub height: u32,
    pub sharpness: f32,
    pub brightness: f32,
    pub issues: Vec<PhotoIssue>,
    /// The photo to keep in its similar group.
    pub best: bool,
    pub selected: bool,
}

/// Result of fingerprinting the scan's audio and video files.
#[derive(Clone, Debug, Default)]
pub struct MediaAnalysis {
    pub durations: HashMap<u32, Option<u64>>,
    pub groups: Vec<Vec<u32>>,
    pub analyzed: u64,
    pub failed: u64,
}

#[derive(Clone, Debug)]
pub struct MediaItem {
    pub id: u32,
    pub path: PathBuf,
    pub size: u64,
    pub modified_ns: i64,
    pub duration_ms: Option<u64>,
    pub video: bool,
    /// The copy to keep: the largest file (highest quality).
    pub best: bool,
    pub selected: bool,
}

#[derive(Clone, Debug)]
pub struct SimilarMediaView {
    pub index: u32,
    pub reclaimable: u64,
    pub items: Vec<MediaItem>,
}

#[derive(Clone, Debug)]
pub struct SimilarGroupView {
    pub index: u32,
    pub reclaimable: u64,
    /// Best shot first, then by path.
    pub items: Vec<PhotoItem>,
}

#[derive(Clone, Debug)]
pub struct JunkItem {
    pub id: u32,
    pub path: PathBuf,
    pub size: u64,
    pub modified_ns: i64,
    pub kind: JunkKind,
    pub selected: bool,
}

#[derive(Clone, Debug)]
pub struct FileGroupView {
    pub index: u32,
    pub size: u64,
    pub wasted: u64,
    pub digest: String,
    pub category: FileCategory,
    pub items: Vec<FileItem>,
}

#[derive(Clone, Debug)]
pub struct FolderItem {
    pub id: u32,
    pub path: PathBuf,
    pub modified_ns: i64,
    pub selected: bool,
}

#[derive(Clone, Debug)]
pub struct FolderGroupView {
    pub index: u32,
    pub total_bytes: u64,
    pub file_count: u64,
    pub dir_count: u64,
    pub wasted: u64,
    pub digest: String,
    pub items: Vec<FolderItem>,
}

#[derive(Clone, Debug)]
pub struct Page<T> {
    pub total: usize,
    pub items: Vec<T>,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct SelectionSummary {
    pub files: u64,
    pub file_bytes: u64,
    pub folders: u64,
    pub folder_bytes: u64,
    pub empty_folders: u64,
    pub active_file_groups: u64,
    pub file_wasted: u64,
    pub active_folder_groups: u64,
    pub folder_wasted: u64,
    pub remaining_empty_folders: u64,
    pub large_files: u64,
    pub large_file_bytes: u64,
    pub remaining_large_files: u64,
    pub old_files: u64,
    pub old_file_bytes: u64,
    pub photos_analyzed: bool,
    pub media_analyzed: bool,
    pub media_groups: u64,
    pub media_reclaimable: u64,
    pub media: u64,
    pub media_bytes: u64,
    pub similar_groups: u64,
    pub similar_reclaimable: u64,
    pub similar: u64,
    pub similar_bytes: u64,
    pub remaining_photo_issues: u64,
    pub photo_issues: u64,
    pub photo_issue_bytes: u64,
    pub junk: u64,
    pub junk_bytes: u64,
    pub remaining_junk: u64,
    pub remaining_junk_bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum SelectionError {
    #[error("at least one copy in each group must be kept")]
    WouldSelectAll,
    #[error("item is no longer available")]
    NotPresent,
    #[error("unknown item")]
    Unknown,
}

/// Per folder: bytes and file count of its tree, counting present files.
type LiveTree = Arc<Vec<(u64, u64)>>;

pub struct Session {
    pub result: ScanResult,
    pub(crate) tree: TreeStats,
    pub(crate) file_state: Vec<ItemState>,
    pub(crate) dir_state: Vec<ItemState>,
    /// Content below this folder changed through an action since the scan.
    pub(crate) dir_modified: Vec<bool>,
    pub(crate) file_selected: Vec<bool>,
    pub(crate) dir_selected: Vec<bool>,
    file_group_of: Vec<u32>,
    folder_group_of: Vec<u32>,
    pub(crate) is_empty_entry: Vec<bool>,
    /// Selection on the large-files list, kept apart from duplicate
    /// selection because the keep-one rule does not apply there.
    pub(crate) large_selected: Vec<bool>,
    /// Selection on the old-files list, kept apart from the large-files
    /// list so removing from one never touches what was ticked in the other.
    pub(crate) old_selected: Vec<bool>,
    photo: Option<PhotoAnalysis>,
    media: Option<MediaAnalysis>,
    media_group_of: HashMap<u32, u32>,
    pub(crate) media_selected: Vec<bool>,
    similar_group_of: HashMap<u32, u32>,
    pub(crate) similar_selected: Vec<bool>,
    pub(crate) photo_selected: Vec<bool>,
    /// Groups whose content the user marked as "not duplicates".
    file_group_ignored: Vec<bool>,
    folder_group_ignored: Vec<bool>,
    /// A folder inside this one is ignored, so it no longer matches its
    /// copies and is left out of folder groups.
    pub(crate) dir_partial: Vec<bool>,
    pub(crate) junk_state: Vec<ItemState>,
    pub(crate) junk_selected: Vec<bool>,
    generation: u64,
    view_cache: Mutex<Option<(ViewKey, Arc<Vec<u32>>)>>,
    live_tree_cache: Mutex<Option<(u64, LiveTree)>>,
}

impl Session {
    pub fn new(result: ScanResult) -> Self {
        let nf = result.files.len();
        let nd = result.dirs.len();
        let mut file_group_of = vec![NO_ID; nf];
        for (g, group) in result.file_groups.iter().enumerate() {
            for &f in &group.files {
                file_group_of[f as usize] = g as u32;
            }
        }
        let mut folder_group_of = vec![NO_ID; nd];
        for (g, group) in result.folder_groups.iter().enumerate() {
            for &d in &group.dirs {
                folder_group_of[d as usize] = g as u32;
            }
        }
        let mut is_empty_entry = vec![false; nd];
        for &d in &result.empty_folders {
            is_empty_entry[d as usize] = true;
        }
        let tree = folders::tree_stats(&result.dirs, &result.files);
        Self {
            large_selected: vec![false; nf],
            old_selected: vec![false; nf],
            photo: None,
            media: None,
            media_group_of: HashMap::new(),
            media_selected: vec![false; nf],
            similar_group_of: HashMap::new(),
            similar_selected: vec![false; nf],
            photo_selected: vec![false; nf],
            file_group_ignored: vec![false; result.file_groups.len()],
            folder_group_ignored: vec![false; result.folder_groups.len()],
            dir_partial: vec![false; nd],
            junk_state: vec![ItemState::Present; result.junk.len()],
            junk_selected: vec![false; result.junk.len()],
            tree,
            file_state: vec![ItemState::Present; nf],
            dir_state: vec![ItemState::Present; nd],
            dir_modified: vec![false; nd],
            file_selected: vec![false; nf],
            dir_selected: vec![false; nd],
            file_group_of,
            folder_group_of,
            is_empty_entry,
            generation: 0,
            view_cache: Mutex::new(None),
            live_tree_cache: Mutex::new(None),
            result,
        }
    }

    pub(crate) fn bump_generation(&mut self) {
        self.generation += 1;
        *self.view_cache.lock() = None;
    }

    // ── Group liveness ─────────────────────────────────────────────────

    pub(crate) fn present_files(&self, group: u32) -> impl Iterator<Item = u32> + '_ {
        self.result.file_groups[group as usize]
            .files
            .iter()
            .copied()
            .filter(|&f| self.file_state[f as usize] == ItemState::Present)
    }

    pub(crate) fn present_dirs(&self, group: u32) -> impl Iterator<Item = u32> + '_ {
        self.result.folder_groups[group as usize]
            .dirs
            .iter()
            .copied()
            .filter(|&d| {
                self.dir_state[d as usize] == ItemState::Present && !self.dir_partial[d as usize]
            })
    }

    /// Still there: not removed itself, nor its file record or folder.
    pub(crate) fn junk_present(&self, j: u32) -> bool {
        let entry = &self.result.junk[j as usize];
        self.junk_state[j as usize] == ItemState::Present
            && self.dir_state[entry.dir as usize] == ItemState::Present
            && (entry.file == NO_ID || self.file_state[entry.file as usize] == ItemState::Present)
    }

    fn live_file_count(&self, group: u32) -> usize {
        self.present_files(group).count()
    }

    fn live_dir_count(&self, group: u32) -> usize {
        self.present_dirs(group).count()
    }

    fn file_group_wasted(&self, group: u32) -> u64 {
        let n = self.live_file_count(group) as u64;
        self.result.file_groups[group as usize].size * n.saturating_sub(1)
    }

    fn folder_group_wasted(&self, group: u32) -> u64 {
        let n = self.live_dir_count(group) as u64;
        self.result.folder_groups[group as usize].total_bytes * n.saturating_sub(1)
    }

    fn file_name_lower(&self, f: u32) -> String {
        self.result.files[f as usize]
            .name
            .to_string_lossy()
            .to_lowercase()
    }

    fn matches_search(&self, path: &Path, needle: &str) -> bool {
        path.to_string_lossy().to_lowercase().contains(needle)
    }

    // ── Views ──────────────────────────────────────────────────────────

    fn ordered(
        &self,
        kind: GroupKind,
        sort: SortKey,
        descending: bool,
        filter: &GroupFilter,
    ) -> Arc<Vec<u32>> {
        let key = ViewKey {
            kind,
            sort,
            descending,
            filter: filter.clone(),
            generation: self.generation,
        };
        if let Some((cached_key, order)) = self.view_cache.lock().as_ref() {
            if *cached_key == key {
                return order.clone();
            }
        }
        let needle = filter
            .search
            .as_ref()
            .map(|s| s.trim().to_lowercase())
            .filter(|s| !s.is_empty());

        let mut order: Vec<u32> = match kind {
            GroupKind::Files => (0..self.result.file_groups.len() as u32)
                .filter(|&g| {
                    let group = &self.result.file_groups[g as usize];
                    !self.file_group_ignored[g as usize]
                        && self.live_file_count(g) > 1
                        && filter.category.is_none_or(|c| c == group.category)
                        && filter.min_size.is_none_or(|m| group.size >= m)
                        && needle.as_ref().is_none_or(|n| {
                            self.present_files(g)
                                .any(|f| self.matches_search(&self.result.file_path(f), n))
                        })
                })
                .collect(),
            GroupKind::Folders => (0..self.result.folder_groups.len() as u32)
                .filter(|&g| {
                    let group = &self.result.folder_groups[g as usize];
                    !self.folder_group_ignored[g as usize]
                        && self.live_dir_count(g) > 1
                        && filter.min_size.is_none_or(|m| group.total_bytes >= m)
                        && needle.as_ref().is_none_or(|n| {
                            self.present_dirs(g)
                                .any(|d| self.matches_search(self.result.dir_path(d), n))
                        })
                })
                .collect(),
            GroupKind::EmptyFolders => self
                .result
                .empty_folders
                .iter()
                .copied()
                .filter(|&d| {
                    self.dir_state[d as usize] == ItemState::Present
                        && needle
                            .as_ref()
                            .is_none_or(|n| self.matches_search(self.result.dir_path(d), n))
                })
                .collect(),
            GroupKind::LargeFiles => self
                .result
                .large_files
                .iter()
                .copied()
                .filter(|&f| {
                    let file = &self.result.files[f as usize];
                    self.file_state[f as usize] == ItemState::Present
                        && filter.category.is_none_or(|c| c == file.category)
                        && filter.min_size.is_none_or(|m| file.size >= m)
                        && needle
                            .as_ref()
                            .is_none_or(|n| self.matches_search(&self.result.file_path(f), n))
                })
                .collect(),
            GroupKind::OldFiles => {
                let within: Vec<PathBuf> =
                    filter.within.iter().map(|p| paths::normalize(p)).collect();
                (0..self.result.files.len() as u32)
                    .filter(|&f| {
                        let file = &self.result.files[f as usize];
                        file.eligible
                            && self.file_state[f as usize] == ItemState::Present
                            && filter
                                .modified_before_ns
                                .is_none_or(|t| file.modified_ns < t)
                            && filter.category.is_none_or(|c| c == file.category)
                            && filter.min_size.is_none_or(|m| file.size >= m)
                            && (filter.extensions.is_empty()
                                || paths::extension_lower(&file.name)
                                    .is_some_and(|e| filter.extensions.contains(&e)))
                            && (within.is_empty()
                                || paths::is_within_any(self.result.dir_path(file.dir), &within))
                            && needle
                                .as_ref()
                                .is_none_or(|n| self.matches_search(&self.result.file_path(f), n))
                    })
                    .collect()
            }
            GroupKind::SimilarMedia => (0..self.media.as_ref().map_or(0, |m| m.groups.len())
                as u32)
                .filter(|&g| {
                    let live = self.live_media(g);
                    live.len() > 1
                        && needle.as_ref().is_none_or(|n| {
                            live.iter()
                                .any(|&f| self.matches_search(&self.result.file_path(f), n))
                        })
                })
                .collect(),
            GroupKind::SimilarPhotos => (0..self.photo.as_ref().map_or(0, |p| p.groups.len())
                as u32)
                .filter(|&g| {
                    let live = self.live_similar(g);
                    live.len() > 1
                        && needle.as_ref().is_none_or(|n| {
                            live.iter()
                                .any(|&f| self.matches_search(&self.result.file_path(f), n))
                        })
                })
                .collect(),
            GroupKind::PhotoIssues => {
                let mut ids: Vec<u32> = self
                    .photo
                    .as_ref()
                    .map(|p| {
                        p.issues
                            .iter()
                            .filter(|(_, issues)| {
                                filter.photo_issue.is_none_or(|k| issues.contains(&k))
                            })
                            .map(|(&f, _)| f)
                            .collect()
                    })
                    .unwrap_or_default();
                ids.retain(|&f| {
                    self.file_state[f as usize] == ItemState::Present
                        && needle
                            .as_ref()
                            .is_none_or(|n| self.matches_search(&self.result.file_path(f), n))
                });
                ids
            }
            GroupKind::Junk => (0..self.result.junk.len() as u32)
                .filter(|&j| {
                    let entry = &self.result.junk[j as usize];
                    self.junk_present(j)
                        && filter.junk_kind.is_none_or(|k| k == entry.kind)
                        && filter.min_size.is_none_or(|m| entry.size >= m)
                        && needle
                            .as_ref()
                            .is_none_or(|n| self.matches_search(&self.result.junk_path(j), n))
                })
                .collect(),
        };

        let cmp = |a: &u32, b: &u32| -> Ordering {
            match kind {
                GroupKind::Files => {
                    let (ga, gb) = (
                        &self.result.file_groups[*a as usize],
                        &self.result.file_groups[*b as usize],
                    );
                    match sort {
                        SortKey::Wasted => {
                            self.file_group_wasted(*a).cmp(&self.file_group_wasted(*b))
                        }
                        SortKey::Size => ga.size.cmp(&gb.size),
                        SortKey::Count => self.live_file_count(*a).cmp(&self.live_file_count(*b)),
                        SortKey::Name => self
                            .first_present_file(*a)
                            .map(|f| self.file_name_lower(f))
                            .cmp(&self.first_present_file(*b).map(|f| self.file_name_lower(f))),
                        SortKey::Path => self
                            .first_present_file(*a)
                            .map(|f| self.result.file_path(f))
                            .cmp(
                                &self
                                    .first_present_file(*b)
                                    .map(|f| self.result.file_path(f)),
                            ),
                        SortKey::Modified => self.newest_file(*a).cmp(&self.newest_file(*b)),
                    }
                }
                GroupKind::Folders => {
                    let (ga, gb) = (
                        &self.result.folder_groups[*a as usize],
                        &self.result.folder_groups[*b as usize],
                    );
                    match sort {
                        SortKey::Wasted => self
                            .folder_group_wasted(*a)
                            .cmp(&self.folder_group_wasted(*b)),
                        SortKey::Size => ga.total_bytes.cmp(&gb.total_bytes),
                        SortKey::Count => self.live_dir_count(*a).cmp(&self.live_dir_count(*b)),
                        SortKey::Name | SortKey::Path | SortKey::Modified => {
                            let pa = self
                                .present_dirs(*a)
                                .next()
                                .map(|d| self.result.dir_path(d));
                            let pb = self
                                .present_dirs(*b)
                                .next()
                                .map(|d| self.result.dir_path(d));
                            if sort == SortKey::Name {
                                pa.and_then(Path::file_name)
                                    .cmp(&pb.and_then(Path::file_name))
                            } else {
                                pa.cmp(&pb)
                            }
                        }
                    }
                }
                GroupKind::SimilarMedia => {
                    let (la, lb) = (self.live_media(*a), self.live_media(*b));
                    match sort {
                        SortKey::Count => la.len().cmp(&lb.len()),
                        SortKey::Size => self.files_bytes(&la).cmp(&self.files_bytes(&lb)),
                        SortKey::Wasted => {
                            self.media_reclaimable(*a).cmp(&self.media_reclaimable(*b))
                        }
                        _ => la
                            .first()
                            .map(|&f| self.result.file_path(f))
                            .cmp(&lb.first().map(|&f| self.result.file_path(f))),
                    }
                }
                GroupKind::SimilarPhotos => {
                    let (la, lb) = (self.live_similar(*a), self.live_similar(*b));
                    match sort {
                        SortKey::Count => la.len().cmp(&lb.len()),
                        SortKey::Size => self.files_bytes(&la).cmp(&self.files_bytes(&lb)),
                        SortKey::Name | SortKey::Path => la
                            .first()
                            .map(|&f| self.result.file_path(f))
                            .cmp(&lb.first().map(|&f| self.result.file_path(f))),
                        SortKey::Modified => la
                            .iter()
                            .map(|&f| self.result.files[f as usize].modified_ns)
                            .max()
                            .cmp(
                                &lb.iter()
                                    .map(|&f| self.result.files[f as usize].modified_ns)
                                    .max(),
                            ),
                        SortKey::Wasted => self
                            .similar_reclaimable(*a)
                            .cmp(&self.similar_reclaimable(*b)),
                    }
                }
                GroupKind::LargeFiles | GroupKind::OldFiles | GroupKind::PhotoIssues => {
                    let (fa, fb) = (
                        &self.result.files[*a as usize],
                        &self.result.files[*b as usize],
                    );
                    match sort {
                        SortKey::Name => self.file_name_lower(*a).cmp(&self.file_name_lower(*b)),
                        SortKey::Path => self.result.file_path(*a).cmp(&self.result.file_path(*b)),
                        SortKey::Modified => fa.modified_ns.cmp(&fb.modified_ns),
                        _ => fa.size.cmp(&fb.size),
                    }
                }
                GroupKind::Junk => {
                    let (ja, jb) = (
                        &self.result.junk[*a as usize],
                        &self.result.junk[*b as usize],
                    );
                    match sort {
                        SortKey::Name => ja
                            .name
                            .to_ascii_lowercase()
                            .cmp(&jb.name.to_ascii_lowercase()),
                        SortKey::Path => self.result.junk_path(*a).cmp(&self.result.junk_path(*b)),
                        SortKey::Modified => ja.modified_ns.cmp(&jb.modified_ns),
                        SortKey::Count => ja.kind.cmp(&jb.kind),
                        _ => ja.size.cmp(&jb.size),
                    }
                }
                GroupKind::EmptyFolders => {
                    let (pa, pb) = (self.result.dir_path(*a), self.result.dir_path(*b));
                    match sort {
                        SortKey::Name => pa.file_name().cmp(&pb.file_name()),
                        SortKey::Modified => self.result.dirs[*a as usize]
                            .modified_ns
                            .cmp(&self.result.dirs[*b as usize].modified_ns),
                        _ => pa.cmp(pb),
                    }
                }
            }
        };
        order.sort_by(|a, b| {
            let o = cmp(a, b);
            let o = if descending { o.reverse() } else { o };
            o.then(a.cmp(b))
        });
        let order = Arc::new(order);
        *self.view_cache.lock() = Some((key, order.clone()));
        order
    }

    fn first_present_file(&self, group: u32) -> Option<u32> {
        self.present_files(group).next()
    }

    fn newest_file(&self, group: u32) -> i64 {
        self.present_files(group)
            .map(|f| self.result.files[f as usize].modified_ns)
            .max()
            .unwrap_or(0)
    }

    pub fn file_item(&self, f: u32) -> FileItem {
        let file = &self.result.files[f as usize];
        FileItem {
            id: f,
            path: self.result.file_path(f),
            size: file.size,
            modified_ns: file.modified_ns,
            created_ns: file.created_ns,
            hidden: file.hidden,
            selected: self.file_selected[f as usize],
        }
    }

    pub fn file_group_view(&self, g: u32) -> FileGroupView {
        let group = &self.result.file_groups[g as usize];
        FileGroupView {
            index: g,
            size: group.size,
            wasted: self.file_group_wasted(g),
            digest: hex::encode(group.digest),
            category: group.category,
            items: self.present_files(g).map(|f| self.file_item(f)).collect(),
        }
    }

    pub fn folder_item(&self, d: u32) -> FolderItem {
        FolderItem {
            id: d,
            path: self.result.dirs[d as usize].path.clone(),
            modified_ns: self.result.dirs[d as usize].modified_ns,
            selected: self.dir_selected[d as usize],
        }
    }

    pub fn folder_group_view(&self, g: u32) -> FolderGroupView {
        let group = &self.result.folder_groups[g as usize];
        FolderGroupView {
            index: g,
            total_bytes: group.total_bytes,
            file_count: group.file_count,
            dir_count: group.dir_count,
            wasted: self.folder_group_wasted(g),
            digest: hex::encode(group.digest),
            items: self.present_dirs(g).map(|d| self.folder_item(d)).collect(),
        }
    }

    pub fn file_groups(
        &self,
        offset: usize,
        limit: usize,
        sort: SortKey,
        descending: bool,
        filter: &GroupFilter,
    ) -> Page<FileGroupView> {
        let order = self.ordered(GroupKind::Files, sort, descending, filter);
        Page {
            total: order.len(),
            items: order
                .iter()
                .skip(offset)
                .take(limit)
                .map(|&g| self.file_group_view(g))
                .collect(),
        }
    }

    pub fn folder_groups(
        &self,
        offset: usize,
        limit: usize,
        sort: SortKey,
        descending: bool,
        filter: &GroupFilter,
    ) -> Page<FolderGroupView> {
        let order = self.ordered(GroupKind::Folders, sort, descending, filter);
        Page {
            total: order.len(),
            items: order
                .iter()
                .skip(offset)
                .take(limit)
                .map(|&g| self.folder_group_view(g))
                .collect(),
        }
    }

    pub fn empty_folders(
        &self,
        offset: usize,
        limit: usize,
        sort: SortKey,
        descending: bool,
        filter: &GroupFilter,
    ) -> Page<FolderItem> {
        let order = self.ordered(GroupKind::EmptyFolders, sort, descending, filter);
        Page {
            total: order.len(),
            items: order
                .iter()
                .skip(offset)
                .take(limit)
                .map(|&d| self.folder_item(d))
                .collect(),
        }
    }

    pub fn large_file_item(&self, f: u32) -> FileItem {
        FileItem {
            selected: self.large_selected[f as usize],
            ..self.file_item(f)
        }
    }

    pub fn large_files(
        &self,
        offset: usize,
        limit: usize,
        sort: SortKey,
        descending: bool,
        filter: &GroupFilter,
    ) -> Page<FileItem> {
        let order = self.ordered(GroupKind::LargeFiles, sort, descending, filter);
        Page {
            total: order.len(),
            items: order
                .iter()
                .skip(offset)
                .take(limit)
                .map(|&f| self.large_file_item(f))
                .collect(),
        }
    }

    /// Files not changed for a long time, filtered by `filter`
    /// (`modified_before_ns`, `within`, `extensions`, size, search).
    /// They have their own selection ([`Session::set_old_selected`]).
    pub fn old_files(
        &self,
        offset: usize,
        limit: usize,
        sort: SortKey,
        descending: bool,
        filter: &GroupFilter,
    ) -> Page<FileItem> {
        let order = self.ordered(GroupKind::OldFiles, sort, descending, filter);
        Page {
            total: order.len(),
            items: order
                .iter()
                .skip(offset)
                .take(limit)
                .map(|&f| FileItem {
                    selected: self.old_selected[f as usize],
                    ..self.file_item(f)
                })
                .collect(),
        }
    }

    pub fn set_old_selected(&mut self, f: u32, selected: bool) -> Result<(), SelectionError> {
        let idx = f as usize;
        if idx >= self.result.files.len() || !self.result.files[idx].eligible {
            return Err(SelectionError::Unknown);
        }
        if self.file_state[idx] != ItemState::Present {
            return Err(SelectionError::NotPresent);
        }
        self.old_selected[idx] = selected;
        Ok(())
    }

    pub fn selected_old_files(&self) -> Vec<u32> {
        (0..self.old_selected.len() as u32)
            .filter(|&f| {
                self.old_selected[f as usize] && self.file_state[f as usize] == ItemState::Present
            })
            .collect()
    }

    // ── Photos ─────────────────────────────────────────────────────────

    // ── Audio and video ────────────────────────────────────────────────

    /// Audio and video files worth fingerprinting.
    pub fn media_candidates(&self) -> Vec<(u32, PathBuf, u64, i64)> {
        (0..self.result.files.len() as u32)
            .filter(|&f| {
                let file = &self.result.files[f as usize];
                file.eligible
                    && self.file_state[f as usize] == ItemState::Present
                    && crate::media::is_supported(paths::extension_lower(&file.name).as_deref())
            })
            .map(|f| {
                let file = &self.result.files[f as usize];
                (f, self.result.file_path(f), file.size, file.modified_ns)
            })
            .collect()
    }

    /// Stores fingerprints and groups similar songs and videos. Earlier
    /// selections on that list are cleared.
    pub fn set_media_analysis(
        &mut self,
        features: Vec<(u32, crate::media::MediaFeatures)>,
        failed: u64,
    ) {
        let mut ordered = features;
        ordered.sort_by_key(|(f, _)| self.result.file_path(*f));
        let mut groups = crate::media::group_similar(&ordered);
        // Sets of byte-identical copies are already duplicate groups.
        groups.retain(|members| {
            let first = self.file_group_of[members[0] as usize];
            first == NO_ID
                || members
                    .iter()
                    .any(|&f| self.file_group_of[f as usize] != first)
        });
        self.media_group_of = groups
            .iter()
            .enumerate()
            .flat_map(|(g, members)| members.iter().map(move |&f| (f, g as u32)))
            .collect();
        self.media_selected.iter_mut().for_each(|s| *s = false);
        self.media = Some(MediaAnalysis {
            analyzed: ordered.len() as u64,
            durations: ordered.iter().map(|(f, m)| (*f, m.duration_ms)).collect(),
            groups,
            failed,
        });
        self.bump_generation();
    }

    pub fn media_analysis(&self) -> Option<&MediaAnalysis> {
        self.media.as_ref()
    }

    fn live_media(&self, g: u32) -> Vec<u32> {
        self.media
            .as_ref()
            .and_then(|m| m.groups.get(g as usize))
            .map(|members| {
                members
                    .iter()
                    .copied()
                    .filter(|&f| self.file_state[f as usize] == ItemState::Present)
                    .collect()
            })
            .unwrap_or_default()
    }

    /// The largest present copy (usually the best quality), then by path.
    fn media_best(&self, g: u32) -> Option<u32> {
        self.live_media(g).into_iter().max_by(|&a, &b| {
            self.result.files[a as usize]
                .size
                .cmp(&self.result.files[b as usize].size)
                .then_with(|| self.result.file_path(b).cmp(&self.result.file_path(a)))
        })
    }

    fn media_reclaimable(&self, g: u32) -> u64 {
        let best = self.media_best(g);
        self.live_media(g)
            .into_iter()
            .filter(|&f| Some(f) != best)
            .map(|f| self.result.files[f as usize].size)
            .sum()
    }

    pub fn media_group_view(&self, g: u32) -> SimilarMediaView {
        let best = self.media_best(g);
        let mut live = self.live_media(g);
        live.sort_by_key(|&f| (Some(f) != best, self.result.file_path(f)));
        SimilarMediaView {
            index: g,
            reclaimable: self.media_reclaimable(g),
            items: live
                .into_iter()
                .map(|f| {
                    let file = &self.result.files[f as usize];
                    MediaItem {
                        id: f,
                        path: self.result.file_path(f),
                        size: file.size,
                        modified_ns: file.modified_ns,
                        duration_ms: self
                            .media
                            .as_ref()
                            .and_then(|m| m.durations.get(&f).copied().flatten()),
                        video: crate::media::is_video(
                            paths::extension_lower(&file.name).as_deref(),
                        ),
                        best: Some(f) == best,
                        selected: self.media_selected[f as usize],
                    }
                })
                .collect(),
        }
    }

    pub fn media_groups(
        &self,
        offset: usize,
        limit: usize,
        sort: SortKey,
        descending: bool,
        filter: &GroupFilter,
    ) -> Page<SimilarMediaView> {
        let order = self.ordered(GroupKind::SimilarMedia, sort, descending, filter);
        Page {
            total: order.len(),
            items: order
                .iter()
                .skip(offset)
                .take(limit)
                .map(|&g| self.media_group_view(g))
                .collect(),
        }
    }

    /// Ticks a song or video; one copy of each set stays unticked.
    pub fn set_media_selected(&mut self, f: u32, selected: bool) -> Result<(), SelectionError> {
        let Some(&g) = self.media_group_of.get(&f) else {
            return Err(SelectionError::Unknown);
        };
        if self.file_state[f as usize] != ItemState::Present {
            return Err(SelectionError::NotPresent);
        }
        if selected && !self.media_selected[f as usize] {
            let unselected = self
                .live_media(g)
                .into_iter()
                .filter(|&m| !self.media_selected[m as usize])
                .count();
            if unselected <= 1 {
                return Err(SelectionError::WouldSelectAll);
            }
        }
        self.media_selected[f as usize] = selected;
        Ok(())
    }

    /// Ticks every copy except the best of each set; returns sets changed.
    pub fn select_all_but_best_media(&mut self, filter: &GroupFilter) -> u64 {
        let order = self.ordered(GroupKind::SimilarMedia, SortKey::Wasted, true, filter);
        let mut changed = 0;
        for &g in order.iter() {
            let best = self.media_best(g);
            for f in self.live_media(g) {
                self.media_selected[f as usize] = Some(f) != best;
            }
            changed += 1;
        }
        changed
    }

    pub fn selected_media(&self) -> Vec<u32> {
        (0..self.media_selected.len() as u32)
            .filter(|&f| {
                self.media_selected[f as usize] && self.file_state[f as usize] == ItemState::Present
            })
            .collect()
    }

    pub fn media_group_of(&self, f: u32) -> Option<u32> {
        self.media_group_of.get(&f).copied()
    }

    pub(crate) fn media_members(&self, g: u32) -> Vec<u32> {
        self.live_media(g)
    }

    /// Image files worth analysing: present, reported, in a supported format.
    pub fn photo_candidates(&self) -> Vec<(u32, PathBuf, u64, i64)> {
        (0..self.result.files.len() as u32)
            .filter(|&f| {
                let file = &self.result.files[f as usize];
                file.eligible
                    && self.file_state[f as usize] == ItemState::Present
                    && crate::photos::is_supported(paths::extension_lower(&file.name).as_deref())
            })
            .map(|f| {
                let file = &self.result.files[f as usize];
                (f, self.result.file_path(f), file.size, file.modified_ns)
            })
            .collect()
    }

    /// Stores photo features and groups them. Earlier photo selections are
    /// cleared.
    pub fn set_photo_analysis(&mut self, features: Vec<(u32, PhotoFeatures)>, failed: u64) {
        let mut ordered = features;
        ordered.sort_by_key(|(f, _)| self.result.file_path(*f));
        let mut groups = crate::photos::group_similar(&ordered);
        // Sets of byte-identical copies are already duplicate groups.
        groups.retain(|members| {
            let first = self.file_group_of[members[0] as usize];
            first == NO_ID
                || members
                    .iter()
                    .any(|&f| self.file_group_of[f as usize] != first)
        });
        let mut issues = HashMap::new();
        for (f, feats) in &ordered {
            let file = &self.result.files[*f as usize];
            let folder = self.result.dir_path(file.dir).to_string_lossy();
            let found = crate::photos::issues(feats, &file.name.to_string_lossy(), &folder);
            if !found.is_empty() {
                issues.insert(*f, found);
            }
        }
        self.similar_group_of = groups
            .iter()
            .enumerate()
            .flat_map(|(g, members)| members.iter().map(move |&f| (f, g as u32)))
            .collect();
        self.similar_selected.iter_mut().for_each(|s| *s = false);
        self.photo_selected.iter_mut().for_each(|s| *s = false);
        self.photo = Some(PhotoAnalysis {
            analyzed: ordered.len() as u64,
            features: ordered.into_iter().collect(),
            groups,
            issues,
            failed,
        });
        self.bump_generation();
    }

    pub fn photo_analysis(&self) -> Option<&PhotoAnalysis> {
        self.photo.as_ref()
    }

    fn live_similar(&self, g: u32) -> Vec<u32> {
        self.photo
            .as_ref()
            .and_then(|p| p.groups.get(g as usize))
            .map(|members| {
                members
                    .iter()
                    .copied()
                    .filter(|&f| self.file_state[f as usize] == ItemState::Present)
                    .collect()
            })
            .unwrap_or_default()
    }

    fn files_bytes(&self, files: &[u32]) -> u64 {
        files
            .iter()
            .map(|&f| self.result.files[f as usize].size)
            .sum()
    }

    /// The best present photo of a similar group.
    fn similar_best(&self, g: u32) -> Option<u32> {
        let p = self.photo.as_ref()?;
        let members: Vec<(u32, PhotoFeatures, u64)> = self
            .live_similar(g)
            .into_iter()
            .filter_map(|f| {
                p.features
                    .get(&f)
                    .map(|ft| (f, *ft, self.result.files[f as usize].size))
            })
            .collect();
        crate::photos::best_shot(&members)
    }

    fn similar_reclaimable(&self, g: u32) -> u64 {
        let live = self.live_similar(g);
        let best = self.similar_best(g);
        live.iter()
            .filter(|&&f| Some(f) != best)
            .map(|&f| self.result.files[f as usize].size)
            .sum()
    }

    fn photo_item(&self, f: u32, best: bool, selected: bool) -> PhotoItem {
        let file = &self.result.files[f as usize];
        let p = self.photo.as_ref();
        let feats = p.and_then(|p| p.features.get(&f));
        PhotoItem {
            id: f,
            path: self.result.file_path(f),
            size: file.size,
            modified_ns: file.modified_ns,
            width: feats.map_or(0, |x| x.width),
            height: feats.map_or(0, |x| x.height),
            sharpness: feats.map_or(0.0, |x| x.sharpness),
            brightness: feats.map_or(0.0, |x| x.brightness),
            issues: p
                .and_then(|p| p.issues.get(&f))
                .cloned()
                .unwrap_or_default(),
            best,
            selected,
        }
    }

    pub fn similar_group_view(&self, g: u32) -> SimilarGroupView {
        let best = self.similar_best(g);
        let mut live = self.live_similar(g);
        live.sort_by_key(|&f| (Some(f) != best, self.result.file_path(f)));
        SimilarGroupView {
            index: g,
            reclaimable: self.similar_reclaimable(g),
            items: live
                .into_iter()
                .map(|f| self.photo_item(f, Some(f) == best, self.similar_selected[f as usize]))
                .collect(),
        }
    }

    pub fn similar_groups(
        &self,
        offset: usize,
        limit: usize,
        sort: SortKey,
        descending: bool,
        filter: &GroupFilter,
    ) -> Page<SimilarGroupView> {
        let order = self.ordered(GroupKind::SimilarPhotos, sort, descending, filter);
        Page {
            total: order.len(),
            items: order
                .iter()
                .skip(offset)
                .take(limit)
                .map(|&g| self.similar_group_view(g))
                .collect(),
        }
    }

    pub fn photo_issue_list(
        &self,
        offset: usize,
        limit: usize,
        sort: SortKey,
        descending: bool,
        filter: &GroupFilter,
    ) -> Page<PhotoItem> {
        let order = self.ordered(GroupKind::PhotoIssues, sort, descending, filter);
        Page {
            total: order.len(),
            items: order
                .iter()
                .skip(offset)
                .take(limit)
                .map(|&f| self.photo_item(f, false, self.photo_selected[f as usize]))
                .collect(),
        }
    }

    /// Ticks a similar photo; at least one photo of each set stays unticked.
    pub fn set_similar_selected(&mut self, f: u32, selected: bool) -> Result<(), SelectionError> {
        let Some(&g) = self.similar_group_of.get(&f) else {
            return Err(SelectionError::Unknown);
        };
        if self.file_state[f as usize] != ItemState::Present {
            return Err(SelectionError::NotPresent);
        }
        if selected && !self.similar_selected[f as usize] {
            let unselected = self
                .live_similar(g)
                .into_iter()
                .filter(|&m| !self.similar_selected[m as usize])
                .count();
            if unselected <= 1 {
                return Err(SelectionError::WouldSelectAll);
            }
        }
        self.similar_selected[f as usize] = selected;
        Ok(())
    }

    /// Ticks every similar photo except the best of each set. Returns the
    /// number of sets changed.
    pub fn select_all_but_best(&mut self, filter: &GroupFilter) -> u64 {
        let order = self.ordered(GroupKind::SimilarPhotos, SortKey::Wasted, true, filter);
        let mut changed = 0;
        for &g in order.iter() {
            let best = self.similar_best(g);
            for f in self.live_similar(g) {
                self.similar_selected[f as usize] = Some(f) != best;
            }
            changed += 1;
        }
        changed
    }

    pub fn set_photo_selected(&mut self, f: u32, selected: bool) -> Result<(), SelectionError> {
        let known = self
            .photo
            .as_ref()
            .is_some_and(|p| p.issues.contains_key(&f));
        if !known {
            return Err(SelectionError::Unknown);
        }
        if self.file_state[f as usize] != ItemState::Present {
            return Err(SelectionError::NotPresent);
        }
        self.photo_selected[f as usize] = selected;
        Ok(())
    }

    pub fn selected_similar(&self) -> Vec<u32> {
        (0..self.similar_selected.len() as u32)
            .filter(|&f| {
                self.similar_selected[f as usize]
                    && self.file_state[f as usize] == ItemState::Present
            })
            .collect()
    }

    pub fn selected_photo_issues(&self) -> Vec<u32> {
        (0..self.photo_selected.len() as u32)
            .filter(|&f| {
                self.photo_selected[f as usize] && self.file_state[f as usize] == ItemState::Present
            })
            .collect()
    }

    /// The similar group of a photo, for actions.
    pub fn similar_group_of(&self, f: u32) -> Option<u32> {
        self.similar_group_of.get(&f).copied()
    }

    pub(crate) fn similar_members(&self, g: u32) -> Vec<u32> {
        self.live_similar(g)
    }

    pub fn junk_item(&self, j: u32) -> JunkItem {
        let entry = &self.result.junk[j as usize];
        JunkItem {
            id: j,
            path: self.result.junk_path(j),
            size: entry.size,
            modified_ns: entry.modified_ns,
            kind: entry.kind,
            selected: self.junk_selected[j as usize],
        }
    }

    pub fn junk(
        &self,
        offset: usize,
        limit: usize,
        sort: SortKey,
        descending: bool,
        filter: &GroupFilter,
    ) -> Page<JunkItem> {
        let order = self.ordered(GroupKind::Junk, sort, descending, filter);
        Page {
            total: order.len(),
            items: order
                .iter()
                .skip(offset)
                .take(limit)
                .map(|&j| self.junk_item(j))
                .collect(),
        }
    }

    pub fn set_junk_selected(&mut self, j: u32, selected: bool) -> Result<(), SelectionError> {
        if j as usize >= self.junk_selected.len() {
            return Err(SelectionError::Unknown);
        }
        if !self.junk_present(j) {
            return Err(SelectionError::NotPresent);
        }
        self.junk_selected[j as usize] = selected;
        Ok(())
    }

    /// Selects every junk item whose removal is always safe (system caches)
    /// among those matching `filter`. Returns how many were selected.
    pub fn select_safe_junk(&mut self, filter: &GroupFilter) -> u64 {
        let order = self.ordered(GroupKind::Junk, SortKey::Size, true, filter);
        let mut n = 0;
        for &j in order.iter() {
            if self.result.junk[j as usize].kind.is_safe() {
                self.junk_selected[j as usize] = true;
                n += 1;
            }
        }
        n
    }

    pub fn selected_junk(&self) -> Vec<u32> {
        (0..self.junk_selected.len() as u32)
            .filter(|&j| self.junk_selected[j as usize] && self.junk_present(j))
            .collect()
    }

    /// Picks a file from the large- or old-files list for removal.
    pub fn set_large_selected(&mut self, f: u32, selected: bool) -> Result<(), SelectionError> {
        let idx = f as usize;
        if idx >= self.result.files.len() || !self.result.files[idx].eligible {
            return Err(SelectionError::Unknown);
        }
        if self.file_state[idx] != ItemState::Present {
            return Err(SelectionError::NotPresent);
        }
        self.large_selected[idx] = selected;
        Ok(())
    }

    /// Files picked one by one from the large-files list.
    pub fn selected_large_files(&self) -> Vec<u32> {
        (0..self.large_selected.len() as u32)
            .filter(|&f| {
                self.large_selected[f as usize] && self.file_state[f as usize] == ItemState::Present
            })
            .collect()
    }

    /// Files inside a folder (direct children), for previews and comparisons.
    pub fn folder_children(&self, d: u32) -> (Vec<FileItem>, Vec<FolderItem>) {
        let dir = &self.result.dirs[d as usize];
        let files = dir
            .files
            .iter()
            .filter(|&&f| self.file_state[f as usize] == ItemState::Present)
            .map(|&f| self.file_item(f))
            .collect();
        let dirs = dir
            .subdirs
            .iter()
            .filter(|&&s| self.dir_state[s as usize] == ItemState::Present)
            .map(|&s| self.folder_item(s))
            .collect();
        (files, dirs)
    }

    // ── Storage overview ───────────────────────────────────────────────

    /// Space used by every scanned file still present, per category,
    /// largest first.
    pub fn category_usage(&self) -> Vec<CategoryUsage> {
        let mut acc: std::collections::BTreeMap<FileCategory, (u64, u64)> = Default::default();
        for (f, file) in self.result.files.iter().enumerate() {
            if self.file_state[f] == ItemState::Present {
                let e = acc.entry(file.category).or_default();
                e.0 += 1;
                e.1 += file.size;
            }
        }
        let mut out: Vec<CategoryUsage> = acc
            .into_iter()
            .map(|(category, (files, bytes))| CategoryUsage {
                category,
                files,
                bytes,
            })
            .collect();
        out.sort_by_key(|n| std::cmp::Reverse(n.bytes));
        out
    }

    /// Size and file count of every folder's tree, counting only files
    /// still present. Computed once per generation.
    fn live_tree(&self) -> LiveTree {
        if let Some((generation, tree)) = self.live_tree_cache.lock().as_ref() {
            if *generation == self.generation {
                return tree.clone();
            }
        }
        let dirs = &self.result.dirs;
        let mut tree = vec![(0u64, 0u64); dirs.len()];
        for d in (0..dirs.len()).rev() {
            if self.dir_state[d] != ItemState::Present {
                continue;
            }
            let (mut bytes, mut files) = (0, 0);
            for &f in &dirs[d].files {
                if self.file_state[f as usize] == ItemState::Present {
                    bytes += self.result.files[f as usize].size;
                    files += 1;
                }
            }
            for &s in &dirs[d].subdirs {
                bytes += tree[s as usize].0;
                files += tree[s as usize].1;
            }
            tree[d] = (bytes, files);
        }
        let tree = Arc::new(tree);
        *self.live_tree_cache.lock() = Some((self.generation, tree.clone()));
        tree
    }

    /// What takes up space inside `dir` (scan roots for `None`): its
    /// sub-folders and, as one node, the files directly in it. Largest
    /// first.
    pub fn space_children(&self, dir: Option<u32>) -> Vec<SpaceNode> {
        let tree = self.live_tree();
        let node = |d: u32| SpaceNode {
            dir: d,
            path: self.result.dirs[d as usize].path.clone(),
            bytes: tree[d as usize].0,
            files: tree[d as usize].1,
            folders: self.result.dirs[d as usize]
                .subdirs
                .iter()
                .filter(|&&s| self.dir_state[s as usize] == ItemState::Present)
                .count() as u64,
        };
        let mut out: Vec<SpaceNode> = match dir {
            None => (0..self.result.dirs.len() as u32)
                .filter(|&d| {
                    let r = &self.result.dirs[d as usize];
                    r.is_root && r.parent == NO_ID
                })
                .map(node)
                .collect(),
            Some(d) => {
                let record = &self.result.dirs[d as usize];
                let mut out: Vec<SpaceNode> = record
                    .subdirs
                    .iter()
                    .copied()
                    .filter(|&s| self.dir_state[s as usize] == ItemState::Present)
                    .map(node)
                    .collect();
                let (bytes, files) = record
                    .files
                    .iter()
                    .filter(|&&f| self.file_state[f as usize] == ItemState::Present)
                    .fold((0, 0), |(b, n), &f| {
                        (b + self.result.files[f as usize].size, n + 1)
                    });
                if files > 0 {
                    out.push(SpaceNode {
                        dir: NO_ID,
                        path: record.path.clone(),
                        bytes,
                        files,
                        folders: 0,
                    });
                }
                out
            }
        };
        out.retain(|n| n.bytes > 0 || n.files > 0);
        out.sort_by_key(|n| std::cmp::Reverse(n.bytes));
        out
    }

    /// Biggest files directly inside `dir` (for the "files here" node).
    pub fn files_in(&self, dir: u32, limit: usize) -> Vec<FileItem> {
        let mut files: Vec<u32> = self.result.dirs[dir as usize]
            .files
            .iter()
            .copied()
            .filter(|&f| self.file_state[f as usize] == ItemState::Present)
            .collect();
        files.sort_by_key(|&f| std::cmp::Reverse(self.result.files[f as usize].size));
        files
            .into_iter()
            .take(limit)
            .map(|f| self.large_file_item(f))
            .collect()
    }

    // ── Recommendations ────────────────────────────────────────────────

    /// Copies inside `downloads` that can go while a copy is kept: every
    /// such copy when one exists elsewhere, all but one otherwise.
    fn download_duplicates(&self, downloads: &[PathBuf]) -> Vec<u32> {
        let mut out = Vec::new();
        if downloads.is_empty() {
            return out;
        }
        for g in 0..self.result.file_groups.len() as u32 {
            if self.file_group_ignored[g as usize] {
                continue;
            }
            let members: Vec<u32> = self.present_files(g).collect();
            if members.len() < 2 {
                continue;
            }
            let (inside, outside): (Vec<u32>, Vec<u32>) = members.into_iter().partition(|&f| {
                paths::is_within_any(
                    self.result.dir_path(self.result.files[f as usize].dir),
                    downloads,
                )
            });
            if outside.is_empty() {
                // Keep the oldest download, which is usually the original.
                let keep = inside
                    .iter()
                    .copied()
                    .min_by_key(|&f| (self.result.files[f as usize].modified_ns, f));
                out.extend(inside.into_iter().filter(|&f| Some(f) != keep));
            } else {
                out.extend(inside);
            }
        }
        out
    }

    fn junk_of(&self, kinds: &[JunkKind]) -> impl Iterator<Item = u32> + '_ {
        let kinds = kinds.to_vec();
        (0..self.result.junk.len() as u32).filter(move |&j| {
            kinds.contains(&self.result.junk[j as usize].kind) && self.junk_present(j)
        })
    }

    /// Low-risk cleanups, with how much each would free. `downloads` are
    /// the user's download folders.
    pub fn recommendations(&self, downloads: &[PathBuf]) -> Vec<Recommendation> {
        let downloads: Vec<PathBuf> = downloads.iter().map(|p| paths::normalize(p)).collect();
        let sum_junk = |kinds: &[JunkKind]| {
            self.junk_of(kinds).fold((0, 0), |(n, b), j| {
                (n + 1, b + self.result.junk[j as usize].size)
            })
        };
        let dupes = self.download_duplicates(&downloads);
        let mut out = vec![
            {
                let (items, bytes) = sum_junk(&[JunkKind::SystemCache]);
                Recommendation {
                    kind: RecommendationKind::SystemCaches,
                    items,
                    bytes,
                }
            },
            {
                let (items, bytes) = sum_junk(&[JunkKind::PartialDownload, JunkKind::TempFile]);
                Recommendation {
                    kind: RecommendationKind::LeftoverFiles,
                    items,
                    bytes,
                }
            },
            Recommendation {
                kind: RecommendationKind::DownloadDuplicates,
                items: dupes.len() as u64,
                bytes: dupes
                    .iter()
                    .map(|&f| self.result.files[f as usize].size)
                    .sum(),
            },
            Recommendation {
                kind: RecommendationKind::EmptyFolders,
                items: self
                    .result
                    .empty_folders
                    .iter()
                    .filter(|&&d| self.dir_state[d as usize] == ItemState::Present)
                    .count() as u64,
                bytes: 0,
            },
        ];
        out.retain(|r| r.items > 0);
        out
    }

    /// Replaces the selection of the matching list with what a
    /// recommendation removes, and returns that list's kind. Junk
    /// recommendations add to each other; call [`Session::clear_selection`]
    /// first to start fresh.
    pub fn select_recommendation(
        &mut self,
        kind: RecommendationKind,
        downloads: &[PathBuf],
    ) -> GroupKind {
        match kind {
            RecommendationKind::SystemCaches | RecommendationKind::LeftoverFiles => {
                let kinds: &[JunkKind] = if kind == RecommendationKind::SystemCaches {
                    &[JunkKind::SystemCache]
                } else {
                    &[JunkKind::PartialDownload, JunkKind::TempFile]
                };
                let picked: Vec<u32> = self.junk_of(kinds).collect();
                for j in picked {
                    self.junk_selected[j as usize] = true;
                }
                GroupKind::Junk
            }
            RecommendationKind::DownloadDuplicates => {
                let downloads: Vec<PathBuf> =
                    downloads.iter().map(|p| paths::normalize(p)).collect();
                self.clear_selection(GroupKind::Files);
                for f in self.download_duplicates(&downloads) {
                    self.file_selected[f as usize] = true;
                }
                GroupKind::Files
            }
            RecommendationKind::EmptyFolders => {
                self.clear_selection(GroupKind::EmptyFolders);
                self.select_all_empty_folders(&GroupFilter::default());
                GroupKind::EmptyFolders
            }
        }
    }

    /// Marks items removed outside the session (e.g. archived and moved to
    /// the recovery bin) so the results stop showing them.
    pub fn mark_removed(&mut self, removed: &[PathBuf]) -> usize {
        // The items may be gone already: normalise through their parent.
        let wanted: Vec<PathBuf> = removed
            .iter()
            .map(|p| match (p.parent(), p.file_name()) {
                (Some(parent), Some(name)) if !p.exists() => paths::normalize(parent).join(name),
                _ => paths::normalize(p),
            })
            .collect();
        let same = |a: &Path| {
            wanted
                .iter()
                .any(|w| paths::starts_with(a, w) && paths::starts_with(w, a))
        };
        let dirs: Vec<u32> = (0..self.result.dirs.len() as u32)
            .filter(|&d| {
                self.dir_state[d as usize] == ItemState::Present && same(self.result.dir_path(d))
            })
            .collect();
        let mut n = 0;
        for d in dirs {
            if self.dir_state[d as usize] == ItemState::Present {
                self.mark_dir_tree(d, ItemState::Removed);
                n += 1;
            }
        }
        for f in 0..self.result.files.len() as u32 {
            if self.file_state[f as usize] == ItemState::Present && same(&self.result.file_path(f))
            {
                self.mark_file(f, ItemState::Removed);
                n += 1;
            }
        }
        if n > 0 {
            self.bump_generation();
        }
        n
    }

    /// Category breakdown of reclaimable space across active file groups.
    pub fn category_breakdown(&self) -> Vec<(FileCategory, u64, u64)> {
        let mut acc: std::collections::BTreeMap<FileCategory, (u64, u64)> = Default::default();
        for g in 0..self.result.file_groups.len() as u32 {
            let wasted = self.file_group_wasted(g);
            if self.file_group_ignored[g as usize] || (wasted == 0 && self.live_file_count(g) < 2) {
                continue;
            }
            let e = acc
                .entry(self.result.file_groups[g as usize].category)
                .or_default();
            e.0 += 1;
            e.1 += wasted;
        }
        acc.into_iter().map(|(c, (n, w))| (c, n, w)).collect()
    }

    // ── Selection ──────────────────────────────────────────────────────

    pub fn set_file_selected(&mut self, f: u32, selected: bool) -> Result<(), SelectionError> {
        let idx = f as usize;
        if idx >= self.file_selected.len() {
            return Err(SelectionError::Unknown);
        }
        if self.file_state[idx] != ItemState::Present {
            return Err(SelectionError::NotPresent);
        }
        let group = self.file_group_of[idx];
        if group == NO_ID {
            return Err(SelectionError::Unknown);
        }
        if self.file_group_ignored[group as usize] {
            return Err(SelectionError::NotPresent);
        }
        if selected && !self.file_selected[idx] {
            let unselected = self
                .present_files(group)
                .filter(|&m| !self.file_selected[m as usize])
                .count();
            if unselected <= 1 {
                return Err(SelectionError::WouldSelectAll);
            }
        }
        self.file_selected[idx] = selected;
        Ok(())
    }

    pub fn set_dir_selected(&mut self, d: u32, selected: bool) -> Result<(), SelectionError> {
        let idx = d as usize;
        if idx >= self.dir_selected.len() {
            return Err(SelectionError::Unknown);
        }
        if self.dir_state[idx] != ItemState::Present {
            return Err(SelectionError::NotPresent);
        }
        let group = self.folder_group_of[idx];
        if group == NO_ID {
            if !self.is_empty_entry[idx] {
                return Err(SelectionError::Unknown);
            }
        } else if self.folder_group_ignored[group as usize] || self.dir_partial[idx] {
            return Err(SelectionError::NotPresent);
        } else if selected && !self.dir_selected[idx] {
            let unselected = self
                .present_dirs(group)
                .filter(|&m| !self.dir_selected[m as usize])
                .count();
            if unselected <= 1 {
                return Err(SelectionError::WouldSelectAll);
            }
        }
        self.dir_selected[idx] = selected;
        Ok(())
    }

    /// Selects every copy of a group except `keep`.
    pub fn keep_only(&mut self, kind: GroupKind, group: u32, keep: u32) {
        match kind {
            GroupKind::Files => {
                let members: Vec<u32> = self.present_files(group).collect();
                if self.file_group_ignored[group as usize] || !members.contains(&keep) {
                    return;
                }
                for m in members {
                    self.file_selected[m as usize] = m != keep;
                }
            }
            GroupKind::Folders => {
                let members: Vec<u32> = self.present_dirs(group).collect();
                if self.folder_group_ignored[group as usize] || !members.contains(&keep) {
                    return;
                }
                for m in members {
                    self.dir_selected[m as usize] = m != keep;
                }
            }
            GroupKind::EmptyFolders
            | GroupKind::LargeFiles
            | GroupKind::Junk
            | GroupKind::OldFiles
            | GroupKind::SimilarPhotos
            | GroupKind::PhotoIssues
            | GroupKind::SimilarMedia => {}
        }
    }

    pub fn clear_selection(&mut self, kind: GroupKind) {
        match kind {
            GroupKind::Files => self.file_selected.iter_mut().for_each(|s| *s = false),
            GroupKind::Folders => {
                for (d, s) in self.dir_selected.iter_mut().enumerate() {
                    if self.folder_group_of[d] != NO_ID {
                        *s = false;
                    }
                }
            }
            GroupKind::EmptyFolders => {
                for (d, s) in self.dir_selected.iter_mut().enumerate() {
                    if self.is_empty_entry[d] {
                        *s = false;
                    }
                }
            }
            GroupKind::LargeFiles => self.large_selected.iter_mut().for_each(|s| *s = false),
            GroupKind::OldFiles => self.old_selected.iter_mut().for_each(|s| *s = false),
            GroupKind::SimilarPhotos => self.similar_selected.iter_mut().for_each(|s| *s = false),
            GroupKind::SimilarMedia => self.media_selected.iter_mut().for_each(|s| *s = false),
            GroupKind::PhotoIssues => self.photo_selected.iter_mut().for_each(|s| *s = false),
            GroupKind::Junk => self.junk_selected.iter_mut().for_each(|s| *s = false),
        }
    }

    pub fn select_all_empty_folders(&mut self, filter: &GroupFilter) {
        let order = self.ordered(GroupKind::EmptyFolders, SortKey::Path, false, filter);
        for &d in order.iter() {
            self.dir_selected[d as usize] = true;
        }
    }

    fn pick_keeper(
        &self,
        members: &[u32],
        rule: &SelectionRule,
        path_of: impl Fn(u32) -> PathBuf,
        mtime_of: impl Fn(u32) -> i64,
    ) -> Option<u32> {
        let preferred: Vec<u32> = if rule.prefer_keep_in.is_empty() {
            Vec::new()
        } else {
            members
                .iter()
                .copied()
                .filter(|&m| paths::is_within_any(&path_of(m), &rule.prefer_keep_in))
                .collect()
        };
        let pool: &[u32] = if preferred.is_empty() {
            members
        } else {
            &preferred
        };
        let depth = |m: u32| path_of(m).components().count();
        let len = |m: u32| path_of(m).as_os_str().len();
        let pick = match rule.strategy {
            KeepStrategy::Newest => pool
                .iter()
                .max_by_key(|&&m| (mtime_of(m), std::cmp::Reverse(m))),
            KeepStrategy::Oldest => pool.iter().min_by_key(|&&m| (mtime_of(m), m)),
            KeepStrategy::ShortestPath => pool.iter().min_by_key(|&&m| (len(m), m)),
            KeepStrategy::LongestPath => {
                pool.iter().max_by_key(|&&m| (len(m), std::cmp::Reverse(m)))
            }
            KeepStrategy::ShallowestPath => pool.iter().min_by_key(|&&m| (depth(m), len(m), m)),
            KeepStrategy::FirstAlphabetical => pool
                .iter()
                .min_by_key(|&&m| path_of(m).to_string_lossy().to_lowercase()),
        };
        pick.copied()
    }

    /// Applies an automatic selection rule to every matching group of `kind`.
    /// Returns the number of groups changed.
    pub fn apply_rule(&mut self, kind: GroupKind, rule: &SelectionRule) -> u64 {
        if matches!(
            kind,
            GroupKind::LargeFiles
                | GroupKind::Junk
                | GroupKind::OldFiles
                | GroupKind::SimilarPhotos
                | GroupKind::PhotoIssues
                | GroupKind::SimilarMedia
        ) {
            return 0;
        }
        // Folder paths from pickers may differ in form from scanned paths.
        let rule = &SelectionRule {
            prefer_keep_in: rule
                .prefer_keep_in
                .iter()
                .map(|p| paths::normalize(p))
                .collect(),
            only_select_in: rule
                .only_select_in
                .iter()
                .map(|p| paths::normalize(p))
                .collect(),
            ..rule.clone()
        };
        let order = self.ordered(kind, SortKey::Wasted, true, &rule.filter);
        let mut changed = 0;
        for &g in order.iter() {
            let (members, keeper): (Vec<u32>, Option<u32>) = match kind {
                GroupKind::Files => {
                    let members: Vec<u32> = self.present_files(g).collect();
                    let keeper = self.pick_keeper(
                        &members,
                        rule,
                        |f| self.result.file_path(f),
                        |f| self.result.files[f as usize].modified_ns,
                    );
                    (members, keeper)
                }
                GroupKind::Folders => {
                    let members: Vec<u32> = self.present_dirs(g).collect();
                    let keeper = self.pick_keeper(
                        &members,
                        rule,
                        |d| self.result.dirs[d as usize].path.clone(),
                        |d| self.result.dirs[d as usize].modified_ns,
                    );
                    (members, keeper)
                }
                GroupKind::LargeFiles
                | GroupKind::Junk
                | GroupKind::OldFiles
                | GroupKind::SimilarPhotos
                | GroupKind::PhotoIssues
                | GroupKind::SimilarMedia => continue,
                GroupKind::EmptyFolders => {
                    self.dir_selected[g as usize] = rule.only_select_in.is_empty()
                        || paths::is_within_any(self.result.dir_path(g), &rule.only_select_in);
                    changed += 1;
                    continue;
                }
            };
            let Some(keeper) = keeper else { continue };
            for m in members {
                let path = match kind {
                    GroupKind::Files => self.result.file_path(m),
                    _ => self.result.dirs[m as usize].path.clone(),
                };
                let select = m != keeper
                    && (rule.only_select_in.is_empty()
                        || paths::is_within_any(&path, &rule.only_select_in));
                match kind {
                    GroupKind::Files => self.file_selected[m as usize] = select,
                    _ => self.dir_selected[m as usize] = select,
                }
            }
            changed += 1;
        }
        changed
    }

    pub fn summary(&self) -> SelectionSummary {
        let mut s = SelectionSummary::default();
        for (f, &sel) in self.file_selected.iter().enumerate() {
            if sel && self.file_state[f] == ItemState::Present {
                s.files += 1;
                s.file_bytes += self.result.files[f].size;
            }
        }
        for (d, &sel) in self.dir_selected.iter().enumerate() {
            if !sel || self.dir_state[d] != ItemState::Present {
                continue;
            }
            if self.folder_group_of[d] != NO_ID {
                s.folders += 1;
                s.folder_bytes += self.tree.bytes[d];
            } else if self.is_empty_entry[d] {
                s.empty_folders += 1;
            }
        }
        for g in 0..self.result.file_groups.len() as u32 {
            if !self.file_group_ignored[g as usize] && self.live_file_count(g) > 1 {
                s.active_file_groups += 1;
                s.file_wasted += self.file_group_wasted(g);
            }
        }
        for g in 0..self.result.folder_groups.len() as u32 {
            if !self.folder_group_ignored[g as usize] && self.live_dir_count(g) > 1 {
                s.active_folder_groups += 1;
                s.folder_wasted += self.folder_group_wasted(g);
            }
        }
        s.remaining_empty_folders = self
            .result
            .empty_folders
            .iter()
            .filter(|&&d| self.dir_state[d as usize] == ItemState::Present)
            .count() as u64;
        for &f in &self.result.large_files {
            if self.file_state[f as usize] == ItemState::Present {
                s.remaining_large_files += 1;
            }
        }
        for f in self.selected_large_files() {
            s.large_files += 1;
            s.large_file_bytes += self.result.files[f as usize].size;
        }
        for f in self.selected_old_files() {
            s.old_files += 1;
            s.old_file_bytes += self.result.files[f as usize].size;
        }
        if let Some(p) = &self.photo {
            s.photos_analyzed = true;
            for g in 0..p.groups.len() as u32 {
                if self.live_similar(g).len() > 1 {
                    s.similar_groups += 1;
                    s.similar_reclaimable += self.similar_reclaimable(g);
                }
            }
            s.remaining_photo_issues = p
                .issues
                .keys()
                .filter(|&&f| self.file_state[f as usize] == ItemState::Present)
                .count() as u64;
        }
        for f in self.selected_similar() {
            s.similar += 1;
            s.similar_bytes += self.result.files[f as usize].size;
        }
        for f in self.selected_photo_issues() {
            s.photo_issues += 1;
            s.photo_issue_bytes += self.result.files[f as usize].size;
        }
        if let Some(m) = &self.media {
            s.media_analyzed = true;
            for g in 0..m.groups.len() as u32 {
                if self.live_media(g).len() > 1 {
                    s.media_groups += 1;
                    s.media_reclaimable += self.media_reclaimable(g);
                }
            }
        }
        for f in self.selected_media() {
            s.media += 1;
            s.media_bytes += self.result.files[f as usize].size;
        }
        for j in 0..self.result.junk.len() as u32 {
            if !self.junk_present(j) {
                continue;
            }
            let size = self.result.junk[j as usize].size;
            s.remaining_junk += 1;
            s.remaining_junk_bytes += size;
            if self.junk_selected[j as usize] {
                s.junk += 1;
                s.junk_bytes += size;
            }
        }
        s
    }

    pub fn selected_files(&self) -> Vec<u32> {
        (0..self.file_selected.len() as u32)
            .filter(|&f| {
                self.file_selected[f as usize] && self.file_state[f as usize] == ItemState::Present
            })
            .collect()
    }

    pub fn file_group_of(&self, f: u32) -> u32 {
        self.file_group_of[f as usize]
    }

    pub fn folder_group_of(&self, d: u32) -> u32 {
        self.folder_group_of[d as usize]
    }

    // ── Ignore list ────────────────────────────────────────────────────

    /// Hides the duplicate groups whose content the user marked as "not
    /// duplicates", replacing the previous set. Members of hidden groups
    /// are deselected. Returns the number of groups hidden.
    pub fn set_ignored_content(
        &mut self,
        files: &HashSet<Digest>,
        folders: &HashSet<Digest>,
    ) -> u64 {
        let mut hidden = 0;
        for (g, group) in self.result.file_groups.iter().enumerate() {
            let ignored = files.contains(&group.digest);
            if ignored {
                hidden += 1;
                for &f in &group.files {
                    self.file_selected[f as usize] = false;
                }
            }
            self.file_group_ignored[g] = ignored;
        }
        for (g, group) in self.result.folder_groups.iter().enumerate() {
            let ignored = folders.contains(&group.digest);
            if ignored {
                hidden += 1;
                for &d in &group.dirs {
                    self.dir_selected[d as usize] = false;
                }
            }
            self.folder_group_ignored[g] = ignored;
        }
        self.bump_generation();
        hidden
    }

    /// Hides everything inside `folders`, as if they had been excluded from
    /// the scan. Folders containing one of them no longer match their
    /// copies. Returns the number of files hidden.
    pub fn ignore_folders(&mut self, folders: &[PathBuf]) -> u64 {
        let folders: Vec<PathBuf> = folders.iter().map(|p| paths::normalize(p)).collect();
        let mut hidden = 0;
        for d in 0..self.result.dirs.len() {
            if self.dir_state[d] != ItemState::Present
                || !paths::is_within_any(&self.result.dirs[d].path, &folders)
            {
                continue;
            }
            self.dir_state[d] = ItemState::Ignored;
            self.dir_selected[d] = false;
            for &f in &self.result.dirs[d].files {
                if self.file_state[f as usize] == ItemState::Present {
                    self.file_state[f as usize] = ItemState::Ignored;
                    self.file_selected[f as usize] = false;
                    self.large_selected[f as usize] = false;
                    self.old_selected[f as usize] = false;
                    self.similar_selected[f as usize] = false;
                    self.photo_selected[f as usize] = false;
                    self.media_selected[f as usize] = false;
                    hidden += 1;
                }
            }
            let mut p = self.result.dirs[d].parent;
            while p != NO_ID && !self.dir_partial[p as usize] {
                self.dir_partial[p as usize] = true;
                if self.folder_group_of[p as usize] != NO_ID {
                    self.dir_selected[p as usize] = false;
                }
                p = self.result.dirs[p as usize].parent;
            }
        }
        self.bump_generation();
        hidden
    }

    // ── State changes (used by actions) ────────────────────────────────

    pub(crate) fn mark_file(&mut self, f: u32, state: ItemState) {
        self.file_state[f as usize] = state;
        self.file_selected[f as usize] = false;
        self.large_selected[f as usize] = false;
        self.old_selected[f as usize] = false;
        self.similar_selected[f as usize] = false;
        self.photo_selected[f as usize] = false;
        self.media_selected[f as usize] = false;
        if state != ItemState::Linked {
            let dir = self.result.files[f as usize].dir;
            self.mark_ancestors_modified(dir);
        }
    }

    /// Records what happened to a junk item, and to its file record if it
    /// has one, so folder comparisons know the folder changed.
    pub(crate) fn mark_junk(&mut self, j: u32, state: ItemState) {
        self.junk_state[j as usize] = state;
        self.junk_selected[j as usize] = false;
        let entry = &self.result.junk[j as usize];
        let (file, dir, kind) = (entry.file, entry.dir, entry.kind);
        if file != NO_ID {
            self.mark_file(file, state);
        } else if kind != JunkKind::SystemCache {
            // System caches are ignored by folder comparison; others are not.
            self.mark_ancestors_modified(dir);
        }
    }

    pub(crate) fn mark_dir_tree(&mut self, d: u32, state: ItemState) {
        let mut subtree = Vec::new();
        self.result.for_each_descendant(d, |x| subtree.push(x));
        for x in subtree {
            self.dir_state[x as usize] = state;
            self.dir_selected[x as usize] = false;
            for i in 0..self.result.dirs[x as usize].files.len() {
                let f = self.result.dirs[x as usize].files[i];
                self.file_state[f as usize] = state;
                self.file_selected[f as usize] = false;
                self.large_selected[f as usize] = false;
                self.old_selected[f as usize] = false;
                self.similar_selected[f as usize] = false;
                self.photo_selected[f as usize] = false;
                self.media_selected[f as usize] = false;
            }
        }
        let parent = self.result.dirs[d as usize].parent;
        if parent != NO_ID {
            self.mark_ancestors_modified(parent);
        }
    }

    fn mark_ancestors_modified(&mut self, mut d: u32) {
        while d != NO_ID {
            if self.dir_modified[d as usize] {
                break;
            }
            self.dir_modified[d as usize] = true;
            d = self.result.dirs[d as usize].parent;
        }
    }

    /// Marks removed items as present again after they were restored from
    /// the recovery bin. Only items whose path exists again are revived.
    /// Returns the number of items revived.
    pub fn mark_present(&mut self, restored: &[PathBuf]) -> usize {
        let wanted: std::collections::HashSet<&Path> =
            restored.iter().map(PathBuf::as_path).collect();
        let mut revived = 0;
        let removed_dirs: Vec<u32> = (0..self.dir_state.len() as u32)
            .filter(|&d| self.dir_state[d as usize] == ItemState::Removed)
            .collect();
        for d in removed_dirs {
            let path = self.result.dir_path(d).to_path_buf();
            if wanted.contains(path.as_path()) && path.is_dir() {
                let mut subtree = Vec::new();
                self.result.for_each_descendant(d, |x| subtree.push(x));
                for x in subtree {
                    self.dir_state[x as usize] = ItemState::Present;
                    for i in 0..self.result.dirs[x as usize].files.len() {
                        let f = self.result.dirs[x as usize].files[i];
                        self.file_state[f as usize] = ItemState::Present;
                    }
                }
                revived += 1;
            }
        }
        for f in 0..self.file_state.len() {
            if self.file_state[f] != ItemState::Removed {
                continue;
            }
            let path = self.result.file_path(f as u32);
            if wanted.contains(path.as_path()) && path.is_file() {
                self.file_state[f] = ItemState::Present;
                revived += 1;
            }
        }
        for j in 0..self.junk_state.len() {
            if self.junk_state[j] != ItemState::Removed {
                continue;
            }
            let path = self.result.junk_path(j as u32);
            if wanted.contains(path.as_path()) && fs_exists_no_follow(&path) {
                self.junk_state[j] = ItemState::Present;
                revived += 1;
            }
        }
        if revived > 0 {
            self.bump_generation();
        }
        revived
    }

    pub fn file_state(&self, f: u32) -> ItemState {
        self.file_state[f as usize]
    }

    pub fn dir_state(&self, d: u32) -> ItemState {
        self.dir_state[d as usize]
    }

    pub fn tree_bytes(&self, d: u32) -> u64 {
        self.tree.bytes[d as usize]
    }

    pub fn tree_files(&self, d: u32) -> u64 {
        self.tree.files[d as usize]
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }
}

/// Exists as a file, folder or (possibly broken) link.
fn fs_exists_no_follow(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok()
}
