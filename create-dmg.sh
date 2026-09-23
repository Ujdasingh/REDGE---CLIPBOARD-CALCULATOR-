#!/bin/bash
# Build Redge.app and package it as a distributable .dmg (drag-to-Applications layout).
set -e
cd "$(dirname "$0")"

APP_NAME="Redge"
VERSION="2.1.2"
DMG_FILE="${APP_NAME}-${VERSION}.dmg"
STAGING="dmg-staging"
VOLUME_NAME="${APP_NAME}"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  echo "=== Building app bundle ==="
  ./build-app.sh
elif [[ ! -d "${APP_NAME}.app" ]]; then
  echo "Error: ${APP_NAME}.app not found. Run ./build-app.sh first or omit SKIP_BUILD=1."
  exit 1
else
  echo "=== Using existing ${APP_NAME}.app (SKIP_BUILD=1) ==="
fi

echo "=== Preparing DMG contents ==="
rm -rf "$STAGING" "$DMG_FILE"
mkdir -p "$STAGING"
cp -R "${APP_NAME}.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

cat > "$STAGING/Install Redge.txt" <<'EOF'
Install Redge
=============

1. Drag Redge.app onto the Applications folder arrow.
2. Open Applications and double-click Redge.
3. On first launch, macOS may warn the app is from an unidentified developer:
   - Open System Settings → Privacy & Security
   - Click "Open Anyway" for Redge
   Or right-click Redge.app → Open → Open.

Usage
-----
• Slide your cursor to the screen edge (right by default; change in Settings) to open the panel.
• Press Control+Command+V to toggle the panel (customizable).
• Click a clip to fill the selected Excel/Numbers cell when Auto-paste is on.
• Repeat (⌘⌥R) is off until you enable it in Settings.
• Redge lives in the menu bar.

Requires macOS 13 or later.
EOF

echo "=== Creating compressed DMG ==="
# Remove previous DMG if present
rm -f "$DMG_FILE"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG_FILE"

rm -rf "$STAGING"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
  codesign --force --sign "Developer ID Application" "$DMG_FILE" 2>/dev/null || true
else
  codesign --force --sign "Redge Developer" "$DMG_FILE" 2>/dev/null \
    || codesign --force --sign - "$DMG_FILE" 2>/dev/null || true
fi

echo ""
echo "Done: $(pwd)/$DMG_FILE"
echo "Share this file — recipients open it and drag Redge.app to Applications."
ls -lh "$DMG_FILE"
