# DigiClean roadmap: from duplicate finder to storage manager

Goal: help people **understand** what fills their storage, **clean it safely**,
and **keep it clean**, without giving up the promises the app makes today:
everything runs on the device, one copy is always kept, removals can be
undone.

Effort: **S** ≈ a few days · **M** ≈ 1–2 weeks · **L** ≈ 3+ weeks (one developer).

---

## What we can build on

| Existing piece | Reused for |
|---|---|
| Parallel walker with size/mtime/category per file (`walker.rs`) | Storage map, large/old files, junk rules |
| Per-folder size totals (`folders::TreeStats`) | Folder size ranking, treemap |
| Hash cache (`cache.rs`, redb) | Fast rescans, history, scheduled scans, backup checks |
| Session + paged queries + selection invariants (`session.rs`) | Every new "findings" list |
| Safe action executor + recovery bin (`actions.rs`, `recovery.rs`) | Cleaning anything new, with undo |
| Results UI (group cards, smart select, compare) | New finding types |

One architectural change makes most features below cheap: **generalise the
session from "duplicate groups" to "findings"**. A finding is a group of
items plus a kind (`duplicate`, `similar_photo`, `large_file`, `old_file`,
`junk`, `empty_folder`), a reclaimable size, and a suggested selection.
The walker gets an *analysis-only* mode that keeps every file (today it
drops files that fail the duplicate filters).

---

## Phase 1 — Quick wins (≈ 3–4 weeks)

| Feature | Why | How | Effort |
|---|---|---|---|
| **Large files** ✅ done | Often the fastest way to free space | Top-N query over walk data, filters by type/age, same Keep/Remove flow | S |
| **Honest "freed" numbers + empty the trash** ✅ done | Moving to the Recycle Bin frees *nothing* until it is emptied; today we report it as freed | Report "moved to trash" separately; show system trash size and an "Empty trash" action (`trash::os_limited` on Windows/Linux, Finder on macOS); recovery-bin size and retention already exist | S |
| **"Not duplicates" / ignore list** ✅ done | Backups and intentional copies shouldn't reappear on every scan | Store ignored groups by content hash (+ folder rules) in the app data; filter in the session | S |
| **Saved results & cleanup history** ✅ done | Today results vanish when the app closes | Serialise the session to disk; history screen with "You've freed 12.4 GB" | M |
| **Export report** ✅ done | Share or audit before deleting | CSV / JSON (CLI already has JSON) / printable HTML | S |
| **More junk detected safely** ✅ done | Zero-byte files, broken shortcuts and symlinks, partial downloads (`.crdownload`, `.part`, `.tmp`), OS junk (`Thumbs.db`, `.DS_Store`) | Rule table in the engine, each rule with a safety level; shown as a "Junk" tab | S–M |

## Phase 2 — Storage overview (≈ 4–6 weeks)

| Feature | Why | How | Effort |
|---|---|---|---|
| **Storage dashboard** ✅ done | Answers "where did my space go?" before any cleanup | Per-drive used/free (`sysinfo`/`fs4` on desktop, `StatFs` on Android, `volumeAvailableCapacity` on iOS); breakdown by category; total reclaimable across all findings | M |
| **Space map (treemap / sunburst)** ✅ done | Big folders jump out visually; drill down by clicking | Analysis-only walk + `TreeStats`; squarified treemap drawn with `CustomPainter`; lazy child loading for huge trees | M |
| **Old & forgotten files** ✅ done | Downloads and installers pile up for years | Rules: not modified in N months, in Downloads/Desktop, installers (`.exe`, `.msi`, `.dmg`, `.apk`) whose app is installed | S–M |
| **One-tap recommendations** ✅ done | Most people want "what's safe to remove?" | Aggregate low-risk findings (exact duplicates in Downloads, junk, empty folders) into a reviewed checklist with total size | M |
| **Compress or move to external drive** ✅ done | Some data shouldn't be deleted, just moved off the main disk | Archive folders to `.zip`/`.7z` (verify, then remove originals into the recovery bin); "move to drive" reuses `MoveTo` with structure kept | M |

## Phase 3 — Photos and media (≈ 6–8 weeks)

Photos are the biggest storage hog on phones and the main reason people
install cleaners.

| Feature | Why | How | Effort |
|---|---|---|---|
| **Similar photos** (resized, re-saved, burst shots, WhatsApp copies) ✅ done | Exact hashing misses near-duplicates | Perceptual hash (dHash + pHash) per image in Rust (`image` + `image_hasher`), decoded from embedded EXIF thumbnails when available for speed; group with a BK-tree by Hamming distance; cache hashes like content hashes | L |
| **Best shot picker** ✅ done | Users don't want to compare 12 burst photos manually | Score by resolution, sharpness (Laplacian variance), file size, EXIF date; pre-select all but the best | M |
| **Blurry, dark and screenshot cleanup** ✅ done | Low-value photos nobody will miss | Sharpness/brightness metrics + screenshot detection (folder, aspect ratio, EXIF) | M |
| **Messaging media** ✅ done | WhatsApp/Telegram folders duplicate every forwarded file | Presets for known folders on Android/desktop | S |
| **iOS Photos library** ✅ done (Swift side needs a Mac to build and test) | iOS users' photos are not files, so today they can't be scanned | PhotoKit in Swift: stream asset data to the same hashing; delete through `PHAssetChangeRequest` (goes to "Recently Deleted", which doubles as undo) | L |
| **Similar videos / audio** ✅ done (pure Rust: soundtrack fingerprints, no FFmpeg) | Re-encoded copies | Frame sampling needs FFmpeg (heavy); audio fingerprinting (Chromaprint). Evaluate size/licensing first | L |

## Phase 4 — Keep it clean automatically (≈ 4–6 weeks)

| Feature | Why | How | Effort |
|---|---|---|---|
| **Scheduled scans + notifications** ✅ done | Storage fills up again | Desktop: launch-at-login tray icon with a background schedule; Android: `WorkManager` (charging + idle constraints); iOS: `BGProcessingTask`. The hash cache keeps rescans cheap | M–L |
| **Watch folders** ✅ done (download folders, while the app is open) | Catch new duplicates in Downloads as they arrive | `notify` crate on desktop; quick check of new files against the hash index | M |
| **Low-space alert** ✅ done | Warn before the disk is full | Free-space check on the schedule; notification links to recommendations | S |
| **Copy-on-write dedupe** (desktop) ✅ done | Keep both files, store the data once — safer than hard links | Reflinks via the `reflink-copy` crate: APFS (macOS), Btrfs/XFS (Linux), ReFS/Dev Drive (Windows). Offer next to "Replace with hard links" when the volume supports it | M |

## Phase 5 — Across devices and backups (≈ 4–6 weeks)

| Feature | Why | How | Effort |
|---|---|---|---|
| **"Is this already backed up?"** | Lets people delete from the phone with confidence | Export a hash index (paths + digests, no file contents) from one device, import on another, mark files that exist on both. Private: only hashes leave the device, and only via a file the user moves | M |
| **Folder compare / backup check** | "Which photos are missing from my backup?" | Content-based diff of two folder trees using the same engine: only in A, only in B, in both | M |
| **Network drives & NAS** | Large libraries live on NAS boxes | Already works with mapped paths; add a network-aware performance profile and resume-after-disconnect | S–M |

## Quality track (alongside every phase)

- **Localisation** (Flutter `intl` ARB files) and screen-reader labels on all controls.
- **CLI actions**: `digiclean clean --keep newest --to-trash` for power users and scripts.
- **Crash-safe sessions**: resume an interrupted scan from the cache.
- **Signed releases** on every platform (see `DEPLOYMENT.md`).
- **Privacy stays a feature**: no analytics or cloud by default; any future sync must be opt-in and end-to-end encrypted.

---

## Recommended order

1. **Phase 1**: small changes that fix real gaps (honest "freed" numbers, the ignore list, saved results) and add the most-requested tool (large files).
2. **Phase 2**: the dashboard and space map turn DigiClean from a single tool into a storage manager. The rest of the roadmap plugs into the "findings" model introduced here.
3. **Phase 3**: similar photos is the headline feature for mobile and the strongest reason to choose DigiClean over built-in tools.
4. **Phases 4–5** once the core is solid; scheduled scans depend on saved results, and backup checks reuse the hash index.

## Platform limits to design around

- **Android 11+** doesn't let apps clear other apps' caches or read `Android/data`. Link to the system storage screen (`ACTION_MANAGE_STORAGE`) instead of promising a "cache cleaner".
- **iOS**: only folders the user picks and, with permission, the Photos library. No system-wide junk cleaning is possible.
- **Desktop trash** keeps the space in use until it is emptied; the UI must say so.
- **macOS** asks the user before the app reads Desktop/Documents/Downloads. Request access per folder, and only ask for Full Disk Access with an explanation.
