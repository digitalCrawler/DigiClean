//! Operating-system specific details: hidden/system attributes, cloud
//! placeholders, file identity (for hard-link detection) and locations that
//! must never be scanned.

use std::ffi::OsStr;
use std::fs::{File, Metadata, OpenOptions};
use std::path::{Path, PathBuf};

/// `(device, inode)` on Unix, `(volume serial, file index)` on Windows.
pub type FileIdentity = (u64, u64);

pub fn is_hidden(name: &OsStr, meta: Option<&Metadata>) -> bool {
    name.to_string_lossy().starts_with('.') || has_hidden_attribute(meta)
}

/// The Windows "hidden" attribute; other systems hide by name only.
#[cfg(windows)]
fn has_hidden_attribute(meta: Option<&Metadata>) -> bool {
    use std::os::windows::fs::MetadataExt;
    const FILE_ATTRIBUTE_HIDDEN: u32 = 0x2;
    meta.is_some_and(|m| m.file_attributes() & FILE_ATTRIBUTE_HIDDEN != 0)
}

#[cfg(not(windows))]
fn has_hidden_attribute(_meta: Option<&Metadata>) -> bool {
    false
}

/// System-flagged files on Windows (pagefile, hiberfil, …).
pub fn is_system_file(_meta: &Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        const FILE_ATTRIBUTE_SYSTEM: u32 = 0x4;
        return _meta.file_attributes() & FILE_ATTRIBUTE_SYSTEM != 0;
    }
    #[allow(unreachable_code)]
    false
}

/// True for cloud files whose content is not stored locally and would be
/// downloaded on read (OneDrive / iCloud for Windows / Dropbox placeholders).
pub fn is_cloud_placeholder(_meta: &Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        const FILE_ATTRIBUTE_OFFLINE: u32 = 0x1000;
        const FILE_ATTRIBUTE_RECALL_ON_OPEN: u32 = 0x4_0000;
        const FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS: u32 = 0x40_0000;
        return _meta.file_attributes()
            & (FILE_ATTRIBUTE_OFFLINE
                | FILE_ATTRIBUTE_RECALL_ON_OPEN
                | FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS)
            != 0;
    }
    #[allow(unreachable_code)]
    false
}

/// Identity available from directory-walk metadata (free on Unix).
pub fn identity_from_metadata(_meta: &Metadata) -> Option<FileIdentity> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        return Some((_meta.dev(), _meta.ino()));
    }
    #[allow(unreachable_code)]
    None
}

/// Identity from an open handle. On Windows this is the only cheap way to
/// get a stable file id.
pub fn identity_from_file(_file: &File) -> Option<FileIdentity> {
    #[cfg(windows)]
    {
        use std::os::windows::io::AsRawHandle;
        use windows_sys::Win32::Storage::FileSystem::{
            GetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION,
        };
        // SAFETY: the handle is valid for the lifetime of `_file` and `info`
        // is a plain-old-data out parameter.
        unsafe {
            let mut info: BY_HANDLE_FILE_INFORMATION = std::mem::zeroed();
            if GetFileInformationByHandle(_file.as_raw_handle() as _, &mut info) != 0 {
                let index = ((info.nFileIndexHigh as u64) << 32) | info.nFileIndexLow as u64;
                return Some((info.dwVolumeSerialNumber as u64, index));
            }
        }
        return None;
    }
    #[cfg(unix)]
    {
        return _file
            .metadata()
            .ok()
            .and_then(|m| identity_from_metadata(&m));
    }
    #[allow(unreachable_code)]
    None
}

/// Opens a file for a single sequential pass, hinting the OS cache manager.
pub fn open_sequential(path: &Path) -> std::io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        const FILE_FLAG_SEQUENTIAL_SCAN: u32 = 0x0800_0000;
        options.custom_flags(FILE_FLAG_SEQUENTIAL_SCAN);
    }
    options.open(path)
}

/// Opens a file for random sampling reads.
pub fn open_random(path: &Path) -> std::io::Result<File> {
    OpenOptions::new().read(true).open(path)
}

/// OS-generated metadata files that may differ between otherwise identical
/// folders and are recreated automatically. They are ignored when comparing
/// folders and when deciding whether a folder is empty.
pub fn is_junk_file(name: &OsStr) -> bool {
    matches!(
        name.to_string_lossy().as_ref(),
        ".DS_Store" | "Thumbs.db" | "ehthumbs.db" | "desktop.ini" | "Desktop.ini" | ".localized"
    )
}

/// Directory names that are OS-managed wherever they appear.
pub fn is_system_dir_name(name: &OsStr) -> bool {
    let n = name.to_string_lossy();
    matches!(
        n.as_ref(),
        "$Recycle.Bin"
            | "$RECYCLE.BIN"
            | "System Volume Information"
            | "$WinREAgent"
            | "$SysReset"
            | "Config.Msi"
            | ".Spotlight-V100"
            | ".fseventsd"
            | ".Trashes"
            | ".DocumentRevisions-V100"
            | ".TemporaryItems"
            | "lost+found"
            | "DigiCleanRecovery"
    ) || n.starts_with(".Trash")
}

/// Absolute locations that should not be scanned when
/// `skip_system_folders` is enabled.
pub fn system_paths() -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = Vec::new();
    #[cfg(windows)]
    {
        if let Some(windir) = std::env::var_os("WINDIR") {
            out.push(PathBuf::from(windir));
        }
        if let Some(program_data) = std::env::var_os("ProgramData") {
            out.push(
                PathBuf::from(program_data)
                    .join("Microsoft")
                    .join("Windows Defender"),
            );
        }
    }
    #[cfg(target_os = "android")]
    {
        for base in ["/storage/emulated/0", "/sdcard"] {
            out.push(PathBuf::from(base).join("Android").join("data"));
            out.push(PathBuf::from(base).join("Android").join("obb"));
        }
        out.extend(["/proc", "/sys", "/dev", "/system", "/vendor"].map(PathBuf::from));
    }
    #[cfg(all(unix, not(target_os = "android")))]
    {
        out.extend(["/proc", "/sys", "/dev", "/run", "/var/run", "/snap"].map(PathBuf::from));
        #[cfg(target_os = "macos")]
        out.extend(["/System", "/private/var/vm", "/Volumes/Recovery"].map(PathBuf::from));
    }
    out
}

/// Whether moving to the operating system's trash is available.
pub const fn supports_system_trash() -> bool {
    cfg!(any(
        windows,
        target_os = "macos",
        all(target_os = "linux", not(target_os = "android"))
    ))
}

/// Whether hard links can be created by the app on this platform.
pub const fn supports_hardlinks() -> bool {
    cfg!(any(windows, target_os = "macos", target_os = "linux"))
}

#[cfg(any(
    windows,
    target_os = "macos",
    all(target_os = "linux", not(target_os = "android"))
))]
pub fn move_to_system_trash(paths: &[PathBuf]) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        use trash::macos::{DeleteMethod, TrashContextExtMacos};
        let mut ctx = trash::TrashContext::default();
        // NSFileManager avoids the Finder automation permission prompt.
        ctx.set_delete_method(DeleteMethod::NsFileManager);
        return ctx.delete_all(paths).map_err(|e| e.to_string());
    }
    #[allow(unreachable_code)]
    trash::delete_all(paths).map_err(|e| e.to_string())
}

#[cfg(not(any(
    windows,
    target_os = "macos",
    all(target_os = "linux", not(target_os = "android"))
)))]
pub fn move_to_system_trash(_paths: &[PathBuf]) -> Result<(), String> {
    Err("the system trash is not available on this platform".into())
}

/// What is currently in the system trash. Space used by these items is only
/// released when the trash is emptied.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TrashInfo {
    pub items: u64,
    /// `None` where the OS does not let apps measure the trash (macOS).
    pub bytes: Option<u64>,
}

/// Contents of the system trash, or `None` where there is no system trash.
pub fn system_trash_info() -> Result<Option<TrashInfo>, String> {
    #[cfg(windows)]
    {
        use windows_sys::Win32::UI::Shell::{SHQueryRecycleBinW, SHQUERYRBINFO};
        let mut info = SHQUERYRBINFO {
            cbSize: std::mem::size_of::<SHQUERYRBINFO>() as u32,
            i64Size: 0,
            i64NumItems: 0,
        };
        // SAFETY: a null root means "all drives"; `info` is a valid out pointer.
        let hr = unsafe { SHQueryRecycleBinW(std::ptr::null(), &mut info) };
        if hr < 0 {
            return Err(format!("could not read the Recycle Bin (0x{hr:08x})"));
        }
        return Ok(Some(TrashInfo {
            items: info.i64NumItems.max(0) as u64,
            bytes: Some(info.i64Size.max(0) as u64),
        }));
    }
    #[cfg(all(target_os = "linux", not(target_os = "android")))]
    {
        let items = trash::os_limited::list().map_err(|e| e.to_string())?;
        let mut bytes = 0u64;
        for item in &items {
            // Folders report entry counts only; count what can be measured.
            if let Ok(meta) = trash::os_limited::metadata(item) {
                bytes += meta.size.size().unwrap_or(0);
            }
        }
        return Ok(Some(TrashInfo {
            items: items.len() as u64,
            bytes: Some(bytes),
        }));
    }
    #[cfg(target_os = "macos")]
    {
        // ~/.Trash is privacy-protected; only Finder may look inside.
        return Ok(Some(TrashInfo {
            items: 0,
            bytes: None,
        }));
    }
    #[allow(unreachable_code)]
    Ok(None)
}

/// Permanently deletes everything in the system trash.
pub fn empty_system_trash() -> Result<(), String> {
    #[cfg(windows)]
    {
        use windows_sys::Win32::UI::Shell::{
            SHEmptyRecycleBinW, SHERB_NOCONFIRMATION, SHERB_NOPROGRESSUI, SHERB_NOSOUND,
        };
        if system_trash_info()?.is_some_and(|i| i.items == 0) {
            return Ok(());
        }
        // SAFETY: no owner window, null root = all drives.
        let hr = unsafe {
            SHEmptyRecycleBinW(
                std::ptr::null_mut(),
                std::ptr::null(),
                SHERB_NOCONFIRMATION | SHERB_NOPROGRESSUI | SHERB_NOSOUND,
            )
        };
        if hr < 0 {
            return Err(format!("could not empty the Recycle Bin (0x{hr:08x})"));
        }
        return Ok(());
    }
    #[cfg(all(target_os = "linux", not(target_os = "android")))]
    {
        let items = trash::os_limited::list().map_err(|e| e.to_string())?;
        return trash::os_limited::purge_all(items).map_err(|e| e.to_string());
    }
    #[cfg(target_os = "macos")]
    {
        // Asks the user once to allow DigiClean to control Finder.
        let status = std::process::Command::new("osascript")
            .args(["-e", "tell application \"Finder\" to empty trash"])
            .status()
            .map_err(|e| e.to_string())?;
        return if status.success() {
            Ok(())
        } else {
            Err("Finder did not empty the Trash (permission may have been denied)".into())
        };
    }
    #[allow(unreachable_code)]
    Err("there is no system trash on this platform".into())
}

/// Whether the volume holding `path` can make copy-on-write clones:
/// `Some(false)` when known not to (e.g. NTFS), `None` when it can only be
/// found out by trying (most non-Windows systems).
pub fn clone_support(path: &Path) -> Option<bool> {
    match reflink_copy::check_reflink_support(path, path) {
        Ok(reflink_copy::ReflinkSupport::Supported) => Some(true),
        Ok(reflink_copy::ReflinkSupport::NotSupported) => Some(false),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Read-only: never empties anything.
    #[test]
    fn system_trash_can_be_measured_where_supported() {
        let info = system_trash_info().expect("query trash");
        if cfg!(any(
            windows,
            all(target_os = "linux", not(target_os = "android"))
        )) {
            assert!(info.and_then(|i| i.bytes).is_some());
        }
    }
}
