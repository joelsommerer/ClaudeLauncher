#!/usr/bin/env bash
set -euo pipefail

# Build ClaudeLauncher.app from Swift sources without Xcode (only Command Line Tools).

cd "$(dirname "$0")"
ROOT="$(pwd)"
BUILD="$ROOT/build"
APP="$BUILD/ClaudeLauncher.app"
BIN="$APP/Contents/MacOS/ClaudeLauncher"
RES="$APP/Contents/Resources"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$RES"

echo "[1/4] Compiling Swift sources…"
SOURCES=$(find Sources -name '*.swift' -print)
# Compile arm64 only by default. To make universal: also compile x86_64 and lipo.
swiftc -O \
    -target arm64-apple-macos14 \
    -framework AppKit \
    -framework SwiftUI \
    -framework Network \
    -framework Foundation \
    $SOURCES \
    -o "$BIN"

echo "[2/4] Copying Info.plist…"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "[3/4] Generating app icon…"
# Generate a simple icon if iconutil/sips available.
ICON_TMP="$BUILD/icon.iconset"
mkdir -p "$ICON_TMP"
# Use a simple solid-color PNG via a tiny Swift one-liner if no icon resource exists.
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$RES/AppIcon.icns"
else
    # Fallback: try to generate placeholder icon using sips on a generated PNG
    # Skip if tools missing — app works without icon.
    if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
        # create a 1024x1024 solid blue png using ImageMagick? Not present.
        # Instead, use the system Terminal icon as a placeholder if possible.
        SYSICON="/System/Applications/Utilities/Terminal.app/Contents/Resources/Terminal.icns"
        if [ -f "$SYSICON" ]; then
            cp "$SYSICON" "$RES/AppIcon.icns" || true
        fi
    fi
fi

echo "[4/4] Bundle complete: $APP"
echo ""
echo "Test run:"
echo "  open '$APP'"
echo ""
echo "Install:"
echo "  cp -R '$APP' /Applications/"
