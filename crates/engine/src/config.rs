use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::error::{EngineError, Result};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum HashAlgorithm {
    /// Fast, SIMD-accelerated cryptographic hash. Default.
    #[default]
    Blake3,
    /// Slower but widely recognised; useful when hashes are compared with
    /// other tools.
    Sha256,
}

impl HashAlgorithm {
    pub fn id(self) -> u8 {
        match self {
            HashAlgorithm::Blake3 => 1,
            HashAlgorithm::Sha256 => 2,
        }
    }

    pub fn from_id(id: u8) -> Option<Self> {
        match id {
            1 => Some(HashAlgorithm::Blake3),
            2 => Some(HashAlgorithm::Sha256),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            HashAlgorithm::Blake3 => "BLAKE3",
            HashAlgorithm::Sha256 => "SHA-256",
        }
    }
}

/// Trade-off between speed and resource usage.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Performance {
    /// Use every core; best for desktops on AC power.
    Maximum,
    /// Leave headroom for the rest of the system. Default.
    #[default]
    Balanced,
    /// Minimal parallelism to save battery and keep the device cool.
    BatterySaver,
    /// One reader at a time — avoids seek thrashing on spinning disks.
    SpinningDisk,
}

impl Performance {
    /// Threads used for the metadata walk (latency-bound, benefits from
    /// more concurrency than cores on SSDs and network shares).
    pub fn walk_threads(self, cores: usize) -> usize {
        match self {
            Performance::Maximum => (cores * 2).clamp(4, 32),
            Performance::Balanced => cores.clamp(2, 12),
            Performance::BatterySaver => 2,
            Performance::SpinningDisk => 2,
        }
    }

    /// Threads used for hashing (throughput-bound).
    pub fn hash_threads(self, cores: usize) -> usize {
        match self {
            Performance::Maximum => cores.max(1),
            Performance::Balanced => (cores / 2).clamp(2, 8),
            Performance::BatterySaver => 1,
            Performance::SpinningDisk => 1,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FileCategory {
    Image,
    Video,
    Audio,
    Document,
    Archive,
    Application,
    Other,
}

impl FileCategory {
    pub const ALL: [FileCategory; 7] = [
        FileCategory::Image,
        FileCategory::Video,
        FileCategory::Audio,
        FileCategory::Document,
        FileCategory::Archive,
        FileCategory::Application,
        FileCategory::Other,
    ];

    /// Classifies by lower-case extension (without the dot).
    pub fn from_extension(ext: &str) -> Self {
        match ext {
            "jpg" | "jpeg" | "png" | "gif" | "bmp" | "webp" | "heic" | "heif" | "tif" | "tiff"
            | "svg" | "ico" | "raw" | "cr2" | "cr3" | "nef" | "arw" | "dng" | "orf" | "rw2"
            | "psd" | "avif" | "jxl" => FileCategory::Image,
            "mp4" | "mkv" | "mov" | "avi" | "wmv" | "flv" | "webm" | "m4v" | "3gp" | "mpg"
            | "mpeg" | "ts" | "mts" | "m2ts" | "vob" => FileCategory::Video,
            "mp3" | "wav" | "flac" | "aac" | "ogg" | "opus" | "m4a" | "wma" | "aiff" | "alac"
            | "amr" | "mid" | "midi" => FileCategory::Audio,
            "pdf" | "doc" | "docx" | "xls" | "xlsx" | "ppt" | "pptx" | "odt" | "ods" | "odp"
            | "rtf" | "txt" | "md" | "csv" | "epub" | "mobi" | "pages" | "numbers" | "key"
            | "json" | "xml" | "html" | "htm" | "log" => FileCategory::Document,
            "zip" | "rar" | "7z" | "tar" | "gz" | "tgz" | "bz2" | "xz" | "zst" | "iso" | "cab"
            | "lz" | "lzma" => FileCategory::Archive,
            "exe" | "msi" | "apk" | "aab" | "xapk" | "ipa" | "dmg" | "pkg" | "deb" | "rpm"
            | "appimage" | "dll" | "so" | "dylib" | "jar" => FileCategory::Application,
            _ => FileCategory::Other,
        }
    }
}

/// Everything that controls a scan. Serialisable so front-ends and the CLI
/// can persist presets.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct ScanConfig {
    /// Folders (or individual files) to scan.
    pub roots: Vec<PathBuf>,
    /// Descend into sub-folders.
    pub recursive: bool,
    /// Maximum depth below each root (0 = the root itself only). `None` is unlimited.
    pub max_depth: Option<u32>,
    pub follow_symlinks: bool,
    /// Report hidden files as duplicates. Hidden *folders* are not entered
    /// unless this is set.
    pub include_hidden: bool,
    /// Skip OS-managed locations (system folders, recycle bins, Android/data…).
    pub skip_system_folders: bool,
    /// Skip cloud placeholders that would be downloaded on read (OneDrive
    /// Files On-Demand, etc.).
    pub skip_cloud_placeholders: bool,

    /// Minimum file size in bytes for duplicate reporting.
    pub min_size: u64,
    pub max_size: Option<u64>,
    /// Lower-case extensions without dot; empty means all.
    pub include_extensions: Vec<String>,
    pub exclude_extensions: Vec<String>,
    /// Empty means every category.
    pub categories: Vec<FileCategory>,
    /// Folders never entered.
    pub exclude_paths: Vec<PathBuf>,
    /// Glob patterns (`**/node_modules`, `*.tmp`) matched against full paths.
    pub exclude_globs: Vec<String>,
    /// Paths the engine must never report or modify (recovery bin, cache…).
    pub protected_paths: Vec<PathBuf>,

    pub hash_algorithm: HashAlgorithm,
    /// After hashing, confirm duplicates with a byte-by-byte comparison.
    pub verify_byte_by_byte: bool,
    pub detect_duplicate_folders: bool,
    pub detect_empty_folders: bool,
    /// Report zero-byte files as a group.
    pub include_empty_files: bool,

    pub performance: Performance,
    /// Explicit hashing thread count; 0 derives it from `performance`.
    pub threads: u32,
    /// Directory for the persistent hash cache; `None` disables caching.
    pub cache_dir: Option<PathBuf>,
}

impl Default for ScanConfig {
    fn default() -> Self {
        Self {
            roots: Vec::new(),
            recursive: true,
            max_depth: None,
            follow_symlinks: false,
            include_hidden: false,
            skip_system_folders: true,
            skip_cloud_placeholders: true,
            min_size: 1,
            max_size: None,
            include_extensions: Vec::new(),
            exclude_extensions: Vec::new(),
            categories: Vec::new(),
            exclude_paths: Vec::new(),
            exclude_globs: Vec::new(),
            protected_paths: Vec::new(),
            hash_algorithm: HashAlgorithm::Blake3,
            verify_byte_by_byte: false,
            detect_duplicate_folders: true,
            detect_empty_folders: true,
            include_empty_files: false,
            performance: Performance::Balanced,
            threads: 0,
            cache_dir: None,
        }
    }
}

impl ScanConfig {
    pub fn validate(&self) -> Result<()> {
        if self.roots.is_empty() {
            return Err(EngineError::InvalidConfig(
                "select at least one folder to scan".into(),
            ));
        }
        if let Some(max) = self.max_size {
            if max < self.min_size {
                return Err(EngineError::InvalidConfig(
                    "maximum size is smaller than minimum size".into(),
                ));
            }
        }
        for glob in &self.exclude_globs {
            globset::Glob::new(glob).map_err(|e| {
                EngineError::InvalidConfig(format!("invalid exclude pattern '{glob}': {e}"))
            })?;
        }
        Ok(())
    }

    pub fn cores() -> usize {
        std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(2)
    }

    pub fn effective_hash_threads(&self) -> usize {
        if self.threads > 0 {
            self.threads as usize
        } else {
            self.performance.hash_threads(Self::cores())
        }
    }

    pub fn effective_walk_threads(&self) -> usize {
        if self.threads > 0 {
            (self.threads as usize).max(2)
        } else {
            self.performance.walk_threads(Self::cores())
        }
    }

    /// Folder comparison needs to see every entry of a tree.
    pub fn folder_analysis_enabled(&self) -> bool {
        self.recursive && self.detect_duplicate_folders
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn categories() {
        assert_eq!(FileCategory::from_extension("jpg"), FileCategory::Image);
        assert_eq!(FileCategory::from_extension("mkv"), FileCategory::Video);
        assert_eq!(FileCategory::from_extension("flac"), FileCategory::Audio);
        assert_eq!(
            FileCategory::from_extension("apk"),
            FileCategory::Application
        );
        assert_eq!(FileCategory::from_extension("xyz"), FileCategory::Other);
    }

    #[test]
    fn validation() {
        let mut cfg = ScanConfig::default();
        assert!(cfg.validate().is_err());
        cfg.roots.push(".".into());
        assert!(cfg.validate().is_ok());
        cfg.exclude_globs.push("[".into());
        assert!(cfg.validate().is_err());
    }
}
