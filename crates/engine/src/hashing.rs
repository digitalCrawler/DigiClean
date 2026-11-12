//! Streaming content hashing with reusable per-thread buffers.

use std::cell::RefCell;
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::Path;

use sha2::Digest as _;

use crate::config::HashAlgorithm;
use crate::control::ScanControl;
use crate::error::{EngineError, Result};
use crate::platform;
use crate::progress::ProgressTracker;

pub type Digest = [u8; 32];

/// Size of each sampled block for the partial fingerprint.
pub const SAMPLE_SIZE: usize = 4096;
/// Files at or below this size are hashed completely in the first pass,
/// which is cheaper than sampling them and hashing them again.
pub const SMALL_FILE_LIMIT: u64 = 16 * 1024;
/// Read buffer for full hashing. Large enough for efficient sequential I/O,
/// small enough to stay cache- and mobile-friendly.
const BUFFER_SIZE: usize = 512 * 1024;

thread_local! {
    static BUFFER: RefCell<Vec<u8>> = RefCell::new(vec![0u8; BUFFER_SIZE]);
    static BUFFER_B: RefCell<Vec<u8>> = RefCell::new(vec![0u8; BUFFER_SIZE]);
}

enum Hasher {
    Blake3(Box<blake3::Hasher>),
    Sha256(sha2::Sha256),
}

impl Hasher {
    fn new(algo: HashAlgorithm) -> Self {
        match algo {
            HashAlgorithm::Blake3 => Hasher::Blake3(Box::new(blake3::Hasher::new())),
            HashAlgorithm::Sha256 => Hasher::Sha256(sha2::Sha256::new()),
        }
    }

    fn update(&mut self, data: &[u8]) {
        match self {
            Hasher::Blake3(h) => {
                h.update(data);
            }
            Hasher::Sha256(h) => h.update(data),
        }
    }

    fn finalize(self) -> Digest {
        match self {
            Hasher::Blake3(h) => *h.finalize().as_bytes(),
            Hasher::Sha256(h) => h.finalize().into(),
        }
    }
}

/// Result of the first, cheap pass over a candidate file.
#[derive(Debug, Clone, Copy)]
pub struct Probe {
    pub partial: u128,
    /// Present when the whole file was read (small files).
    pub full: Option<Digest>,
    pub identity: Option<platform::FileIdentity>,
}

/// Reads up to three sampled blocks (head, middle, tail). For files no
/// larger than [`SMALL_FILE_LIMIT`] the complete content is hashed instead.
///
/// The partial fingerprint is always BLAKE3-based so that cached values stay
/// comparable when the user switches the full-hash algorithm.
pub fn probe_file(path: &Path, size: u64, algo: HashAlgorithm) -> io::Result<Probe> {
    if size <= SMALL_FILE_LIMIT {
        let mut file = platform::open_sequential(path)?;
        let identity = platform::identity_from_file(&file);
        let (partial, full) = BUFFER.with(|buf| -> io::Result<(u128, Digest)> {
            let mut buf = buf.borrow_mut();
            let data = read_exact_size(&mut file, &mut buf[..size as usize + 1], size)?;
            let b3 = *blake3::hash(data).as_bytes();
            let full = match algo {
                HashAlgorithm::Blake3 => b3,
                HashAlgorithm::Sha256 => sha2::Sha256::digest(data).into(),
            };
            Ok((u128::from_le_bytes(b3[..16].try_into().unwrap()), full))
        })?;
        return Ok(Probe {
            partial,
            full: Some(full),
            identity,
        });
    }

    let mut file = platform::open_random(path)?;
    let identity = platform::identity_from_file(&file);
    let mut hasher = blake3::Hasher::new();
    hasher.update(&size.to_le_bytes());
    let mut block = [0u8; SAMPLE_SIZE];
    let offsets = [
        0,
        size / 2 - SAMPLE_SIZE as u64 / 2,
        size - SAMPLE_SIZE as u64,
    ];
    for offset in offsets {
        file.seek(SeekFrom::Start(offset))?;
        file.read_exact(&mut block)?;
        hasher.update(&block);
    }
    let out = hasher.finalize();
    Ok(Probe {
        partial: u128::from_le_bytes(out.as_bytes()[..16].try_into().unwrap()),
        full: None,
        identity,
    })
}

/// Reads exactly `size` bytes into `buf` (which must be one byte larger so
/// that growth since the walk is detected) and returns the filled slice.
fn read_exact_size<'a>(file: &mut File, buf: &'a mut [u8], size: u64) -> io::Result<&'a [u8]> {
    let mut filled = 0usize;
    loop {
        let n = file.read(&mut buf[filled..])?;
        if n == 0 {
            break;
        }
        filled += n;
        if filled == buf.len() {
            break;
        }
    }
    if filled as u64 != size {
        return Err(io::Error::other("file changed while scanning"));
    }
    Ok(&buf[..filled])
}

/// Hashes the complete file, honouring pause/cancel between buffer reads
/// and reporting bytes to `progress`.
pub fn full_hash(
    path: &Path,
    size: u64,
    algo: HashAlgorithm,
    control: &ScanControl,
    progress: &ProgressTracker,
) -> Result<Digest> {
    let mut file = platform::open_sequential(path).map_err(|e| EngineError::io(path, e))?;
    BUFFER.with(|buf| {
        let mut buf = buf.borrow_mut();
        let mut hasher = Hasher::new(algo);
        let mut total = 0u64;
        loop {
            control.checkpoint()?;
            let n = match file.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => n,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(EngineError::io(path, e)),
            };
            hasher.update(&buf[..n]);
            total += n as u64;
            progress.add_bytes(n as u64);
        }
        if total != size {
            return Err(EngineError::io(
                path,
                io::Error::other("file changed while scanning"),
            ));
        }
        Ok(hasher.finalize())
    })
}

/// Digest of zero bytes, so empty files never need to be opened.
pub fn empty_digest(algo: HashAlgorithm) -> Digest {
    Hasher::new(algo).finalize()
}

/// Hashes a file outside of a scan (used for verification before actions).
pub fn hash_file(path: &Path, algo: HashAlgorithm) -> io::Result<Digest> {
    let mut file = platform::open_sequential(path)?;
    BUFFER.with(|buf| {
        let mut buf = buf.borrow_mut();
        let mut hasher = Hasher::new(algo);
        loop {
            let n = match file.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => n,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(e),
            };
            hasher.update(&buf[..n]);
        }
        Ok(hasher.finalize())
    })
}

/// Byte-by-byte comparison of two files.
pub fn files_identical(a: &Path, b: &Path, control: &ScanControl) -> Result<bool> {
    let mut fa = platform::open_sequential(a).map_err(|e| EngineError::io(a, e))?;
    let mut fb = platform::open_sequential(b).map_err(|e| EngineError::io(b, e))?;
    BUFFER.with(|ba| {
        BUFFER_B.with(|bb| {
            let mut ba = ba.borrow_mut();
            let mut bb = bb.borrow_mut();
            loop {
                control.checkpoint()?;
                let na = read_full(&mut fa, &mut ba).map_err(|e| EngineError::io(a, e))?;
                let nb = read_full(&mut fb, &mut bb).map_err(|e| EngineError::io(b, e))?;
                if na != nb || ba[..na] != bb[..nb] {
                    return Ok(false);
                }
                if na == 0 {
                    return Ok(true);
                }
            }
        })
    })
}

/// Fills `buf` as far as possible; returns fewer bytes only at EOF.
fn read_full(file: &mut File, buf: &mut [u8]) -> io::Result<usize> {
    let mut filled = 0;
    while filled < buf.len() {
        match file.read(&mut buf[filled..]) {
            Ok(0) => break,
            Ok(n) => filled += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(filled)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_vectors() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("abc.txt");
        std::fs::write(&p, b"abc").unwrap();
        assert_eq!(
            hex::encode(hash_file(&p, HashAlgorithm::Sha256).unwrap()),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            hex::encode(hash_file(&p, HashAlgorithm::Blake3).unwrap()),
            "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"
        );
    }

    #[test]
    fn small_probe_equals_full_hash() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("small.bin");
        std::fs::write(&p, vec![7u8; 1000]).unwrap();
        let probe = probe_file(&p, 1000, HashAlgorithm::Blake3).unwrap();
        let control = ScanControl::new();
        let tracker = ProgressTracker::default();
        let full = full_hash(&p, 1000, HashAlgorithm::Blake3, &control, &tracker).unwrap();
        assert_eq!(probe.full, Some(full));
    }

    #[test]
    fn partial_differs_on_tail_change() {
        let dir = tempfile::tempdir().unwrap();
        let a = dir.path().join("a.bin");
        let b = dir.path().join("b.bin");
        let mut data = vec![1u8; 100_000];
        std::fs::write(&a, &data).unwrap();
        *data.last_mut().unwrap() = 2;
        std::fs::write(&b, &data).unwrap();
        let pa = probe_file(&a, 100_000, HashAlgorithm::Blake3).unwrap();
        let pb = probe_file(&b, 100_000, HashAlgorithm::Blake3).unwrap();
        assert_ne!(pa.partial, pb.partial);
        assert!(!files_identical(&a, &b, &ScanControl::new()).unwrap());
        assert!(files_identical(&a, &a, &ScanControl::new()).unwrap());
    }

    #[test]
    fn detects_size_change() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("grow.bin");
        std::fs::write(&p, vec![0u8; 500]).unwrap();
        assert!(probe_file(&p, 400, HashAlgorithm::Blake3).is_err());
    }
}
