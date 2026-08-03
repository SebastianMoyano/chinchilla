#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Chinchilla"
BUNDLE_ID="com.sebastian.chinchilla"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
CONFIG="${1:-release}"

# CHINCHILLA_UNIVERSAL=1 builds arm64 + x86_64 (Intel Macs + Apple Silicon,
# incl. MacBook Neo). Native-only for day-to-day dev (half the compile time).
# Note: `swift build --arch a --arch b` needs full Xcode (xcbuild), so with
# Command Line Tools we build per-triple and merge with lipo.
if [ "${CHINCHILLA_UNIVERSAL:-0}" = "1" ]; then
  swift build -c "$CONFIG" --triple arm64-apple-macosx --package-path "$ROOT"
  swift build -c "$CONFIG" --triple x86_64-apple-macosx --package-path "$ROOT"
  mkdir -p "$ROOT/.build/universal"
  BIN="$ROOT/.build/universal/$APP_NAME"
  lipo -create \
    "$ROOT/.build/arm64-apple-macosx/$CONFIG/$APP_NAME" \
    "$ROOT/.build/x86_64-apple-macosx/$CONFIG/$APP_NAME" \
    -output "$BIN"
else
  swift build -c "$CONFIG" --package-path "$ROOT"
  BIN="$ROOT/.build/$CONFIG/$APP_NAME"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/packaging/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Localizations
cp -R "$ROOT/packaging/lproj/"*.lproj "$APP/Contents/Resources/"

# SMAppService agent (weekly auto-clean) — must live inside the bundle.
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp "$ROOT/packaging/com.sebastian.chinchilla.autoclean.plist" "$APP/Contents/Library/LaunchAgents/"

# SPM resource bundles (if any target declares resources)
find "$ROOT/.build/$CONFIG" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \; 2>/dev/null || true

# Icon (optional until packaging/icon-1024.png exists)
if [ -f "$ROOT/packaging/icon-1024.png" ]; then
  if [ ! -f "$DIST/AppIcon.icns" ] || [ "$ROOT/packaging/icon-1024.png" -nt "$DIST/AppIcon.icns" ]; then
    "$ROOT/scripts/make-icon.sh" "$ROOT/packaging/icon-1024.png" "$DIST/AppIcon.icns"
  fi
  cp "$DIST/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Sign: prefer Developer ID (stable identity → Full Disk Access survives
# rebuilds, no Gatekeeper friction), then a self-signed "Chinchilla Dev",
# then ad-hoc. Override with CHINCHILLA_IDENTITY.
IDENTITY="${CHINCHILLA_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')
fi
if [ -z "$IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "Chinchilla Dev"; then
  IDENTITY="Chinchilla Dev"
fi
IDENTITY="${IDENTITY:--}"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"

echo "Built: $APP (signed: $IDENTITY)"
