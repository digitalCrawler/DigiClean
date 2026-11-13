//! Previews for the results screen, built to stay cheap:
//!
//! * [`system_thumbnail`]: the operating system's own thumbnail (what the
//!   file manager shows), so videos, PDFs, office documents and camera RAW
//!   files get a picture without bundling decoders. Windows only for now;
//!   other systems return `None` and the app shows its own preview.
//! * [`audio_preview`]: duration, tags and a waveform, decoded with a time
//!   budget so long recordings never stall the interface.
//! * [`zip_listing`]: the contents of a zip archive, read from its central
//!   directory without decompressing anything.

use std::fs::File;
use std::path::Path;
use std::time::{Duration, Instant};

use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::errors::Error as SymError;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::{MetadataOptions, MetadataRevision, StandardTagKey};
use symphonia::core::probe::Hint;

/// Pixels of a thumbnail, top-down, 4 bytes per pixel in B, G, R, A order.
#[derive(Debug, Clone)]
pub struct Thumbnail {
    pub width: u32,
    pub height: u32,
    pub bgra: Vec<u8>,
}

#[derive(Debug, Clone, Default)]
pub struct AudioPreview {
    pub duration_ms: Option<u64>,
    pub sample_rate: Option<u32>,
    pub channels: Option<u32>,
    pub codec: Option<String>,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    /// Loudness per bin, 0–255 (relative to the loudest moment). Empty when
    /// decoding was not requested or failed.
    pub peaks: Vec<u8>,
    /// How much of the recording the waveform covers.
    pub decoded_ms: u64,
}

#[derive(Debug, Clone)]
pub struct ArchiveEntry {
    pub name: String,
    pub size: u64,
    pub is_dir: bool,
}

#[derive(Debug, Clone, Default)]
pub struct ArchiveListing {
    pub entries: Vec<ArchiveEntry>,
    pub total_entries: u64,
    /// Uncompressed size of everything inside.
    pub total_bytes: u64,
}

/// Longest stretch decoded for a waveform.
const MAX_WAVEFORM_SECONDS: u64 = 15 * 60;
/// Wall-clock budget for decoding a waveform.
const WAVEFORM_BUDGET: Duration = Duration::from_millis(1500);
/// Peak resolution before downsampling to the requested bins.
const BLOCKS_PER_SECOND: u64 = 50;

/// Duration, tags and (when `decode`) a waveform of `bins` bars.
pub fn audio_preview(path: &Path, bins: usize, decode: bool) -> Result<AudioPreview, String> {
    let file = File::open(path).map_err(|e| e.to_string())?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = crate::paths::extension_lower(path.as_os_str()) {
        hint.with_extension(&ext);
    }
    let mut probed = symphonia::default::get_probe()
        .format(
            &hint,
            mss,
            &FormatOptions::default(),
            &MetadataOptions::default(),
        )
        .map_err(|e| e.to_string())?;

    let mut out = AudioPreview::default();
    // Tags outside the container (ID3v2 before an MP3), then the container's own.
    if let Some(rev) = probed
        .metadata
        .get()
        .as_ref()
        .and_then(|m| m.current().cloned())
    {
        read_tags(&rev, &mut out);
    }
    let mut format = probed.format;
    if let Some(rev) = format.metadata().current() {
        read_tags(rev, &mut out);
    }

    let track = format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != CODEC_TYPE_NULL && t.codec_params.sample_rate.is_some())
        .ok_or("no soundtrack")?;
    let params = track.codec_params.clone();
    let track_id = track.id;
    out.sample_rate = params.sample_rate;
    out.channels = params.channels.map(|c| c.count() as u32);
    out.codec = symphonia::default::get_codecs()
        .get_codec(params.codec)
        .map(|d| d.short_name.to_string());
    out.duration_ms = match (params.n_frames, params.sample_rate) {
        (Some(frames), Some(rate)) if rate > 0 => Some(frames * 1000 / u64::from(rate)),
        _ => None,
    };
    if !decode || bins == 0 {
        return Ok(out);
    }

    let mut decoder = symphonia::default::get_codecs()
        .make(&params, &DecoderOptions::default())
        .map_err(|e| e.to_string())?;
    let started = Instant::now();
    let mut blocks: Vec<f32> = Vec::new();
    let mut block_peak = 0f32;
    let mut in_block = 0u64;
    let mut frames = 0u64;
    let mut rate = 0u64;
    let mut buf: Option<SampleBuffer<f32>> = None;
    let mut reached_end = false;
    loop {
        if started.elapsed() > WAVEFORM_BUDGET {
            break;
        }
        let packet = match format.next_packet() {
            Ok(p) => p,
            Err(SymError::IoError(e)) if e.kind() == std::io::ErrorKind::UnexpectedEof => {
                reached_end = true;
                break;
            }
            Err(_) => break,
        };
        if packet.track_id() != track_id {
            continue;
        }
        let decoded = match decoder.decode(&packet) {
            Ok(d) => d,
            Err(SymError::DecodeError(_)) => continue,
            Err(_) => break,
        };
        let spec = *decoded.spec();
        let channels = spec.channels.count().max(1);
        rate = u64::from(spec.rate.max(1));
        let block_frames = (rate / BLOCKS_PER_SECOND).max(1);
        let needed = decoded.capacity() as u64;
        let sb = match &mut buf {
            Some(b) if b.capacity() as u64 >= needed * channels as u64 => b,
            _ => buf.insert(SampleBuffer::<f32>::new(needed, spec)),
        };
        sb.copy_interleaved_ref(decoded);
        for frame in sb.samples().chunks(channels) {
            let peak = frame.iter().fold(0f32, |m, s| m.max(s.abs()));
            block_peak = block_peak.max(peak);
            in_block += 1;
            if in_block == block_frames {
                blocks.push(block_peak);
                block_peak = 0.0;
                in_block = 0;
            }
        }
        frames += (sb.samples().len() / channels) as u64;
        if frames >= rate * MAX_WAVEFORM_SECONDS {
            break;
        }
    }
    if in_block > 0 {
        blocks.push(block_peak);
    }
    if let Some(ms) = (frames * 1000).checked_div(rate) {
        out.decoded_ms = ms;
        if out.duration_ms.is_none() && reached_end {
            out.duration_ms = Some(ms);
        }
    }
    out.peaks = downsample(&blocks, bins);
    Ok(out)
}

fn read_tags(rev: &MetadataRevision, out: &mut AudioPreview) {
    for tag in rev.tags() {
        let slot = match tag.std_key {
            Some(StandardTagKey::TrackTitle) => &mut out.title,
            Some(StandardTagKey::Artist) => &mut out.artist,
            Some(StandardTagKey::Album) => &mut out.album,
            _ => continue,
        };
        let value = tag.value.to_string();
        if slot.is_none() && !value.trim().is_empty() {
            *slot = Some(value.trim().to_string());
        }
    }
}

/// Max-pools `blocks` into `bins` values scaled to 0–255 against the loudest.
fn downsample(blocks: &[f32], bins: usize) -> Vec<u8> {
    if blocks.is_empty() || bins == 0 {
        return Vec::new();
    }
    let loudest = blocks.iter().fold(0f32, |m, &b| m.max(b));
    if loudest <= f32::EPSILON {
        return vec![0; bins.min(blocks.len())];
    }
    let n = bins.min(blocks.len());
    (0..n)
        .map(|i| {
            let start = i * blocks.len() / n;
            let end = ((i + 1) * blocks.len() / n).max(start + 1);
            let peak = blocks[start..end].iter().fold(0f32, |m, &b| m.max(b));
            ((peak / loudest) * 255.0).round().clamp(0.0, 255.0) as u8
        })
        .collect()
}

/// The first `limit` entries of a zip archive plus totals.
pub fn zip_listing(path: &Path, limit: usize) -> Result<ArchiveListing, String> {
    let file = File::open(path).map_err(|e| e.to_string())?;
    let mut zip = zip::ZipArchive::new(file).map_err(|e| e.to_string())?;
    let mut out = ArchiveListing {
        total_entries: zip.len() as u64,
        ..Default::default()
    };
    for i in 0..zip.len() {
        let entry = zip.by_index_raw(i).map_err(|e| e.to_string())?;
        out.total_bytes += entry.size();
        if out.entries.len() < limit {
            out.entries.push(ArchiveEntry {
                name: entry.name().to_string(),
                size: entry.size(),
                is_dir: entry.is_dir(),
            });
        }
    }
    Ok(out)
}

/// The system's thumbnail for `path`, at least `size` pixels on its longer
/// side when the system can provide that. `None` when there is none (no
/// thumbnail handler for the type, unreadable file, unsupported system).
pub fn system_thumbnail(path: &Path, size: u32) -> Option<Thumbnail> {
    #[cfg(windows)]
    {
        windows_thumbnail::get(path, size)
    }
    #[cfg(not(windows))]
    {
        let _ = (path, size);
        None
    }
}

#[cfg(windows)]
mod windows_thumbnail {
    use std::ffi::c_void;
    use std::os::windows::ffi::OsStrExt;
    use std::path::Path;
    use std::ptr::{null, null_mut};

    use windows_sys::core::{GUID, HRESULT};
    use windows_sys::Win32::Foundation::SIZE;
    use windows_sys::Win32::Graphics::Gdi::{
        DeleteObject, GetDC, GetDIBits, GetObjectW, ReleaseDC, BITMAP, BITMAPINFO,
        BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS, HBITMAP,
    };
    use windows_sys::Win32::System::Com::{
        CoInitializeEx, CoUninitialize, COINIT_DISABLE_OLE1DDE, COINIT_MULTITHREADED,
    };
    use windows_sys::Win32::UI::Shell::{
        SHCreateItemFromParsingName, SIIGBF_BIGGERSIZEOK, SIIGBF_THUMBNAILONLY,
    };

    use super::Thumbnail;

    const IID_ISHELLITEMIMAGEFACTORY: GUID =
        GUID::from_u128(0xbcc18b79_ba16_442f_80c4_8a59c30c463b);

    /// IShellItemImageFactory: IUnknown plus GetImage.
    #[repr(C)]
    struct ImageFactoryVtbl {
        _query_interface:
            unsafe extern "system" fn(*mut c_void, *const GUID, *mut *mut c_void) -> HRESULT,
        _add_ref: unsafe extern "system" fn(*mut c_void) -> u32,
        release: unsafe extern "system" fn(*mut c_void) -> u32,
        get_image: unsafe extern "system" fn(*mut c_void, SIZE, i32, *mut HBITMAP) -> HRESULT,
    }

    /// Balances a successful CoInitializeEx on this thread.
    struct ComGuard(bool);
    impl Drop for ComGuard {
        fn drop(&mut self) {
            if self.0 {
                // SAFETY: paired with the successful CoInitializeEx below.
                unsafe { CoUninitialize() };
            }
        }
    }

    pub(super) fn get(path: &Path, size: u32) -> Option<Thumbnail> {
        let size = size.clamp(16, 1024) as i32;
        let wide: Vec<u16> = path
            .as_os_str()
            .encode_wide()
            .chain(std::iter::once(0))
            .collect();
        // SAFETY: standard COM usage; every pointer passed is valid for the
        // call, the factory is released and the bitmap deleted before return.
        unsafe {
            let hr = CoInitializeEx(
                null(),
                (COINIT_MULTITHREADED | COINIT_DISABLE_OLE1DDE) as u32,
            );
            // S_OK / S_FALSE need balancing; RPC_E_CHANGED_MODE means the
            // thread already chose another apartment, which works too.
            let _com = ComGuard(hr >= 0);

            let mut factory: *mut c_void = null_mut();
            if SHCreateItemFromParsingName(
                wide.as_ptr(),
                null_mut(),
                &IID_ISHELLITEMIMAGEFACTORY,
                &mut factory,
            ) < 0
                || factory.is_null()
            {
                return None;
            }
            let vtbl = *(factory as *const *const ImageFactoryVtbl);
            let mut bitmap: HBITMAP = null_mut();
            let hr = ((*vtbl).get_image)(
                factory,
                SIZE { cx: size, cy: size },
                SIIGBF_THUMBNAILONLY | SIIGBF_BIGGERSIZEOK,
                &mut bitmap,
            );
            ((*vtbl).release)(factory);
            if hr < 0 || bitmap.is_null() {
                return None;
            }
            let pixels = read_bitmap(bitmap);
            DeleteObject(bitmap);
            pixels
        }
    }

    unsafe fn read_bitmap(bitmap: HBITMAP) -> Option<Thumbnail> {
        let mut bm: BITMAP = std::mem::zeroed();
        if GetObjectW(
            bitmap,
            std::mem::size_of::<BITMAP>() as i32,
            &mut bm as *mut BITMAP as *mut c_void,
        ) == 0
        {
            return None;
        }
        let (width, height) = (bm.bmWidth, bm.bmHeight.abs());
        if width <= 0 || height <= 0 || width > 4096 || height > 4096 {
            return None;
        }
        let mut info: BITMAPINFO = std::mem::zeroed();
        info.bmiHeader = BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: width,
            biHeight: -height, // top-down rows
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB,
            ..std::mem::zeroed()
        };
        let mut bgra = vec![0u8; width as usize * height as usize * 4];
        let dc = GetDC(null_mut());
        let lines = GetDIBits(
            dc,
            bitmap,
            0,
            height as u32,
            bgra.as_mut_ptr() as *mut c_void,
            &mut info,
            DIB_RGB_COLORS,
        );
        ReleaseDC(null_mut(), dc);
        if lines == 0 {
            return None;
        }
        // Many handlers leave alpha at 0 for opaque pictures.
        if bgra.chunks_exact(4).all(|p| p[3] == 0) {
            for p in bgra.chunks_exact_mut(4) {
                p[3] = 255;
            }
        }
        Some(Thumbnail {
            width: width as u32,
            height: height as u32,
            bgra,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn waveform_of_a_wav() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("tone.wav");
        let samples = crate::media::synth_song(7, 22_050, 4.0, 0.8);
        crate::media::write_wav(&path, 22_050, &samples).unwrap();

        let p = audio_preview(&path, 120, true).unwrap();
        assert_eq!(p.sample_rate, Some(22_050));
        assert_eq!(p.channels, Some(1));
        let ms = p.duration_ms.unwrap();
        assert!((3_900..=4_100).contains(&ms), "duration {ms}");
        assert_eq!(p.peaks.len(), 120);
        assert_eq!(
            *p.peaks.iter().max().unwrap(),
            255,
            "scaled to the loudest moment"
        );
        assert!(p.decoded_ms >= 3_900);

        let info = audio_preview(&path, 120, false).unwrap();
        assert!(info.peaks.is_empty(), "no waveform unless asked");
        assert_eq!(info.duration_ms, p.duration_ms);
    }

    #[test]
    fn not_audio_is_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("x.mp3");
        std::fs::write(&path, b"definitely not audio").unwrap();
        assert!(audio_preview(&path, 10, true).is_err());
    }

    #[test]
    fn downsample_pools_peaks() {
        assert_eq!(downsample(&[0.1, 0.5, 0.2, 1.0], 2), vec![128, 255]);
        assert_eq!(
            downsample(&[0.5, 0.5], 8),
            vec![255, 255],
            "never more bins than blocks"
        );
        assert!(downsample(&[], 4).is_empty());
    }

    #[test]
    fn lists_a_zip() {
        use std::io::Write;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a.zip");
        let mut w = zip::ZipWriter::new(File::create(&path).unwrap());
        let opts = zip::write::SimpleFileOptions::default();
        w.add_directory("docs/", opts).unwrap();
        w.start_file("docs/readme.txt", opts).unwrap();
        w.write_all(b"hello world").unwrap();
        w.start_file("photo.jpg", opts).unwrap();
        w.write_all(&[7u8; 1000]).unwrap();
        w.finish().unwrap();

        let l = zip_listing(&path, 2).unwrap();
        assert_eq!(l.total_entries, 3);
        assert_eq!(l.total_bytes, 1011);
        assert_eq!(l.entries.len(), 2, "limited");
        assert!(l.entries[0].is_dir);
        assert_eq!(l.entries[1].name, "docs/readme.txt");
        assert_eq!(l.entries[1].size, 11);
    }

    #[cfg(windows)]
    #[test]
    fn windows_thumbnail_of_a_png() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("red.png");
        image::RgbImage::from_pixel(64, 48, image::Rgb([220, 20, 10]))
            .save(&path)
            .unwrap();
        let t = system_thumbnail(&path, 32).expect("Windows makes PNG thumbnails");
        assert!(t.width > 0 && t.height > 0);
        assert_eq!(t.bgra.len(), (t.width * t.height * 4) as usize);
        let mid = ((t.height / 2 * t.width + t.width / 2) * 4) as usize;
        let (b, g, r, a) = (
            t.bgra[mid],
            t.bgra[mid + 1],
            t.bgra[mid + 2],
            t.bgra[mid + 3],
        );
        assert!(
            r > 180 && g < 70 && b < 70 && a == 255,
            "BGRA {b},{g},{r},{a}"
        );

        assert!(system_thumbnail(&dir.path().join("missing.png"), 32).is_none());
    }
}
