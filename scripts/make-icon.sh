#!/bin/bash
# Usage: make-icon.sh <input-1024.png> <output.icns>
set -euo pipefail
SRC="$1"
OUT="$2"
TMP="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$TMP" "$(dirname "$OUT")"

for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$SRC" --out "$TMP/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" "$SRC" --out "$TMP/icon_${s}x${s}@2x.png" >/dev/null
done

iconutil -c icns "$TMP" -o "$OUT"
echo "Icon: $OUT"
