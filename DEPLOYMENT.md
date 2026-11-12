# Deploying DigiClean with CI/CD

DigiClean is built, tested and published entirely by GitHub Actions. You push
code; the pipeline does the rest:

```
push / pull request ──► CI            tests + static analysis (every change)
push tag v1.2.0     ──► Release       builds Windows, macOS, Linux
                                      ─► tests the Windows installer
                                      ─► publishes a GitHub Release
push to main        ──► DigiDeploy    landing page (website/), redeployed
                        (or Vercel)   download buttons → latest release
```

| Workflow | File | Trigger | Result |
|---|---|---|---|
| **CI** | `.github/workflows/ci.yml` | every push to `main`, every pull request | Rust engine tests + clippy on Windows, macOS, Linux; `flutter analyze` + `flutter test` |
| **Release** | `.github/workflows/release.yml` | pushing a tag `v*` (or manual run → draft) | installers and packages for every desktop platform, attached to a GitHub Release |

The landing page is not built by GitHub Actions: a web host (DigiDeploy or
Vercel, see [1.4](#14-the-website)) builds it from `website/`.

macOS and Linux apps cannot be built on Windows (and vice versa), which is
why releases are built by CI on each platform's own runner.

## What a release contains

| File | For |
|---|---|
| `DigiClean-Windows-Setup.exe` | Windows 10/11 installer (see [Windows installer](#the-windows-installer)) |
| `DigiClean-Windows-Portable.zip` | Windows without installing: unzip and run |
| `DigiClean-macOS.dmg` | macOS 10.15+, universal (Apple silicon + Intel) |
| `DigiClean-Linux-x86_64.AppImage` | most Linux distributions |
| `digiclean_amd64.deb` | Debian, Ubuntu, Mint |
| `DigiClean-Linux-x86_64.tar.gz` | any distribution, plain archive |
| `SHA256SUMS.txt` | checksums of all of the above |

The website links to `https://github.com/<owner>/<repo>/releases/latest/download/<file>`,
so it always serves the newest release. **Keep these file names unchanged.**

---

## 1. One-time setup

### 1.1 Put the project on GitHub

```bash
git init
git add .
git commit -m "DigiClean 1.0.0"
git branch -M main
git remote add origin https://github.com/<owner>/<repo>.git
git push -u origin main
```

The CI workflow runs on this first push. Check **Actions → CI** is green.

### 1.2 Repository settings

* **Settings → Actions → General → Workflow permissions**: the workflows
  declare the permissions they need (`contents: write` for releases,
  `pages: write` for the website), so the default "read" setting is fine.
* **Settings → Secrets and variables → Actions → Variables** (optional):
  `DIGICLEAN_PUBLISHER` — the publisher name shown in Windows Settings › Apps
  and in the installer. Defaults to the repository owner.
* **Branch protection** (recommended): Settings → Branches → add a rule for
  `main` requiring the **CI** checks to pass before merging.

### 1.3 Code signing (recommended)

Without signing, Windows SmartScreen shows "Windows protected your PC" and
macOS refuses to open the app until the user allows it in System Settings.
The pipeline signs automatically when these **secrets** exist
(Settings → Secrets and variables → Actions → Secrets):

| Secret | What it is |
|---|---|
| `WINDOWS_CERT_PFX_BASE64` | Authenticode code-signing certificate (`.pfx`), base64 |
| `WINDOWS_CERT_PASSWORD` | its password |
| `MACOS_CERT_P12_BASE64` | "Developer ID Application" certificate exported as `.p12`, base64 |
| `MACOS_CERT_PASSWORD` | its password |
| `MACOS_SIGN_IDENTITY` | e.g. `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | notarization (app-specific password from appleid.apple.com) |

Base64-encode a certificate file:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("cert.pfx")) | Set-Clipboard   # Windows
```
```bash
base64 -i cert.p12 | pbcopy                                                       # macOS
```

On Windows the app, its engine DLL, the background checker, the installer
**and the uninstaller** are signed. A Developer ID certificate requires the
Apple Developer Program.

### 1.4 The website

The landing page is a static site in `website/`. Its build,
`website/vercel-build.sh`, copies it to `website/public/` and fills in the
GitHub repository the download buttons point at. Pick **one** host.

**DigiDeploy** (current host): create a project from the GitHub repository
with these settings:

| Setting | Value |
|---|---|
| Runtime mode | **Static** |
| Build command | `cd website && sh vercel-build.sh` |
| Output directory | `website/public` |
| Start command | *(empty)* |
| Environment | `DIGICLEAN_REPO` = `owner/repo` (a pasted `https://github.com/owner/repo` works too); optional `SITE_URL` = `https://your-domain` for link previews |

If the project was detected as another type (Rust, Flutter), the Runtime mode
setting is what matters: with **Static** nothing is started; the files are
served. Turn on *Deploy automatically on push* to redeploy after each push.

**Vercel**: import the repository in Vercel and set **Root Directory** to
`website`; everything else comes from `website/vercel.json`. Download
buttons point at the connected GitHub repository automatically (set
`DIGICLEAN_REPO=owner/repo` when deploying with the Vercel CLI). Add a domain
under Domains; set `SITE_URL` if link previews should use a different one.

Either way the website needs no redeploy per release: links point at the
latest release and the version number is read from GitHub in the browser.

---

## 2. Everyday development

1. Work on a branch and open a pull request.
2. **CI** runs the engine tests on all three operating systems and the
   Flutter analyzer and tests. Merge when it is green.
3. Changes to `website/` reach the landing page on the next website deploy.

Run the same checks locally before pushing:

```bash
cargo test -p digiclean_engine
cargo clippy --workspace --all-targets -- -D warnings
flutter analyze
flutter test
flutter test integration_test/app_test.dart -d windows   # end-to-end, on a desktop
```

## 3. Publishing a release

1. Update `version:` in `pubspec.yaml` (e.g. `1.1.0+2`) and commit.
2. Tag the commit and push the tag:
   ```bash
   git tag v1.1.0
   git push origin v1.1.0
   ```
3. **Release** (about 20–30 minutes):
   * builds Windows, macOS and Linux in parallel, each with the background
     checker (`digiclean-check`) bundled;
   * signs everything when the secrets are set;
   * **installs the Windows installer, checks it and uninstalls it** — once
     "for me only" and once "for all users" (see below); the release stops
     if anything is wrong;
   * creates the GitHub Release with all files, checksums and generated
     release notes.
4. Done. The website's download buttons already point at it.

**Dry run:** Actions → **Release** → **Run workflow**, enter a version. This
creates a **draft** release you can inspect and delete without anyone
seeing it.

**Fixing a bad release:** delete the release and the tag on GitHub
(`git push --delete origin v1.1.0`), fix, and tag again. Or publish a new
patch version — users of the website always get the latest.

---

## The Windows installer

`DigiClean-Windows-Setup.exe` is built with Inno Setup from
`packaging/windows/digiclean.iss`. It behaves like any professionally
installed Windows application.

**What the user sees**

1. **Install mode**: *Install for all users (recommended)* — requires
   administrator rights (Windows asks via UAC) and installs to
   `C:\Program Files\DigiClean` — or *Install for me only*, which needs no
   administrator rights and installs to `%LOCALAPPDATA%\Programs\DigiClean`.
2. Welcome, destination folder, and **Create a desktop shortcut** (ticked).
3. Install, then *Launch DigiClean* (ticked).

**What it sets up**

* **Start menu** entry *DigiClean* (searchable from Start), for everyone or
  just the user depending on the install mode.
* **Desktop shortcut**, if ticked.
* **Settings › Apps › Installed apps** (and Programs and Features) entry with
  name, version, publisher, size, icon and links to the project, releases
  and issues; *Uninstall* works from there.
* Upgrades: running a newer installer updates in place (same install mode
  and folder; a running DigiClean is closed first).
* Uninstall removes the program, the shortcuts and the optional daily
  background check. The user's settings and Recovery Bin are kept.

**Silent installation (IT, scripts)**

```powershell
DigiClean-Windows-Setup.exe /VERYSILENT /ALLUSERS                     # all users (elevated)
DigiClean-Windows-Setup.exe /VERYSILENT /CURRENTUSER                  # current user only
DigiClean-Windows-Setup.exe /VERYSILENT /ALLUSERS /TASKS=""           # without desktop shortcut
DigiClean-Windows-Setup.exe /VERYSILENT /ALLUSERS /DIR="D:\Apps\DigiClean" /LOG="setup.log"
"C:\Program Files\DigiClean\unins000.exe" /VERYSILENT                 # uninstall
```

**Testing it locally** (needs [Inno Setup 6](https://jrsoftware.org/isinfo.php),
e.g. `winget install JRSoftware.InnoSetup`):

```powershell
flutter build windows --release --build-name=1.1.0
./packaging/windows/package.ps1 -Version 1.1.0 -Url https://github.com/<owner>/<repo> -Publisher "Your Name"
./packaging/windows/test-installer.ps1 -Version 1.1.0              # per-user install, checks, uninstall
./packaging/windows/test-installer.ps1 -Version 1.1.0 -AllUsers    # from an elevated PowerShell
```

`test-installer.ps1` installs silently, verifies the program files, Start
menu entry, desktop shortcut and the Apps entry (name, version, publisher,
icon, size), uninstalls, and verifies everything is gone. CI runs the same
script.

---

## Building packages locally

Each platform's packages must be built on that platform. Start from a clean
build so no stale files end up in the package. Outputs go to `dist/`.

**Windows** (PowerShell; Inno Setup 6 for the installer):
```powershell
flutter clean
flutter build windows --release --build-name=1.1.0
./packaging/windows/package.ps1 -Version 1.1.0
```

**macOS:**
```bash
flutter build macos --release --build-name=1.1.0
packaging/macos/package.sh 1.1.0
```

**Linux** (needs `dpkg-deb` and `curl`):
```bash
flutter build linux --release --build-name=1.1.0
packaging/linux/package.sh 1.1.0
```

All three build and bundle `digiclean-check`, the small windowless program
the system scheduler runs once a day when "Check in the background" is on
(`cargo build --release -p digiclean-cli --bin digiclean-check`).

## Previewing the website locally

```bash
python -m http.server 8080 --bind 127.0.0.1 --directory website
```

Open http://127.0.0.1:8080/. Download buttons show a "preview" note until
the site is deployed from the repository.

## Refreshing artwork

* Brand source: `branding/brand-sheet.png` (navy `#112F47`, mint `#6FD8B0`,
  Outfit typeface). `python tools/brand_assets.py` (Pillow) rebuilds every
  app icon, the in-app logo, the website favicons and the link-preview image.
* Landing-page screenshots (Windows):
  ```bash
  flutter test integration_test/marketing_shots.dart -d windows \
    --dart-define=SHOTS=website/assets --dart-define=DEMO=build/demo
  ```

## Troubleshooting

| Problem | Fix |
|---|---|
| "Windows protected your PC" on the installer | Expected without a signing certificate: *More info → Run anyway*. Add the Windows signing secrets (1.3). |
| macOS: "DigiClean can't be opened" | Unsigned build: right-click → Open, or System Settings › Privacy & Security → Open Anyway. Add the Apple secrets (1.3). |
| Release job fails at **Test the installer** | Read the step log: each failing check is listed (e.g. a missing shortcut). `setup.log` is in the runner's `%TEMP%`. Reproduce with `test-installer.ps1` locally. |
| `Inno Setup (ISCC) not found` locally | `winget install JRSoftware.InnoSetup`; the release workflow installs it itself. |
| Website download buttons say "preview" | The site was built without the repository name: set `DIGICLEAN_REPO` (`owner/repo`) on the web host and redeploy. |
| Download link looks like `github.com/https://github.com/…` | Built with an old `vercel-build.sh`; current versions accept a full URL in `DIGICLEAN_REPO`. Or set it to `owner/repo`. |
| A CI job is "cancelled" in seconds with "configuration … is not supported" | GitHub retired that runner image. Change `runs-on` to a current label from [actions/runner-images](https://github.com/actions/runner-images#available-images). |
| Download links give 404 | No release published yet (or a file was renamed). Publish a release (section 3). |
| Users see an old version | Browsers cache the page for a few minutes; the links always resolve to the latest release on GitHub's side. |

## Notes

* **macOS sandbox is off** (`macos/Runner/Release.entitlements`) because
  the app is distributed directly and must read whatever folders the user
  scans. A Mac App Store build would need the sandbox plus security-scoped
  bookmarks.
* **Windows** packages include the Microsoft C++ runtime DLLs next to the
  executable, so the app starts on PCs without the VC++ Redistributable.
* **Linux** builds run on Ubuntu 22.04, so they work on distributions with
  glibc 2.35 or newer. The folder picker uses `zenity` or `kdialog`.
* **Mobile** (Android, iOS) is not part of this pipeline: store releases need
  signing keys, store accounts and review. See README › Release checklist.
