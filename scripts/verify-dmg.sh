#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 || "${1:e:l}" != "dmg" || ! -f "$1" ]]; then
  echo "usage: $0 path/to/Cadence.dmg" >&2
  exit 2
fi

DMG_PATH="${1:A}"
MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cadence-dmg-verify.XXXXXX")"
MOUNTED=0
cleanup() {
  if [[ "$MOUNTED" == "1" ]]; then
    hdiutil detach "$MOUNT_DIR" -quiet || true
  fi
  rmdir "$MOUNT_DIR" 2>/dev/null || true
}
trap cleanup EXIT

hdiutil verify "$DMG_PATH" >/dev/null
if SIGNATURE_DETAILS="$(codesign -dvv "$DMG_PATH" 2>&1)"; then
  if [[ "$SIGNATURE_DETAILS" != *"Authority=Developer ID Application:"* ]]; then
    echo "DMG is signed, but not with a Developer ID Application identity" >&2
    exit 1
  fi
  codesign --verify --strict "$DMG_PATH"
else
  echo "DMG has no Developer ID signature; verifying its contents only" >&2
fi
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_DIR" "$DMG_PATH" >/dev/null
MOUNTED=1

[[ -d "$MOUNT_DIR/Cadence.app" ]]
[[ -L "$MOUNT_DIR/Applications" ]]
[[ "$(readlink "$MOUNT_DIR/Applications")" == "/Applications" ]]
plutil -lint "$MOUNT_DIR/Cadence.app/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict "$MOUNT_DIR/Cadence.app"

echo "Verified Cadence.app and the Applications shortcut in $DMG_PATH"
