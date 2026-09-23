#!/bin/bash
# Notarize a signed Redge.app with a paid Apple Developer ID.
# Local "Redge Developer" self-signed builds cannot be notarized.
#
# Prerequisites:
#   1. Apple Developer Program membership
#   2. Developer ID Application certificate in the login keychain
#   3. An app-specific password for notarytool (or a stored keychain profile)
#
# Usage:
#   APPLE_ID=you@example.com TEAM_ID=ABCD123456 ./scripts/notarize.sh
#   # or, after: xcrun notarytool store-credentials redge
#   NOTARY_PROFILE=redge ./scripts/notarize.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP="Redge.app"
if [[ ! -d "$APP" ]]; then
  echo "Building first…"
  ./build-app.sh
fi

IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "No Developer ID Application certificate found."
  echo "Until you have an Apple Developer account, share the self-signed app or DMG"
  echo "and ask recipients to right-click → Open. Check for updates uses GitHub Releases."
  exit 1
fi

echo "Signing with Developer ID…"
codesign --force --options runtime --timestamp \
  --sign "$IDENTITY" \
  --identifier "com.jayeshkanodia.redge.app" \
  "$APP"

ZIP="${TMPDIR:-/tmp}/Redge-notarize.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
elif [[ -n "${APPLE_ID:-}" && -n "${TEAM_ID:-}" ]]; then
  xcrun notarytool submit "$ZIP" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "${NOTARY_PASSWORD:?Set NOTARY_PASSWORD or use NOTARY_PROFILE}" \
    --wait
else
  echo "Set NOTARY_PROFILE=redge or APPLE_ID + TEAM_ID + NOTARY_PASSWORD."
  exit 1
fi

xcrun stapler staple "$APP"
echo "Notarized and stapled: $APP"
echo "Package with: ./create-dmg.sh (SKIP_BUILD=1 if this bundle is already current)"
