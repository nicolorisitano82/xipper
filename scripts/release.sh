#!/bin/bash
# Builds a beta release: Release build, self-signed signature (no Developer ID / notarization),
# DMG with an Applications link and tester notes, SHA-256 checksums.
#   scripts/release.sh [suffix]      e.g. scripts/release.sh beta1  → dist/Xipper-0.9.0-beta1.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

SUFFIX="${1:-beta1}"
IDENTITY="Xipper Self-Signed"
KC="$HOME/Library/Keychains/xipper-signing.keychain-db"
DERIVED=".build/release-xcode"
DIST="dist"

[ -f "$KC" ] || scripts/create-signing-identity.sh
security unlock-keychain -p "$(cat "$HOME/.xipper-signing/keychain-password")" "$KC"

VERSION=$(grep -m1 'MARKETING_VERSION' App/Xipper.xcodeproj/project.pbxproj | sed -E 's/.*= ([^;]+);/\1/')
NAME="Xipper-$VERSION-$SUFFIX"
echo "==> building $NAME"
xcodebuild -project App/Xipper.xcodeproj -scheme Xipper -configuration Release \
    -derivedDataPath "$DERIVED" -destination 'platform=macOS,arch=arm64' build >"$DERIVED.log" 2>&1 \
    || { tail -30 "$DERIVED.log"; exit 1; }

rm -rf "$DIST/$NAME" && mkdir -p "$DIST/$NAME"
APP="$DIST/$NAME/Xipper.app"
ditto "$DERIVED/Build/Products/Release/Xipper.app" "$APP"

echo "==> signing with \"$IDENTITY\""
sign() { codesign --force --keychain "$KC" -s "$IDENTITY" --options runtime --timestamp=none "$@"; }
sign "$APP/Contents/Helpers/xipper"
sign --entitlements App/XipperFinder/XipperFinder.entitlements "$APP/Contents/PlugIns/XipperFinder.appex"
sign "$APP"
codesign --verify --deep --strict "$APP"
codesign -dvv "$APP" 2>&1 | grep -E '^(Identifier|Authority|Runtime)' || true
spctl --assess --type execute "$APP" 2>&1 | sed 's/^/gatekeeper: /' || true

echo "==> packaging"
cp docs/BETA_TESTERS.md "$DIST/$NAME/LEGGIMI - beta.md" 2>/dev/null || true
ln -s /Applications "$DIST/$NAME/Applicazioni"
rm -f "$DIST/$NAME.dmg"
hdiutil create -quiet -volname "Xipper $VERSION $SUFFIX" -srcfolder "$DIST/$NAME" -format UDZO -ov "$DIST/$NAME.dmg"
(cd "$DIST" && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256")
echo "==> $DIST/$NAME.dmg ($(du -h "$DIST/$NAME.dmg" | cut -f1))"
cat "$DIST/$NAME.dmg.sha256"
