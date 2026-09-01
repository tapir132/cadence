#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_PATH="${1:-$PROJECT_DIR/dist/Cadence.app}"
OUTPUT_PATH="${2:-$PROJECT_DIR/release/installers/Cadence.dmg}"

if [[ ! -d "$APP_PATH" || "${APP_PATH:t}" != "Cadence.app" ]]; then
  echo "Cadence.app was not found at $APP_PATH" >&2
  exit 1
fi
if [[ "${OUTPUT_PATH:e:l}" != "dmg" ]]; then
  echo "The output path must end in .dmg" >&2
  exit 1
fi

IDENTITY="${CADENCE_DMG_SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
    | head -n 1)"
fi
if [[ -n "$IDENTITY" && "$IDENTITY" != "Developer ID Application:"* ]]; then
  echo "CADENCE_DMG_SIGNING_IDENTITY must name a Developer ID Application identity" >&2
  exit 1
fi
if [[ -n "$IDENTITY" ]] \
   && ! security find-identity -v -p codesigning | grep -Fq "\"$IDENTITY\""; then
  echo "Disk-image signing identity '$IDENTITY' was not found" >&2
  exit 1
fi

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cadence-dmg.XXXXXX")"
cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

mkdir -p "${OUTPUT_PATH:h}"
ditto "$APP_PATH" "$STAGING_DIR/Cadence.app"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$OUTPUT_PATH"
hdiutil create \
  -volname "Cadence" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -ov \
  "$OUTPUT_PATH" >/dev/null

if [[ -n "$IDENTITY" ]]; then
  codesign \
    --force \
    --timestamp \
    --sign "$IDENTITY" \
    --identifier "app.cadence.mac.disk-image" \
    "$OUTPUT_PATH"
else
  # Apple only supports Developer ID Application identities for distributed
  # disk-image signatures. Cadence's self-signed app identity preserves local
  # privacy grants but is not a valid DMG distribution identity, so leave the
  # container unsigned until the project has Developer ID + notarization.
  echo "No Developer ID Application identity found; leaving the DMG unsigned" >&2
fi

echo "$OUTPUT_PATH"
