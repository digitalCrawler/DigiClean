# DigiClean architecture

## Goals

| Goal | How it is met |
|---|---|
| One code base for Windows, Linux, macOS, Android, iOS | Flutter UI + a Rust engine shared by every platform |
| Speed on large volumes | Parallel walk, staged elimination, SIMD hashing, persistent cache |
| Accuracy | Content hashes (BLAKE3 / SHA-256), optional byte-by-byte check, hard-link awareness |
| Safety | Keep-one invariant, re-verification before every removal, recovery bin, undo |
| Low memory / battery on phones | Compact records, results paged from Rust, adaptive thread counts, foreground-service wake lock only while scanning |

## Layers

```
┌──────────────────────────── Flutter (Dart) ────────────────────────────┐
│ lib/src/ui        screens & widgets (Material 3, adaptive layouts)     │
│ lib/src/state     Riverpod controllers: settings, locations, scan,     │
│                   results, recovery; PagedList for lazy group lists    │
│ lib/src/core      formatting, file kinds, storage permissions,         │
│                   platform channel (digiclean/platform)                │
│ lib/src/rust      generated bindings (flutter_rust_bridge 2.13)        │
└───────────────┬────────────────────────────────────────────────────────┘
                │ FFI (generated, async on worker threads + Dart streams)
┌───────────────┴──────── rust/ (digiclean_bridge) ──────────────────────┐
│ api/scanner.rs   ScanController: start (stream of progress), pause,    │
│                  resume, cancel, take_results                          │
│ api/results.rs   ScanResults: paged queries, selection, rules, actions │
│ api/maintenance  recovery bin, hash cache, platform capabilities       │
│ api/types.rs     DTOs only — engine types never cross the boundary     │
└───────────────┬────────────────────────────────────────────────────────┘
┌───────────────┴──────── crates/engine (digiclean_engine) ──────────────┐
│ walker   parallel directory walk (rayon task per directory)            │
│ scan     size → partial hash → full hash → verify → folders pipeline   │
│ hashing  BLAKE3 / SHA-256 streaming with per-thread buffers            │
│ folders  Merkle signatures for duplicate folders, empty folders        │
│ cache    redb hash cache keyed by path, validated by size + mtime      │
│ session  results, paging, sorting, filtering, selection invariants     │
│ actions  trash / recovery bin / delete / move / hard-link executor     │
│ recovery app-managed recovery bin with crash-safe sidecars             │
│ platform OS specifics: attributes, cloud placeholders, file identity   │
└────────────────────────────────────────────────────────────────────────┘
crates/cli — `digiclean` command-line tool on the same engine (read-only)
```

Native platform code is deliberately small:

* **Android** (`MainActivity.kt`, `ScanService.kt`): storage volumes and
  per-volume app directories, a `dataSync` foreground service with a
  progress notification and partial wake lock during scans, and
  `MediaScannerConnection` refresh after deletions so galleries update.
* **iOS** (`AppDelegate.swift`): folder picker returning security-scoped
  URLs, bookmark persistence/resolution, and a background task so scans are
  not suspended immediately when the app is backgrounded.

## Duplicate detection pipeline

1. **Discover.** Each directory is a rayon task; directory ids are allocated
   at spawn time so `child id > parent id`, which lets later stages process
   trees bottom-up with a reverse loop instead of recursion. Only metadata
   is read. Filters (size, extension, category, globs, excluded paths,
   hidden, system folders) are applied here. On Windows, OneDrive/Dropbox
   placeholders are skipped so a scan never triggers downloads.
2. **Size.** Files with a unique size are dropped (no I/O).
3. **Partial fingerprint.** BLAKE3 of three 4 KiB samples (head, middle,
   tail) plus the size. Files ≤ 16 KiB are hashed in full here instead.
   This eliminates the vast majority of same-size false positives at a few
   KiB of I/O per file. The partial hash is algorithm-independent so cached
   values stay valid when the user switches algorithms.
4. **Full hash.** BLAKE3 (default) or SHA-256 over the full content,
   largest files first to avoid a long single-file tail. Reads use a
   512 KiB thread-local buffer and honour pause/cancel between reads.
5. **Verify (optional).** Byte-by-byte comparison inside each group.
6. **Hard links.** Files sharing `(device, inode)` — or `(volume serial,
   file index)` on Windows — are one physical file; only one path is kept.

### Duplicate folders

Two folders are duplicates when their whole trees match: same relative
names, same structure, byte-identical files. Detection uses two Merkle
passes:

* **Structure signature** — names + sizes only. Folders whose signature is
  unique cannot be duplicates, so most folders are discarded without I/O.
* **Content hash** — names + file digests for the remaining candidates.
  Files inside candidate folders that the file pipeline skipped (filtered
  out, unique size, hidden) are hashed now; folder comparison always uses
  *every* file so a filtered scan can never declare two different folders
  identical.

A folder is only comparable if its whole tree was seen (no unreadable
entries, nothing excluded, depth limit not reached). OS junk files
(`Thumbs.db`, `.DS_Store`, `desktop.ini`) are ignored. Groups implied by a
duplicate parent are hidden.

## Hash cache

`redb` (pure Rust, ACID, no C toolchain needed for mobile cross-builds).
Key: BLAKE3 of the exact path bytes (lossless on every OS). Value: size,
mtime (ns), file identity, partial hash, algorithm + full hash, last-seen
day. A hit requires size and mtime (and inode on Unix) to match. Lookups and
writes are batched in one transaction per stage. A corrupt cache is
discarded and rebuilt — it is only an accelerator.

## Results, selection and safety

Results never leave Rust in bulk. The UI asks for pages
(`file_groups(offset, limit, sort, filter)`), and the sorted/filtered order
is cached per query. Selection lives in Rust as well, so rules apply to
hundreds of thousands of groups instantly.

Safety rules, enforced in the engine:

* **Keep-one invariant.** Selecting the last unselected copy of a group is
  rejected.
* **Re-verification.** Before each removal the target must still have its
  scanned size and mtime, and a kept copy must exist unchanged (optionally
  re-hashed).
* **Folders.** A folder is removed only if a kept, *intact* member of its
  group exists (nothing inside it removed since the scan) and both trees
  still have the scanned file count and size. Items are processed in order
  with state updates, so mixed file + folder actions can never remove the
  last copy of anything (covered by
  `folder_then_file_actions_never_lose_the_last_copy`).
* **Recovery.** Desktop defaults to the system Recycle Bin/Trash. Android
  and iOS use the app's recovery bin, placed on the same volume as the file
  whenever possible (instant rename). A sidecar is written *before* the
  move and finalised after; a cross-volume move copies, verifies the size,
  and only then removes the source — if the source cannot be fully removed
  the complete copy is kept and reported. Undo restores a whole batch.
* **Honest numbers.** Action reports separate bytes freed (permanent delete,
  hard link) from bytes moved into a bin or to another folder. Space in a
  bin counts as freed only when the bin is emptied, which the app can do
  for its own bin and for the system Recycle Bin/Trash.

Ignore list: "Not duplicates" stores a group's content hash (with the hash
algorithm) in the app's preferences; the session hides matching groups and
refuses to select their members. "Ignore folder" adds an excluded path for
later scans and marks everything inside as `Ignored` in the open session;
folders containing it stop matching their copies.

Saved results: `snapshot.rs` writes the scan plus item states and the
selection to a versioned binary file in the app's data folder after scans,
after actions and when the app is hidden or closed. A damaged file or one
of another version is discarded, and the next start shows an empty state.
Reopened results are only as fresh as the scan, which is why every action
re-verifies size and mtime first.

Junk (`junk.rs`) is classified during the walk: OS thumbnail caches
(`Thumbs.db`, `.DS_Store`; always safe), unfinished downloads and temporary
files older than a day, empty files that are not known markers, broken
symbolic links and Windows shortcuts whose drive exists but target does
not. `desktop.ini` and `.localized` are never junk. Junk entries reference
their file record when there is one, so removing junk updates folder
comparisons too. Removal re-checks size and mtime (or that a link is still
broken) and only ever removes the link itself.

Reports (`report.rs`) render what the results screen shows, including the
selection: CSV (one row per item, Excel-friendly, formula-safe), JSON and a
self-contained HTML page. The app saves them through the system save dialog;
the CLI writes them with `--export`.

## Platform storage model

| Platform | Access model | Removal |
|---|---|---|
| Windows / Linux / macOS | regular file-system permissions; system folders skipped | system trash (batched), recovery bin, permanent, move, hard link |
| Android 11+ | `MANAGE_EXTERNAL_STORAGE` (“All files access”); `Android/data` and `Android/obb` are not accessible and skipped | recovery bin in the per-volume app directory, permanent, move; MediaStore refreshed afterwards |
| Android ≤ 10 | `READ/WRITE_EXTERNAL_STORAGE`, legacy storage | as above |
| iOS | folders picked in Files (On My iPhone, iCloud Drive, external drives, providers); security-scoped bookmarks persisted; the app's Documents folder is visible in Files | recovery bin, permanent, move |

## Performance profiles

| Profile | Walk threads | Hash threads | Use |
|---|---|---|---|
| Maximum | 2 × cores (4–32) | cores | desktop on AC power |
| Balanced | cores (2–12) | cores / 2 (2–8) | default on phones |
| Battery saver | 2 | 1 | keeps devices cool |
| Spinning disk | 2 | 1 | HDDs, avoids seek thrashing |

Progress is published by a separate reporter thread every 150 ms from
atomic counters, so UI update rate is independent of file throughput; the
Android notification is throttled further to once per second.

## Storage overview

Every file in a scanned folder is recorded (filters only decide what is
compared as a duplicate), so the session can answer storage questions
without another walk:

* `category_usage` sums present files per category.
* `space_children` lists a folder's sub-folders and its own files with live
  sizes (a per-generation cache of tree sizes that follows removals); the app
  draws them as a squarified treemap (`lib/src/core/treemap.dart`).
* The old-files view filters eligible files by modification time, folder and
  extension, with its own selection.
* `recommendations` collects low-risk cleanups (system caches, leftovers a
  day old, duplicate copies inside the download folders while a copy is kept,
  empty folders) and `select_recommendation` applies them as ordinary
  selections, so they run through the same verified actions.
* `volumes.rs` lists drives with capacity (Windows drive APIs, `statvfs` and
  `/proc/self/mounts` on Linux, `/Volumes` on macOS); Android and iOS pass
  their own storage paths to `disk_usage`.
* `archive.rs` writes a `.zip` under a temporary name, reads every entry back
  (CRC and size) and only then renames it. Originals are removed separately,
  after the user sees the saving, through the same trash / recovery bin used
  everywhere else. Moving to another drive copies, checks sizes and only then
  removes the source.

## Photos

`photos.rs` decodes images small (JPEG at 1/8 scale straight from the DCT,
PNG/WebP/GIF/BMP through `image` and then reduced to 256 px) and computes:

* dHash (9×8 gradients) and pHash (8×8 low frequencies of a 32×32 DCT);
* sharpness (variance of the Laplacian), brightness and contrast.

Two photos are similar when pHash differs by at most 12 bits, dHash by at
most 16 and both together by at most 20. pHash carries most of the weight
because dHash flips bits in smooth areas (skies) when a photo is resized.
Grouping is leader clustering over a BK-tree, so chains of "almost similar"
photos never merge. Sets made only of byte-identical copies are dropped
(they are already duplicate groups). The best shot scores sharpness,
resolution and file size; "Keep best" ticks the rest, and removal requires an
unticked, unchanged photo of the set to remain.

Blurry, dark and screenshot images are flagged with conservative thresholds;
screenshots are recognised by name or folder and never judged on blur.
Fingerprints are cached in the hash cache (`photos_v1` table) keyed by path,
size and mtime. Analysis runs on demand from the Photos tab and is not part
of saved results; reopening results needs a re-analysis, which is fast
because of the cache. HEIC and RAW files are skipped (no portable decoder).

## Similar audio and video

`media.rs` decodes the first two minutes of a file's soundtrack with
Symphonia (MP3, AAC/M4A/MP4/MOV, FLAC, ALAC, Vorbis/OGG, WAV, MKV) and
fingerprints it with the Chromaprint algorithm (`rusty-chromaprint`). Two
files are the same recording when their durations agree (within 2 s or 3%)
and at least 85% of fingerprint bits match at some offset of up to 6 s.
Videos are matched through their audio, so videos without sound are not
compared. The largest file of a set is suggested as the one to keep.
Fingerprints are cached (`media_v1`). No FFmpeg is needed.

## Keeping it clean

* **While the app is open**: the dashboard warns about drives under 10% free;
  download folders are checked every 10 minutes for new files whose content
  already exists in the scanned folders (`watch.rs`); a rescan starts when
  the last one is older than the chosen interval.
* **Desktop background check**: the app writes `background-job.json` (the
  same scan options, the "not duplicates" list and where to save results)
  and registers a daily run of the windowless `digiclean-check` with the
  system scheduler (Task Scheduler XML on Windows, a systemd user timer on
  Linux, a LaunchAgent on macOS). The check scans, saves results the app
  reopens, checks free space and shows a system notification (PowerShell
  toast, `osascript`, `notify-send`). It never removes anything.
  `digiclean-check` ships next to the app in every package.
* **Android**: a daily WorkManager job (battery not low) notifies about low
  storage and due rescans; the rescan runs when the app opens.
* **iOS**: a background app refresh (`BGAppRefreshTask`) does the same.
* **Copy-on-write clones** (`ReplaceWithClone`): each duplicate becomes a
  reflink clone of the kept copy where the drive supports it (APFS, Btrfs,
  XFS, ReFS); Windows reports support up front, elsewhere it is tried and
  unsupported drives leave files untouched.

## iOS Photos library

Photos-library items are not files. The iOS side (PhotoKit, in
`AppDelegate.swift`) writes 512-px previews to the cache, using only local
data, and lists each photo's original size and whether it is a screenshot.
`analyze_image_set` groups similar previews and flags blurry, dark and
screenshot photos with the same code as files. Deletion goes through
`PHAssetChangeRequest`: iOS asks for confirmation and keeps photos in
Recently Deleted for 30 days.
