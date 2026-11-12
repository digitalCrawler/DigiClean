//! DigiClean engine — content-based duplicate file and folder detection.
//!
//! The pipeline is staged so that expensive work is only done for files that
//! can still be duplicates:
//!
//! 1. **Discover** — a parallel directory walk collects metadata only.
//! 2. **Size** — files with a unique size cannot have a duplicate.
//! 3. **Partial hash** — a BLAKE3 digest of sampled blocks (head/middle/tail)
//!    splits most same-size false positives with a few KiB of I/O per file.
//!    Files ≤ [`hashing::SMALL_FILE_LIMIT`] are hashed in full here.
//! 4. **Full hash** — BLAKE3 or SHA-256 over the complete content.
//! 5. **Verify** (optional) — byte-by-byte comparison inside each group.
//! 6. **Folders** — Merkle hashes over directory trees whose structural
//!    signature matches, to find identical folders.
//!
//! Hashes are cached on disk ([`cache::HashCache`]) keyed by path and
//! validated by size + mtime, so rescans only touch changed files.

pub mod actions;
pub mod archive;
pub mod background;
pub mod cache;
pub mod config;
pub mod control;
pub mod error;
pub mod filters;
pub mod folders;
pub mod hashing;
pub mod junk;
pub mod media;
pub mod model;
pub mod paths;
pub mod photos;
pub mod priority;
pub mod platform;
pub mod progress;
pub mod recovery;
pub mod report;
pub mod scan;
pub mod session;
pub mod snapshot;
pub mod volumes;
pub mod walker;
pub mod watch;

pub use actions::{ActionKind, ActionReport, ActionTarget};
pub use cache::HashCache;
pub use config::{FileCategory, HashAlgorithm, Performance, ScanConfig};
pub use control::ScanControl;
pub use error::{EngineError, Result};
pub use model::{FileGroup, FolderGroup, ScanResult, ScanStats};
pub use progress::{ProgressSink, ProgressSnapshot, ScanPhase};
pub use recovery::{RecoveryBin, RecoveryItem};
pub use scan::run_scan;
pub use session::Session;
