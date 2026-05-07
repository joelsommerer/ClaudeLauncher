#!/usr/bin/env bash
# Builds ClaudeLauncher.app, ad-hoc-signs it, and packages it into a DMG.
# Output: dist/ClaudeLauncher-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"

ROOT="$(pwd)"
APP="$ROOT/build/ClaudeLauncher.app"
DIST="$ROOT/dist"
VERSION=$(grep -A1 CFBundleShortVersionString Resources/Info.plist | grep '<string>' | head -1 | sed 's/.*<string>\(.*\)<\/string>.*/\1/')
DMG="$DIST/ClaudeLauncher-${VERSION}.dmg"

echo "[1/5] Bauen…"
./build.sh >/dev/null

echo "[2/5] Ad-hoc-Codesign (entfernt 'Beschädigt'-Warnung auf manchen Macs)…"
# `-` is the ad-hoc identity. Not trusted but better than nothing.
codesign --force --deep --sign - "$APP"
codesign --verify --deep "$APP" >/dev/null

echo "[3/5] DMG-Staging vorbereiten…"
mkdir -p "$DIST"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "[4/5] DMG erzeugen…"
rm -f "$DMG"
hdiutil create \
    -volname "ClaudeLauncher ${VERSION}" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    -fs HFS+ \
    "$DMG" >/dev/null

rm -rf "$STAGE"

echo "[5/5] Fertig."
ls -lh "$DMG"
echo ""
echo "Distributable:"
echo "  $DMG"
