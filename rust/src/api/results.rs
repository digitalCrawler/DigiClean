use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::time::Duration;

use anyhow::{anyhow, Result};
use digiclean_engine as engine;
use engine::session::{GroupFilter, Session};
use flutter_rust_bridge::frb;
use parking_lot::{Mutex, RwLock, RwLockReadGuard, RwLockWriteGuard};

use crate::api::types::*;
use crate::convert::lossy;

/// UI-thread calls must never block behind a long-running action.
const UI_LOCK_TIMEOUT: Duration = Duration::from_millis(150);

/// The results of one scan. Groups are queried page by page; selection
/// lives here so rules and actions scale to millions of files.
#[frb(opaque)]
pub struct ScanResults {
    session: RwLock<Session>,
    action_control: Mutex<engine::ScanControl>,
    action_done: AtomicI64,
    action_total: AtomicI64,
    action_running: AtomicBool,
    /// When the scan finished, for results reopened from a snapshot.
    saved_finished_ms: Option<i64>,
}

fn filter(
    category: Option<Category>,
    search: Option<String>,
    min_size: Option<i64>,
) -> GroupFilter {
    GroupFilter {
        category: category.map(Into::into),
        search: search.filter(|s| !s.trim().is_empty()),
        min_size: min_size.map(|m| m.max(0) as u64),
        ..Default::default()
    }
}

fn junk_filter(search: Option<String>, kind: Option<JunkKind>) -> GroupFilter {
    GroupFilter {
        junk_kind: kind.map(Into::into),
        ..filter(None, search, None)
    }
}

fn algorithm_of(session: &Session) -> HashAlgo {
    match session.result.config.hash_algorithm {
        engine::HashAlgorithm::Blake3 => HashAlgo::Blake3,
        engine::HashAlgorithm::Sha256 => HashAlgo::Sha256,
    }
}

fn to_hex(digest: &[u8]) -> String {
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

fn from_hex(hex: &str) -> Option<engine::hashing::Digest> {
    let mut out = engine::hashing::Digest::default();
    if hex.len() != out.len() * 2 {
        return None;
    }
    for (i, b) in out.iter_mut().enumerate() {
        *b = u8::from_str_radix(hex.get(i * 2..i * 2 + 2)?, 16).ok()?;
    }
    Some(out)
}

fn busy() -> anyhow::Error {
    anyhow!("busy: an operation is still running")
}

impl ScanResults {
    pub(crate) fn from_result(result: engine::ScanResult) -> ScanResults {
        Self::from_session(Session::new(result), None)
    }

    fn from_session(session: Session, saved_finished_ms: Option<i64>) -> ScanResults {
        ScanResults {
            saved_finished_ms,
            session: RwLock::new(session),
            action_control: Mutex::new(engine::ScanControl::new()),
            action_done: AtomicI64::new(0),
            action_total: AtomicI64::new(0),
            action_running: AtomicBool::new(false),
        }
    }

    fn read_ui(&self) -> Result<RwLockReadGuard<'_, Session>> {
        self.session.try_read_for(UI_LOCK_TIMEOUT).ok_or_else(busy)
    }

    fn write_ui(&self) -> Result<RwLockWriteGuard<'_, Session>> {
        self.session.try_write_for(UI_LOCK_TIMEOUT).ok_or_else(busy)
    }

    #[frb(sync)]
    pub fn stats(&self) -> Result<ScanStatsDto> {
        Ok((&self.read_ui()?.result.stats).into())
    }

    #[frb(sync)]
    pub fn roots(&self) -> Result<Vec<String>> {
        Ok(self
            .read_ui()?
            .result
            .roots
            .iter()
            .map(|r| lossy(r))
            .collect())
    }

    #[frb(sync)]
    pub fn hash_algorithm(&self) -> Result<HashAlgo> {
        let session = self.read_ui()?;
        Ok(algorithm_of(&session))
    }

    /// Changes whenever an action alters the results; use it to invalidate
    /// cached pages.
    #[frb(sync)]
    pub fn generation(&self) -> Result<i64> {
        Ok(self.read_ui()?.generation() as i64)
    }

    #[frb(sync)]
    pub fn issues(&self) -> Result<Vec<IssueDto>> {
        Ok(self
            .read_ui()?
            .result
            .issues
            .iter()
            .map(|i| IssueDto {
                path: i.path.clone(),
                message: i.message.clone(),
            })
            .collect())
    }

    pub fn file_groups(&self, query: GroupQuery) -> FileGroupPage {
        let session = self.session.read();
        let page = session.file_groups(
            query.offset as usize,
            query.limit as usize,
            query.sort.into(),
            query.descending,
            &filter(query.category, query.search, query.min_size),
        );
        FileGroupPage {
            total: page.total as u32,
            groups: page.items.into_iter().map(Into::into).collect(),
        }
    }

    pub fn folder_groups(&self, query: GroupQuery) -> FolderGroupPage {
        let session = self.session.read();
        let page = session.folder_groups(
            query.offset as usize,
            query.limit as usize,
            query.sort.into(),
            query.descending,
            &filter(None, query.search, query.min_size),
        );
        FolderGroupPage {
            total: page.total as u32,
            groups: page.items.into_iter().map(Into::into).collect(),
        }
    }

    pub fn empty_folders(&self, query: GroupQuery) -> EmptyFolderPage {
        let session = self.session.read();
        let page = session.empty_folders(
            query.offset as usize,
            query.limit as usize,
            query.sort.into(),
            query.descending,
            &filter(None, query.search, None),
        );
        EmptyFolderPage {
            total: page.total as u32,
            folders: page.items.into_iter().map(Into::into).collect(),
        }
    }

    /// Junk items (filters: search, minimum size, kind).
    pub fn junk(&self, query: GroupQuery) -> JunkPage {
        let session = self.session.read();
        let mut f = junk_filter(query.search, query.junk_kind);
        f.min_size = query.min_size.map(|m| m.max(0) as u64);
        let page = session.junk(
            query.offset as usize,
            query.limit as usize,
            query.sort.into(),
            query.descending,
            &f,
        );
        JunkPage {
            total: page.total as u32,
            items: page.items.into_iter().map(Into::into).collect(),
        }
    }

    #[frb(sync)]
    pub fn set_junk_selected(&self, junk_id: u32, selected: bool) -> Result<SelectionSummaryDto> {
        let mut session = self.write_ui()?;
        session.set_junk_selected(junk_id, selected)?;
        Ok(session.summary().into())
    }

    /// Selects the junk that is always safe to remove (system caches),
    /// within the given search and kind.
    pub fn select_safe_junk(
        &self,
        search: Option<String>,
        kind: Option<JunkKind>,
    ) -> SelectionSummaryDto {
        let mut session = self.session.write();
        session.select_safe_junk(&junk_filter(search, kind));
        session.summary().into()
    }

    /// Files not changed for a long time (filters: age, folders,
    /// extensions, category, search, minimum size).
    pub fn old_files(&self, query: GroupQuery) -> LargeFilePage {
        let session = self.session.read();
        let f = GroupFilter {
            modified_before_ns: query
                .modified_before_ms
                .map(|ms| ms.saturating_mul(1_000_000)),
            within: query
                .within
                .unwrap_or_default()
                .into_iter()
                .map(Into::into)
                .collect(),
            extensions: query
                .extensions
                .unwrap_or_default()
                .into_iter()
                .map(|e| e.trim_start_matches('.').to_lowercase())
                .collect(),
            ..filter(query.category, query.search, query.min_size)
        };
        let page = session.old_files(
            query.offset as usize,
            query.limit as usize,
            query.sort.into(),
            query.descending,
            &f,
        );
        LargeFilePage {
            total: page.total as u32,
            files: page.items.into_iter().map(Into::into).collect(),
        }
    }

    /// The biggest files of the scan (filters: category, search, minimum size).
    pub fn large_files(&self, query: GroupQuery) -> LargeFilePage {
        let session = self.session.read();
        let page = session.large_files(
            query.offset as usize,
            query.limit as usize,
            query.sort.into(),
            query.descending,
            &filter(query.category, query.search, query.min_size),
        );
        LargeFilePage {
            total: page.total as u32,
            files: page.items.into_iter().map(Into::into).collect(),
        }
    }

    #[frb(sync)]
    pub fn file_group(&self, index: u32) -> Result<Option<FileGroupDto>> {
        let session = self.read_ui()?;
        Ok(((index as usize) < session.result.file_groups.len())
            .then(|| session.file_group_view(index).into()))
    }

    #[frb(sync)]
    pub fn folder_group(&self, index: u32) -> Result<Option<FolderGroupDto>> {
        let session = self.read_ui()?;
        Ok(((index as usize) < session.result.folder_groups.len())
            .then(|| session.folder_group_view(index).into()))
    }

    /// Direct children of a scanned folder (for previews and comparison).
    pub fn folder_children(&self, folder_id: u32) -> Result<FolderChildren> {
        let session = self.session.read();
        if folder_id as usize >= session.result.dirs.len() {
            return Err(anyhow!("unknown folder"));
        }
        let (files, folders) = session.folder_children(folder_id);
        Ok(FolderChildren {
            files: files.into_iter().map(Into::into).collect(),
            folders: folders.into_iter().map(Into::into).collect(),
        })
    }

    pub fn category_breakdown(&self) -> Vec<CategoryStat> {
        self.session
            .read()
            .category_breakdown()
            .into_iter()
            .map(|(c, groups, wasted)| CategoryStat {
                category: c.into(),
                groups: groups as i64,
                wasted: wasted.min(i64::MAX as u64) as i64,
            })
            .collect()
    }

    // ── Storage overview ───────────────────────────────────────────────

    /// Space used by scanned files, per category, largest first.
    pub fn category_usage(&self) -> Vec<CategoryUsageDto> {
        self.session
            .read()
            .category_usage()
            .into_iter()
            .map(|u| CategoryUsageDto {
                category: u.category.into(),
                files: crate::convert::i(u.files),
                bytes: crate::convert::i(u.bytes),
            })
            .collect()
    }

    /// What takes up space inside a folder (the scanned roots for `None`),
    /// largest first.
    pub fn space_children(&self, folder_id: Option<u32>) -> Vec<SpaceNodeDto> {
        let session = self.session.read();
        if folder_id.is_some_and(|d| d as usize >= session.result.dirs.len()) {
            return Vec::new();
        }
        session
            .space_children(folder_id)
            .into_iter()
            .map(|n| {
                let files_here = n.dir == engine::model::NO_ID;
                SpaceNodeDto {
                    folder_id: (!files_here).then_some(n.dir),
                    name: if files_here {
                        String::new()
                    } else {
                        n.path
                            .file_name()
                            .map(|s| s.to_string_lossy().into_owned())
                            .unwrap_or_else(|| lossy(&n.path))
                    },
                    path: lossy(&n.path),
                    bytes: crate::convert::i(n.bytes),
                    files: crate::convert::i(n.files),
                    folders: crate::convert::i(n.folders),
                }
            })
            .collect()
    }

    /// Biggest files directly inside a folder.
    pub fn files_in(&self, folder_id: u32, limit: u32) -> Vec<FileEntryDto> {
        let session = self.session.read();
        if folder_id as usize >= session.result.dirs.len() {
            return Vec::new();
        }
        session
            .files_in(folder_id, limit as usize)
            .into_iter()
            .map(Into::into)
            .collect()
    }

    /// Low-risk cleanups with what each would free. `downloads` are the
    /// user's download folders.
    pub fn recommendations(&self, downloads: Vec<String>) -> Vec<RecommendationDto> {
        let downloads: Vec<std::path::PathBuf> = downloads.into_iter().map(Into::into).collect();
        self.session
            .read()
            .recommendations(&downloads)
            .into_iter()
            .map(|r| RecommendationDto {
                kind: r.kind.into(),
                items: crate::convert::i(r.items),
                bytes: crate::convert::i(r.bytes),
            })
            .collect()
    }

    /// Replaces the selection of the affected lists with what the chosen
    /// recommendations remove. Returns the lists to act on, in a safe order
    /// (duplicates, then junk, then empty folders).
    pub fn select_recommendations(
        &self,
        kinds: Vec<RecommendationKind>,
        downloads: Vec<String>,
    ) -> Vec<ResultKind> {
        use engine::session::GroupKind;
        let downloads: Vec<std::path::PathBuf> = downloads.into_iter().map(Into::into).collect();
        let mut session = self.session.write();
        let mut targets: Vec<GroupKind> = Vec::new();
        for k in &kinds {
            let target = match engine::session::RecommendationKind::from(*k) {
                engine::session::RecommendationKind::DownloadDuplicates => GroupKind::Files,
                engine::session::RecommendationKind::EmptyFolders => GroupKind::EmptyFolders,
                _ => GroupKind::Junk,
            };
            if !targets.contains(&target) {
                session.clear_selection(target);
                targets.push(target);
            }
        }
        for k in kinds {
            session.select_recommendation(k.into(), &downloads);
        }
        let order = [GroupKind::Files, GroupKind::Junk, GroupKind::EmptyFolders];
        order
            .into_iter()
            .filter(|t| targets.contains(t))
            .map(Into::into)
            .collect()
    }

    /// Stops showing items that were removed or moved outside an action
    /// (archived or moved to another drive).
    pub fn mark_removed(&self, paths: Vec<String>) -> SelectionSummaryDto {
        let paths: Vec<std::path::PathBuf> = paths.into_iter().map(Into::into).collect();
        let mut session = self.session.write();
        session.mark_removed(&paths);
        session.summary().into()
    }

    // ── Selection ──────────────────────────────────────────────────────

    #[frb(sync)]
    pub fn selection_summary(&self) -> Result<SelectionSummaryDto> {
        Ok(self.read_ui()?.summary().into())
    }

    /// Fails with a readable message when the change would leave a group
    /// without a kept copy.
    #[frb(sync)]
    pub fn set_file_selected(&self, file_id: u32, selected: bool) -> Result<SelectionSummaryDto> {
        let mut session = self.write_ui()?;
        session
            .set_file_selected(file_id, selected)
            .map_err(|e| anyhow!(e.to_string()))?;
        Ok(session.summary().into())
    }

    /// Selection on the large-files list (separate from duplicate selection).
    #[frb(sync)]
    pub fn set_old_file_selected(
        &self,
        file_id: u32,
        selected: bool,
    ) -> Result<SelectionSummaryDto> {
        let mut session = self.write_ui()?;
        session.set_old_selected(file_id, selected)?;
        Ok(session.summary().into())
    }

    #[frb(sync)]
    pub fn set_large_file_selected(
        &self,
        file_id: u32,
        selected: bool,
    ) -> Result<SelectionSummaryDto> {
        let mut session = self.write_ui()?;
        session
            .set_large_selected(file_id, selected)
            .map_err(|e| anyhow!(e.to_string()))?;
        Ok(session.summary().into())
    }

    #[frb(sync)]
    pub fn set_folder_selected(
        &self,
        folder_id: u32,
        selected: bool,
    ) -> Result<SelectionSummaryDto> {
        let mut session = self.write_ui()?;
        session
            .set_dir_selected(folder_id, selected)
            .map_err(|e| anyhow!(e.to_string()))?;
        Ok(session.summary().into())
    }

    /// Selects every copy in a group except `keep_id`.
    #[frb(sync)]
    pub fn keep_only(
        &self,
        kind: ResultKind,
        group_index: u32,
        keep_id: u32,
    ) -> Result<SelectionSummaryDto> {
        let mut session = self.write_ui()?;
        session.keep_only(kind.into(), group_index, keep_id);
        Ok(session.summary().into())
    }

    /// Deselects every member of one group.
    #[frb(sync)]
    pub fn clear_group(&self, kind: ResultKind, group_index: u32) -> Result<SelectionSummaryDto> {
        let mut session = self.write_ui()?;
        match kind {
            ResultKind::Files => {
                let members: Vec<u32> = session
                    .result
                    .file_groups
                    .get(group_index as usize)
                    .map(|g| g.files.clone())
                    .unwrap_or_default();
                for f in members {
                    let _ = session.set_file_selected(f, false);
                }
            }
            ResultKind::Folders => {
                let members: Vec<u32> = session
                    .result
                    .folder_groups
                    .get(group_index as usize)
                    .map(|g| g.dirs.clone())
                    .unwrap_or_default();
                for d in members {
                    let _ = session.set_dir_selected(d, false);
                }
            }
            ResultKind::SimilarPhotos => {
                if session
                    .photo_analysis()
                    .is_some_and(|p| (group_index as usize) < p.groups.len())
                {
                    let members: Vec<u32> = session
                        .similar_group_view(group_index)
                        .items
                        .iter()
                        .map(|i| i.id)
                        .collect();
                    for f in members {
                        let _ = session.set_similar_selected(f, false);
                    }
                }
            }
            ResultKind::EmptyFolders
            | ResultKind::LargeFiles
            | ResultKind::Junk
            | ResultKind::OldFiles
            | ResultKind::PhotoIssues
            | ResultKind::SimilarMedia => {}
        }
        Ok(session.summary().into())
    }

    #[frb(sync)]
    pub fn clear_selection(&self, kind: ResultKind) -> Result<SelectionSummaryDto> {
        let mut session = self.write_ui()?;
        session.clear_selection(kind.into());
        Ok(session.summary().into())
    }

    /// Applies an automatic rule to all matching groups; returns how many
    /// groups were changed.
    pub fn apply_rule(&self, kind: ResultKind, rule: SelectionRuleDto) -> i64 {
        let rule = engine::session::SelectionRule {
            strategy: rule.keep.into(),
            prefer_keep_in: rule.prefer_keep_in.into_iter().map(Into::into).collect(),
            only_select_in: rule.only_select_in.into_iter().map(Into::into).collect(),
            filter: filter(rule.category, rule.search, None),
        };
        self.session.write().apply_rule(kind.into(), &rule) as i64
    }

    pub fn select_all_empty_folders(&self, search: Option<String>) -> SelectionSummaryDto {
        let mut session = self.session.write();
        session.select_all_empty_folders(&filter(None, search, None));
        session.summary().into()
    }

    // ── Actions ────────────────────────────────────────────────────────

    /// Executes an action on the current selection of `request.target`.
    /// `recovery_roots` are candidate recovery-bin locations (one per
    /// storage volume, primary first). Poll [`ScanResults::action_progress`]
    /// for progress.
    pub fn execute_action(
        &self,
        request: ActionRequestDto,
        recovery_roots: Vec<String>,
    ) -> Result<ActionReportDto> {
        if self.action_running.swap(true, Ordering::SeqCst) {
            return Err(anyhow!("another action is running"));
        }
        let control = engine::ScanControl::new();
        *self.action_control.lock() = control.clone();
        self.action_done.store(0, Ordering::Relaxed);
        self.action_total.store(0, Ordering::Relaxed);

        let result = (|| -> Result<ActionReportDto> {
            let bin = if recovery_roots.is_empty() {
                None
            } else {
                Some(engine::RecoveryBin::new(
                    recovery_roots.into_iter().map(Into::into).collect(),
                )?)
            };
            let req = engine::actions::ActionRequest {
                kind: request.action.into(),
                target: request.target.into(),
                destination: request
                    .destination
                    .filter(|d| !d.is_empty())
                    .map(Into::into),
                keep_structure: request.keep_structure,
                verify_content: request.verify_content,
            };
            let done = &self.action_done;
            let total = &self.action_total;
            let progress = move |d: u64, t: u64| {
                done.store(d as i64, Ordering::Relaxed);
                total.store(t as i64, Ordering::Relaxed);
            };
            let mut session = self.session.write();
            let report =
                engine::actions::execute(&mut session, &req, bin.as_ref(), &control, &progress)?;
            Ok(report.into())
        })();
        self.action_running.store(false, Ordering::SeqCst);
        result
    }

    /// Revives items restored from the recovery bin (undo).
    pub fn mark_restored(&self, paths: Vec<String>) -> SelectionSummaryDto {
        let paths: Vec<std::path::PathBuf> = paths.into_iter().map(Into::into).collect();
        let mut session = self.session.write();
        session.mark_present(&paths);
        session.summary().into()
    }

    #[frb(sync)]
    pub fn action_progress(&self) -> ActionProgressDto {
        ActionProgressDto {
            done: self.action_done.load(Ordering::Relaxed),
            total: self.action_total.load(Ordering::Relaxed),
            running: self.action_running.load(Ordering::SeqCst),
        }
    }

    #[frb(sync)]
    pub fn cancel_action(&self) {
        self.action_control.lock().cancel();
    }

    // ── Ignore list ────────────────────────────────────────────────────

    /// The entry to remember when the user marks a group as "not
    /// duplicates". `None` for other kinds or unknown groups.
    #[frb(sync)]
    pub fn ignore_entry(
        &self,
        kind: ResultKind,
        group_index: u32,
    ) -> Result<Option<IgnoredGroupDto>> {
        let session = self.read_ui()?;
        let algorithm = algorithm_of(&session);
        let key = |digest: &engine::hashing::Digest| IgnoreKeyDto {
            kind,
            algorithm,
            digest: to_hex(digest),
        };
        let g = group_index as usize;
        Ok(match kind {
            ResultKind::Files => session.result.file_groups.get(g).map(|group| {
                let path = session.result.file_path(group.files[0]);
                IgnoredGroupDto {
                    key: key(&group.digest),
                    name: path
                        .file_name()
                        .map(|n| n.to_string_lossy().into_owned())
                        .unwrap_or_default(),
                    path: lossy(&path),
                    copies: group.files.len() as u32,
                    size: group.size as i64,
                }
            }),
            ResultKind::Folders => session.result.folder_groups.get(g).map(|group| {
                let path = session.result.dir_path(group.dirs[0]);
                IgnoredGroupDto {
                    key: key(&group.digest),
                    name: path
                        .file_name()
                        .map(|n| n.to_string_lossy().into_owned())
                        .unwrap_or_default(),
                    path: lossy(path),
                    copies: group.dirs.len() as u32,
                    size: group.total_bytes as i64,
                }
            }),
            ResultKind::EmptyFolders
            | ResultKind::LargeFiles
            | ResultKind::Junk
            | ResultKind::OldFiles
            | ResultKind::SimilarPhotos
            | ResultKind::PhotoIssues
            | ResultKind::SimilarMedia => None,
        })
    }

    /// Replaces the set of hidden "not duplicates" groups. Entries made with
    /// another hash algorithm are skipped.
    #[frb(sync)]
    pub fn set_ignored(&self, keys: Vec<IgnoreKeyDto>) -> Result<SelectionSummaryDto> {
        let mut session = self.write_ui()?;
        let algorithm = algorithm_of(&session);
        let mut files = std::collections::HashSet::new();
        let mut folders = std::collections::HashSet::new();
        for k in keys.iter().filter(|k| k.algorithm == algorithm) {
            let Some(digest) = from_hex(&k.digest) else {
                continue;
            };
            match k.kind {
                ResultKind::Files => files.insert(digest),
                ResultKind::Folders => folders.insert(digest),
                ResultKind::EmptyFolders
                | ResultKind::LargeFiles
                | ResultKind::Junk
                | ResultKind::OldFiles
                | ResultKind::SimilarPhotos
                | ResultKind::PhotoIssues
                | ResultKind::SimilarMedia => false,
            };
        }
        session.set_ignored_content(&files, &folders);
        Ok(session.summary().into())
    }

    /// Hides everything inside `paths` until the next scan (which excludes
    /// them through the scan options).
    pub fn ignore_folders(&self, paths: Vec<String>) -> SelectionSummaryDto {
        let paths: Vec<std::path::PathBuf> = paths.into_iter().map(Into::into).collect();
        let mut session = self.session.write();
        session.ignore_folders(&paths);
        session.summary().into()
    }

    // ── Saved results ──────────────────────────────────────────────────

    /// Saves these results, including removals and the selection, so they
    /// can be reopened after a restart. Replaces the file atomically.
    pub fn save_snapshot(&self, path: String, finished_ms: i64) -> Result<()> {
        let bytes = engine::snapshot::encode(&self.session.read(), finished_ms);
        engine::snapshot::write_bytes(&bytes, std::path::Path::new(&path))?;
        Ok(())
    }

    /// Reopens results written by [`ScanResults::save_snapshot`]. Fails when
    /// the file is missing, damaged or from another app version.
    pub fn load_snapshot(path: String) -> Result<ScanResults> {
        let (session, finished_ms) = engine::snapshot::load(std::path::Path::new(&path))?;
        Ok(Self::from_session(session, Some(finished_ms)))
    }

    /// When the scan finished, for reopened results; `None` for a new scan.
    #[frb(sync)]
    pub fn saved_finished_ms(&self) -> Option<i64> {
        self.saved_finished_ms
    }

    // ── Reports ────────────────────────────────────────────────────────

    /// A report of what the results screen shows, with the selection.
    /// Dates are written for a time zone `utc_offset_min` minutes from UTC.
    pub fn export_report(&self, format: ReportFormat, utc_offset_min: i32) -> Vec<u8> {
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        engine::report::render(
            &self.session.read(),
            format.into(),
            engine::report::ReportClock {
                now_ms,
                utc_offset_min,
            },
        )
    }

    // ── Photos ─────────────────────────────────────────────────────────

    /// Fingerprints the scan's photos to find similar shots and blurry,
    /// dark or screenshot images. Progress and cancel use
    /// [`ScanResults::action_progress`] and [`ScanResults::cancel_action`].
    /// `cache_dir` reuses fingerprints of unchanged files.
    pub fn analyze_photos(
        &self,
        cache_dir: Option<String>,
        threads: u32,
    ) -> Result<PhotoAnalysisDto> {
        if self.action_running.swap(true, Ordering::SeqCst) {
            return Err(anyhow!("another action is running"));
        }
        let control = engine::ScanControl::new();
        *self.action_control.lock() = control.clone();
        let result = (|| -> Result<PhotoAnalysisDto> {
            let candidates = self.session.read().photo_candidates();
            self.action_done.store(0, Ordering::Relaxed);
            self.action_total
                .store(candidates.len() as i64, Ordering::Relaxed);
            let cache = cache_dir
                .filter(|d| !d.is_empty())
                .and_then(|d| engine::HashCache::open(std::path::Path::new(&d)).ok());
            let threads = if threads == 0 {
                std::thread::available_parallelism().map_or(2, |n| n.get())
            } else {
                threads as usize
            };
            let pool = engine::priority::background_pool(threads, "digiclean-photos")
                .map_err(|e| anyhow!("{e}"))?;
            let done = &self.action_done;
            let (features, failed) = engine::photos::analyze_many(
                &candidates,
                cache.as_ref(),
                &control,
                &pool,
                &|| {
                    done.fetch_add(1, Ordering::Relaxed);
                },
            )?;
            let mut session = self.session.write();
            session.set_photo_analysis(features, failed);
            let p = session.photo_analysis().expect("just set");
            let summary = session.summary();
            Ok(PhotoAnalysisDto {
                analyzed: p.analyzed as i64,
                failed: p.failed as i64,
                similar_groups: crate::convert::i(summary.similar_groups),
                with_issues: crate::convert::i(summary.remaining_photo_issues),
            })
        })();
        self.action_running.store(false, Ordering::SeqCst);
        result
    }

    /// Sets of similar photos, best shot first in each.
    pub fn similar_groups(&self, query: GroupQuery) -> SimilarGroupPage {
        let session = self.session.read();
        let page = session.similar_groups(
            query.offset as usize,
            query.limit as usize,
            query.sort.into(),
            query.descending,
            &filter(None, query.search, None),
        );
        SimilarGroupPage {
            total: page.total as u32,
            groups: page.items.into_iter().map(Into::into).collect(),
        }
    }

    /// Blurry, dark and screenshot images (filter: `photo_issue`, search).
    pub fn photo_issues(&self, query: GroupQuery) -> PhotoPage {
        let session = self.session.read();
        let f = GroupFilter {
            photo_issue: query.photo_issue.map(Into::into),
            ..filter(None, query.search, None)
        };
        let page = session.photo_issue_list(
            query.offset as usize,
            query.limit as usize,
            query.sort.into(),
            query.descending,
            &f,
        );
        PhotoPage {
            total: page.total as u32,
            photos: page.items.into_iter().map(Into::into).collect(),
        }
    }

    #[frb(sync)]
    pub fn similar_group(&self, index: u32) -> Result<Option<SimilarGroupDto>> {
        let session = self.read_ui()?;
        Ok(session
            .photo_analysis()
            .is_some_and(|p| (index as usize) < p.groups.len())
            .then(|| session.similar_group_view(index).into()))
    }

    #[frb(sync)]
    pub fn set_similar_selected(
        &self,
        file_id: u32,
        selected: bool,
    ) -> Result<SelectionSummaryDto> {
        let mut session = self.write_ui()?;
        session.set_similar_selected(file_id, selected)?;
        Ok(session.summary().into())
    }

    /// Ticks every similar photo except the best of each set.
    pub fn select_all_but_best(&self, search: Option<String>) -> SelectionSummaryDto {
        let mut session = self.session.write();
        session.select_all_but_best(&filter(None, search, None));
        session.summary().into()
    }

    #[frb(sync)]
    pub fn set_photo_selected(&self, file_id: u32, selected: bool) -> Result<SelectionSummaryDto> {
        let mut session = self.write_ui()?;
        session.set_photo_selected(file_id, selected)?;
        Ok(session.summary().into())
    }

    // ── Watching ───────────────────────────────────────────────────────

    /// New files (for example fresh downloads) whose content already exists
    /// in the scanned folders. `cache_dir` speeds up hashing scanned files.
    pub fn find_copies(&self, paths: Vec<String>, cache_dir: Option<String>) -> Vec<CopyMatchDto> {
        let paths: Vec<std::path::PathBuf> = paths.into_iter().map(Into::into).collect();
        let cache = cache_dir
            .filter(|d| !d.is_empty())
            .and_then(|d| engine::HashCache::open(std::path::Path::new(&d)).ok());
        let session = self.session.read();
        engine::watch::find_copies(&session, &paths, cache.as_ref())
            .into_iter()
            .map(|m| CopyMatchDto {
                path: lossy(&m.path),
                existing: lossy(&m.existing),
                size: crate::convert::i(m.size),
            })
            .collect()
    }

    // ── Audio and video ────────────────────────────────────────────────

    /// Fingerprints the soundtracks of the scan's songs and videos. Progress
    /// and cancel use [`ScanResults::action_progress`] / `cancel_action`.
    pub fn analyze_media(
        &self,
        cache_dir: Option<String>,
        threads: u32,
    ) -> Result<MediaAnalysisDto> {
        if self.action_running.swap(true, Ordering::SeqCst) {
            return Err(anyhow!("another action is running"));
        }
        let control = engine::ScanControl::new();
        *self.action_control.lock() = control.clone();
        let result = (|| -> Result<MediaAnalysisDto> {
            let candidates = self.session.read().media_candidates();
            self.action_done.store(0, Ordering::Relaxed);
            self.action_total
                .store(candidates.len() as i64, Ordering::Relaxed);
            let cache = cache_dir
                .filter(|d| !d.is_empty())
                .and_then(|d| engine::HashCache::open(std::path::Path::new(&d)).ok());
            let threads = if threads == 0 {
                std::thread::available_parallelism().map_or(2, |n| n.get())
            } else {
                threads as usize
            };
            let pool = engine::priority::background_pool(threads, "digiclean-media")
                .map_err(|e| anyhow!("{e}"))?;
            let done = &self.action_done;
            let (features, failed) =
                engine::media::analyze_many(&candidates, cache.as_ref(), &control, &pool, &|| {
                    done.fetch_add(1, Ordering::Relaxed);
                })?;
            let mut session = self.session.write();
            session.set_media_analysis(features, failed);
            let m = session.media_analysis().expect("just set");
            let (analyzed, failed) = (m.analyzed, m.failed);
            Ok(MediaAnalysisDto {
                analyzed: analyzed as i64,
                failed: failed as i64,
                similar_groups: crate::convert::i(session.summary().media_groups),
            })
        })();
        self.action_running.store(false, Ordering::SeqCst);
        result
    }

    /// Sets of songs and videos with the same soundtrack, best copy first.
    pub fn media_groups(&self, query: GroupQuery) -> MediaGroupPage {
        let session = self.session.read();
        let page = session.media_groups(
            query.offset as usize,
            query.limit as usize,
            query.sort.into(),
            query.descending,
            &filter(None, query.search, None),
        );
        MediaGroupPage {
            total: page.total as u32,
            groups: page.items.into_iter().map(Into::into).collect(),
        }
    }

    #[frb(sync)]
    pub fn media_group(&self, index: u32) -> Result<Option<MediaGroupDto>> {
        let session = self.read_ui()?;
        Ok(session
            .media_analysis()
            .is_some_and(|m| (index as usize) < m.groups.len())
            .then(|| session.media_group_view(index).into()))
    }

    #[frb(sync)]
    pub fn set_media_selected(&self, file_id: u32, selected: bool) -> Result<SelectionSummaryDto> {
        let mut session = self.write_ui()?;
        session.set_media_selected(file_id, selected)?;
        Ok(session.summary().into())
    }

    /// Ticks every copy except the best of each set.
    pub fn select_all_but_best_media(&self, search: Option<String>) -> SelectionSummaryDto {
        let mut session = self.session.write();
        session.select_all_but_best_media(&filter(None, search, None));
        session.summary().into()
    }
}
