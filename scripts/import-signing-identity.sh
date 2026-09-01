#!/bin/zsh
# Imports the Cadence code-signing identity into a temporary keychain on CI so
# build-app.sh can sign with it. Expects two repository secrets:
#   CADENCE_SIGNING_P12           base64-encoded PKCS#12 export of the identity
#   CADENCE_SIGNING_P12_PASSWORD  the export password
set -euo pipefail

if [[ -z "${CADENCE_SIGNING_P12:-}" || -z "${CADENCE_SIGNING_P12_PASSWORD:-}" ]]; then
  echo "CADENCE_SIGNING_P12 and CADENCE_SIGNING_P12_PASSWORD must be set" >&2
  exit 1
fi

WORK_DIR="${RUNNER_TEMP:-$(mktemp -d)}"
KEYCHAIN="$WORK_DIR/cadence-signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"
P12="$WORK_DIR/cadence-signing.p12"
CERT="$WORK_DIR/cadence-signing.pem"

printf '%s' "$CADENCE_SIGNING_P12" | base64 --decode > "$P12"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" -P "$CADENCE_SIGNING_P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

# A self-signed certificate is only a usable identity once it is trusted for
# code signing. The runner's passwordless sudo lets us set that system-wide.
openssl pkcs12 -in "$P12" -clcerts -nokeys -passin "pass:$CADENCE_SIGNING_P12_PASSWORD" -out "$CERT"
sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain "$CERT"
rm -f "$P12" "$CERT"

security find-identity -v -p codesigning "$KEYCHAIN" | grep -Fq '"Cadence Signing"'
echo "Imported the Cadence Signing identity"
