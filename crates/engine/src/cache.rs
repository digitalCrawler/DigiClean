//! Persistent hash cache backed by redb (pure Rust, ACID, crash-safe).
//!
//! Key: BLAKE3 of the exact path bytes. Value: a fixed binary record holding
//! the size and mtime the hashes were computed for, so a lookup only hits
//! when the file is unchanged.

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use redb::{Database, ReadableDatabase, ReadableTableMetadata, TableDefinition};

use crate::config::HashAlgorithm;
use crate::error::{EngineError, Result};
use crate::hashing::Digest;
use crate::media::MediaFeatures;
use crate::paths;
use crate::photos::PhotoFeatures;
use crate::platform::FileIdentity;

const TABLE: TableDefinition<&[u8], &[u8]> = TableDefinition::new("hashes_v1");
/// Photo fingerprints: size, mtime, day, then the features.
const PHOTOS: TableDefinition<&[u8], &[u8]> = TableDefinition::new("photos_v1");
/// Audio fingerprints: size, mtime, day, duration (ms, -1 unknown), items.
const MEDIA: TableDefinition<&[u8], &[u8]> = TableDefinition::new("media_v1");
const PHOTO_LEN: usize = 8 + 8 + 4 + 8 + 8 + 4 + 4 + 4 + 4 + 4;
const RECORD_LEN: usize = 1 + 8 + 8 + 16 + 1 + 16 + 1 + 32 + 4;
const RECORD_VERSION: u8 = 1;
const FILE_NAME: &str = "hash-cache.redb";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CacheEntry {
    pub size: u64,
    pub modified_ns: i64,
    pub identity: Option<FileIdentity>,
    pub partial: Option<u128>,
    pub full: Option<(HashAlgorithm, Digest)>,
}

impl CacheEntry {
    pub fn full_for(&self, algo: HashAlgorithm) -> Option<Digest> {
        self.full.filter(|(a, _)| *a == algo).map(|(_, d)| d)
    }

    fn encode(&self, day: u32) -> [u8; RECORD_LEN] {
        let mut out = [0u8; RECORD_LEN];
        let mut w = 0;
        let mut put = |bytes: &[u8]| {
            out[w..w + bytes.len()].copy_from_slice(bytes);
            w += bytes.len();
        };
        put(&[RECORD_VERSION]);
        put(&self.size.to_le_bytes());
        put(&self.modified_ns.to_le_bytes());
        let (dev, ino) = self.identity.unwrap_or((0, 0));
        put(&dev.to_le_bytes());
        put(&ino.to_le_bytes());
        put(&[self.partial.is_some() as u8]);
        put(&self.partial.unwrap_or(0).to_le_bytes());
        match self.full {
            Some((algo, digest)) => {
                put(&[algo.id()]);
                put(&digest);
            }
            None => {
                put(&[0]);
                put(&[0u8; 32]);
            }
        }
        put(&day.to_le_bytes());
        out
    }

    fn decode(bytes: &[u8]) -> Option<(Self, u32)> {
        if bytes.len() != RECORD_LEN || bytes[0] != RECORD_VERSION {
            return None;
        }
        let u64_at = |o: usize| u64::from_le_bytes(bytes[o..o + 8].try_into().unwrap());
        let size = u64_at(1);
        let modified_ns = u64_at(9) as i64;
        let dev = u64_at(17);
        let ino = u64_at(25);
        let has_partial = bytes[33] == 1;
        let partial = u128::from_le_bytes(bytes[34..50].try_into().unwrap());
        let full = HashAlgorithm::from_id(bytes[50])
            .map(|algo| (algo, <Digest>::try_from(&bytes[51..83]).unwrap()));
        let day = u32::from_le_bytes(bytes[83..87].try_into().unwrap());
        Some((
            CacheEntry {
                size,
                modified_ns,
                identity: (dev != 0 || ino != 0).then_some((dev, ino)),
                partial: has_partial.then_some(partial),
                full,
            },
            day,
        ))
    }
}

pub struct HashCache {
    db: Database,
    path: PathBuf,
}

fn key_for(path: &Path) -> [u8; 32] {
    *blake3::hash(&paths::path_bytes(path)).as_bytes()
}

fn today() -> u32 {
    (SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
        / 86_400) as u32
}

fn decode_photo(v: &[u8]) -> Option<(u64, i64, PhotoFeatures)> {
    if v.len() != PHOTO_LEN {
        return None;
    }
    let u64_at = |at: usize| u64::from_le_bytes(v[at..at + 8].try_into().unwrap());
    let u32_at = |at: usize| u32::from_le_bytes(v[at..at + 4].try_into().unwrap());
    let f32_at = |at: usize| f32::from_le_bytes(v[at..at + 4].try_into().unwrap());
    Some((
        u64_at(0),
        u64_at(8) as i64,
        PhotoFeatures {
            dhash: u64_at(20),
            phash: u64_at(28),
            width: u32_at(36),
            height: u32_at(40),
            sharpness: f32_at(44),
            brightness: f32_at(48),
            contrast: f32_at(52),
        },
    ))
}

fn decode_media(v: &[u8]) -> Option<(u64, i64, MediaFeatures)> {
    if v.len() < 28 || (v.len() - 28) % 4 != 0 {
        return None;
    }
    let u64_at = |at: usize| u64::from_le_bytes(v[at..at + 8].try_into().unwrap());
    let duration = u64_at(20) as i64;
    Some((
        u64_at(0),
        u64_at(8) as i64,
        MediaFeatures {
            duration_ms: (duration >= 0).then_some(duration as u64),
            fingerprint: v[28..]
                .chunks_exact(4)
                .map(|c| u32::from_le_bytes(c.try_into().unwrap()))
                .collect(),
        },
    ))
}

fn cache_err(e: impl std::fmt::Display) -> EngineError {
    EngineError::Cache(e.to_string())
}

impl HashCache {
    /// Opens (or creates) the cache in `dir`. A corrupt or incompatible
    /// database is discarded and recreated — the cache is only an accelerator.
    pub fn open(dir: &Path) -> Result<Self> {
        std::fs::create_dir_all(dir).map_err(|e| EngineError::io(dir, e))?;
        let path = dir.join(FILE_NAME);
        let db = match Database::create(&path) {
            Ok(db) => db,
            Err(first) => {
                log::warn!("hash cache unusable ({first}); recreating");
                let _ = std::fs::remove_file(&path);
                Database::create(&path).map_err(cache_err)?
            }
        };
        let cache = Self { db, path };
        // Ensure the table exists so read transactions never fail on a fresh file.
        let txn = cache.db.begin_write().map_err(cache_err)?;
        txn.open_table(TABLE).map_err(cache_err)?;
        txn.open_table(PHOTOS).map_err(cache_err)?;
        txn.open_table(MEDIA).map_err(cache_err)?;
        txn.commit().map_err(cache_err)?;
        Ok(cache)
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Looks up many files in one read transaction. An entry is returned only
    /// when size, mtime and (where known at walk time) identity still match.
    pub fn lookup_many(
        &self,
        items: &[(PathBuf, u64, i64, Option<FileIdentity>)],
    ) -> Vec<Option<CacheEntry>> {
        let run = || -> Result<Vec<Option<CacheEntry>>> {
            let txn = self.db.begin_read().map_err(cache_err)?;
            let table = txn.open_table(TABLE).map_err(cache_err)?;
            let mut out = Vec::with_capacity(items.len());
            for (path, size, mtime, walk_identity) in items {
                let key = key_for(path);
                let hit = table
                    .get(key.as_slice())
                    .map_err(cache_err)?
                    .and_then(|v| CacheEntry::decode(v.value()))
                    .map(|(e, _)| e)
                    .filter(|e| {
                        e.size == *size
                            && e.modified_ns == *mtime
                            && (walk_identity.is_none() || e.identity == *walk_identity)
                    });
                out.push(hit);
            }
            Ok(out)
        };
        run().unwrap_or_else(|e| {
            log::warn!("hash cache lookup failed: {e}");
            vec![None; items.len()]
        })
    }

    pub fn store_many(&self, entries: &[(PathBuf, CacheEntry)]) -> Result<()> {
        if entries.is_empty() {
            return Ok(());
        }
        let day = today();
        let txn = self.db.begin_write().map_err(cache_err)?;
        {
            let mut table = txn.open_table(TABLE).map_err(cache_err)?;
            for (path, entry) in entries {
                let key = key_for(path);
                let value = entry.encode(day);
                table
                    .insert(key.as_slice(), value.as_slice())
                    .map_err(cache_err)?;
            }
        }
        txn.commit().map_err(cache_err)
    }

    /// Removes entries not refreshed within `max_age_days`.
    pub fn prune(&self, max_age_days: u32) -> Result<u64> {
        let cutoff = today().saturating_sub(max_age_days);
        let txn = self.db.begin_write().map_err(cache_err)?;
        let removed;
        {
            let mut table = txn.open_table(TABLE).map_err(cache_err)?;
            let before = table.len().map_err(cache_err)?;
            table
                .retain(|_, v| CacheEntry::decode(v).is_some_and(|(_, day)| day >= cutoff))
                .map_err(cache_err)?;
            removed = before - table.len().map_err(cache_err)?;
            let fresh = |v: &[u8]| {
                v.get(16..20)
                    .and_then(|d| d.try_into().ok())
                    .is_some_and(|d| u32::from_le_bytes(d) >= cutoff)
            };
            let mut photos = txn.open_table(PHOTOS).map_err(cache_err)?;
            photos.retain(|_, v| fresh(v)).map_err(cache_err)?;
            let mut media = txn.open_table(MEDIA).map_err(cache_err)?;
            media.retain(|_, v| fresh(v)).map_err(cache_err)?;
        }
        txn.commit().map_err(cache_err)?;
        Ok(removed)
    }

    pub fn entry_count(&self) -> u64 {
        (|| -> Result<u64> {
            let txn = self.db.begin_read().map_err(cache_err)?;
            let table = txn.open_table(TABLE).map_err(cache_err)?;
            table.len().map_err(cache_err)
        })()
        .unwrap_or(0)
    }

    pub fn size_on_disk(&self) -> u64 {
        std::fs::metadata(&self.path).map(|m| m.len()).unwrap_or(0)
    }

    pub fn clear(&self) -> Result<()> {
        let txn = self.db.begin_write().map_err(cache_err)?;
        txn.delete_table(TABLE).map_err(cache_err)?;
        txn.open_table(TABLE).map_err(cache_err)?;
        txn.delete_table(PHOTOS).map_err(cache_err)?;
        txn.open_table(PHOTOS).map_err(cache_err)?;
        txn.delete_table(MEDIA).map_err(cache_err)?;
        txn.open_table(MEDIA).map_err(cache_err)?;
        txn.commit().map_err(cache_err)
    }

    /// Cached audio fingerprints, for files unchanged since they were made.
    pub fn lookup_media(&self, items: &[(PathBuf, u64, i64)]) -> Vec<Option<MediaFeatures>> {
        let run = || -> Result<Vec<Option<MediaFeatures>>> {
            let txn = self.db.begin_read().map_err(cache_err)?;
            let table = txn.open_table(MEDIA).map_err(cache_err)?;
            let mut out = Vec::with_capacity(items.len());
            for (path, size, mtime) in items {
                let hit = table
                    .get(key_for(path).as_slice())
                    .map_err(cache_err)?
                    .and_then(|v| decode_media(v.value()))
                    .filter(|(s, m, _)| s == size && m == mtime)
                    .map(|(_, _, f)| f);
                out.push(hit);
            }
            Ok(out)
        };
        run().unwrap_or_else(|e| {
            log::warn!("media cache lookup failed: {e}");
            vec![None; items.len()]
        })
    }

    pub fn store_media(&self, entries: &[(PathBuf, u64, i64, MediaFeatures)]) -> Result<()> {
        if entries.is_empty() {
            return Ok(());
        }
        let day = today();
        let txn = self.db.begin_write().map_err(cache_err)?;
        {
            let mut table = txn.open_table(MEDIA).map_err(cache_err)?;
            for (path, size, mtime, f) in entries {
                let mut v = Vec::with_capacity(28 + f.fingerprint.len() * 4);
                v.extend_from_slice(&size.to_le_bytes());
                v.extend_from_slice(&mtime.to_le_bytes());
                v.extend_from_slice(&day.to_le_bytes());
                v.extend_from_slice(&f.duration_ms.map_or(-1i64, |d| d as i64).to_le_bytes());
                for item in &f.fingerprint {
                    v.extend_from_slice(&item.to_le_bytes());
                }
                table
                    .insert(key_for(path).as_slice(), v.as_slice())
                    .map_err(cache_err)?;
            }
        }
        txn.commit().map_err(cache_err)
    }

    /// Cached photo fingerprints, for files unchanged since they were made.
    pub fn lookup_photos(&self, items: &[(PathBuf, u64, i64)]) -> Vec<Option<PhotoFeatures>> {
        let run = || -> Result<Vec<Option<PhotoFeatures>>> {
            let txn = self.db.begin_read().map_err(cache_err)?;
            let table = txn.open_table(PHOTOS).map_err(cache_err)?;
            let mut out = Vec::with_capacity(items.len());
            for (path, size, mtime) in items {
                let hit = table
                    .get(key_for(path).as_slice())
                    .map_err(cache_err)?
                    .and_then(|v| decode_photo(v.value()))
                    .filter(|(s, m, _)| s == size && m == mtime)
                    .map(|(_, _, f)| f);
                out.push(hit);
            }
            Ok(out)
        };
        run().unwrap_or_else(|e| {
            log::warn!("photo cache lookup failed: {e}");
            vec![None; items.len()]
        })
    }

    pub fn store_photos(&self, entries: &[(PathBuf, u64, i64, PhotoFeatures)]) -> Result<()> {
        if entries.is_empty() {
            return Ok(());
        }
        let day = today();
        let txn = self.db.begin_write().map_err(cache_err)?;
        {
            let mut table = txn.open_table(PHOTOS).map_err(cache_err)?;
            for (path, size, mtime, f) in entries {
                let mut v = Vec::with_capacity(PHOTO_LEN);
                v.extend_from_slice(&size.to_le_bytes());
                v.extend_from_slice(&mtime.to_le_bytes());
                v.extend_from_slice(&day.to_le_bytes());
                v.extend_from_slice(&f.dhash.to_le_bytes());
                v.extend_from_slice(&f.phash.to_le_bytes());
                v.extend_from_slice(&f.width.to_le_bytes());
                v.extend_from_slice(&f.height.to_le_bytes());
                v.extend_from_slice(&f.sharpness.to_le_bytes());
                v.extend_from_slice(&f.brightness.to_le_bytes());
                v.extend_from_slice(&f.contrast.to_le_bytes());
                table
                    .insert(key_for(path).as_slice(), v.as_slice())
                    .map_err(cache_err)?;
            }
        }
        txn.commit().map_err(cache_err)
    }

    pub fn compact(&mut self) -> Result<()> {
        self.db.compact().map(|_| ()).map_err(cache_err)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_and_invalidation() {
        let dir = tempfile::tempdir().unwrap();
        let cache = HashCache::open(dir.path()).unwrap();
        let file = PathBuf::from("/data/photo.jpg");
        let entry = CacheEntry {
            size: 42,
            modified_ns: 1_700_000_000_000_000_000,
            identity: Some((1, 99)),
            partial: Some(0xdead_beef),
            full: Some((HashAlgorithm::Blake3, [9u8; 32])),
        };
        cache.store_many(&[(file.clone(), entry)]).unwrap();

        let hit = cache.lookup_many(&[(file.clone(), 42, entry.modified_ns, Some((1, 99)))]);
        assert_eq!(hit[0], Some(entry));
        assert_eq!(hit[0].unwrap().full_for(HashAlgorithm::Sha256), None);

        let stale = cache.lookup_many(&[
            (file.clone(), 43, entry.modified_ns, None),
            (file.clone(), 42, entry.modified_ns + 1, None),
            (file.clone(), 42, entry.modified_ns, Some((1, 100))),
        ]);
        assert!(stale.iter().all(|e| e.is_none()));
        assert_eq!(cache.entry_count(), 1);

        cache.clear().unwrap();
        assert_eq!(cache.entry_count(), 0);
    }

    #[test]
    fn reopen_persists() {
        let dir = tempfile::tempdir().unwrap();
        let file = PathBuf::from("/x");
        let entry = CacheEntry {
            size: 1,
            modified_ns: 5,
            identity: None,
            partial: Some(1),
            full: None,
        };
        {
            let cache = HashCache::open(dir.path()).unwrap();
            cache.store_many(&[(file.clone(), entry)]).unwrap();
        }
        let cache = HashCache::open(dir.path()).unwrap();
        assert_eq!(cache.lookup_many(&[(file, 1, 5, None)])[0], Some(entry));
        assert_eq!(cache.prune(30).unwrap(), 0);
    }
}
