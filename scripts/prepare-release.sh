#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 || ! "$1" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  echo "usage: $0 X.Y.Z" >&2
  exit 2
fi

VERSION="$1"
PROJECT_DIR="${0:A:h:h}"
RELEASE_DIR="$PROJECT_DIR/release"
INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"
SPARKLE_BIN="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin"

BUILD_NUMBER="$(git -C "$PROJECT_DIR" show -s --format=%ct HEAD)"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFO_PLIST"

"$PROJECT_DIR/scripts/build-app.sh"
mkdir -p "$RELEASE_DIR"

ARCHIVE="$RELEASE_DIR/Cadence-$VERSION.zip"
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$PROJECT_DIR/dist/Cadence.app" "$ARCHIVE"

"$SPARKLE_BIN/generate_appcast" \
  --account app.cadence.updates \
  --download-url-prefix "https://github.com/tapir132/whisper-live/releases/download/v$VERSION/" \
  --maximum-versions 5 \
  --maximum-deltas 4 \
  --delta-compression lzfse \
  -o appcast.xml \
  "$RELEASE_DIR"

echo "Prepared signed update artifacts in $RELEASE_DIR"
echo "No files were uploaded. Review them before creating GitHub release v$VERSION."
