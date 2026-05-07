#!/usr/bin/env bash
# Convert icon/claude.png to Resources/AppIcon.icns (all 10 standard sizes).
# Run this whenever you replace icon/claude.png.

set -euo pipefail
cd "$(dirname "$0")"

SRC="icon/claude.png"
OUT="Resources/AppIcon.icns"

if [ ! -f "$SRC" ]; then
    echo "Source missing: $SRC"
    exit 1
fi

TMP=$(mktemp -d)/AppIcon.iconset
mkdir -p "$TMP"

# Generate all required sizes via sips.
declare -a sizes=(
    "16:icon_16x16.png"
    "32:icon_16x16@2x.png"
    "32:icon_32x32.png"
    "64:icon_32x32@2x.png"
    "128:icon_128x128.png"
    "256:icon_128x128@2x.png"
    "256:icon_256x256.png"
    "512:icon_256x256@2x.png"
    "512:icon_512x512.png"
    "1024:icon_512x512@2x.png"
)

for entry in "${sizes[@]}"; do
    px="${entry%%:*}"
    name="${entry##*:}"
    sips -z "$px" "$px" "$SRC" --out "$TMP/$name" >/dev/null
done

iconutil -c icns "$TMP" -o "$OUT"
rm -rf "$(dirname "$TMP")"

echo "Wrote $OUT"
