#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/dist/TeamsMicFloat.app"
BINARY="$ROOT/.build/release/TeamsMicFloat"

echo "Building release binary…"
swift build -c release --disable-sandbox

if [[ ! -x "$BINARY" ]]; then
    echo "Build succeeded but the binary was not found at $BINARY" >&2
    exit 1
fi

echo "Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/TeamsMicFloat"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Teams Mic Float</string>
    <key>CFBundleExecutable</key>
    <string>TeamsMicFloat</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.teamsmicfloat</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Teams Mic Float</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Use the stable local identity when available. Ad-hoc signing gives macOS a
# per-build hash as the designated requirement, which invalidates the macOS 27
# Device Control permission after every rebuild.
SIGN_DIR="$ROOT/signing"
KEYCHAIN="$SIGN_DIR/TeamsMicFloat-Signing.keychain-db"
PASSWORD_FILE="$SIGN_DIR/keychain-password"
IDENTITY="Teams Mic Float Local Signing"

if [[ -f "$KEYCHAIN" && -f "$PASSWORD_FILE" ]] && command -v codesign >/dev/null 2>&1; then
    PASS="$(cat "$PASSWORD_FILE")"
    security unlock-keychain -p "$PASS" "$KEYCHAIN" >/dev/null
    if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
        codesign --force --deep --sign "$IDENTITY" --keychain "$KEYCHAIN" "$APP"
        codesign --verify --deep --strict "$APP"
        echo "Signed with stable local identity: $IDENTITY"
    else
        echo "Signing keychain exists but the local identity is missing." >&2
        echo "Run: ./scripts/setup_signing.sh" >&2
        exit 1
    fi
else
    echo "Warning: no local signing identity found; using ad-hoc signing." >&2
    echo "The macOS permission must be granted again after each rebuild." >&2
    echo "Run ./scripts/setup_signing.sh first to avoid that." >&2
    codesign --force --deep --sign - "$APP"
fi

echo ""
echo "Built: $APP"
echo "Launch: open \"$APP\""
echo "Debug: \"$APP/Contents/MacOS/TeamsMicFloat\" --debug"
