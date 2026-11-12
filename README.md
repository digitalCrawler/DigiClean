# DigiClean

Cross-platform duplicate file & folder finder for **Windows, Linux, macOS,
Android and iOS**. Files are compared by their *contents* — renamed and
moved copies are found — using BLAKE3 or SHA-256, and whole folders are
compared by structure and contents.

* Flutter UI (Material 3, phone/tablet/desktop layouts) over a Rust engine
  shared by every platform via [flutter_rust_bridge](https://cjycode.com/flutter_rust_bridge/).
* Staged detection: size → sampled fingerprint → full hash → optional
  byte-by-byte check; duplicate folders via Merkle hashes; empty folders.
* Persistent hash cache: rescans only read files that changed.
* Safe cleanup: one copy is always kept, items are re-verified before
  removal, Recycle Bin/Trash or a recovery bin with undo, move, hard links.
  Space is reported honestly: items in a bin count as freed only once the
  bin is emptied, which the app can do.
* Large files list, and a "Not duplicates" list matched by content so
  backups you keep stay hidden in later scans.
* Results are saved and reopened after a restart; a cleanup history shows
  how much space was really freed.
* Junk finder (caches, unfinished downloads, leftover temp files, empty
  files, broken shortcuts) and reports as CSV, JSON or a printable page.
* Storage overview: drives and free space, what uses space by type, a
  space map to drill into folders, old files, one-tap recommended cleanup,
  and compress-to-zip or move-to-another-drive for data you want to keep.
* Similar photos (resized, re-saved, burst and messaging copies) with the
  best shot suggested, plus blurry, dark and screenshot images to review;
  songs and videos that sound the same; the iPhone Photos library on iOS.
* Keeps itself clean: low-space warnings, new duplicate downloads, scheduled
  rescans, a daily background check with notifications (desktop, Android,
  iOS) and copy-on-write clones where the drive supports them.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design.

## Repository layout

```
crates/engine/   Rust engine (scan pipeline, cache, selection, actions, recovery bin)
crates/cli/      `digiclean` command-line tool on the same engine
rust/            flutter_rust_bridge API crate (DTOs + thin wrappers)
rust_builder/    cargokit plugin that builds the Rust crate for each platform
lib/             Flutter app
android/ ios/ linux/ macos/ windows/   platform runners (+ native channel code)
```

## Prerequisites

* Flutter 3.41+ (Dart 3.11)
* Rust 1.82+ (`rustup`), plus targets for mobile:
  * Android: `rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android i686-linux-android`
    and the Android NDK (installed through Android Studio's SDK Manager).
  * iOS: `rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios` (macOS + Xcode).
* Windows: Visual Studio with "Desktop development with C++".
* Linux: `clang cmake ninja-build pkg-config libgtk-3-dev`; for folder
  picking `zenity` or `kdialog`.

The Rust crate is compiled automatically by `flutter build` / `flutter run`
(cargokit). Nothing else to install.

## Build & run

```bash
flutter pub get
flutter run -d windows          # or linux, macos, <android device>, <ios device>
flutter build windows --release
flutter build apk --release     # Android (or appbundle)
flutter build ios --release     # on macOS
flutter build linux --release
```

After changing anything in `rust/src/api/`, regenerate the bindings:

```bash
cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked   # once
flutter_rust_bridge_codegen generate
```

## Tests

```bash
cargo test -p digiclean_engine     # engine unit + end-to-end tests (real files)
cargo clippy --workspace
flutter analyze
flutter test                       # Dart unit tests
```

## Command-line tool

```bash
cargo build --release -p digiclean-cli
target/release/digiclean scan ~/Pictures ~/Downloads --min-size 100K --cache ~/.cache/digiclean
target/release/digiclean scan D:\Backup --json > duplicates.json
target/release/digiclean scan /data --algo sha256 --verify --performance hdd
target/release/digiclean scan ~/Downloads --export report.html   # or .csv / .json
```

The CLI only reports; it never modifies files.

## Platform notes

* **Android 11+** requires "All files access" (`MANAGE_EXTERNAL_STORAGE`)
  to scan and delete files in shared storage. The app explains this on first
  launch and links to the system setting. For Google Play distribution,
  declare the *file management* use case in the Play Console permission
  declaration. `Android/data` and `Android/obb` are not accessible on
  Android 11+ and are skipped. Removed files go to a recovery bin inside
  the app's directory on the same volume (instant move, survives until
  emptied or the retention period passes). Long scans run in a foreground
  service with a progress notification.
* **iOS** apps are sandboxed: add folders via the Files picker (On My
  iPhone, iCloud Drive, external drives, third-party providers). Access is
  remembered with security-scoped bookmarks. Files you put in
  *On My iPhone › DigiClean* are scannable too. The Photos library is not
  file-based and is not scanned.
* **Windows**: online-only OneDrive/Dropbox files are skipped by default so
  scans never trigger downloads. Removal uses the Recycle Bin.
* **Linux/macOS**: removal uses the freedesktop Trash / macOS Trash.

## Releases and website

Windows, macOS and Linux packages (installer, DMG, AppImage, .deb) are built
by GitHub Actions when a `v*` tag is pushed, and the landing page in
`website/` is deployed to GitHub Pages. See [DEPLOYMENT.md](DEPLOYMENT.md) for the CI/CD pipeline, the Windows installer and how to publish a release.

## Release checklist

* Set a real application id / bundle id (`com.digiclean.digiclean` is a placeholder)
  and signing configs (`android/app/build.gradle.kts`, Xcode).
* Android: complete the Play Console declaration for `MANAGE_EXTERNAL_STORAGE`.
