#!/usr/bin/env bash
set -euo pipefail

# Downloads the pinned ExifTool into Pentimento/Resources/ExifTool, which the app bundles and runs
# with /usr/bin/perl. exiftool.org deletes old releases, so this uses the tag archive from the
# official GitHub mirror. To upgrade, change VERSION and SHA256 (shasum -a 256 of the archive).

VERSION="13.59"
SHA256="87d3317882fdae9cb4dcfe57a96a378d0132ffc02c731315bf128b19ddcf7aac"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT_DIR/Pentimento/Resources/ExifTool"

if [ -f "$DEST/exiftool" ] && grep -q "^my \$version = '$VERSION';" "$DEST/exiftool"; then
  exit 0
fi

echo "==> fetching ExifTool $VERSION"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/exiftool.tar.gz" "https://github.com/exiftool/exiftool/archive/refs/tags/$VERSION.tar.gz"
echo "$SHA256  $TMP/exiftool.tar.gz" | shasum -a 256 -c - >/dev/null

# The archive also holds tests, HTML docs and build tooling; the app needs only these.
SRC="exiftool-$VERSION"
tar -xzf "$TMP/exiftool.tar.gz" -C "$TMP" "$SRC/exiftool" "$SRC/lib" "$SRC/README"
rm -rf "$DEST"
mkdir -p "$DEST"
mv "$TMP/$SRC/exiftool" "$TMP/$SRC/lib" "$TMP/$SRC/README" "$DEST/"
