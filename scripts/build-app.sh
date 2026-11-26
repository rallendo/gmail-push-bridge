#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
cd "$PROJECT_DIR"

echo "==> Building GmailPushBridge (release)…"
mkdir -p .build/release "$PROJECT_DIR/.build/swift-module-cache"
swiftc -O \
    -disable-sandbox \
    -parse-as-library \
    -target arm64-apple-macosx13.0 \
    -module-cache-path "$PROJECT_DIR/.build/swift-module-cache" \
    Sources/GmailPushBridge/*.swift \
    -o .build/release/GmailPushBridge

APP_NAME="GmailPushBridge"
APP_BUNDLE="$PROJECT_DIR/dist/${APP_NAME}.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp ".build/release/${APP_NAME}" "$MACOS_DIR/${APP_NAME}"
chmod +x "$MACOS_DIR/${APP_NAME}"

cat > "$CONTENTS_DIR/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>GmailPushBridge</string>
    <key>CFBundleIdentifier</key>
    <string>com.gmailpushbridge.app</string>
    <key>CFBundleName</key>
    <string>Gmail Push Bridge</string>
    <key>CFBundleDisplayName</key>
    <string>Gmail Push Bridge</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.5.0</string>
    <key>CFBundleVersion</key>
    <string>9</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Gmail Push Bridge tells Apple Mail to fetch new messages immediately when Gmail reports new mail via IMAP IDLE.</string>
</dict>
</plist>
EOF

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
echo "==> Signing app bundle (identity: ${CODESIGN_IDENTITY})…"
codesign --force --options runtime --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"
codesign --verify --strict --verbose=2 "$APP_BUNDLE"

echo "==> Creating release archive (${APP_NAME}.zip)…"
(cd "$PROJECT_DIR/dist" && rm -f "${APP_NAME}.zip" "${APP_NAME}.zip.sha256" && /usr/bin/ditto -c -k --keepParent "${APP_NAME}.app" "${APP_NAME}.zip" && /usr/bin/shasum -a 256 "${APP_NAME}.zip" > "${APP_NAME}.zip.sha256")

echo "==> Done! App bundle created at: $APP_BUNDLE"
echo "==> Release archive created at: $PROJECT_DIR/dist/${APP_NAME}.zip"
echo "==> Checksum created at: $PROJECT_DIR/dist/${APP_NAME}.zip.sha256"
