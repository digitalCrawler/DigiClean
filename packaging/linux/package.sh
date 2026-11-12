#!/usr/bin/env bash
# Packages a Flutter Linux release build into:
#   dist/DigiClean-Linux-x86_64.AppImage   (runs on most distributions)
#   dist/digiclean_amd64.deb               (Debian, Ubuntu, Mint, …)
#   dist/DigiClean-Linux-x86_64.tar.gz     (plain archive)
#
# Usage:  packaging/linux/package.sh 1.2.0
# Run after `flutter build linux --release`. Needs dpkg-deb and curl.
set -euo pipefail

VERSION="${1:?usage: package.sh <version>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUNDLE="${BUNDLE:-$ROOT/build/linux/x64/release/bundle}"
DIST="${DIST:-$ROOT/dist}"
MAINTAINER="${MAINTAINER:-DigiClean Maintainers <maintainers@digiclean.invalid>}"
HERE="$ROOT/packaging/linux"

[[ -x "$BUNDLE/digiclean" ]] || { echo "no release bundle at $BUNDLE" >&2; exit 1; }
mkdir -p "$DIST"

# The background checker the systemd user timer runs while the app is closed.
cargo build --release --manifest-path "$ROOT/Cargo.toml" -p digiclean-cli --bin digiclean-check
install -m 755 "$ROOT/target/release/digiclean-check" "$BUNDLE/digiclean-check"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── tar.gz ───────────────────────────────────────────────────────────────
cp -a "$BUNDLE" "$WORK/DigiClean"
tar -C "$WORK" -czf "$DIST/DigiClean-Linux-x86_64.tar.gz" DigiClean
echo "created $DIST/DigiClean-Linux-x86_64.tar.gz"

# ── .deb ─────────────────────────────────────────────────────────────────
PKG="$WORK/deb"
install -d "$PKG/DEBIAN" "$PKG/opt/digiclean" "$PKG/usr/bin" \
  "$PKG/usr/share/applications" "$PKG/usr/share/icons/hicolor/512x512/apps"
cp -a "$BUNDLE/." "$PKG/opt/digiclean/"
ln -s /opt/digiclean/digiclean "$PKG/usr/bin/digiclean"
install -m644 "$HERE/digiclean.desktop" "$PKG/usr/share/applications/digiclean.desktop"
install -m644 "$HERE/digiclean.png" "$PKG/usr/share/icons/hicolor/512x512/apps/digiclean.png"
cat > "$PKG/DEBIAN/control" <<CONTROL
Package: digiclean
Version: $VERSION
Section: utils
Priority: optional
Architecture: amd64
Installed-Size: $(du -sk "$PKG/opt" | cut -f1)
Depends: libgtk-3-0, libglib2.0-0, libstdc++6
Recommends: zenity | kdialog
Maintainer: $MAINTAINER
Description: Find duplicate files and folders by their contents
 DigiClean finds exact duplicate files (also when renamed or moved) and
 duplicate folders using BLAKE3 or SHA-256 content hashes, and removes them
 safely: one copy is always kept and removed files go to the Trash.
CONTROL
dpkg-deb --build --root-owner-group "$PKG" "$DIST/digiclean_amd64.deb"
echo "created $DIST/digiclean_amd64.deb"

# ── AppImage ─────────────────────────────────────────────────────────────
APPDIR="$WORK/DigiClean.AppDir"
install -d "$APPDIR/usr/bin"
cp -a "$BUNDLE/." "$APPDIR/usr/bin/"
install -m644 "$HERE/digiclean.desktop" "$APPDIR/digiclean.desktop"
install -m644 "$HERE/digiclean.png" "$APPDIR/digiclean.png"
ln -s digiclean.png "$APPDIR/.DirIcon"
cat > "$APPDIR/AppRun" <<'APPRUN'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/bin/digiclean" "$@"
APPRUN
chmod +x "$APPDIR/AppRun"

TOOL="${APPIMAGETOOL:-$WORK/appimagetool}"
if [[ ! -x "$TOOL" ]]; then
  curl -fsSL -o "$TOOL" \
    https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
  chmod +x "$TOOL"
fi
# Extract-and-run avoids needing FUSE on build machines.
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 VERSION="$VERSION" \
  "$TOOL" --no-appstream "$APPDIR" "$DIST/DigiClean-Linux-x86_64.AppImage"
echo "created $DIST/DigiClean-Linux-x86_64.AppImage"
