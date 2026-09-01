#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_DIR="$PROJECT_DIR/dist/Cadence.app"
CONTENTS_DIR="$APP_DIR/Contents"

cd "$PROJECT_DIR"
"$PROJECT_DIR/scripts/generate-icon.sh" >/dev/null
swift build -c release

if [[ "$APP_DIR" != "$PROJECT_DIR/dist/Cadence.app" ]]; then
  echo "Refusing to clean an unexpected app bundle path" >&2
  exit 1
fi
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources" "$CONTENTS_DIR/Frameworks"
cp ".build/release/Cadence" "$CONTENTS_DIR/MacOS/Cadence"
cp "Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "Resources/Cadence.icns" "$CONTENTS_DIR/Resources/Cadence.icns"

# A locally installed smoke-test build may share a bundle identifier and update
# preferences with an older published build. Give it a current numeric build
# number so Sparkle cannot silently replace uncommitted fixes with the existing
# Edge artifact. Distribution workflows configure their immutable version
# before invoking this script and opt out of this local-only stamp.
if [[ "${CADENCE_DISTRIBUTION_BUILD:-0}" != "1" ]]; then
  LOCAL_BUILD_NUMBER="$(date +%s)"
  LOCAL_SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CONTENTS_DIR/Info.plist")"
  LOCAL_REVISION="$(git -C "$PROJECT_DIR" rev-parse --short=7 HEAD)"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $LOCAL_BUILD_NUMBER" "$CONTENTS_DIR/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $LOCAL_SHORT_VERSION-local.$LOCAL_REVISION" "$CONTENTS_DIR/Info.plist"
fi

# FluidAudio includes TTS resources in its product even though Cadence uses ASR
# only. Keep the dependency bundle in the conventional sealed resource folder;
# macOS code signing rejects arbitrary content at the .app bundle root.
FLUID_AUDIO_RESOURCES="$PROJECT_DIR/.build/release/FluidAudio_FluidAudio.bundle"
if [[ ! -d "$FLUID_AUDIO_RESOURCES" ]]; then
  echo "FluidAudio resource bundle was not produced by Swift Package Manager" >&2
  exit 1
fi
ditto "$FLUID_AUDIO_RESOURCES" "$CONTENTS_DIR/Resources/FluidAudio_FluidAudio.bundle"

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

# SwiftPM may embed its local SDK/framework search directory as an absolute
# fallback rpath. The application bundle must not depend on a build machine.
while IFS= read -r RPATH; do
  if [[ "$RPATH" == /* ]]; then
    install_name_tool -delete_rpath "$RPATH" "$CONTENTS_DIR/MacOS/Cadence"
  fi
done < <(otool -l "$CONTENTS_DIR/MacOS/Cadence" | awk '/cmd LC_RPATH/{getline; getline; print $2}')

# macOS privacy grants (Accessibility, Microphone) are keyed to the signing
# identity. An ad-hoc signature's identity is the binary's own hash, so every
# rebuild or update silently revoked them. Sign with the Cadence certificate
# when it is present; contributors without it still get a runnable ad-hoc build.
IDENTITY="${CADENCE_SIGNING_IDENTITY:-Cadence Signing}"
if security find-identity -v -p codesigning | grep -Fq "\"$IDENTITY\""; then
  codesign --force --deep --sign "$IDENTITY" "$APP_DIR"
else
  echo "Signing identity '$IDENTITY' not found; using an ad-hoc signature" >&2
  codesign --force --deep --sign - "$APP_DIR"
fi
echo "$APP_DIR"
