//! Previews for the results screen. Every function here runs on a bridge
//! worker thread (never the UI thread) and is cheap or time-bounded.

use anyhow::{anyhow, Result};
use digiclean_engine as engine;

/// Pixels of a system thumbnail: top-down rows, 4 bytes per pixel (B, G, R, A).
pub struct ThumbnailDto {
    pub width: u32,
    pub height: u32,
    pub bgra: Vec<u8>,
}

pub struct AudioPreviewDto {
    pub duration_ms: Option<i64>,
    pub sample_rate: Option<u32>,
    pub channels: Option<u32>,
    pub codec: Option<String>,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    /// Loudness per bar, 0–255. Empty when no waveform was requested.
    pub peaks: Vec<u8>,
    /// How much of the recording the waveform covers.
    pub decoded_ms: i64,
}

pub struct ArchiveEntryDto {
    pub name: String,
    pub size: i64,
    pub is_dir: bool,
}

pub struct ArchiveListingDto {
    pub entries: Vec<ArchiveEntryDto>,
    pub total_entries: i64,
    pub total_bytes: i64,
}

/// The operating system's thumbnail (what the file manager shows): video
/// frames, PDF and document pages, RAW photos… `None` when there is none.
pub fn system_thumbnail(path: String, size: u32) -> Option<ThumbnailDto> {
    engine::preview::system_thumbnail(std::path::Path::new(&path), size).map(|t| ThumbnailDto {
        width: t.width,
        height: t.height,
        bgra: t.bgra,
    })
}

/// Whether [`system_thumbnail`] can return anything on this platform.
#[flutter_rust_bridge::frb(sync)]
pub fn system_thumbnails_supported() -> bool {
    cfg!(windows)
}

/// Duration and tags of a song or video soundtrack, plus a waveform of
/// `bars` bars when `waveform` is set (decoded within a short time budget).
pub fn audio_preview(path: String, bars: u32, waveform: bool) -> Result<AudioPreviewDto> {
    let p = engine::preview::audio_preview(std::path::Path::new(&path), bars as usize, waveform)
        .map_err(|e| anyhow!(e))?;
    Ok(AudioPreviewDto {
        duration_ms: p.duration_ms.map(|v| v as i64),
        sample_rate: p.sample_rate,
        channels: p.channels,
        codec: p.codec,
        title: p.title,
        artist: p.artist,
        album: p.album,
        peaks: p.peaks,
        decoded_ms: p.decoded_ms as i64,
    })
}

/// The first `limit` entries of a zip archive, with totals.
pub fn archive_listing(path: String, limit: u32) -> Result<ArchiveListingDto> {
    let l = engine::preview::zip_listing(std::path::Path::new(&path), limit as usize)
        .map_err(|e| anyhow!(e))?;
    Ok(ArchiveListingDto {
        entries: l
            .entries
            .into_iter()
            .map(|e| ArchiveEntryDto {
                name: e.name,
                size: e.size as i64,
                is_dir: e.is_dir,
            })
            .collect(),
        total_entries: l.total_entries as i64,
        total_bytes: l.total_bytes as i64,
    })
}
