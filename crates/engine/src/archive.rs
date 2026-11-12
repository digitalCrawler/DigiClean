//! Compresses files and folders into a `.zip` archive for keeping rarely
//! used data in less space.
//!
//! The archive is written under a temporary name, read back entry by entry
//! (which checks every CRC) and compared with what was written before it
//! gets its final name. Originals are never touched here: the caller decides
//! what to do with them once the user has seen the actual saving.

use std::fs::{self, File};
use std::io::{self, BufWriter, Read, Write};
use std::path::{Path, PathBuf};

use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, DateTime, ZipArchive, ZipWriter};

use crate::control::ScanControl;
use crate::error::{EngineError, Result};
use crate::paths;
use crate::walker::system_time_ns;

#[derive(Clone, Debug)]
pub struct ArchiveReport {
    pub archive: PathBuf,
    pub files: u64,
    pub folders: u64,
    /// Total size of the files that went in.
    pub original_bytes: u64,
    pub archive_bytes: u64,
}

impl ArchiveReport {
    /// Space the archive saves compared with the originals.
    pub fn saved_bytes(&self) -> u64 {
        self.original_bytes.saturating_sub(self.archive_bytes)
    }
}

/// Formats that are already compressed: stored as-is, which is as small and
/// much faster than deflating them again.
const COMPRESSED: &[&str] = &[
    "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif", "mp4", "m4v", "mov", "mkv", "avi",
    "webm", "mp3", "m4a", "aac", "ogg", "opus", "flac", "zip", "7z", "rar", "gz", "bz2", "xz",
    "zst", "docx", "xlsx", "pptx", "odt", "epub", "apk", "jar", "dmg", "iso",
];

enum Entry {
    Dir(String),
    File {
        name: String,
        path: PathBuf,
        size: u64,
    },
}

/// Lists what goes into the archive: each source under its own name.
/// Links are refused: they cannot be restored faithfully from a zip.
fn collect(sources: &[PathBuf], control: &ScanControl) -> Result<Vec<Entry>> {
    fn walk(path: &Path, name: String, out: &mut Vec<Entry>, control: &ScanControl) -> Result<()> {
        control.checkpoint()?;
        let meta = fs::symlink_metadata(path).map_err(|e| EngineError::io(path, e))?;
        if meta.file_type().is_symlink() {
            return Err(EngineError::Other(format!(
                "{} is a link; links cannot be archived",
                path.display()
            )));
        }
        if meta.is_dir() {
            out.push(Entry::Dir(format!("{name}/")));
            let mut children: Vec<_> = fs::read_dir(path)
                .map_err(|e| EngineError::io(path, e))?
                .collect::<io::Result<Vec<_>>>()
                .map_err(|e| EngineError::io(path, e))?;
            children.sort_by_key(|c| c.file_name());
            for child in children {
                let child_name = format!("{name}/{}", child.file_name().to_string_lossy());
                walk(&child.path(), child_name, out, control)?;
            }
        } else if meta.is_file() {
            out.push(Entry::File {
                name,
                path: path.to_path_buf(),
                size: meta.len(),
            });
        }
        Ok(())
    }
    let mut out = Vec::new();
    for source in sources {
        let name = source
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .ok_or_else(|| {
                EngineError::InvalidConfig(format!("cannot archive {}", source.display()))
            })?;
        walk(source, name, &mut out, control)?;
    }
    Ok(out)
}

/// ZIP stores local date and time without a zone; UTC is used.
fn zip_time(path: &Path) -> DateTime {
    let ns = fs::metadata(path)
        .and_then(|m| m.modified())
        .map(system_time_ns)
        .unwrap_or(0);
    let secs = ns.div_euclid(1_000_000_000);
    let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    // Civil date from days since 1970 (H. Hinnant).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u8;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u8;
    let year = (yoe + era * 400 + i64::from(month <= 2)).clamp(1980, 2107) as u16;
    DateTime::from_date_and_time(
        year,
        month,
        day,
        (rem / 3600) as u8,
        (rem % 3600 / 60) as u8,
        (rem % 60) as u8,
    )
    .unwrap_or_default()
}

/// Creates `dest` (made unique if it exists) from `sources`, verifies it
/// and returns its size. `progress(done, total)` reports bytes read.
pub fn create_zip(
    sources: &[PathBuf],
    dest: &Path,
    control: &ScanControl,
    progress: &dyn Fn(u64, u64),
) -> Result<ArchiveReport> {
    if sources.is_empty() {
        return Err(EngineError::InvalidConfig("nothing to archive".into()));
    }
    for s in sources {
        if paths::starts_with(dest, s) {
            return Err(EngineError::InvalidConfig(
                "the archive cannot be saved inside what it archives".into(),
            ));
        }
    }
    let entries = collect(sources, control)?;
    let total: u64 = entries
        .iter()
        .map(|e| match e {
            Entry::File { size, .. } => *size,
            Entry::Dir(_) => 0,
        })
        .sum();
    let dest = paths::unique_destination(dest);
    let mut tmp_name = dest.file_name().unwrap_or_default().to_os_string();
    tmp_name.push(".part");
    let tmp = dest.with_file_name(tmp_name);

    let result = write_and_verify(&entries, &tmp, total, control, progress);
    if let Err(e) = result {
        let _ = fs::remove_file(&tmp);
        return Err(e);
    }
    fs::rename(&tmp, &dest).map_err(|e| {
        let _ = fs::remove_file(&tmp);
        EngineError::io(&dest, e)
    })?;
    let archive_bytes = fs::metadata(&dest).map(|m| m.len()).unwrap_or(0);
    Ok(ArchiveReport {
        archive: dest,
        files: entries
            .iter()
            .filter(|e| matches!(e, Entry::File { .. }))
            .count() as u64,
        folders: entries
            .iter()
            .filter(|e| matches!(e, Entry::Dir(_)))
            .count() as u64,
        original_bytes: total,
        archive_bytes,
    })
}

fn write_and_verify(
    entries: &[Entry],
    tmp: &Path,
    total: u64,
    control: &ScanControl,
    progress: &dyn Fn(u64, u64),
) -> Result<()> {
    let file = File::create(tmp).map_err(|e| EngineError::io(tmp, e))?;
    let mut zip = ZipWriter::new(BufWriter::with_capacity(1 << 20, file));
    let zip_err = |e: zip::result::ZipError| EngineError::Other(format!("archive: {e}"));
    let mut done = 0u64;
    let mut buf = vec![0u8; 1 << 20];
    for entry in entries {
        control.checkpoint()?;
        match entry {
            Entry::Dir(name) => {
                zip.add_directory(name.as_str(), SimpleFileOptions::default())
                    .map_err(zip_err)?;
            }
            Entry::File { name, path, size } => {
                let stored = paths::extension_lower(path.as_os_str())
                    .is_some_and(|e| COMPRESSED.contains(&e.as_str()));
                let options = SimpleFileOptions::default()
                    .compression_method(if stored {
                        CompressionMethod::Stored
                    } else {
                        CompressionMethod::Deflated
                    })
                    .last_modified_time(zip_time(path))
                    .large_file(*size >= u32::MAX as u64);
                zip.start_file(name.as_str(), options).map_err(zip_err)?;
                let mut src = File::open(path).map_err(|e| EngineError::io(path, e))?;
                loop {
                    control.checkpoint()?;
                    let n = src.read(&mut buf).map_err(|e| EngineError::io(path, e))?;
                    if n == 0 {
                        break;
                    }
                    zip.write_all(&buf[..n])
                        .map_err(|e| EngineError::io(tmp, e))?;
                    done += n as u64;
                    progress(done, total);
                }
            }
        }
    }
    let mut writer = zip.finish().map_err(zip_err)?;
    writer.flush().map_err(|e| EngineError::io(tmp, e))?;
    writer
        .into_inner()
        .map_err(|e| EngineError::io(tmp, e.into_error()))?
        .sync_all()
        .map_err(|e| EngineError::io(tmp, e))?;

    // Read everything back: names, sizes, and every CRC.
    let file = File::open(tmp).map_err(|e| EngineError::io(tmp, e))?;
    let mut archive = ZipArchive::new(file).map_err(zip_err)?;
    if archive.len() != entries.len() {
        return Err(EngineError::Other(
            "archive check failed: entries missing".into(),
        ));
    }
    for (i, entry) in entries.iter().enumerate() {
        control.checkpoint()?;
        let mut stored = archive.by_index(i).map_err(zip_err)?;
        let (name, size) = match entry {
            Entry::Dir(name) => (name.as_str(), 0),
            Entry::File { name, size, .. } => (name.as_str(), *size),
        };
        let read = io::copy(&mut stored, &mut io::sink())
            .map_err(|e| EngineError::Other(format!("archive check failed for {name}: {e}")))?;
        if stored.name() != name || read != size {
            return Err(EngineError::Other(format!(
                "archive check failed for {name}"
            )));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn folders_round_trip_and_text_compresses() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("Project notes");
        fs::create_dir_all(src.join("drafts/empty")).unwrap();
        let text = "All work and no play makes Jack a dull boy.\n".repeat(5000);
        fs::write(src.join("notes.txt"), &text).unwrap();
        fs::write(src.join("drafts/photo.jpg"), [7u8; 3000]).unwrap();
        let loose = dir.path().join("readme.md");
        fs::write(&loose, "# Hello").unwrap();

        let report = create_zip(
            &[src.clone(), loose.clone()],
            &dir.path().join("archive.zip"),
            &ScanControl::new(),
            &|_, _| {},
        )
        .unwrap();
        assert_eq!(report.files, 3);
        assert_eq!(report.folders, 3);
        assert_eq!(report.original_bytes, text.len() as u64 + 3000 + 7);
        assert!(
            report.archive_bytes < report.original_bytes / 4,
            "{report:?}"
        );
        assert!(report.saved_bytes() > 0);
        assert!(!dir.path().join("archive.zip.part").exists());

        let mut zip = ZipArchive::new(File::open(&report.archive).unwrap()).unwrap();
        let mut out = String::new();
        zip.by_name("Project notes/notes.txt")
            .unwrap()
            .read_to_string(&mut out)
            .unwrap();
        assert_eq!(out, text);
        assert!(zip.by_name("Project notes/drafts/empty/").unwrap().is_dir());
        assert_eq!(
            zip.by_name("Project notes/drafts/photo.jpg")
                .unwrap()
                .compression(),
            CompressionMethod::Stored
        );
        // Originals are untouched.
        assert!(src.join("notes.txt").exists() && loose.exists());

        // A second archive with the same name does not overwrite the first.
        let again = create_zip(
            std::slice::from_ref(&loose),
            &dir.path().join("archive.zip"),
            &ScanControl::new(),
            &|_, _| {},
        )
        .unwrap();
        assert_ne!(again.archive, report.archive);
    }

    #[test]
    fn an_archive_cannot_go_inside_its_source() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("a.txt"), "a").unwrap();
        let err = create_zip(
            &[dir.path().to_path_buf()],
            &dir.path().join("self.zip"),
            &ScanControl::new(),
            &|_, _| {},
        );
        assert!(err.is_err());
        assert!(!dir.path().join("self.zip").exists());
    }
}
