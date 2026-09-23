#!/bin/bash
set -e
cd "$(dirname "$0")"

APP_NAME="Redge"
APP_BUNDLE="$APP_NAME.app"
ICON="$APP_NAME.icns"

if [ ! -f "$ICON" ]; then
    echo "Generating icon..."
    rm -rf "$APP_NAME.iconset"
    swift gen_icon.swift "$APP_NAME.iconset"
    iconutil -c icns -o "$ICON" "$APP_NAME.iconset"
fi

echo "Building release binary..."
swift build -c release

echo "Creating $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp ".build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"
# Standard icon path (CFBundleIconFile fallback if custom icon ever gets stripped).
cp "$ICON" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.jayeshkanodia.redge.app</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>Redge — Clipboard, Calculator &amp; Repeat</string>
    <key>CFBundleVersion</key>
    <string>2.1.2</string>
    <key>CFBundleShortVersionString</key>
    <string>2.1.2</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Redge fills Excel cells and renames Finder items when you press Repeat.</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>Redge uses Accessibility to Repeat your last typed value into the next field. Enable the Redge icon, not Terminal.</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"
plutil -lint "$APP_BUNDLE/Contents/Info.plist"

# Do not NSWorkspace.setIcon / xattr -cr / touch after signing — those
# unbind Info.plist and strip the real AppIcon.icns from Launch Services.

echo "Signing with a stable identity..."
chmod +x ./scripts/ensure-signing-identity.sh
./scripts/ensure-signing-identity.sh
if codesign --force --sign "Redge Developer" --identifier "com.jayeshkanodia.redge.app" "$APP_BUNDLE"; then
    echo "Signed as 'Redge Developer'."
else
    echo "WARNING: stable signing failed; falling back to ad-hoc (permissions will reset on next update)."
    codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true
fi

echo "Done. Install with: cp -R $APP_BUNDLE /Applications/ && open /Applications/$APP_BUNDLE"
echo "Enable Accessibility for the Redge icon only — not Terminal."
