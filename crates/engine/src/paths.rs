//! Path helpers that behave consistently across platforms.

use std::path::{Component, Path, PathBuf};

/// Canonicalises a user-supplied path for comparisons, without producing
/// Windows verbatim (`\\?\`) prefixes that are confusing in the UI.
pub fn normalize(path: &Path) -> PathBuf {
    match std::fs::canonicalize(path) {
        Ok(canonical) => strip_verbatim(canonical),
        Err(_) => lexical_clean(path),
    }
}

#[cfg(windows)]
fn strip_verbatim(path: PathBuf) -> PathBuf {
    let s = match path.to_str() {
        Some(s) => s,
        None => return path,
    };
    if let Some(rest) = s.strip_prefix(r"\\?\UNC\") {
        PathBuf::from(format!(r"\\{rest}"))
    } else if let Some(rest) = s.strip_prefix(r"\\?\") {
        // Only strip for plain drive paths (C:\...), which are always valid without the prefix.
        let bytes = rest.as_bytes();
        if bytes.len() >= 2 && bytes[1] == b':' && bytes[0].is_ascii_alphabetic() {
            PathBuf::from(rest)
        } else {
            path
        }
    } else {
        path
    }
}

#[cfg(not(windows))]
fn strip_verbatim(path: PathBuf) -> PathBuf {
    path
}

/// Removes `.` components and resolves `..` lexically.
pub fn lexical_clean(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for comp in path.components() {
        match comp {
            Component::CurDir => {}
            Component::ParentDir => {
                if !out.pop() {
                    out.push("..");
                }
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// Component-wise prefix test; case-insensitive on Windows and macOS/iOS
/// whose default file systems are case-insensitive.
pub fn starts_with(path: &Path, prefix: &Path) -> bool {
    if cfg!(any(windows, target_os = "macos", target_os = "ios")) {
        let mut p = path.components();
        for want in prefix.components() {
            match p.next() {
                Some(have) => {
                    if !component_eq_ci(have, want) {
                        return false;
                    }
                }
                None => return false,
            }
        }
        true
    } else {
        path.starts_with(prefix)
    }
}

fn component_eq_ci(a: Component<'_>, b: Component<'_>) -> bool {
    let a = a.as_os_str().to_string_lossy();
    let b = b.as_os_str().to_string_lossy();
    a.eq_ignore_ascii_case(&b) || a.to_lowercase() == b.to_lowercase()
}

pub fn is_within_any(path: &Path, prefixes: &[PathBuf]) -> bool {
    prefixes.iter().any(|p| starts_with(path, p))
}

/// Exact byte representation of a path, used for stable cache keys.
/// Unlike `to_string_lossy`, distinct paths never map to the same bytes.
pub fn path_bytes(path: &Path) -> Vec<u8> {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        path.as_os_str().as_bytes().to_vec()
    }
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        path.as_os_str()
            .encode_wide()
            .flat_map(|u| u.to_le_bytes())
            .collect()
    }
    #[cfg(not(any(unix, windows)))]
    {
        path.to_string_lossy().into_owned().into_bytes()
    }
}

/// Identifies the volume a path lives on for "same device" decisions on
/// platforms without `st_dev` (Windows): the drive letter or UNC share.
pub fn volume_key(path: &Path) -> Option<String> {
    match path.components().next()? {
        Component::Prefix(prefix) => Some(prefix.as_os_str().to_string_lossy().to_lowercase()),
        _ => None,
    }
}

/// Lower-case extension without the dot.
pub fn extension_lower(name: &std::ffi::OsStr) -> Option<String> {
    Path::new(name)
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
}

/// Returns a non-existing path by appending ` (n)` before the extension.
pub fn unique_destination(path: &Path) -> PathBuf {
    if !path.exists() {
        return path.to_path_buf();
    }
    let parent = path.parent().unwrap_or_else(|| Path::new(""));
    let stem = path
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default();
    let ext = path
        .extension()
        .map(|e| format!(".{}", e.to_string_lossy()))
        .unwrap_or_default();
    for n in 1..10_000 {
        let candidate = parent.join(format!("{stem} ({n}){ext}"));
        if !candidate.exists() {
            return candidate;
        }
    }
    parent.join(format!("{stem} ({}){ext}", std::process::id()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prefix_is_component_wise() {
        assert!(starts_with(Path::new("/a/b/c"), Path::new("/a/b")));
        assert!(!starts_with(Path::new("/a/bc"), Path::new("/a/b")));
    }

    #[cfg(windows)]
    #[test]
    fn windows_prefix_ignores_case() {
        assert!(starts_with(
            Path::new(r"C:\Users\Me"),
            Path::new(r"c:\users")
        ));
        assert_eq!(
            strip_verbatim(PathBuf::from(r"\\?\C:\Data")),
            PathBuf::from(r"C:\Data")
        );
        assert_eq!(
            strip_verbatim(PathBuf::from(r"\\?\UNC\srv\share")),
            PathBuf::from(r"\\srv\share")
        );
    }

    #[test]
    fn clean_resolves_dots() {
        assert_eq!(lexical_clean(Path::new("a/./b/../c")), PathBuf::from("a/c"));
    }

    #[test]
    fn unique_destination_appends_counter() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("photo.jpg");
        assert_eq!(unique_destination(&p), p);
        std::fs::write(&p, b"x").unwrap();
        assert_eq!(unique_destination(&p), dir.path().join("photo (1).jpg"));
    }
}
