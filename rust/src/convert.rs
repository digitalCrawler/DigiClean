//! Conversions between engine types and the bridge DTOs. Kept outside
//! `crate::api` so flutter_rust_bridge does not try to bind them.

use std::path::Path;

use digiclean_engine as engine;
use engine::session::{FileItem, FolderItem, JunkItem};

use crate::api::types::*;

pub(crate) fn i(v: u64) -> i64 {
    v.min(i64::MAX as u64) as i64
}

pub(crate) fn ns_to_ms(ns: i64) -> i64 {
    ns / 1_000_000
}

pub(crate) fn lossy(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

fn name_and_parent(p: &Path) -> (String, String) {
    (
        p.file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| lossy(p)),
        p.parent().map(lossy).unwrap_or_default(),
    )
}

impl From<HashAlgo> for engine::HashAlgorithm {
    fn from(v: HashAlgo) -> Self {
        match v {
            HashAlgo::Blake3 => engine::HashAlgorithm::Blake3,
            HashAlgo::Sha256 => engine::HashAlgorithm::Sha256,
        }
    }
}

impl From<PerformanceMode> for engine::Performance {
    fn from(v: PerformanceMode) -> Self {
        match v {
            PerformanceMode::Maximum => engine::Performance::Maximum,
            PerformanceMode::Balanced => engine::Performance::Balanced,
            PerformanceMode::BatterySaver => engine::Performance::BatterySaver,
            PerformanceMode::SpinningDisk => engine::Performance::SpinningDisk,
        }
    }
}

impl From<Category> for engine::FileCategory {
    fn from(v: Category) -> Self {
        match v {
            Category::Image => engine::FileCategory::Image,
            Category::Video => engine::FileCategory::Video,
            Category::Audio => engine::FileCategory::Audio,
            Category::Document => engine::FileCategory::Document,
            Category::Archive => engine::FileCategory::Archive,
            Category::Application => engine::FileCategory::Application,
            Category::Other => engine::FileCategory::Other,
        }
    }
}

impl From<engine::FileCategory> for Category {
    fn from(v: engine::FileCategory) -> Self {
        match v {
            engine::FileCategory::Image => Category::Image,
            engine::FileCategory::Video => Category::Video,
            engine::FileCategory::Audio => Category::Audio,
            engine::FileCategory::Document => Category::Document,
            engine::FileCategory::Archive => Category::Archive,
            engine::FileCategory::Application => Category::Application,
            engine::FileCategory::Other => Category::Other,
        }
    }
}

impl From<engine::ScanPhase> for Phase {
    fn from(v: engine::ScanPhase) -> Self {
        use engine::ScanPhase as P;
        match v {
            P::Discovering => Phase::Discovering,
            P::GroupingBySize => Phase::GroupingBySize,
            P::PartialHashing => Phase::PartialHashing,
            P::FullHashing => Phase::FullHashing,
            P::Verifying => Phase::Verifying,
            P::AnalyzingFolders => Phase::AnalyzingFolders,
            P::Finalizing => Phase::Finalizing,
            P::Done => Phase::Done,
        }
    }
}

impl From<SortBy> for engine::session::SortKey {
    fn from(v: SortBy) -> Self {
        use engine::session::SortKey as S;
        match v {
            SortBy::Wasted => S::Wasted,
            SortBy::Size => S::Size,
            SortBy::Count => S::Count,
            SortBy::Name => S::Name,
            SortBy::Path => S::Path,
            SortBy::Modified => S::Modified,
        }
    }
}

impl From<ResultKind> for engine::session::GroupKind {
    fn from(v: ResultKind) -> Self {
        use engine::session::GroupKind as G;
        match v {
            ResultKind::Files => G::Files,
            ResultKind::Folders => G::Folders,
            ResultKind::EmptyFolders => G::EmptyFolders,
            ResultKind::LargeFiles => G::LargeFiles,
            ResultKind::Junk => G::Junk,
            ResultKind::OldFiles => G::OldFiles,
            ResultKind::SimilarPhotos => G::SimilarPhotos,
            ResultKind::PhotoIssues => G::PhotoIssues,
            ResultKind::SimilarMedia => G::SimilarMedia,
        }
    }
}

impl From<ResultKind> for engine::ActionTarget {
    fn from(v: ResultKind) -> Self {
        match v {
            ResultKind::Files => engine::ActionTarget::Files,
            ResultKind::Folders => engine::ActionTarget::Folders,
            ResultKind::EmptyFolders => engine::ActionTarget::EmptyFolders,
            ResultKind::LargeFiles => engine::ActionTarget::LargeFiles,
            ResultKind::Junk => engine::ActionTarget::Junk,
            ResultKind::OldFiles => engine::ActionTarget::OldFiles,
            ResultKind::SimilarPhotos => engine::ActionTarget::SimilarPhotos,
            ResultKind::PhotoIssues => engine::ActionTarget::PhotoIssues,
            ResultKind::SimilarMedia => engine::ActionTarget::SimilarMedia,
        }
    }
}

impl From<KeepRule> for engine::session::KeepStrategy {
    fn from(v: KeepRule) -> Self {
        use engine::session::KeepStrategy as K;
        match v {
            KeepRule::Newest => K::Newest,
            KeepRule::Oldest => K::Oldest,
            KeepRule::ShortestPath => K::ShortestPath,
            KeepRule::LongestPath => K::LongestPath,
            KeepRule::ShallowestPath => K::ShallowestPath,
            KeepRule::FirstAlphabetical => K::FirstAlphabetical,
        }
    }
}

impl From<ActionType> for engine::ActionKind {
    fn from(v: ActionType) -> Self {
        match v {
            ActionType::Trash => engine::ActionKind::Trash,
            ActionType::RecoveryBin => engine::ActionKind::RecoveryBin,
            ActionType::DeletePermanently => engine::ActionKind::DeletePermanently,
            ActionType::MoveTo => engine::ActionKind::MoveTo,
            ActionType::ReplaceWithHardlink => engine::ActionKind::ReplaceWithHardlink,
            ActionType::ReplaceWithClone => engine::ActionKind::ReplaceWithClone,
        }
    }
}

impl From<ScanOptions> for engine::ScanConfig {
    fn from(o: ScanOptions) -> Self {
        let paths = |v: Vec<String>| v.into_iter().map(Into::into).collect();
        engine::ScanConfig {
            roots: paths(o.roots),
            recursive: o.recursive,
            max_depth: o.max_depth,
            follow_symlinks: o.follow_symlinks,
            include_hidden: o.include_hidden,
            skip_system_folders: o.skip_system_folders,
            skip_cloud_placeholders: o.skip_cloud_placeholders,
            min_size: o.min_size.max(0) as u64,
            max_size: o.max_size.map(|m| m.max(0) as u64),
            include_extensions: o.include_extensions,
            exclude_extensions: o.exclude_extensions,
            categories: o.categories.into_iter().map(Into::into).collect(),
            exclude_paths: paths(o.exclude_paths),
            exclude_globs: o.exclude_globs,
            protected_paths: paths(o.protected_paths),
            hash_algorithm: o.hash_algorithm.into(),
            verify_byte_by_byte: o.verify_byte_by_byte,
            detect_duplicate_folders: o.detect_duplicate_folders,
            detect_empty_folders: o.detect_empty_folders,
            include_empty_files: o.include_empty_files,
            performance: o.performance.into(),
            threads: o.threads,
            cache_dir: o.cache_dir.filter(|d| !d.is_empty()).map(Into::into),
        }
    }
}

impl From<&engine::ProgressSnapshot> for ScanProgress {
    fn from(s: &engine::ProgressSnapshot) -> Self {
        ScanProgress {
            phase: s.phase.into(),
            files_discovered: i(s.files_discovered),
            dirs_discovered: i(s.dirs_discovered),
            bytes_discovered: i(s.bytes_discovered),
            phase_items_done: i(s.phase_items_done),
            phase_items_total: i(s.phase_items_total),
            phase_bytes_done: i(s.phase_bytes_done),
            phase_bytes_total: i(s.phase_bytes_total),
            candidates: i(s.candidates),
            cache_hits: i(s.cache_hits),
            errors: i(s.errors),
            elapsed_ms: i(s.elapsed_ms),
            bytes_per_second: i(s.bytes_per_second),
            eta_ms: s.eta_ms.map(i),
            current_path: s.current_path.clone(),
            paused: s.paused,
        }
    }
}

impl From<&engine::ScanStats> for ScanStatsDto {
    fn from(s: &engine::ScanStats) -> Self {
        ScanStatsDto {
            files_seen: i(s.files_seen),
            dirs_seen: i(s.dirs_seen),
            bytes_seen: i(s.bytes_seen),
            eligible_files: i(s.eligible_files),
            candidates_after_size: i(s.candidates_after_size),
            candidates_after_partial: i(s.candidates_after_partial),
            files_fully_hashed: i(s.files_fully_hashed),
            bytes_hashed: i(s.bytes_hashed),
            cache_hits: i(s.cache_hits),
            hardlinks_skipped: i(s.hardlinks_skipped),
            duplicate_groups: i(s.duplicate_groups),
            duplicate_files: i(s.duplicate_files),
            wasted_bytes: i(s.wasted_bytes),
            folder_groups: i(s.folder_groups),
            folder_wasted_bytes: i(s.folder_wasted_bytes),
            empty_folders: i(s.empty_folders),
            large_files: i(s.large_files),
            photos: i(s.photos),
            junk_items: i(s.junk_items),
            junk_bytes: i(s.junk_bytes),
            errors: i(s.errors),
            elapsed_ms: i(s.elapsed_ms),
            hash_algorithm: s.hash_algorithm.clone(),
        }
    }
}

impl From<FileItem> for FileEntryDto {
    fn from(f: FileItem) -> Self {
        let (name, parent) = name_and_parent(&f.path);
        FileEntryDto {
            id: f.id,
            path: lossy(&f.path),
            name,
            parent,
            size: i(f.size),
            modified_ms: ns_to_ms(f.modified_ns),
            created_ms: f.created_ns.map(ns_to_ms),
            hidden: f.hidden,
            selected: f.selected,
        }
    }
}

impl From<FolderItem> for FolderEntryDto {
    fn from(f: FolderItem) -> Self {
        let (name, parent) = name_and_parent(&f.path);
        FolderEntryDto {
            id: f.id,
            path: lossy(&f.path),
            name,
            parent,
            modified_ms: ns_to_ms(f.modified_ns),
            selected: f.selected,
        }
    }
}

impl From<engine::session::FileGroupView> for FileGroupDto {
    fn from(g: engine::session::FileGroupView) -> Self {
        FileGroupDto {
            index: g.index,
            size: i(g.size),
            wasted: i(g.wasted),
            hash: g.digest,
            category: g.category.into(),
            files: g.items.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<engine::session::FolderGroupView> for FolderGroupDto {
    fn from(g: engine::session::FolderGroupView) -> Self {
        FolderGroupDto {
            index: g.index,
            total_bytes: i(g.total_bytes),
            file_count: i(g.file_count),
            dir_count: i(g.dir_count),
            wasted: i(g.wasted),
            hash: g.digest,
            folders: g.items.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<engine::session::SelectionSummary> for SelectionSummaryDto {
    fn from(s: engine::session::SelectionSummary) -> Self {
        SelectionSummaryDto {
            files: i(s.files),
            file_bytes: i(s.file_bytes),
            folders: i(s.folders),
            folder_bytes: i(s.folder_bytes),
            empty_folders: i(s.empty_folders),
            active_file_groups: i(s.active_file_groups),
            file_wasted: i(s.file_wasted),
            active_folder_groups: i(s.active_folder_groups),
            folder_wasted: i(s.folder_wasted),
            remaining_empty_folders: i(s.remaining_empty_folders),
            large_files: i(s.large_files),
            large_file_bytes: i(s.large_file_bytes),
            remaining_large_files: i(s.remaining_large_files),
            old_files: i(s.old_files),
            old_file_bytes: i(s.old_file_bytes),
            photos_analyzed: s.photos_analyzed,
            media_analyzed: s.media_analyzed,
            media_groups: i(s.media_groups),
            media_reclaimable: i(s.media_reclaimable),
            media: i(s.media),
            media_bytes: i(s.media_bytes),
            similar_groups: i(s.similar_groups),
            similar_reclaimable: i(s.similar_reclaimable),
            similar: i(s.similar),
            similar_bytes: i(s.similar_bytes),
            remaining_photo_issues: i(s.remaining_photo_issues),
            photo_issues: i(s.photo_issues),
            photo_issue_bytes: i(s.photo_issue_bytes),
            junk: i(s.junk),
            junk_bytes: i(s.junk_bytes),
            remaining_junk: i(s.remaining_junk),
            remaining_junk_bytes: i(s.remaining_junk_bytes),
        }
    }
}

impl From<engine::ActionReport> for ActionReportDto {
    fn from(r: engine::ActionReport) -> Self {
        ActionReportDto {
            succeeded: i(r.succeeded),
            failed: i(r.failed),
            skipped: i(r.skipped),
            bytes_freed: i(r.bytes_freed),
            bytes_in_bin: i(r.bytes_in_bin),
            bytes_moved: i(r.bytes_moved),
            batch_id: r.batch_id,
            used_system_trash: r.used_system_trash,
            issues: r
                .issues
                .into_iter()
                .map(|x| IssueDto {
                    path: x.path,
                    message: x.message,
                })
                .collect(),
            affected_paths: r.affected_paths,
        }
    }
}

impl From<engine::RecoveryItem> for RecoveryItemDto {
    fn from(r: engine::RecoveryItem) -> Self {
        RecoveryItemDto {
            id: r.id,
            batch_id: r.batch_id,
            original_path: r.original_path,
            name: r.name,
            is_dir: r.is_dir,
            size: i(r.size),
            file_count: i(r.file_count),
            deleted_at_ms: i(r.deleted_at).saturating_mul(1000),
        }
    }
}

impl From<ReportFormat> for engine::report::ReportFormat {
    fn from(v: ReportFormat) -> Self {
        match v {
            ReportFormat::Csv => Self::Csv,
            ReportFormat::Json => Self::Json,
            ReportFormat::Html => Self::Html,
        }
    }
}

impl From<JunkKind> for engine::junk::JunkKind {
    fn from(v: JunkKind) -> Self {
        match v {
            JunkKind::SystemCache => Self::SystemCache,
            JunkKind::PartialDownload => Self::PartialDownload,
            JunkKind::TempFile => Self::TempFile,
            JunkKind::EmptyFile => Self::EmptyFile,
            JunkKind::BrokenLink => Self::BrokenLink,
        }
    }
}

impl From<engine::junk::JunkKind> for JunkKind {
    fn from(v: engine::junk::JunkKind) -> Self {
        use engine::junk::JunkKind as K;
        match v {
            K::SystemCache => Self::SystemCache,
            K::PartialDownload => Self::PartialDownload,
            K::TempFile => Self::TempFile,
            K::EmptyFile => Self::EmptyFile,
            K::BrokenLink => Self::BrokenLink,
        }
    }
}

impl From<JunkItem> for JunkEntryDto {
    fn from(j: JunkItem) -> Self {
        let (name, parent) = name_and_parent(&j.path);
        JunkEntryDto {
            id: j.id,
            path: lossy(&j.path),
            name,
            parent,
            size: i(j.size),
            modified_ms: ns_to_ms(j.modified_ns),
            kind: j.kind.into(),
            safe: j.kind.is_safe(),
            selected: j.selected,
        }
    }
}

impl From<engine::volumes::VolumeKind> for VolumeKind {
    fn from(v: engine::volumes::VolumeKind) -> Self {
        use engine::volumes::VolumeKind as K;
        match v {
            K::Fixed => Self::Fixed,
            K::Removable => Self::Removable,
            K::Network => Self::Network,
        }
    }
}

impl From<RecommendationKind> for engine::session::RecommendationKind {
    fn from(v: RecommendationKind) -> Self {
        match v {
            RecommendationKind::SystemCaches => Self::SystemCaches,
            RecommendationKind::LeftoverFiles => Self::LeftoverFiles,
            RecommendationKind::DownloadDuplicates => Self::DownloadDuplicates,
            RecommendationKind::EmptyFolders => Self::EmptyFolders,
        }
    }
}

impl From<engine::session::RecommendationKind> for RecommendationKind {
    fn from(v: engine::session::RecommendationKind) -> Self {
        use engine::session::RecommendationKind as K;
        match v {
            K::SystemCaches => Self::SystemCaches,
            K::LeftoverFiles => Self::LeftoverFiles,
            K::DownloadDuplicates => Self::DownloadDuplicates,
            K::EmptyFolders => Self::EmptyFolders,
        }
    }
}

impl From<engine::session::GroupKind> for ResultKind {
    fn from(v: engine::session::GroupKind) -> Self {
        use engine::session::GroupKind as G;
        match v {
            G::Files => Self::Files,
            G::Folders => Self::Folders,
            G::EmptyFolders => Self::EmptyFolders,
            G::LargeFiles => Self::LargeFiles,
            G::Junk => Self::Junk,
            G::OldFiles => Self::OldFiles,
            G::SimilarPhotos => Self::SimilarPhotos,
            G::PhotoIssues => Self::PhotoIssues,
            G::SimilarMedia => Self::SimilarMedia,
        }
    }
}

impl From<engine::photos::PhotoIssue> for PhotoIssueKind {
    fn from(v: engine::photos::PhotoIssue) -> Self {
        use engine::photos::PhotoIssue as P;
        match v {
            P::Blurry => Self::Blurry,
            P::Dark => Self::Dark,
            P::Screenshot => Self::Screenshot,
        }
    }
}

impl From<PhotoIssueKind> for engine::photos::PhotoIssue {
    fn from(v: PhotoIssueKind) -> Self {
        match v {
            PhotoIssueKind::Blurry => Self::Blurry,
            PhotoIssueKind::Dark => Self::Dark,
            PhotoIssueKind::Screenshot => Self::Screenshot,
        }
    }
}

impl From<engine::session::PhotoItem> for PhotoDto {
    fn from(p: engine::session::PhotoItem) -> Self {
        let (name, parent) = name_and_parent(&p.path);
        PhotoDto {
            id: p.id,
            path: lossy(&p.path),
            name,
            parent,
            size: i(p.size),
            modified_ms: ns_to_ms(p.modified_ns),
            width: p.width,
            height: p.height,
            issues: p.issues.into_iter().map(Into::into).collect(),
            best: p.best,
            selected: p.selected,
        }
    }
}

impl From<engine::session::SimilarGroupView> for SimilarGroupDto {
    fn from(g: engine::session::SimilarGroupView) -> Self {
        SimilarGroupDto {
            index: g.index,
            reclaimable: i(g.reclaimable),
            photos: g.items.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<engine::session::SimilarMediaView> for MediaGroupDto {
    fn from(g: engine::session::SimilarMediaView) -> Self {
        MediaGroupDto {
            index: g.index,
            reclaimable: i(g.reclaimable),
            items: g
                .items
                .into_iter()
                .map(|m| {
                    let (name, parent) = name_and_parent(&m.path);
                    MediaDto {
                        id: m.id,
                        path: lossy(&m.path),
                        name,
                        parent,
                        size: i(m.size),
                        modified_ms: ns_to_ms(m.modified_ns),
                        duration_ms: m.duration_ms.map(i),
                        video: m.video,
                        best: m.best,
                        selected: m.selected,
                    }
                })
                .collect(),
        }
    }
}
