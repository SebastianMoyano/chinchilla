#!/bin/bash
# Builds, signs (Developer ID + hardened runtime), packages a DMG,
# notarizes and staples. Result: dist/Chinchilla-<version>.dmg ready to ship.
#
# One-time setup (see README):
#   1. Install your "Developer ID Application" certificate in Keychain.
#   2. xcrun notarytool store-credentials chinchilla-notary \
#        --apple-id "you@example.com" --team-id TEAMID \
#        --password "app-specific-password"
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Chinchilla"
BUNDLE_ID="com.sebastian.chinchilla"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
PROFILE="${NOTARY_PROFILE:-chinchilla-notary}"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$ROOT/packaging/Info.plist")
DMG="$DIST/$APP_NAME-$VERSION.dmg"

# ── Preflight ────────────────────────────────────────────────────────
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
if [ -z "${IDENTITY:-}" ]; then
  echo "ERROR: no 'Developer ID Application' certificate in Keychain."
  echo "Create one at https://developer.apple.com/account/resources/certificates"
  echo "(type: Developer ID Application), download and double-click to install."
  exit 1
fi
echo "Signing identity: $IDENTITY"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "ERROR: notary profile '$PROFILE' not configured. Run:"
  echo "  xcrun notarytool store-credentials $PROFILE --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID --password APP_SPECIFIC_PASSWORD"
  echo "App-specific password: https://account.apple.com → Sign-In and Security."
  exit 1
fi

# ── Build (universal: Apple Silicon + Intel) ─────────────────────────
CHINCHILLA_IDENTITY="-" CHINCHILLA_UNIVERSAL=1 "$ROOT/scripts/build-app.sh" release

# ── Sign for distribution (hardened runtime) ─────────────────────────
codesign -f -o runtime --timestamp -s "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP"
echo "Signature OK"

# ── DMG ──────────────────────────────────────────────────────────────
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign -f -s "$IDENTITY" "$DMG"

# ── Notarize + staple ────────────────────────────────────────────────
echo "Submitting to Apple notary service (usually 1–5 minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

# ── Verify like a user's Mac would ───────────────────────────────────
spctl -a -t open --context context:primary-signature -v "$DMG"
echo ""
echo "✅ Ready to ship: $DMG"
