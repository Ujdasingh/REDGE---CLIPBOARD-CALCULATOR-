#!/bin/bash
# Build Redge.app and package it as a distributable .dmg (drag-to-Applications layout).
set -e
cd "$(dirname "$0")"

APP_NAME="Redge"
VERSION="1.1"
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
• Slide your cursor to the right edge of the screen to open the panel.
• Press Control+Command+V to toggle the panel.
• Redge lives in the menu bar (clipboard icon).

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

# Ad-hoc sign the DMG (optional; helps some Gatekeeper paths)
codesign --force --sign - "$DMG_FILE" 2>/dev/null || true

echo ""
echo "Done: $(pwd)/$DMG_FILE"
echo "Share this file — recipients open it and drag Redge.app to Applications."
ls -lh "$DMG_FILE"
