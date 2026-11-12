//! Data transfer types shared with Dart. Sizes and timestamps are `i64`
//! (Dart `int`); `u64` would be generated as `BigInt`.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HashAlgo {
    Blake3,
    Sha256,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PerformanceMode {
    Maximum,
    Balanced,
    BatterySaver,
    SpinningDisk,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Category {
    Image,
    Video,
    Audio,
    Document,
    Archive,
    Application,
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    Discovering,
    GroupingBySize,
    PartialHashing,
    FullHashing,
    Verifying,
    AnalyzingFolders,
    Finalizing,
    Done,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScanEventKind {
    Progress,
    Completed,
    Cancelled,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SortBy {
    Wasted,
    Size,
    Count,
    Name,
    Path,
    Modified,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResultKind {
    Files,
    Folders,
    EmptyFolders,
    LargeFiles,
    Junk,
    /// Files not changed for a long time.
    OldFiles,
    /// Photos that look alike (after `analyze_photos`).
    SimilarPhotos,
    /// Blurry, dark and screenshot images (after `analyze_photos`).
    PhotoIssues,
    /// Songs and videos with the same soundtrack (after `analyze_media`).
    SimilarMedia,
}

/// See the engine's `junk` module.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JunkKind {
    /// Thumbnail and view caches the OS recreates (always safe).
    SystemCache,
    PartialDownload,
    TempFile,
    EmptyFile,
    BrokenLink,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeepRule {
    Newest,
    Oldest,
    ShortestPath,
    LongestPath,
    ShallowestPath,
    FirstAlphabetical,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActionType {
    /// System trash on desktop, recovery bin on mobile.
    Trash,
    RecoveryBin,
    DeletePermanently,
    MoveTo,
    ReplaceWithHardlink,
    /// Copy-on-write clones of the kept copy (APFS, Btrfs, XFS, ReFS).
    ReplaceWithClone,
}

#[derive(Debug, Clone)]
pub struct ScanOptions {
    pub roots: Vec<String>,
    pub recursive: bool,
    pub max_depth: Option<u32>,
    pub follow_symlinks: bool,
    pub include_hidden: bool,
    pub skip_system_folders: bool,
    pub skip_cloud_placeholders: bool,
    pub min_size: i64,
    pub max_size: Option<i64>,
    pub include_extensions: Vec<String>,
    pub exclude_extensions: Vec<String>,
    pub categories: Vec<Category>,
    pub exclude_paths: Vec<String>,
    pub exclude_globs: Vec<String>,
    pub protected_paths: Vec<String>,
    pub hash_algorithm: HashAlgo,
    pub verify_byte_by_byte: bool,
    pub detect_duplicate_folders: bool,
    pub detect_empty_folders: bool,
    pub include_empty_files: bool,
    pub performance: PerformanceMode,
    /// 0 derives the thread count from `performance`.
    pub threads: u32,
    pub cache_dir: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ScanProgress {
    pub phase: Phase,
    pub files_discovered: i64,
    pub dirs_discovered: i64,
    pub bytes_discovered: i64,
    pub phase_items_done: i64,
    pub phase_items_total: i64,
    pub phase_bytes_done: i64,
    pub phase_bytes_total: i64,
    pub candidates: i64,
    pub cache_hits: i64,
    pub errors: i64,
    pub elapsed_ms: i64,
    pub bytes_per_second: i64,
    pub eta_ms: Option<i64>,
    pub current_path: Option<String>,
    pub paused: bool,
}

#[derive(Debug, Clone)]
pub struct ScanEvent {
    pub kind: ScanEventKind,
    pub progress: Option<ScanProgress>,
    pub error: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ScanStatsDto {
    pub files_seen: i64,
    pub dirs_seen: i64,
    pub bytes_seen: i64,
    pub eligible_files: i64,
    pub candidates_after_size: i64,
    pub candidates_after_partial: i64,
    pub files_fully_hashed: i64,
    pub bytes_hashed: i64,
    pub cache_hits: i64,
    pub hardlinks_skipped: i64,
    pub duplicate_groups: i64,
    pub duplicate_files: i64,
    pub wasted_bytes: i64,
    pub folder_groups: i64,
    pub folder_wasted_bytes: i64,
    pub empty_folders: i64,
    pub large_files: i64,
    pub photos: i64,
    pub junk_items: i64,
    pub junk_bytes: i64,
    pub errors: i64,
    pub elapsed_ms: i64,
    pub hash_algorithm: String,
}

#[derive(Debug, Clone)]
pub struct FileEntryDto {
    pub id: u32,
    pub path: String,
    pub name: String,
    pub parent: String,
    pub size: i64,
    pub modified_ms: i64,
    pub created_ms: Option<i64>,
    pub hidden: bool,
    pub selected: bool,
}

#[derive(Debug, Clone)]
pub struct FileGroupDto {
    pub index: u32,
    pub size: i64,
    pub wasted: i64,
    pub hash: String,
    pub category: Category,
    pub files: Vec<FileEntryDto>,
}

#[derive(Debug, Clone)]
pub struct FolderEntryDto {
    pub id: u32,
    pub path: String,
    pub name: String,
    pub parent: String,
    pub modified_ms: i64,
    pub selected: bool,
}

#[derive(Debug, Clone)]
pub struct FolderGroupDto {
    pub index: u32,
    pub total_bytes: i64,
    pub file_count: i64,
    pub dir_count: i64,
    pub wasted: i64,
    pub hash: String,
    pub folders: Vec<FolderEntryDto>,
}

#[derive(Debug, Clone)]
pub struct FileGroupPage {
    pub total: u32,
    pub groups: Vec<FileGroupDto>,
}

#[derive(Debug, Clone)]
pub struct FolderGroupPage {
    pub total: u32,
    pub groups: Vec<FolderGroupDto>,
}

#[derive(Debug, Clone)]
pub struct JunkEntryDto {
    pub id: u32,
    pub path: String,
    pub name: String,
    pub parent: String,
    pub size: i64,
    pub modified_ms: i64,
    pub kind: JunkKind,
    /// Always safe to remove (the OS recreates it).
    pub safe: bool,
    pub selected: bool,
}

#[derive(Debug, Clone)]
pub struct JunkPage {
    pub total: u32,
    pub items: Vec<JunkEntryDto>,
}

#[derive(Debug, Clone)]
pub struct LargeFilePage {
    pub total: u32,
    pub files: Vec<FileEntryDto>,
}

#[derive(Debug, Clone)]
pub struct EmptyFolderPage {
    pub total: u32,
    pub folders: Vec<FolderEntryDto>,
}

#[derive(Debug, Clone)]
pub struct FolderChildren {
    pub files: Vec<FileEntryDto>,
    pub folders: Vec<FolderEntryDto>,
}

#[derive(Debug, Clone)]
pub struct GroupQuery {
    pub offset: u32,
    pub limit: u32,
    pub sort: SortBy,
    pub descending: bool,
    pub category: Option<Category>,
    pub search: Option<String>,
    pub min_size: Option<i64>,
    /// Junk list only: one kind.
    pub junk_kind: Option<JunkKind>,
    /// Old-files list: last changed before this time (ms since epoch).
    pub modified_before_ms: Option<i64>,
    /// Old-files list: only below these folders.
    pub within: Option<Vec<String>>,
    /// Old-files list: only these extensions (lower case, no dot).
    pub extensions: Option<Vec<String>>,
    /// Photo-issues list: one kind.
    pub photo_issue: Option<PhotoIssueKind>,
}

#[derive(Debug, Clone)]
pub struct SelectionRuleDto {
    pub keep: KeepRule,
    pub prefer_keep_in: Vec<String>,
    pub only_select_in: Vec<String>,
    pub category: Option<Category>,
    pub search: Option<String>,
}

#[derive(Debug, Clone)]
pub struct SelectionSummaryDto {
    pub files: i64,
    pub file_bytes: i64,
    pub folders: i64,
    pub folder_bytes: i64,
    pub empty_folders: i64,
    pub active_file_groups: i64,
    pub file_wasted: i64,
    pub active_folder_groups: i64,
    pub folder_wasted: i64,
    pub remaining_empty_folders: i64,
    pub large_files: i64,
    pub large_file_bytes: i64,
    pub remaining_large_files: i64,
    pub old_files: i64,
    pub old_file_bytes: i64,
    pub photos_analyzed: bool,
    pub media_analyzed: bool,
    pub media_groups: i64,
    pub media_reclaimable: i64,
    pub media: i64,
    pub media_bytes: i64,
    pub similar_groups: i64,
    pub similar_reclaimable: i64,
    pub similar: i64,
    pub similar_bytes: i64,
    pub remaining_photo_issues: i64,
    pub photo_issues: i64,
    pub photo_issue_bytes: i64,
    pub junk: i64,
    pub junk_bytes: i64,
    pub remaining_junk: i64,
    pub remaining_junk_bytes: i64,
}

#[derive(Debug, Clone)]
pub struct ActionRequestDto {
    pub action: ActionType,
    pub target: ResultKind,
    pub destination: Option<String>,
    pub keep_structure: bool,
    pub verify_content: bool,
}

#[derive(Debug, Clone)]
pub struct IssueDto {
    pub path: String,
    pub message: String,
}

#[derive(Debug, Clone)]
pub struct ActionReportDto {
    pub succeeded: i64,
    pub failed: i64,
    pub skipped: i64,
    /// Released right away (permanent deletion, hard links).
    pub bytes_freed: i64,
    /// In the system trash or recovery bin: released when that bin is emptied.
    pub bytes_in_bin: i64,
    pub bytes_moved: i64,
    pub batch_id: Option<String>,
    pub used_system_trash: bool,
    pub issues: Vec<IssueDto>,
    /// Removed/moved paths, for media-index refresh and undo.
    pub affected_paths: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct ActionProgressDto {
    pub done: i64,
    pub total: i64,
    pub running: bool,
}

#[derive(Debug, Clone)]
pub struct CategoryStat {
    pub category: Category,
    pub groups: i64,
    pub wasted: i64,
}

#[derive(Debug, Clone)]
pub struct RecoveryItemDto {
    pub id: String,
    pub batch_id: String,
    pub original_path: String,
    pub name: String,
    pub is_dir: bool,
    pub size: i64,
    pub file_count: i64,
    pub deleted_at_ms: i64,
}

#[derive(Debug, Clone)]
pub struct RestoreReportDto {
    pub restored: u32,
    pub failed: u32,
    pub errors: Vec<IssueDto>,
}

/// Contents of the system Recycle Bin / Trash.
#[derive(Debug, Clone)]
pub struct TrashInfoDto {
    pub items: i64,
    /// `None` where the OS does not allow measuring it (macOS).
    pub bytes: Option<i64>,
}

#[derive(Debug, Clone)]
pub struct CacheInfo {
    pub entries: i64,
    pub size_bytes: i64,
    pub path: String,
}

#[derive(Debug, Clone)]
pub struct PlatformCapabilities {
    pub system_trash: bool,
    pub hardlinks: bool,
    pub os: String,
    pub cores: u32,
    pub engine_version: String,
}

/// Identifies duplicate content the user marked as "not duplicates".
/// Hashes depend on the algorithm, so entries only match scans that use it.
#[derive(Debug, Clone)]
pub struct IgnoreKeyDto {
    /// `Files` or `Folders`.
    pub kind: ResultKind,
    pub algorithm: HashAlgo,
    /// Hex-encoded content hash of the group.
    pub digest: String,
}

/// An ignore-list entry with what the user needs to recognise it later.
#[derive(Debug, Clone)]
pub struct IgnoredGroupDto {
    pub key: IgnoreKeyDto,
    pub name: String,
    pub path: String,
    pub copies: u32,
    /// Size of one copy.
    pub size: i64,
}

/// Formats for [`crate::api::results::ScanResults::export_report`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReportFormat {
    /// One row per item, for spreadsheets.
    Csv,
    /// Structured, for scripts and other tools.
    Json,
    /// A page to read or print.
    Html,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VolumeKind {
    Fixed,
    Removable,
    Network,
}

#[derive(Debug, Clone)]
pub struct VolumeDto {
    pub path: String,
    pub label: String,
    pub kind: VolumeKind,
    pub total: i64,
    pub free: i64,
}

#[derive(Debug, Clone)]
pub struct DiskUsageDto {
    pub total: i64,
    pub free: i64,
}

#[derive(Debug, Clone)]
pub struct CategoryUsageDto {
    pub category: Category,
    pub files: i64,
    pub bytes: i64,
}

/// A tile of the space map: a folder, or the files directly inside the
/// folder being shown (`folder_id` is `None`).
#[derive(Debug, Clone)]
pub struct SpaceNodeDto {
    pub folder_id: Option<u32>,
    pub path: String,
    pub name: String,
    pub bytes: i64,
    pub files: i64,
    pub folders: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecommendationKind {
    /// Thumbnail caches the OS recreates.
    SystemCaches,
    /// Unfinished downloads and temporary files at least a day old.
    LeftoverFiles,
    /// Copies in the download folders of files kept elsewhere.
    DownloadDuplicates,
    EmptyFolders,
}

#[derive(Debug, Clone)]
pub struct RecommendationDto {
    pub kind: RecommendationKind,
    pub items: i64,
    pub bytes: i64,
}

#[derive(Debug, Clone)]
pub struct ArchiveReportDto {
    pub archive: String,
    pub files: i64,
    pub folders: i64,
    pub original_bytes: i64,
    pub archive_bytes: i64,
}

/// Result of removing or moving whole paths outside a scan.
#[derive(Debug, Clone)]
pub struct PathsReportDto {
    pub done: Vec<String>,
    pub bytes: i64,
    pub issues: Vec<IssueDto>,
    pub used_system_trash: bool,
    /// Recovery-bin batch, for undo.
    pub batch_id: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PhotoIssueKind {
    Blurry,
    Dark,
    Screenshot,
}

#[derive(Debug, Clone)]
pub struct PhotoDto {
    pub id: u32,
    pub path: String,
    pub name: String,
    pub parent: String,
    pub size: i64,
    pub modified_ms: i64,
    pub width: u32,
    pub height: u32,
    pub issues: Vec<PhotoIssueKind>,
    /// The photo to keep in its similar set.
    pub best: bool,
    pub selected: bool,
}

#[derive(Debug, Clone)]
pub struct SimilarGroupDto {
    pub index: u32,
    pub reclaimable: i64,
    /// Best shot first.
    pub photos: Vec<PhotoDto>,
}

#[derive(Debug, Clone)]
pub struct SimilarGroupPage {
    pub total: u32,
    pub groups: Vec<SimilarGroupDto>,
}

#[derive(Debug, Clone)]
pub struct PhotoPage {
    pub total: u32,
    pub photos: Vec<PhotoDto>,
}

#[derive(Debug, Clone)]
pub struct PhotoAnalysisDto {
    pub analyzed: i64,
    pub failed: i64,
    pub similar_groups: i64,
    pub with_issues: i64,
}

/// A new file whose content already exists in the scanned folders.
#[derive(Debug, Clone)]
pub struct CopyMatchDto {
    pub path: String,
    pub existing: String,
    pub size: i64,
}

#[derive(Debug, Clone)]
pub struct MediaDto {
    pub id: u32,
    pub path: String,
    pub name: String,
    pub parent: String,
    pub size: i64,
    pub modified_ms: i64,
    pub duration_ms: Option<i64>,
    pub video: bool,
    /// The copy to keep (largest file).
    pub best: bool,
    pub selected: bool,
}

#[derive(Debug, Clone)]
pub struct MediaGroupDto {
    pub index: u32,
    pub reclaimable: i64,
    /// Best copy first.
    pub items: Vec<MediaDto>,
}

#[derive(Debug, Clone)]
pub struct MediaGroupPage {
    pub total: u32,
    pub groups: Vec<MediaGroupDto>,
}

#[derive(Debug, Clone)]
pub struct MediaAnalysisDto {
    pub analyzed: i64,
    /// Files without a usable soundtrack (silent videos, unsupported codecs).
    pub failed: i64,
    pub similar_groups: i64,
}

/// A Photos-library preview to analyse (iOS).
#[derive(Debug, Clone)]
pub struct ImageInputDto {
    pub path: String,
    /// Size of the original photo.
    pub width: u32,
    pub height: u32,
    pub screenshot: bool,
}

#[derive(Debug, Clone)]
pub struct ImageGroupDto {
    /// Indices into the input list.
    pub members: Vec<u32>,
    pub best: u32,
}

#[derive(Debug, Clone)]
pub struct ImageIssuesDto {
    pub index: u32,
    pub issues: Vec<PhotoIssueKind>,
}

#[derive(Debug, Clone)]
pub struct ImageSetAnalysisDto {
    pub groups: Vec<ImageGroupDto>,
    pub issues: Vec<ImageIssuesDto>,
    pub failed: i64,
}
