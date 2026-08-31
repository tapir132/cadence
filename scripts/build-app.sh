#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_DIR="$PROJECT_DIR/dist/Cadence.app"
CONTENTS_DIR="$APP_DIR/Contents"

cd "$PROJECT_DIR"
"$PROJECT_DIR/scripts/generate-icon.sh" >/dev/null
swift build -c release

mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources" "$CONTENTS_DIR/Frameworks"
cp ".build/release/Cadence" "$CONTENTS_DIR/MacOS/Cadence"
cp "Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "Resources/Cadence.icns" "$CONTENTS_DIR/Resources/Cadence.icns"

SPARKLE_FRAMEWORK="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  echo "Sparkle.framework was not resolved by Swift Package Manager" >&2
  exit 1
fi
rm -rf "$CONTENTS_DIR/Frameworks/Sparkle.framework"
ditto "$SPARKLE_FRAMEWORK" "$CONTENTS_DIR/Frameworks/Sparkle.framework"

# SwiftPM links Sparkle with @rpath but its command-line executable does not
# know the conventional app-bundle Frameworks location until we add it.
if ! otool -l "$CONTENTS_DIR/MacOS/Cadence" | grep -q '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath '@executable_path/../Frameworks' "$CONTENTS_DIR/MacOS/Cadence"
fi

codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
