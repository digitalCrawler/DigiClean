//! Drives and their capacity, for the storage overview.
//!
//! Desktop systems list their volumes here. Android and iOS return an empty
//! list: the app knows their storage volumes from the platform and asks for
//! [`disk_usage`] of each.

use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DiskUsage {
    pub total: u64,
    /// Space available to the current user.
    pub free: u64,
}

impl DiskUsage {
    pub fn used(&self) -> u64 {
        self.total.saturating_sub(self.free)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VolumeKind {
    Fixed,
    Removable,
    Network,
}

#[derive(Clone, Debug)]
pub struct Volume {
    /// Mount point or drive root (`C:\`, `/`, `/media/me/USB`).
    pub path: PathBuf,
    pub label: String,
    pub kind: VolumeKind,
    pub usage: DiskUsage,
}

/// Capacity of the volume holding `path`.
pub fn disk_usage(path: &Path) -> Option<DiskUsage> {
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
        let wide: Vec<u16> = path.as_os_str().encode_wide().chain([0]).collect();
        let (mut avail, mut total, mut free) = (0u64, 0u64, 0u64);
        // SAFETY: valid NUL-terminated path and out-pointers.
        let ok = unsafe { GetDiskFreeSpaceExW(wide.as_ptr(), &mut avail, &mut total, &mut free) };
        (ok != 0 && total > 0).then_some(DiskUsage { total, free: avail })
    }
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        let c = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
        // SAFETY: zeroed POD out-struct, valid C string.
        let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
        if unsafe { libc::statvfs(c.as_ptr(), &mut st) } != 0 {
            return None;
        }
        let unit = if st.f_frsize > 0 {
            st.f_frsize as u64
        } else {
            st.f_bsize as u64
        };
        let total = st.f_blocks as u64 * unit;
        (total > 0).then_some(DiskUsage {
            total,
            free: st.f_bavail as u64 * unit,
        })
    }
    #[cfg(not(any(windows, unix)))]
    {
        let _ = path;
        None
    }
}

/// Volumes worth showing: fixed, removable and network drives with a size.
pub fn list() -> Vec<Volume> {
    #[cfg(windows)]
    {
        windows_volumes()
    }
    #[cfg(target_os = "linux")]
    {
        let text = std::fs::read_to_string("/proc/self/mounts").unwrap_or_default();
        linux_volumes(&parse_mounts(&text))
    }
    #[cfg(target_os = "macos")]
    {
        mac_volumes()
    }
    #[cfg(not(any(windows, target_os = "linux", target_os = "macos")))]
    {
        Vec::new()
    }
}

#[cfg(windows)]
fn windows_volumes() -> Vec<Volume> {
    use windows_sys::Win32::Storage::FileSystem::{
        GetDriveTypeW, GetLogicalDrives, GetVolumeInformationW,
    };
    // GetDriveTypeW results.
    const REMOVABLE: u32 = 2;
    const FIXED: u32 = 3;
    const REMOTE: u32 = 4;

    // SAFETY: no arguments.
    let mask = unsafe { GetLogicalDrives() };
    let mut out = Vec::new();
    for i in 0..26u32 {
        if mask & (1 << i) == 0 {
            continue;
        }
        let letter = char::from(b'A' + i as u8);
        let root = format!("{letter}:\\");
        let wide: Vec<u16> = root.encode_utf16().chain([0]).collect();
        // SAFETY: valid NUL-terminated root.
        let kind = match unsafe { GetDriveTypeW(wide.as_ptr()) } {
            FIXED => VolumeKind::Fixed,
            REMOVABLE => VolumeKind::Removable,
            REMOTE => VolumeKind::Network,
            _ => continue, // CD/DVD, RAM disks, unknown
        };
        let Some(usage) = disk_usage(Path::new(&root)) else {
            continue; // e.g. an empty card reader
        };
        let mut name = [0u16; 261];
        // SAFETY: buffer length matches; other outputs are optional.
        let ok = unsafe {
            GetVolumeInformationW(
                wide.as_ptr(),
                name.as_mut_ptr(),
                name.len() as u32,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                0,
            )
        };
        let label = if ok != 0 {
            let len = name.iter().position(|&c| c == 0).unwrap_or(0);
            String::from_utf16_lossy(&name[..len])
        } else {
            String::new()
        };
        let label = match (label.is_empty(), kind) {
            (false, _) => format!("{label} ({letter}:)"),
            (true, VolumeKind::Fixed) => format!("Local Disk ({letter}:)"),
            (true, VolumeKind::Removable) => format!("USB Drive ({letter}:)"),
            (true, VolumeKind::Network) => format!("Network Drive ({letter}:)"),
        };
        out.push(Volume {
            path: PathBuf::from(root),
            label,
            kind,
            usage,
        });
    }
    out
}

/// One line of `/proc/self/mounts`.
#[cfg_attr(not(any(test, target_os = "linux")), allow(dead_code))]
#[derive(Debug, PartialEq, Eq)]
struct Mount {
    device: String,
    point: String,
    fs: String,
}

/// Parses `/proc/self/mounts`, decoding `\040`-style escapes.
#[cfg_attr(not(any(test, target_os = "linux")), allow(dead_code))]
fn parse_mounts(text: &str) -> Vec<Mount> {
    fn unescape(s: &str) -> String {
        let b = s.as_bytes();
        let mut out = Vec::with_capacity(b.len());
        let mut i = 0;
        while i < b.len() {
            let value = b
                .get(i + 1..i + 4)
                .filter(|d| d.iter().all(|c| (b'0'..=b'7').contains(c)))
                .map(|d| d.iter().fold(0u32, |v, c| v * 8 + u32::from(c - b'0')));
            if let (b'\\', Some(v @ 0..=255)) = (b[i], value) {
                out.push(v as u8);
                i += 4;
            } else {
                out.push(b[i]);
                i += 1;
            }
        }
        String::from_utf8_lossy(&out).into_owned()
    }
    text.lines()
        .filter_map(|line| {
            let mut parts = line.split_whitespace();
            Some(Mount {
                device: unescape(parts.next()?),
                point: unescape(parts.next()?),
                fs: parts.next()?.to_string(),
            })
        })
        .collect()
}

/// Real storage among Linux mounts: one entry per device, skipping
/// pseudo file systems, snaps and boot partitions.
#[cfg_attr(not(any(test, target_os = "linux")), allow(dead_code))]
fn linux_mount_choice(mounts: &[Mount]) -> Vec<(&Mount, VolumeKind)> {
    const LOCAL: &[&str] = &[
        "ext2", "ext3", "ext4", "btrfs", "xfs", "zfs", "f2fs", "vfat", "exfat", "ntfs", "ntfs3",
        "fuseblk", "hfsplus", "jfs", "reiserfs", "bcachefs",
    ];
    const NETWORK: &[&str] = &["nfs", "nfs4", "cifs", "smb3", "smbfs", "fuse.sshfs", "9p"];
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for m in mounts {
        let network = NETWORK.contains(&m.fs.as_str());
        if !network && !LOCAL.contains(&m.fs.as_str()) {
            continue;
        }
        let p = m.point.as_str();
        if p.starts_with("/boot")
            || p.starts_with("/snap")
            || p.starts_with("/var/")
            || p.starts_with("/sys")
        {
            continue;
        }
        // btrfs subvolumes and bind mounts repeat the device.
        if !network && !seen.insert(m.device.clone()) {
            continue;
        }
        let kind = if network {
            VolumeKind::Network
        } else if p.starts_with("/media/") || p.starts_with("/run/media/") || p.starts_with("/mnt/")
        {
            VolumeKind::Removable
        } else {
            VolumeKind::Fixed
        };
        out.push((m, kind));
    }
    out
}

#[cfg(target_os = "linux")]
fn linux_volumes(mounts: &[Mount]) -> Vec<Volume> {
    linux_mount_choice(mounts)
        .into_iter()
        .filter_map(|(m, kind)| {
            let path = PathBuf::from(&m.point);
            let usage = disk_usage(&path)?;
            let label = if m.point == "/" {
                "System".to_string()
            } else {
                path.file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_else(|| m.point.clone())
            };
            Some(Volume {
                path,
                label,
                kind,
                usage,
            })
        })
        .collect()
}

#[cfg(target_os = "macos")]
fn mac_volumes() -> Vec<Volume> {
    let mut out = Vec::new();
    if let Some(usage) = disk_usage(Path::new("/")) {
        out.push(Volume {
            path: PathBuf::from("/"),
            label: "Macintosh HD".into(),
            kind: VolumeKind::Fixed,
            usage,
        });
    }
    if let Ok(entries) = std::fs::read_dir("/Volumes") {
        for entry in entries.flatten() {
            let path = entry.path();
            // The boot volume appears here as a link to "/".
            if std::fs::canonicalize(&path).is_ok_and(|p| p == Path::new("/")) {
                continue;
            }
            let Some(usage) = disk_usage(&path) else {
                continue;
            };
            out.push(Volume {
                label: entry.file_name().to_string_lossy().into_owned(),
                path,
                kind: VolumeKind::Removable,
                usage,
            });
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_volume_of_the_temp_folder_has_a_size() {
        let usage = disk_usage(&std::env::temp_dir()).expect("temp dir is on a volume");
        assert!(usage.total > 0 && usage.free <= usage.total);
        assert_eq!(usage.used(), usage.total - usage.free);
    }

    #[cfg(any(windows, target_os = "linux", target_os = "macos"))]
    #[test]
    fn desktop_systems_list_at_least_one_volume() {
        let list = list();
        assert!(!list.is_empty());
        assert!(list
            .iter()
            .all(|v| v.usage.total > 0 && !v.label.is_empty()));
    }

    #[test]
    fn linux_mounts_are_filtered_to_real_storage() {
        let text = "\
sysfs /sys sysfs rw 0 0
proc /proc proc rw 0 0
/dev/nvme0n1p2 / ext4 rw 0 0
/dev/nvme0n1p1 /boot/efi vfat rw 0 0
/dev/nvme0n1p3 /home btrfs rw 0 0
/dev/nvme0n1p3 /home/me/.snapshots btrfs rw 0 0
tmpfs /run tmpfs rw 0 0
/dev/loop3 /snap/core/1 squashfs ro 0 0
/dev/sdb1 /media/me/My\\040USB exfat rw 0 0
//nas/share /mnt/nas cifs rw 0 0
";
        let mounts = parse_mounts(text);
        let chosen: Vec<(&str, VolumeKind)> = linux_mount_choice(&mounts)
            .into_iter()
            .map(|(m, k)| (m.point.as_str(), k))
            .collect();
        assert_eq!(
            chosen,
            vec![
                ("/", VolumeKind::Fixed),
                ("/home", VolumeKind::Fixed),
                ("/media/me/My USB", VolumeKind::Removable),
                ("/mnt/nas", VolumeKind::Network),
            ]
        );
    }
}
