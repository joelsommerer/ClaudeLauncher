#!/usr/bin/env bash
# Builds ClaudeLauncher.app, signs it (Developer ID if available, else ad-hoc),
# notarizes via Apple, and packages everything into a DMG.
#
# One-time setup for full signing+notarization is in SIGNING.md.
set -euo pipefail
cd "$(dirname "$0")"

ROOT="$(pwd)"
APP="$ROOT/build/ClaudeLauncher.app"
DIST="$ROOT/dist"
ENTITLEMENTS="$ROOT/Resources/entitlements.plist"
NOTARY_PROFILE="ClaudeLauncher-Notary"
VERSION=$(grep -A1 CFBundleShortVersionString Resources/Info.plist | grep '<string>' | head -1 | sed 's/.*<string>\(.*\)<\/string>.*/\1/')
DMG="$DIST/ClaudeLauncher-${VERSION}.dmg"

# Detect a Developer ID Application identity, fall back to ad-hoc.
SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F\" '/Developer ID Application/ {print $2; exit}')

echo "[1/6] Bauen…"
./build.sh >/dev/null

if [ -n "$SIGN_IDENTITY" ]; then
    echo "[2/6] Signing mit Developer ID + Hardened Runtime…"
    echo "      Identity: $SIGN_IDENTITY"
    codesign --force --deep \
        --sign "$SIGN_IDENTITY" \
        --options runtime \
        --timestamp \
        --entitlements "$ENTITLEMENTS" \
        "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
    SIGNED_REAL=true
else
    echo "[2/6] Kein Developer-ID-Zertifikat gefunden — Ad-hoc-Signing…"
    echo "      (siehe SIGNING.md für Setup)"
    codesign --force --deep --sign - "$APP"
    SIGNED_REAL=false
fi

echo "[3/6] DMG-Staging…"
mkdir -p "$DIST"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "[4/6] DMG erzeugen…"
rm -f "$DMG"
hdiutil create \
    -volname "ClaudeLauncher ${VERSION}" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    -fs HFS+ \
    "$DMG" >/dev/null
rm -rf "$STAGE"

if [ "$SIGNED_REAL" = "true" ]; then
    # Sign the DMG itself so users see one fewer warning when downloading.
    echo "[5/6] DMG signieren…"
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"

    # Check if notary profile exists; if so, submit + staple. Skip otherwise.
    if security find-generic-password -a "${NOTARY_PROFILE}" -s "${NOTARY_PROFILE}" >/dev/null 2>&1; then
        echo "[6/6] Notarization (kann 2–10 Min dauern)…"
        xcrun notarytool submit "$DMG" \
            --keychain-profile "$NOTARY_PROFILE" \
            --wait
        echo "       Stapling Ticket an DMG…"
        xcrun stapler staple "$DMG"
        # Also staple the inner .app so users who copy the .app directly out of the DMG keep notarization.
        xcrun stapler staple "$APP" || true
    else
        echo "[6/6] Notary-Profil '${NOTARY_PROFILE}' fehlt — Notarization übersprungen."
        echo "       Setup: xcrun notarytool store-credentials \"${NOTARY_PROFILE}\" --apple-id ... --team-id ... --password ..."
        echo "       (siehe SIGNING.md)"
    fi
else
    echo "[5/6] Skip DMG-Signing (kein Zertifikat)"
    echo "[6/6] Skip Notarization (kein Zertifikat)"
fi

echo ""
ls -lh "$DMG"
echo ""
echo "Distributable:"
echo "  $DMG"
if [ "$SIGNED_REAL" = "true" ]; then
    spctl --assess --verbose=2 --type install "$DMG" 2>&1 | head -3 || true
    echo ""
    if xcrun stapler validate "$DMG" >/dev/null 2>&1; then
        echo "✓ DMG ist signiert UND notarisiert — installiert ohne Gatekeeper-Warnung"
    else
        echo "⚠ DMG ist signiert, aber NICHT notarisiert — Gatekeeper warnt noch beim Erstöffnen"
    fi
fi
