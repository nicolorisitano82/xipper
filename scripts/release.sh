#!/bin/bash
# Builds a release: Release build, self-signed signature (no Developer ID / notarization), DMG
# with the background of docs/design/sprites/dmg-background.png, an Applications link and the
# notes (user notes for a final release, tester notes for a beta), SHA-256 checksums.
#   scripts/release.sh final         → dist/Xipper-1.0.0.dmg
#   scripts/release.sh [suffix]      e.g. scripts/release.sh beta1  → dist/Xipper-1.0.0-beta1.dmg
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
if [ "$SUFFIX" = "final" ]; then RELEASE="$VERSION"; else RELEASE="$VERSION-$SUFFIX"; fi
NAME="Xipper-$RELEASE"
echo "==> building $NAME"
xcodebuild -project App/Xipper.xcodeproj -scheme Xipper -configuration Release \
    -derivedDataPath "$DERIVED" -destination 'platform=macOS,arch=arm64' build >"$DERIVED.log" 2>&1 \
    || { tail -30 "$DERIVED.log"; exit 1; }

rm -rf "$DIST/$NAME" && mkdir -p "$DIST/$NAME"
APP="$DIST/$NAME/Xipper.app"
ditto "$DERIVED/Build/Products/Release/Xipper.app" "$APP"

# The full release name, for the update check (Updates.runningVersion): "1.0.0" or "1.0.0-beta1".
/usr/libexec/PlistBuddy -c "Add :XipperReleaseVersion string $RELEASE" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :XipperReleaseVersion $RELEASE" "$APP/Contents/Info.plist"

echo "==> signing with \"$IDENTITY\""
sign() { codesign --force --keychain "$KC" -s "$IDENTITY" --options runtime --timestamp=none "$@"; }
sign "$APP/Contents/Helpers/xipper"
for appex in "$APP"/Contents/PlugIns/*.appex; do
    n=$(basename "$appex" .appex)
    sign --entitlements "App/$n/$n.entitlements" "$appex"
done
sign "$APP"
codesign --verify --deep --strict "$APP"
codesign -dvv "$APP" 2>&1 | grep -E '^(Identifier|Authority|Runtime)' || true
spctl --assess --type execute "$APP" 2>&1 | sed 's/^/gatekeeper: /' || true

echo "==> packaging"
if [ "$SUFFIX" = "final" ]; then
    cp docs/LEGGIMI.md "$DIST/$NAME/LEGGIMI.md"
    cp docs/README-USER.en.md "$DIST/$NAME/README.md"
    NOTES=("LEGGIMI.md" "README.md")
else
    cp docs/BETA_TESTERS.md "$DIST/$NAME/LEGGIMI - beta.md"
    cp docs/BETA_TESTERS.en.md "$DIST/$NAME/README - beta.md"
    NOTES=("LEGGIMI - beta.md" "README - beta.md")
fi
ln -s /Applications "$DIST/$NAME/Applicazioni"
# Background: 768×512 pt window, @1x and @2x in one TIFF (Finder picks the right one).
mkdir -p "$DIST/$NAME/.background"
BG="docs/design/sprites/dmg-background.png"
sips -z 512 768 "$BG" --out "$DIST/bg1x.png" >/dev/null
sips -z 1024 1536 "$BG" --out "$DIST/bg2x.png" >/dev/null
tiffutil -cathidpicheck "$DIST/bg1x.png" "$DIST/bg2x.png" -out "$DIST/$NAME/.background/background.tiff" >/dev/null 2>&1
rm -f "$DIST/bg1x.png" "$DIST/bg2x.png"

# Writable image, laid out by the Finder, then compressed.
VOLNAME="Xipper $RELEASE"
rm -f "$DIST/$NAME.dmg" "$DIST/$NAME-rw.dmg"
hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$DIST/$NAME" -format UDRW -fs HFS+ -ov "$DIST/$NAME-rw.dmg"
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$DIST/$NAME-rw.dmg" | awk '/Apple_HFS/ {print $1}')
sleep 1
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 968, 660}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        -- The two circles of the background (25% and 75% of the width, 46% of the height).
        set position of item "Xipper.app" of container window to {189, 230}
        set position of item "Applicazioni" of container window to {576, 230}
        set position of item "${NOTES[0]}" of container window to {300, 392}
        set position of item "${NOTES[1]}" of container window to {468, 392}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
chflags hidden "/Volumes/$VOLNAME/.background" 2>/dev/null || true
sync
hdiutil detach -quiet "$DEVICE" || hdiutil detach -quiet -force "$DEVICE"
hdiutil convert -quiet "$DIST/$NAME-rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DIST/$NAME.dmg"
rm -f "$DIST/$NAME-rw.dmg"
(cd "$DIST" && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256")
echo "==> $DIST/$NAME.dmg ($(du -h "$DIST/$NAME.dmg" | cut -f1))"
cat "$DIST/$NAME.dmg.sha256"
