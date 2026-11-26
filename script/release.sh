#!/usr/bin/env bash
set -euo pipefail

# Builds a universal, ad-hoc signed Pentimento.app and wraps it in dist/Pentimento-<version>.dmg.
#
# Required env:
#   PENTIMENTO_VERSION    human version, e.g. 0.1.0 (CFBundleShortVersionString)
# Optional env:
#   PENTIMENTO_BUILD      CFBundleVersion (monotonic). Default: git commit count.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

: "${PENTIMENTO_VERSION:?set PENTIMENTO_VERSION, e.g. 0.1.0}"

APP_NAME="Pentimento"
VERSION="$PENTIMENTO_VERSION"
BUILD="${PENTIMENTO_BUILD:-$(git rev-list --count HEAD)}"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
DMG_PATH="$ROOT_DIR/dist/$APP_NAME-$VERSION.dmg"

echo "==> building $APP_NAME $VERSION ($BUILD)"
make dist XCODEBUILD_FLAGS="MARKETING_VERSION=$VERSION CURRENT_PROJECT_VERSION=$BUILD"

# Unsigned Apple Silicon binaries are killed at launch, so sign ad-hoc. Users still need to clear
# quarantine (the Homebrew cask does it) because the app isn't notarized.
echo "==> signing app (ad-hoc)"
codesign --force --sign - "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "==> building $DMG_PATH"
STAGE="$(mktemp -d)"
cp -R "$APP_BUNDLE" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$STAGE"

SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
echo "==> done"
echo "    DMG:    $DMG_PATH"
echo "    SHA256: $SHA"
