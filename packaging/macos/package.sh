#!/usr/bin/env bash
# Packages a Flutter macOS release build into dist/DigiClean-macOS.dmg.
#
# Usage:  packaging/macos/package.sh 1.2.0
# Run after `flutter build macos --release` (a universal arm64 + x86_64 app).
#
# Signing and notarization are optional but strongly recommended; without
# them Gatekeeper blocks the first launch. Set:
#   MACOS_SIGN_IDENTITY   e.g. "Developer ID Application: Your Name (TEAMID)"
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD   (app-specific password)
set -euo pipefail

VERSION="${1:?usage: package.sh <version>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="${APP:-$ROOT/build/macos/Build/Products/Release/DigiClean.app}"
DIST="${DIST:-$ROOT/dist}"
DMG="$DIST/DigiClean-macOS.dmg"

[[ -d "$APP" ]] || { echo "no release app at $APP" >&2; exit 1; }
mkdir -p "$DIST"

# The background checker the LaunchAgent runs while the app is closed;
# universal when both Rust targets are installed.
CHECK="$APP/Contents/MacOS/digiclean-check"
if rustup target list --installed | grep -q x86_64-apple-darwin && rustup target list --installed | grep -q aarch64-apple-darwin; then
  for t in aarch64-apple-darwin x86_64-apple-darwin; do
    cargo build --release --manifest-path "$ROOT/Cargo.toml" -p digiclean-cli --bin digiclean-check --target "$t"
  done
  lipo -create -output "$CHECK" \
    "$ROOT/target/aarch64-apple-darwin/release/digiclean-check" \
    "$ROOT/target/x86_64-apple-darwin/release/digiclean-check"
else
  cargo build --release --manifest-path "$ROOT/Cargo.toml" -p digiclean-cli --bin digiclean-check
  cp "$ROOT/target/release/digiclean-check" "$CHECK"
fi
chmod 755 "$CHECK"

if [[ -n "${MACOS_SIGN_IDENTITY:-}" ]]; then
  # Hardened runtime + secure timestamp are required for notarization.
  codesign --force --deep --options runtime --timestamp \
    --entitlements "$ROOT/macos/Runner/Release.entitlements" \
    --sign "$MACOS_SIGN_IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  echo "warning: MACOS_SIGN_IDENTITY not set - the app is only ad-hoc signed" >&2
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "DigiClean $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

if [[ -n "${MACOS_SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$MACOS_SIGN_IDENTITY" "$DMG"
  if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
    xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
      --password "$APPLE_APP_PASSWORD" --wait
    xcrun stapler staple "$DMG"
  else
    echo "warning: notarization credentials not set - skipping notarization" >&2
  fi
fi
echo "created $DMG"
