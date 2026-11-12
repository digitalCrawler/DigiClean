//! Similar songs and videos: the soundtrack is decoded (Symphonia) and
//! fingerprinted (Chromaprint algorithm), so re-encoded copies — another
//! bitrate, format or container — are found. Videos are matched through
//! their audio track; videos without sound are not compared.
//!
//! Only the first [`MAX_SECONDS`] are decoded. Two items are similar when
//! their durations agree and the fingerprints match at some small offset
//! (leading silence, trimmed intros).

use std::collections::HashMap;
use std::fs::File;
use std::path::{Path, PathBuf};

use rayon::prelude::*;
use rusty_chromaprint::{Configuration, Fingerprinter};
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::errors::Error as SymError;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

use crate::cache::HashCache;
use crate::control::ScanControl;

pub const AUDIO: &[&str] = &["mp3", "m4a", "aac", "flac", "ogg", "oga", "wav", "alac"];
pub const VIDEO: &[&str] = &["mp4", "m4v", "mov", "mkv", "webm"];

/// Audio decoded per file.
pub const MAX_SECONDS: u32 = 120;
/// Shortest audio worth comparing.
const MIN_SECONDS: f32 = 8.0;
/// Largest offset tried between two fingerprints.
const MAX_SHIFT_SECONDS: f32 = 6.0;
/// Fraction of equal fingerprint bits for "same recording". Re-encodes of
/// one recording typically agree on ~90%+ of bits, unrelated audio on ~50%.
pub const SIMILAR_BITS: f32 = 0.85;

#[derive(Clone, Debug, PartialEq)]
pub struct MediaFeatures {
    /// `None` when the container does not say and the file is longer than
    /// what was decoded.
    pub duration_ms: Option<u64>,
    pub fingerprint: Vec<u32>,
}

pub fn is_supported(ext: Option<&str>) -> bool {
    ext.is_some_and(|e| AUDIO.contains(&e) || VIDEO.contains(&e))
}

pub fn is_video(ext: Option<&str>) -> bool {
    ext.is_some_and(|e| VIDEO.contains(&e))
}

fn config() -> Configuration {
    Configuration::preset_test2()
}

fn items_per_second() -> f32 {
    1.0 / config().item_duration_in_seconds()
}

/// Decodes the start of the soundtrack and fingerprints it.
pub fn analyze_file(path: &Path) -> Result<MediaFeatures, String> {
    let file = File::open(path).map_err(|e| e.to_string())?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = crate::paths::extension_lower(path.as_os_str()) {
        hint.with_extension(&ext);
    }
    let probed = symphonia::default::get_probe()
        .format(
            &hint,
            mss,
            &FormatOptions::default(),
            &MetadataOptions::default(),
        )
        .map_err(|e| e.to_string())?;
    let mut format = probed.format;
    let track = format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != CODEC_TYPE_NULL && t.codec_params.sample_rate.is_some())
        .ok_or("no soundtrack")?;
    let track_id = track.id;
    let declared_ms = match (track.codec_params.n_frames, track.codec_params.sample_rate) {
        (Some(frames), Some(rate)) if rate > 0 => Some(frames * 1000 / u64::from(rate)),
        _ => None,
    };
    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|e| e.to_string())?;

    let cfg = config();
    let mut printer = Fingerprinter::new(&cfg);
    let mut started: Option<(u32, usize)> = None; // (rate, channels)
    let mut frames: u64 = 0;
    let mut reached_end = false;
    let mut buf: Option<SampleBuffer<i16>> = None;
    loop {
        let packet = match format.next_packet() {
            Ok(p) => p,
            Err(SymError::IoError(e)) if e.kind() == std::io::ErrorKind::UnexpectedEof => {
                reached_end = true;
                break;
            }
            Err(SymError::ResetRequired) => break,
            Err(e) => return Err(e.to_string()),
        };
        if packet.track_id() != track_id {
            continue;
        }
        let decoded = match decoder.decode(&packet) {
            Ok(d) => d,
            Err(SymError::DecodeError(_)) => continue, // damaged frame
            Err(e) => return Err(e.to_string()),
        };
        let spec = *decoded.spec();
        let channels = spec.channels.count().max(1);
        let (rate, ch) = match started {
            Some(s) => s,
            None => {
                printer
                    .start(spec.rate, channels as u32)
                    .map_err(|e| format!("{e:?}"))?;
                started = Some((spec.rate, channels));
                (spec.rate, channels)
            }
        };
        if ch != channels {
            break; // channel layout changed mid-stream; what we have is enough
        }
        let needed = decoded.capacity() as u64;
        let sb = match &mut buf {
            Some(b) if b.capacity() as u64 >= needed * channels as u64 => b,
            _ => buf.insert(SampleBuffer::<i16>::new(needed, spec)),
        };
        sb.copy_interleaved_ref(decoded);
        printer.consume(sb.samples());
        frames += (sb.samples().len() / channels) as u64;
        if frames >= u64::from(rate) * u64::from(MAX_SECONDS) {
            break;
        }
    }
    let (rate, _) = started.ok_or("no audio decoded")?;
    printer.finish();
    let seconds = frames as f32 / rate as f32;
    if seconds < MIN_SECONDS {
        return Err("too short to compare".into());
    }
    let duration_ms = declared_ms.or(reached_end.then_some(frames * 1000 / u64::from(rate)));
    Ok(MediaFeatures {
        duration_ms,
        fingerprint: printer.fingerprint().to_vec(),
    })
}

/// Fraction of equal bits at the best alignment of two fingerprints, over
/// at least 80% of the shorter one. 0 when they cannot be compared.
pub fn similarity(a: &[u32], b: &[u32]) -> f32 {
    let rate = items_per_second();
    let min_items = (MIN_SECONDS * rate) as usize;
    let shorter = a.len().min(b.len());
    if shorter < min_items {
        return 0.0;
    }
    let min_overlap = (shorter * 8 / 10).max(min_items);
    let max_shift = (MAX_SHIFT_SECONDS * rate) as isize;
    let mut best = 0f32;
    for shift in -max_shift..=max_shift {
        let (ai, bi) = if shift >= 0 {
            (shift as usize, 0)
        } else {
            (0, (-shift) as usize)
        };
        if ai >= a.len() || bi >= b.len() {
            continue;
        }
        let n = (a.len() - ai).min(b.len() - bi);
        if n < min_overlap {
            continue;
        }
        let diff: u32 = a[ai..ai + n]
            .iter()
            .zip(&b[bi..bi + n])
            .map(|(x, y)| (x ^ y).count_ones())
            .sum();
        best = best.max(1.0 - diff as f32 / (32 * n) as f32);
    }
    best
}

/// Durations agree when both are known and within 2 s or 3%.
fn durations_match(a: Option<u64>, b: Option<u64>) -> bool {
    match (a, b) {
        (Some(a), Some(b)) => a.abs_diff(b) <= 2_000.max(a.max(b) * 3 / 100),
        _ => true,
    }
}

pub fn similar(a: &MediaFeatures, b: &MediaFeatures) -> bool {
    durations_match(a.duration_ms, b.duration_ms)
        && similarity(&a.fingerprint, &b.fingerprint) >= SIMILAR_BITS
}

/// Groups similar items (leader clustering, so groups never chain).
/// Returns groups of two or more, members in input order.
pub fn group_similar(items: &[(u32, MediaFeatures)]) -> Vec<Vec<u32>> {
    let mut groups: Vec<Vec<u32>> = Vec::new();
    let mut leaders: Vec<&MediaFeatures> = Vec::new();
    for (id, f) in items {
        match (0..leaders.len()).find(|&g| similar(leaders[g], f)) {
            Some(g) => groups[g].push(*id),
            None => {
                leaders.push(f);
                groups.push(vec![*id]);
            }
        }
    }
    groups.retain(|g| g.len() > 1);
    groups
}

/// Analyses `items` (id, path, size, mtime) in parallel, using and filling
/// `cache`. Returns the features and how many files could not be compared.
pub fn analyze_many(
    items: &[(u32, PathBuf, u64, i64)],
    cache: Option<&HashCache>,
    control: &ScanControl,
    pool: &rayon::ThreadPool,
    tick: &(dyn Fn() + Sync),
) -> crate::Result<(Vec<(u32, MediaFeatures)>, u64)> {
    let keys: Vec<(PathBuf, u64, i64)> = items
        .iter()
        .map(|(_, p, s, m)| (p.clone(), *s, *m))
        .collect();
    let cached = cache
        .map(|c| c.lookup_media(&keys))
        .unwrap_or_else(|| vec![None; items.len()]);
    let results: Vec<Option<(MediaFeatures, bool)>> = pool.install(|| {
        items
            .par_iter()
            .zip(cached.into_par_iter())
            .map(|((_, path, _, _), hit)| {
                if control.checkpoint().is_err() {
                    return None;
                }
                let out = match hit {
                    Some(f) => Some((f, false)),
                    None => analyze_file(path).ok().map(|f| (f, true)),
                };
                tick();
                out
            })
            .collect()
    });
    control.checkpoint()?;
    let mut fresh = Vec::new();
    let mut out = Vec::with_capacity(items.len());
    let mut failed = 0;
    for ((id, path, size, mtime), r) in items.iter().zip(results) {
        match r {
            Some((f, new)) => {
                if new {
                    fresh.push((path.clone(), *size, *mtime, f.clone()));
                }
                out.push((*id, f));
            }
            None => failed += 1,
        }
    }
    if let Some(cache) = cache {
        if let Err(e) = cache.store_media(&fresh) {
            log::warn!("media cache not updated: {e}");
        }
    }
    Ok((out, failed))
}

/// Writes a 16-bit PCM WAV (for tests and examples).
pub fn write_wav(path: &Path, rate: u32, samples: &[i16]) -> std::io::Result<()> {
    use std::io::Write;
    let data_len = (samples.len() * 2) as u32;
    let mut f = std::io::BufWriter::new(File::create(path)?);
    f.write_all(b"RIFF")?;
    f.write_all(&(36 + data_len).to_le_bytes())?;
    f.write_all(b"WAVEfmt ")?;
    f.write_all(&16u32.to_le_bytes())?;
    f.write_all(&1u16.to_le_bytes())?; // PCM
    f.write_all(&1u16.to_le_bytes())?; // mono
    f.write_all(&rate.to_le_bytes())?;
    f.write_all(&(rate * 2).to_le_bytes())?;
    f.write_all(&2u16.to_le_bytes())?;
    f.write_all(&16u16.to_le_bytes())?;
    f.write_all(b"data")?;
    f.write_all(&data_len.to_le_bytes())?;
    for s in samples {
        f.write_all(&s.to_le_bytes())?;
    }
    f.flush()
}

/// A synthetic "song": a melody of notes with harmonics, `seconds` long.
pub fn synth_song(seed: u64, rate: u32, seconds: f32, gain: f32) -> Vec<i16> {
    let mut x = seed
        .wrapping_mul(6364136223846793005)
        .wrapping_add(1442695040888963407);
    let mut next = || {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        x
    };
    let notes: Vec<f32> = (0..((seconds * 4.0) as usize + 1))
        .map(|_| 220.0 * 2f32.powf((next() % 24) as f32 / 12.0))
        .collect();
    let n = (seconds * rate as f32) as usize;
    let mut out = Vec::with_capacity(n);
    let mut phase = [0f32; 3];
    for i in 0..n {
        let t = i as f32 / rate as f32;
        let f = notes[(t * 4.0) as usize];
        let mut v = 0.0;
        for (h, p) in phase.iter_mut().enumerate() {
            *p = (*p + 2.0 * std::f32::consts::PI * f * (h + 1) as f32 / rate as f32)
                % (2.0 * std::f32::consts::PI);
            v += p.sin() / (h + 1) as f32;
        }
        out.push((v * 9000.0 * gain) as i16);
    }
    out
}

/// Per-file durations for display.
pub type Durations = HashMap<u32, Option<u64>>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn re_encoded_copies_match_other_songs_do_not() {
        let dir = tempfile::tempdir().unwrap();
        let a = dir.path().join("song.wav");
        let a_low = dir.path().join("song (22 kHz, quieter).wav");
        let b = dir.path().join("other.wav");
        write_wav(&a, 44_100, &synth_song(1, 44_100, 30.0, 1.0)).unwrap();
        write_wav(&a_low, 22_050, &synth_song(1, 22_050, 30.0, 0.6)).unwrap();
        write_wav(&b, 44_100, &synth_song(2, 44_100, 30.0, 1.0)).unwrap();
        let fa = analyze_file(&a).unwrap();
        let fl = analyze_file(&a_low).unwrap();
        let fb = analyze_file(&b).unwrap();
        assert_eq!(fa.duration_ms, Some(30_000));
        let same = similarity(&fa.fingerprint, &fl.fingerprint);
        let other = similarity(&fa.fingerprint, &fb.fingerprint);
        assert!(same >= SIMILAR_BITS, "same recording: {same}");
        assert!(other < SIMILAR_BITS, "different songs: {other}");
        assert_eq!(
            group_similar(&[(1, fa), (2, fb), (3, fl)]),
            vec![vec![1, 3]]
        );
    }

    #[test]
    fn short_or_silent_files_are_not_compared() {
        let dir = tempfile::tempdir().unwrap();
        let short = dir.path().join("beep.wav");
        write_wav(&short, 44_100, &synth_song(3, 44_100, 3.0, 1.0)).unwrap();
        assert!(analyze_file(&short).is_err());
        assert!(analyze_file(&dir.path().join("missing.mp3")).is_err());
        assert!(durations_match(Some(180_000), Some(181_500)));
        assert!(!durations_match(Some(180_000), Some(200_000)));
    }
}
