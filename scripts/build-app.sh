#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
cd "$PROJECT_DIR"

echo "==> Building GmailPushBridge (release)…"
mkdir -p .build/release /tmp/swift-module-cache
swiftc -O \
    -disable-sandbox \
    -parse-as-library \
    -target arm64-apple-macosx13.0 \
    -module-cache-path /tmp/swift-module-cache \
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
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
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

echo "==> Signing app bundle (ad-hoc)…"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> Creating release archive (${APP_NAME}.zip)…"
(cd "$PROJECT_DIR/dist" && rm -f "${APP_NAME}.zip" && /usr/bin/ditto -c -k --keepParent "${APP_NAME}.app" "${APP_NAME}.zip")

echo "==> Done! App bundle created at: $APP_BUNDLE"
echo "==> Release archive created at: $PROJECT_DIR/dist/${APP_NAME}.zip"
