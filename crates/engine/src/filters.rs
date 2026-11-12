//! Compiled scan filters. Built once per scan and shared read-only by all
//! walker threads.

use std::collections::HashSet;
use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use globset::{GlobBuilder, GlobSet, GlobSetBuilder};

use crate::config::{FileCategory, ScanConfig};
use crate::error::{EngineError, Result};
use crate::paths;
use crate::platform;

pub struct Filters {
    min_size: u64,
    max_size: Option<u64>,
    include_ext: HashSet<String>,
    exclude_ext: HashSet<String>,
    categories: HashSet<FileCategory>,
    include_hidden: bool,
    skip_system: bool,
    excluded_paths: Vec<PathBuf>,
    globs: GlobSet,
}

impl Filters {
    pub fn new(cfg: &ScanConfig) -> Result<Self> {
        let norm_ext = |v: &Vec<String>| -> HashSet<String> {
            v.iter()
                .map(|e| e.trim().trim_start_matches('.').to_lowercase())
                .filter(|e| !e.is_empty())
                .collect()
        };

        let mut globs = GlobSetBuilder::new();
        for pattern in &cfg.exclude_globs {
            let glob = GlobBuilder::new(pattern)
                .case_insensitive(cfg!(any(windows, target_os = "macos", target_os = "ios")))
                .literal_separator(false)
                .build()
                .map_err(|e| EngineError::InvalidConfig(format!("pattern '{pattern}': {e}")))?;
            globs.add(glob);
        }

        let mut excluded_paths: Vec<PathBuf> = cfg
            .exclude_paths
            .iter()
            .chain(cfg.protected_paths.iter())
            .map(|p| paths::normalize(p))
            .collect();
        if cfg.skip_system_folders {
            excluded_paths.extend(platform::system_paths());
        }

        Ok(Self {
            min_size: cfg.min_size,
            max_size: cfg.max_size,
            include_ext: norm_ext(&cfg.include_extensions),
            exclude_ext: norm_ext(&cfg.exclude_extensions),
            categories: cfg.categories.iter().copied().collect(),
            include_hidden: cfg.include_hidden,
            skip_system: cfg.skip_system_folders,
            excluded_paths,
            globs: globs
                .build()
                .map_err(|e| EngineError::InvalidConfig(e.to_string()))?,
        })
    }

    /// Whether the walker should enter this directory.
    pub fn allow_dir(&self, path: &Path, name: &OsStr, hidden: bool) -> bool {
        if hidden && !self.include_hidden {
            return false;
        }
        if self.skip_system && platform::is_system_dir_name(name) {
            return false;
        }
        if paths::is_within_any(path, &self.excluded_paths) {
            return false;
        }
        !self.file_excluded(path)
    }

    /// Whether a file is excluded from the scan entirely (as opposed to being
    /// seen but not reported).
    pub fn file_excluded(&self, path: &Path) -> bool {
        !self.globs.is_empty() && self.globs.is_match(path)
    }

    /// Whether a seen file is eligible for duplicate-file reporting.
    pub fn file_eligible(&self, ext: Option<&str>, size: u64, hidden: bool) -> bool {
        if hidden && !self.include_hidden {
            return false;
        }
        if size < self.min_size {
            return false;
        }
        if let Some(max) = self.max_size {
            if size > max {
                return false;
            }
        }
        let ext = ext.unwrap_or("");
        if !self.include_ext.is_empty() && !self.include_ext.contains(ext) {
            return false;
        }
        if self.exclude_ext.contains(ext) {
            return false;
        }
        if !self.categories.is_empty()
            && !self.categories.contains(&FileCategory::from_extension(ext))
        {
            return false;
        }
        true
    }

    pub fn include_hidden(&self) -> bool {
        self.include_hidden
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn filters(f: impl FnOnce(&mut ScanConfig)) -> Filters {
        let mut cfg = ScanConfig {
            roots: vec![".".into()],
            ..Default::default()
        };
        f(&mut cfg);
        Filters::new(&cfg).unwrap()
    }

    #[test]
    fn size_and_extension_rules() {
        let f = filters(|c| {
            c.min_size = 10;
            c.max_size = Some(100);
            c.include_extensions = vec![".JPG".into(), "png".into()];
        });
        assert!(f.file_eligible(Some("jpg"), 50, false));
        assert!(!f.file_eligible(Some("jpg"), 5, false));
        assert!(!f.file_eligible(Some("jpg"), 500, false));
        assert!(!f.file_eligible(Some("gif"), 50, false));
        assert!(!f.file_eligible(Some("jpg"), 50, true));
    }

    #[test]
    fn categories_filter() {
        let f = filters(|c| c.categories = vec![FileCategory::Video]);
        assert!(f.file_eligible(Some("mp4"), 10, false));
        assert!(!f.file_eligible(Some("jpg"), 10, false));
    }

    #[test]
    fn globs_exclude_dirs() {
        let f = filters(|c| c.exclude_globs = vec!["**/node_modules".into(), "*.tmp".into()]);
        assert!(!f.allow_dir(
            Path::new("/p/app/node_modules"),
            OsStr::new("node_modules"),
            false
        ));
        assert!(f.allow_dir(Path::new("/p/app/src"), OsStr::new("src"), false));
        assert!(f.file_excluded(Path::new("/p/x.tmp")));
    }
}
