#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SIGN_DIR="$ROOT/signing"
KEYCHAIN="$SIGN_DIR/TeamsMicFloat-Signing.keychain-db"
IDENTITY="Teams Mic Float Local Signing"
PASSWORD_FILE="$SIGN_DIR/keychain-password"

mkdir -p "$SIGN_DIR"
chmod 700 "$SIGN_DIR"

if [[ -f "$KEYCHAIN" && -f "$PASSWORD_FILE" ]]; then
    PASS="$(cat "$PASSWORD_FILE")"
    security unlock-keychain -p "$PASS" "$KEYCHAIN" >/dev/null 2>&1 || true
    if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
        echo "Signing identity already present: $IDENTITY"
        exit 0
    fi
fi

if ! command -v openssl >/dev/null 2>&1; then
    echo "openssl is required to create the local signing identity." >&2
    exit 1
fi

PASS="$(openssl rand -base64 24 | tr -d '\n')"
printf '%s' "$PASS" >"$PASSWORD_FILE"
chmod 600 "$PASSWORD_FILE"

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$SIGN_DIR/identity.key" \
    -out "$SIGN_DIR/identity.crt" \
    -subj '/CN=Teams Mic Float Local Signing/O=Teams Mic Float/C=ZA' \
    -addext 'basicConstraints=critical,CA:false' \
    -addext 'keyUsage=critical,digitalSignature' \
    -addext 'extendedKeyUsage=critical,codeSigning' >/dev/null 2>&1
chmod 600 "$SIGN_DIR/identity.key"

openssl pkcs12 -export \
    -out "$SIGN_DIR/identity.p12" \
    -inkey "$SIGN_DIR/identity.key" \
    -in "$SIGN_DIR/identity.crt" \
    -name "$IDENTITY" \
    -passout "pass:$PASS" >/dev/null 2>&1
chmod 600 "$SIGN_DIR/identity.p12"

if [[ ! -f "$KEYCHAIN" ]]; then
    security create-keychain -p "$PASS" "$KEYCHAIN"
fi
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$PASS" "$KEYCHAIN"
security import "$SIGN_DIR/identity.p12" \
    -k "$KEYCHAIN" -P "$PASS" \
    -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list \
    -S apple-tool:,apple: -s -k "$PASS" "$KEYCHAIN" >/dev/null

# Trust is needed for macOS to treat the certificate as a stable code identity
# instead of falling back to a per-build hash.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$SIGN_DIR/identity.crt"

echo "Created local signing identity: $IDENTITY"
security find-identity -v -p codesigning "$KEYCHAIN"
