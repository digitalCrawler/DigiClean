//! Files that can go regardless of duplicates: OS thumbnail caches,
//! unfinished downloads, leftover temporary files, empty files and broken
//! links or shortcuts.
//!
//! Each rule has a safety level. Only [`JunkKind::is_safe`] kinds are picked
//! by "select safe"; the rest are shown for review. Rules err on the side of
//! not reporting: downloads and temporary files must be a day old (they may
//! still be in use), marker files such as `.gitkeep` or `__init__.py` are
//! never "empty junk", and a shortcut is only broken when its drive is
//! present but the target is not.

use std::ffi::OsStr;
use std::fs;
use std::io::{ErrorKind, Read};
use std::path::{Component, Path, PathBuf};

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JunkKind {
    /// Thumbnail and view caches the OS recreates (`Thumbs.db`, `.DS_Store`).
    SystemCache,
    /// Downloads that never finished (`.crdownload`, `.part`, …).
    PartialDownload,
    /// Temporary and lock files left behind (`.tmp`, `~$report.docx`).
    TempFile,
    /// Zero-byte files that are not known markers.
    EmptyFile,
    /// Symbolic links or Windows shortcuts whose target is gone.
    BrokenLink,
}

impl JunkKind {
    pub const ALL: [JunkKind; 5] = [
        JunkKind::SystemCache,
        JunkKind::PartialDownload,
        JunkKind::TempFile,
        JunkKind::EmptyFile,
        JunkKind::BrokenLink,
    ];

    /// Removing it never loses anything: the OS rebuilds it on demand.
    pub fn is_safe(self) -> bool {
        matches!(self, JunkKind::SystemCache)
    }

    pub fn label(self) -> &'static str {
        match self {
            JunkKind::SystemCache => "system cache",
            JunkKind::PartialDownload => "unfinished download",
            JunkKind::TempFile => "temporary file",
            JunkKind::EmptyFile => "empty file",
            JunkKind::BrokenLink => "broken link",
        }
    }
}

/// Downloads and temporary files younger than this may still be in use.
pub const MIN_AGE_NS: i64 = 24 * 3600 * 1_000_000_000;

/// OS caches that are always safe to delete. `desktop.ini` and `.localized`
/// are deliberately absent: they hold folder names and icons.
pub fn is_system_cache(name: &OsStr) -> bool {
    let n = name.to_string_lossy();
    matches!(
        n.as_ref(),
        ".DS_Store" | "Thumbs.db" | "ehthumbs.db" | "ehthumbs_vista.db"
    ) || n.eq_ignore_ascii_case("thumbs.db")
}

/// Zero-byte files that mean something by existing.
const EMPTY_MARKERS: &[&str] = &["__init__.py", "py.typed", "placeholder", "keep", "empty"];

/// Classifies a regular file by name, size and age (`now_ns` is the scan
/// time). System caches are recognised separately by [`is_system_cache`].
pub fn classify(name: &OsStr, size: u64, modified_ns: i64, now_ns: i64) -> Option<JunkKind> {
    let n = name.to_string_lossy();
    let lower = n.to_lowercase();
    let old = now_ns.saturating_sub(modified_ns) >= MIN_AGE_NS;
    let ext = lower.rsplit_once('.').map(|(_, e)| e);
    if matches!(
        ext,
        Some("crdownload" | "part" | "partial" | "opdownload" | "!ut" | "!qb")
    ) {
        return old.then_some(JunkKind::PartialDownload);
    }
    if matches!(ext, Some("tmp" | "temp")) || n.starts_with("~$") {
        return old.then_some(JunkKind::TempFile);
    }
    if size == 0
        && !n.starts_with('.')
        && !EMPTY_MARKERS.contains(&lower.as_str())
        && !lower.contains("lock")
    {
        return Some(JunkKind::EmptyFile);
    }
    None
}

/// Whether a symbolic link's target is missing (not merely unreadable).
pub fn link_is_broken(link: &Path) -> bool {
    matches!(fs::metadata(link), Err(e) if e.kind() == ErrorKind::NotFound)
}

/// Whether a Windows shortcut (`.lnk`) points to a local file or folder that
/// no longer exists on a drive that does. Unknown formats, network targets
/// and targets on missing drives are never reported.
pub fn shortcut_is_broken(path: &Path) -> bool {
    let Some(target) = read_shortcut_target(path) else {
        return false;
    };
    let Some(Component::Prefix(prefix)) = target.components().next() else {
        return false;
    };
    let mut drive = PathBuf::from(prefix.as_os_str());
    drive.push(std::path::MAIN_SEPARATOR_STR);
    drive.exists() && matches!(fs::metadata(&target), Err(e) if e.kind() == ErrorKind::NotFound)
}

/// Local target path of a shell link (MS-SHLLINK `LinkInfo`), if it has one.
pub fn read_shortcut_target(path: &Path) -> Option<PathBuf> {
    let mut bytes = Vec::new();
    fs::File::open(path)
        .ok()?
        .take(64 * 1024)
        .read_to_end(&mut bytes)
        .ok()?;
    parse_shortcut(&bytes)
}

fn parse_shortcut(b: &[u8]) -> Option<PathBuf> {
    let u16_at = |at: usize| Some(u16::from_le_bytes(b.get(at..at + 2)?.try_into().ok()?));
    let u32_at = |at: usize| Some(u32::from_le_bytes(b.get(at..at + 4)?.try_into().ok()?) as usize);
    if u32_at(0)? != 0x4C {
        return None;
    }
    let flags = u32_at(0x14)?;
    let mut at = 0x4C;
    if flags & 0x01 != 0 {
        // HasLinkTargetIDList
        at += 2 + u16_at(at)? as usize;
    }
    if flags & 0x02 == 0 {
        return None; // No LinkInfo: a shell item, not a file path.
    }
    let info = at;
    let header_size = u32_at(info + 4)?;
    let info_flags = u32_at(info + 8)?;
    if info_flags & 0x01 == 0 || info_flags & 0x02 != 0 {
        return None; // No local path, or a network share.
    }
    let ansi = |off: usize| -> Option<String> {
        let s = b.get(info + off..)?;
        let s = &s[..s.iter().position(|&c| c == 0)?];
        // Non-ASCII ANSI depends on the code page; do not guess.
        s.is_ascii()
            .then(|| String::from_utf8_lossy(s).into_owned())
    };
    let wide = |off: usize| -> Option<String> {
        let s = b.get(info + off..)?;
        let units: Vec<u16> = s
            .chunks_exact(2)
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .take_while(|&u| u != 0)
            .collect();
        String::from_utf16(&units).ok()
    };
    let (base, suffix) = if header_size >= 0x24 {
        (wide(u32_at(info + 0x1C)?)?, wide(u32_at(info + 0x20)?)?)
    } else {
        (ansi(u32_at(info + 0x10)?)?, ansi(u32_at(info + 0x18)?)?)
    };
    if base.is_empty() {
        return None;
    }
    Some(PathBuf::from(base + &suffix))
}

#[cfg(test)]
mod tests {
    use super::*;

    const DAY: i64 = MIN_AGE_NS;

    #[test]
    fn rules() {
        let now = 100 * DAY;
        let c = |name: &str, size: u64, age: i64| classify(OsStr::new(name), size, now - age, now);
        assert_eq!(
            c("setup.exe.crdownload", 5, 2 * DAY),
            Some(JunkKind::PartialDownload)
        );
        assert_eq!(
            c("movie.mkv.part", 5, 2 * DAY),
            Some(JunkKind::PartialDownload)
        );
        assert_eq!(
            c("movie.mkv.part", 5, DAY / 2),
            None,
            "may still be downloading"
        );
        assert_eq!(c("movie.part1.rar", 5, 2 * DAY), None);
        assert_eq!(c("~$Budget.xlsx", 165, 3 * DAY), Some(JunkKind::TempFile));
        assert_eq!(c("A1B2.TMP", 9, 3 * DAY), Some(JunkKind::TempFile));
        assert_eq!(c("A1B2.tmp", 9, 60), None, "in use");
        assert_eq!(c("notes.txt", 0, 0), Some(JunkKind::EmptyFile));
        assert_eq!(c(".gitkeep", 0, 0), None);
        assert_eq!(c("__init__.py", 0, 0), None);
        assert_eq!(c("yarn.lock", 0, 0), None);
        assert_eq!(c("notes.txt", 1, 10 * DAY), None);
        assert!(is_system_cache(OsStr::new("Thumbs.db")));
        assert!(is_system_cache(OsStr::new(".DS_Store")));
        assert!(!is_system_cache(OsStr::new("desktop.ini")));
        assert!(JunkKind::SystemCache.is_safe() && !JunkKind::EmptyFile.is_safe());
    }

    /// A minimal shell link: header, LinkInfo with a local base path.
    fn shortcut(base: &str, unicode: bool) -> Vec<u8> {
        let mut b = vec![0u8; 0x4C];
        b[0] = 0x4C;
        b[0x14] = 0x02; // HasLinkInfo
        let header: u32 = if unicode { 0x24 } else { 0x1C };
        let mut info = vec![0u8; header as usize];
        let put =
            |v: &mut Vec<u8>, at: usize, x: u32| v[at..at + 4].copy_from_slice(&x.to_le_bytes());
        put(&mut info, 4, header);
        put(&mut info, 8, 0x01); // VolumeIDAndLocalBasePath
        if unicode {
            let base_at = info.len() as u32;
            for u in base.encode_utf16().chain([0]) {
                info.extend_from_slice(&u.to_le_bytes());
            }
            let suffix_at = info.len() as u32;
            info.extend_from_slice(&[0, 0]);
            put(&mut info, 0x1C, base_at);
            put(&mut info, 0x20, suffix_at);
        } else {
            let base_at = info.len() as u32;
            info.extend_from_slice(base.as_bytes());
            info.push(0);
            let suffix_at = info.len() as u32;
            info.push(0);
            put(&mut info, 0x10, base_at);
            put(&mut info, 0x18, suffix_at);
        }
        let len = info.len() as u32;
        put(&mut info, 0, len);
        b.extend(info);
        b
    }

    #[test]
    fn shortcut_targets_are_read() {
        assert_eq!(
            parse_shortcut(&shortcut(r"C:\Program Files\Old App\app.exe", false)),
            Some(PathBuf::from(r"C:\Program Files\Old App\app.exe"))
        );
        assert_eq!(
            parse_shortcut(&shortcut(r"D:\Fotos\Café", true)),
            Some(PathBuf::from(r"D:\Fotos\Café"))
        );
        assert_eq!(
            parse_shortcut(&shortcut("C:\\Caf\u{e9}", false)),
            None,
            "ANSI non-ASCII"
        );
        assert_eq!(parse_shortcut(b"not a shortcut"), None);
        assert_eq!(parse_shortcut(&[0x4C, 0, 0, 0]), None, "truncated");
    }

    #[cfg(windows)]
    #[test]
    fn broken_shortcuts_need_a_present_drive() {
        let dir = tempfile::tempdir().unwrap();
        let gone = dir.path().join("gone.exe");
        let lnk = dir.path().join("gone.lnk");
        fs::write(&lnk, shortcut(&gone.to_string_lossy(), true)).unwrap();
        assert!(shortcut_is_broken(&lnk));
        fs::write(&gone, b"x").unwrap();
        assert!(!shortcut_is_broken(&lnk));
        let elsewhere = dir.path().join("elsewhere.lnk");
        fs::write(&elsewhere, shortcut(r"Q:\nothing\here.exe", true)).unwrap();
        if !Path::new("Q:\\").exists() {
            assert!(
                !shortcut_is_broken(&elsewhere),
                "missing drive is not 'broken'"
            );
        }
    }
}
