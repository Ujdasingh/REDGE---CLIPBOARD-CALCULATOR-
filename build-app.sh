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
    <string>Redge — Clipboard & Calculator</string>
    <key>CFBundleVersion</key>
    <string>1.1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Set custom icon attribute via NSWorkspace.setIcon — writes Icon\r resource +
# com.apple.FinderInfo xattr on the bundle. Finder reads these directly, no
# iconservicesd involvement. Bypasses any cached "no icon" verdicts.
echo "Attaching custom icon via NSWorkspace.setIcon..."
swift set_bundle_icon.swift "$ICON" "$APP_BUNDLE"

# Ad-hoc sign — required so the icon resource isn't stripped by code-integrity checks.
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true

# Re-attach icon AFTER signing, in case codesign stripped the xattr.
swift set_bundle_icon.swift "$ICON" "$APP_BUNDLE"

touch "$APP_BUNDLE"
touch "$APP_BUNDLE/Contents/Info.plist"

echo "Done. Open with: open $APP_BUNDLE"
echo "Or move to /Applications: mv $APP_BUNDLE /Applications/"
