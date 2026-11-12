//! Photo analysis: perceptual fingerprints to find similar shots (resized,
//! re-saved, recompressed, burst sequences) and quality signals to pick the
//! best shot and to spot blurry, dark and screenshot images.
//!
//! Images are decoded small: JPEGs at 1/8 scale straight from the DCT data,
//! other formats fully and then reduced, so thousands of photos take seconds.
//! Fingerprints:
//! * dHash: 9×8 brightness gradients, robust to resizing and re-encoding;
//! * pHash: low frequencies of a 32×32 DCT, robust to small edits.
//!
//! Two photos are similar when both distances are small. Grouping uses
//! leader clustering over a BK-tree so chains of "almost similar" photos
//! never merge into one huge group.

use std::collections::HashMap;
use std::fs::File;
use std::io::BufReader;
use std::path::{Path, PathBuf};

use rayon::prelude::*;

use crate::cache::HashCache;
use crate::control::ScanControl;

/// Extensions analysed (HEIC/RAW need native codecs and are skipped).
pub const SUPPORTED: &[&str] = &["jpg", "jpeg", "jfif", "png", "webp", "gif", "bmp"];

/// Longest side of the working image.
const WORK: usize = 256;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhotoFeatures {
    pub dhash: u64,
    pub phash: u64,
    /// Size of the original image.
    pub width: u32,
    pub height: u32,
    /// Variance of the Laplacian at working size; higher is sharper.
    pub sharpness: f32,
    /// Mean luminance, 0–255.
    pub brightness: f32,
    /// Standard deviation of luminance; tiny for blank images.
    pub contrast: f32,
}

#[derive(
    Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, serde::Serialize, serde::Deserialize,
)]
#[serde(rename_all = "snake_case")]
pub enum PhotoIssue {
    Blurry,
    Dark,
    Screenshot,
}

/// Thresholds; deliberately conservative (false alarms cost user trust).
/// pHash (low frequencies) is the stable signal; dHash flips bits in smooth
/// areas such as skies when an image is resized, so it gets more room.
/// Unrelated photos differ by about 32 bits on each.
pub const SIMILAR_DHASH: u32 = 16;
pub const SIMILAR_PHASH: u32 = 12;
pub const SIMILAR_TOTAL: u32 = 20;
const BLURRY_BELOW: f32 = 20.0;
const DARK_BELOW: f32 = 35.0;
/// Images flatter than this have no meaningful fingerprint.
const FLAT_BELOW: f32 = 4.0;

pub fn is_supported(ext: Option<&str>) -> bool {
    ext.is_some_and(|e| SUPPORTED.contains(&e))
}

/// A grayscale image as f32 luminance.
struct Gray {
    w: usize,
    h: usize,
    px: Vec<f32>,
}

impl Gray {
    /// Area-average resize (deterministic, good enough for fingerprints).
    fn resize(&self, nw: usize, nh: usize) -> Gray {
        let mut px = vec![0f32; nw * nh];
        for y in 0..nh {
            let y0 = y * self.h / nh;
            let y1 = ((y + 1) * self.h / nh).max(y0 + 1).min(self.h);
            for x in 0..nw {
                let x0 = x * self.w / nw;
                let x1 = ((x + 1) * self.w / nw).max(x0 + 1).min(self.w);
                let mut sum = 0f32;
                for yy in y0..y1 {
                    let row = &self.px[yy * self.w..];
                    for v in &row[x0..x1] {
                        sum += v;
                    }
                }
                px[y * nw + x] = sum / ((y1 - y0) * (x1 - x0)) as f32;
            }
        }
        Gray { w: nw, h: nh, px }
    }

    /// Fits the longest side into [`WORK`] pixels.
    fn working(self) -> Gray {
        let longest = self.w.max(self.h);
        if longest <= WORK {
            return self;
        }
        let nw = (self.w * WORK / longest).max(1);
        let nh = (self.h * WORK / longest).max(1);
        self.resize(nw, nh)
    }
}

fn luma(r: u8, g: u8, b: u8) -> f32 {
    0.299 * r as f32 + 0.587 * g as f32 + 0.114 * b as f32
}

/// Decodes a photo small; returns the working image and original size.
fn decode(path: &Path) -> Result<(Gray, u32, u32), String> {
    let ext = crate::paths::extension_lower(path.as_os_str());
    if matches!(ext.as_deref(), Some("jpg" | "jpeg" | "jfif")) {
        let file = File::open(path).map_err(|e| e.to_string())?;
        let mut decoder = jpeg_decoder::Decoder::new(BufReader::new(file));
        decoder.read_info().map_err(|e| e.to_string())?;
        let info = decoder.info().ok_or("not a JPEG")?;
        let (w0, h0) = (u32::from(info.width), u32::from(info.height));
        // Decode at the smallest DCT scale still at least WORK pixels wide.
        let (w, h) = decoder
            .scale(WORK as u16, WORK as u16)
            .map_err(|e| e.to_string())?;
        let data = decoder.decode().map_err(|e| e.to_string())?;
        let (w, h) = (usize::from(w), usize::from(h));
        let px: Vec<f32> = match info.pixel_format {
            jpeg_decoder::PixelFormat::L8 => data.iter().map(|&v| v as f32).collect(),
            jpeg_decoder::PixelFormat::L16 => data
                .chunks_exact(2)
                .map(|c| u16::from_be_bytes([c[0], c[1]]) as f32 / 257.0)
                .collect(),
            jpeg_decoder::PixelFormat::RGB24 => data
                .chunks_exact(3)
                .map(|c| luma(c[0], c[1], c[2]))
                .collect(),
            jpeg_decoder::PixelFormat::CMYK32 => data
                .chunks_exact(4)
                .map(|c| {
                    let k = 255.0 - c[3] as f32;
                    let f = |v: u8| ((255.0 - v as f32) * k / 255.0) as u8;
                    luma(f(c[0]), f(c[1]), f(c[2]))
                })
                .collect(),
        };
        if px.len() != w * h {
            return Err("unexpected JPEG layout".into());
        }
        return Ok((Gray { w, h, px }.working(), w0, h0));
    }
    let img = image::ImageReader::open(path)
        .map_err(|e| e.to_string())?
        .with_guessed_format()
        .map_err(|e| e.to_string())?
        .decode()
        .map_err(|e| e.to_string())?;
    let (w0, h0) = (img.width(), img.height());
    let gray = img.to_luma8();
    let gray = Gray {
        w: gray.width() as usize,
        h: gray.height() as usize,
        px: gray.into_raw().into_iter().map(f32::from).collect(),
    };
    Ok((gray.working(), w0, h0))
}

fn dhash(g: &Gray) -> u64 {
    let s = g.resize(9, 8);
    let mut bits = 0u64;
    for y in 0..8 {
        for x in 0..8 {
            bits <<= 1;
            if s.px[y * 9 + x] < s.px[y * 9 + x + 1] {
                bits |= 1;
            }
        }
    }
    bits
}

fn phash(g: &Gray) -> u64 {
    const N: usize = 32;
    let s = g.resize(N, N);
    // Separable DCT-II, keeping only the 8×8 lowest frequencies.
    let cos: Vec<f32> = (0..8 * N)
        .map(|i| {
            let (u, x) = (i / N, i % N);
            ((std::f32::consts::PI / N as f32) * (x as f32 + 0.5) * u as f32).cos()
        })
        .collect();
    let mut rows = [[0f32; 8]; N]; // rows[y][u]
    for (y, row) in rows.iter_mut().enumerate() {
        for (u, out) in row.iter_mut().enumerate() {
            *out = (0..N).map(|x| s.px[y * N + x] * cos[u * N + x]).sum();
        }
    }
    let mut coeffs = [0f32; 64];
    for v in 0..8 {
        for u in 0..8 {
            coeffs[v * 8 + u] = (0..N).map(|y| rows[y][u] * cos[v * N + y]).sum();
        }
    }
    // Median of the AC terms (skip the overall brightness term).
    let mut ac: Vec<f32> = coeffs[1..].to_vec();
    ac.sort_by(|a, b| a.total_cmp(b));
    let median = ac[ac.len() / 2];
    coeffs
        .iter()
        .fold(0u64, |bits, &c| (bits << 1) | u64::from(c > median))
}

/// Variance of a 4-neighbour Laplacian.
fn sharpness(g: &Gray) -> f32 {
    if g.w < 3 || g.h < 3 {
        return 0.0;
    }
    let (mut sum, mut sum2, mut n) = (0f64, 0f64, 0f64);
    for y in 1..g.h - 1 {
        for x in 1..g.w - 1 {
            let c = g.px[y * g.w + x];
            let lap = g.px[(y - 1) * g.w + x]
                + g.px[(y + 1) * g.w + x]
                + g.px[y * g.w + x - 1]
                + g.px[y * g.w + x + 1]
                - 4.0 * c;
            sum += lap as f64;
            sum2 += (lap as f64) * (lap as f64);
            n += 1.0;
        }
    }
    let mean = sum / n;
    (sum2 / n - mean * mean) as f32
}

/// Fingerprints and quality signals of one image.
pub fn analyze_file(path: &Path) -> Result<PhotoFeatures, String> {
    let (g, width, height) = decode(path)?;
    let n = g.px.len() as f32;
    let mean = g.px.iter().sum::<f32>() / n;
    let var = g.px.iter().map(|v| (v - mean) * (v - mean)).sum::<f32>() / n;
    Ok(PhotoFeatures {
        dhash: dhash(&g),
        phash: phash(&g),
        width,
        height,
        sharpness: sharpness(&g),
        brightness: mean,
        contrast: var.sqrt(),
    })
}

/// Quality problems of a photo; `name` and `folder` find screenshots.
pub fn issues(f: &PhotoFeatures, name: &str, folder: &str) -> Vec<PhotoIssue> {
    let mut out = Vec::new();
    let lower = name.to_lowercase();
    let screenshot = lower.contains("screenshot")
        || lower.contains("screen shot")
        || lower.starts_with("scrnli")
        || folder.to_lowercase().contains("screenshot");
    if screenshot {
        out.push(PhotoIssue::Screenshot);
    } else {
        // Screenshots are often flat or dark by design; judge photos only.
        if f.brightness < DARK_BELOW {
            out.push(PhotoIssue::Dark);
        }
        if f.contrast >= FLAT_BELOW * 2.0 && f.sharpness < BLURRY_BELOW {
            out.push(PhotoIssue::Blurry);
        }
    }
    out
}

/// Analyses `items` (id, path, size, mtime), using and filling `cache`.
/// `tick` is called once per finished item. Unreadable images are left
/// out; their count is returned with the features.
pub fn analyze_many(
    items: &[(u32, PathBuf, u64, i64)],
    cache: Option<&HashCache>,
    control: &ScanControl,
    pool: &rayon::ThreadPool,
    tick: &(dyn Fn() + Sync),
) -> crate::Result<(Vec<(u32, PhotoFeatures)>, u64)> {
    let keys: Vec<(PathBuf, u64, i64)> = items
        .iter()
        .map(|(_, p, s, m)| (p.clone(), *s, *m))
        .collect();
    let cached = cache
        .map(|c| c.lookup_photos(&keys))
        .unwrap_or_else(|| vec![None; items.len()]);
    let results: Vec<Option<(PhotoFeatures, bool)>> = pool.install(|| {
        items
            .par_iter()
            .zip(cached.par_iter())
            .map(|((_, path, _, _), hit)| {
                if control.checkpoint().is_err() {
                    return None;
                }
                let out = match hit {
                    Some(f) => Some((*f, false)),
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
                    fresh.push((path.clone(), *size, *mtime, f));
                }
                out.push((*id, f));
            }
            None => failed += 1,
        }
    }
    if let Some(cache) = cache {
        if let Err(e) = cache.store_photos(&fresh) {
            log::warn!("photo cache not updated: {e}");
        }
    }
    Ok((out, failed))
}

pub fn distance(a: u64, b: u64) -> u32 {
    (a ^ b).count_ones()
}

/// Whether two photos look alike.
pub fn similar(a: &PhotoFeatures, b: &PhotoFeatures) -> bool {
    let (d, p) = (distance(a.dhash, b.dhash), distance(a.phash, b.phash));
    d <= SIMILAR_DHASH && p <= SIMILAR_PHASH && d + p <= SIMILAR_TOTAL
}

/// BK-tree over dHash values (metric: Hamming distance).
struct BkTree {
    nodes: Vec<(u64, usize, HashMap<u32, usize>)>, // (hash, payload, children)
}

impl BkTree {
    fn insert(&mut self, hash: u64, payload: usize) {
        if self.nodes.is_empty() {
            self.nodes.push((hash, payload, HashMap::new()));
            return;
        }
        let mut at = 0;
        loop {
            let d = distance(self.nodes[at].0, hash);
            match self.nodes[at].2.get(&d) {
                Some(&next) => at = next,
                None => {
                    let id = self.nodes.len();
                    self.nodes.push((hash, payload, HashMap::new()));
                    self.nodes[at].2.insert(d, id);
                    return;
                }
            }
        }
    }

    fn within(&self, hash: u64, max: u32, out: &mut Vec<usize>) {
        if self.nodes.is_empty() {
            return;
        }
        let mut stack = vec![0];
        while let Some(at) = stack.pop() {
            let (h, payload, children) = &self.nodes[at];
            let d = distance(*h, hash);
            if d <= max {
                out.push(*payload);
            }
            for (&cd, &child) in children {
                if cd + max >= d && cd <= d + max {
                    stack.push(child);
                }
            }
        }
    }
}

/// Groups similar photos. `items` should be in a stable order (e.g. by
/// path or date); each group's first member is its leader. Flat images are
/// left out. Returns groups of two or more.
pub fn group_similar(items: &[(u32, PhotoFeatures)]) -> Vec<Vec<u32>> {
    let mut groups: Vec<Vec<u32>> = Vec::new();
    let mut leaders: Vec<PhotoFeatures> = Vec::new();
    let mut tree = BkTree { nodes: Vec::new() };
    let mut candidates = Vec::new();
    for &(id, f) in items {
        if f.contrast < FLAT_BELOW {
            continue;
        }
        candidates.clear();
        tree.within(f.dhash, SIMILAR_DHASH, &mut candidates);
        let best = candidates
            .iter()
            .copied()
            .filter(|&g| similar(&leaders[g], &f))
            .min_by_key(|&g| {
                (
                    distance(leaders[g].dhash, f.dhash) + distance(leaders[g].phash, f.phash),
                    g,
                )
            });
        match best {
            Some(g) => groups[g].push(id),
            None => {
                tree.insert(f.dhash, groups.len());
                leaders.push(f);
                groups.push(vec![id]);
            }
        }
    }
    groups.retain(|g| g.len() > 1);
    groups
}

/// The photo worth keeping: sharpest and largest, then the bigger file.
/// `members` are (id, features, file size).
pub fn best_shot(members: &[(u32, PhotoFeatures, u64)]) -> Option<u32> {
    let max = |f: &dyn Fn(&(u32, PhotoFeatures, u64)) -> f64| {
        members.iter().map(f).fold(f64::MIN_POSITIVE, f64::max)
    };
    let max_sharp = max(&|m| m.1.sharpness as f64);
    let max_pixels = max(&|m| m.1.width as f64 * m.1.height as f64);
    let max_size = max(&|m| m.2 as f64);
    members
        .iter()
        .map(|m| {
            let score = 0.45 * (m.1.sharpness as f64 / max_sharp)
                + 0.35 * (m.1.width as f64 * m.1.height as f64 / max_pixels)
                + 0.20 * (m.2 as f64 / max_size);
            (score, m.0)
        })
        .max_by(|a, b| a.0.total_cmp(&b.0).then(b.1.cmp(&a.1)))
        .map(|(_, id)| id)
}

/// An image outside a scan (for example a preview of a Photos-library
/// item), with what is known about its original.
#[derive(Clone, Debug)]
pub struct ImageInput {
    pub path: PathBuf,
    /// Size of the original, when the image is a preview (0 = use the file).
    pub width: u32,
    pub height: u32,
    pub screenshot: bool,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ImageSetAnalysis {
    /// Similar images by input index, each with its best one.
    pub groups: Vec<(Vec<u32>, u32)>,
    /// Issues by input index.
    pub issues: Vec<(u32, Vec<PhotoIssue>)>,
    pub failed: u64,
}

/// Fingerprints `images` and groups similar ones; indices refer to
/// `images`. Images that cannot be decoded are counted in `failed`.
pub fn analyze_set(
    images: &[ImageInput],
    cache: Option<&HashCache>,
    control: &ScanControl,
    pool: &rayon::ThreadPool,
) -> crate::Result<ImageSetAnalysis> {
    let items: Vec<(u32, PathBuf, u64, i64)> = images
        .iter()
        .enumerate()
        .map(|(i, img)| {
            let meta = std::fs::metadata(&img.path).ok();
            let size = meta.as_ref().map_or(0, |m| m.len());
            let mtime = meta
                .and_then(|m| m.modified().ok())
                .map(crate::walker::system_time_ns)
                .unwrap_or(0);
            (i as u32, img.path.clone(), size, mtime)
        })
        .collect();
    let (mut features, failed) = analyze_many(&items, cache, control, pool, &|| {})?;
    for (i, f) in &mut features {
        let img = &images[*i as usize];
        if img.width > 0 && img.height > 0 {
            f.width = img.width;
            f.height = img.height;
        }
    }
    let groups = group_similar(&features)
        .into_iter()
        .map(|members| {
            let scored: Vec<(u32, PhotoFeatures, u64)> = members
                .iter()
                .filter_map(|&m| {
                    features
                        .iter()
                        .find(|(i, _)| *i == m)
                        .map(|(_, f)| (m, *f, 0))
                })
                .collect();
            let best = best_shot(&scored).unwrap_or(members[0]);
            (members, best)
        })
        .collect();
    let issues = features
        .iter()
        .filter_map(|(i, f)| {
            let mut found = if images[*i as usize].screenshot {
                vec![PhotoIssue::Screenshot]
            } else {
                issues(f, "", "")
            };
            found.dedup();
            (!found.is_empty()).then_some((*i, found))
        })
        .collect();
    Ok(ImageSetAnalysis {
        groups,
        issues,
        failed,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A photo-like test image: smooth gradients plus a few shapes.
    fn scene(w: u32, h: u32, seed: u32) -> image::RgbImage {
        image::RgbImage::from_fn(w, h, |x, y| {
            let fx = x as f32 / w as f32;
            let fy = y as f32 / h as f32;
            let blob =
                |cx: f32, cy: f32, r: f32| ((fx - cx).powi(2) + (fy - cy).powi(2) < r * r) as u8;
            let s = seed as f32 * 0.37;
            let v = (120.0 + 90.0 * (fx * 3.0 + s).sin() * (fy * 2.0 - s).cos()) as u8;
            let shape = blob(0.3 + s.sin() * 0.1, 0.4, 0.15) * 90
                + blob(0.7, 0.6 + s.cos() * 0.1, 0.1) * 70;
            image::Rgb([v.saturating_add(shape), v / 2 + shape, 255 - v])
        })
    }

    fn save_jpeg(img: &image::RgbImage, path: &Path, quality: u8) {
        let mut out = std::fs::File::create(path).unwrap();
        let mut enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, quality);
        enc.encode_image(img).unwrap();
    }

    #[test]
    fn resized_and_recompressed_copies_are_similar_other_scenes_are_not() {
        let dir = tempfile::tempdir().unwrap();
        let original = scene(1600, 1200, 1);
        save_jpeg(&original, &dir.path().join("a.jpg"), 92);
        let small =
            image::imageops::resize(&original, 640, 480, image::imageops::FilterType::Triangle);
        save_jpeg(&small, &dir.path().join("a_small.jpg"), 60);
        small.save(dir.path().join("a_small.png")).unwrap();
        save_jpeg(&scene(1600, 1200, 7), &dir.path().join("b.jpg"), 92);

        let f = |n: &str| analyze_file(&dir.path().join(n)).unwrap();
        let (a, a_small, a_png, b) = (f("a.jpg"), f("a_small.jpg"), f("a_small.png"), f("b.jpg"));
        assert_eq!((a.width, a.height), (1600, 1200));
        assert_eq!((a_small.width, a_small.height), (640, 480));
        assert!(similar(&a, &a_small));
        assert!(similar(&a, &a_png));
        assert!(!similar(&a, &b));

        let groups = group_similar(&[(1, a), (2, b), (3, a_small), (4, a_png)]);
        assert_eq!(groups, vec![vec![1, 3, 4]]);
        // The full-size, sharper original wins.
        let best = best_shot(&[(1, a, 900_000), (3, a_small, 60_000), (4, a_png, 400_000)]);
        assert_eq!(best, Some(1));
    }

    #[test]
    fn blur_darkness_and_screenshots_are_noticed() {
        let dir = tempfile::tempdir().unwrap();
        let sharp = scene(800, 600, 3);
        let blurred = image::imageops::blur(&sharp, 6.0);
        let dark = image::RgbImage::from_fn(800, 600, |x, y| {
            let p = sharp.get_pixel(x, y);
            image::Rgb([p[0] / 10, p[1] / 10, p[2] / 10])
        });
        save_jpeg(&sharp, &dir.path().join("sharp.jpg"), 90);
        save_jpeg(&blurred, &dir.path().join("blurred.jpg"), 90);
        save_jpeg(&dark, &dir.path().join("dark.jpg"), 90);
        let f = |n: &str| analyze_file(&dir.path().join(n)).unwrap();
        let (s, b, d) = (f("sharp.jpg"), f("blurred.jpg"), f("dark.jpg"));
        assert!(
            s.sharpness > b.sharpness * 4.0,
            "{} vs {}",
            s.sharpness,
            b.sharpness
        );
        assert_eq!(issues(&s, "IMG_1.jpg", "Camera"), vec![]);
        assert_eq!(issues(&b, "IMG_2.jpg", "Camera"), vec![PhotoIssue::Blurry]);
        assert!(issues(&d, "IMG_3.jpg", "Camera").contains(&PhotoIssue::Dark));
        assert_eq!(
            issues(&s, "Screenshot 2024-05-01.png", "Pictures"),
            vec![PhotoIssue::Screenshot]
        );
        assert_eq!(
            issues(&s, "x.png", "Pictures/Screenshots"),
            vec![PhotoIssue::Screenshot]
        );
    }

    #[test]
    fn image_sets_are_grouped_with_their_best_and_flagged() {
        let dir = tempfile::tempdir().unwrap();
        let original = scene(1600, 1200, 11);
        let small =
            image::imageops::resize(&original, 400, 300, image::imageops::FilterType::Triangle);
        save_jpeg(&small, &dir.path().join("a.jpg"), 90);
        save_jpeg(&small, &dir.path().join("b.jpg"), 70);
        save_jpeg(&scene(400, 300, 30), &dir.path().join("c.jpg"), 90);
        let input = |name: &str, w: u32, h: u32, screenshot: bool| ImageInput {
            path: dir.path().join(name),
            width: w,
            height: h,
            screenshot,
        };
        let pool = rayon::ThreadPoolBuilder::new()
            .num_threads(2)
            .build()
            .unwrap();
        let out = analyze_set(
            &[
                input("a.jpg", 800, 600, false),
                // Same picture, but the original was larger: it is the one to keep.
                input("b.jpg", 4032, 3024, false),
                input("c.jpg", 1170, 2532, true),
                input("missing.jpg", 0, 0, false),
            ],
            None,
            &ScanControl::new(),
            &pool,
        )
        .unwrap();
        assert_eq!(out.groups, vec![(vec![0, 1], 1)]);
        assert_eq!(out.issues, vec![(2, vec![PhotoIssue::Screenshot])]);
        assert_eq!(out.failed, 1);
    }

    #[test]
    fn grouping_does_not_chain() {
        // a ~ b and b ~ c, but a and c are far apart: c must not join a.
        let base = PhotoFeatures {
            dhash: 0,
            phash: 0,
            width: 10,
            height: 10,
            sharpness: 50.0,
            brightness: 100.0,
            contrast: 40.0,
        };
        let with = |d: u64, p: u64| PhotoFeatures {
            dhash: d,
            phash: p,
            ..base
        };
        let a = with(0, 0);
        let b = with(0x3FF, 0x3FF); // 10 bits from a
        let c = with(0xFFFFF, 0xFFFFF); // 20 bits from a, 10 from b
        let groups = group_similar(&[(1, a), (2, b), (3, c)]);
        assert_eq!(groups, vec![vec![1, 2]]);
    }
}
