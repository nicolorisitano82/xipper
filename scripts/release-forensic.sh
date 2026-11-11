#!/bin/bash
# Xipper Forensic release (docs/XIPPER_FORENSIC.md §7, P3b): release build signed with the
# self-signed identity (scripts/build-forensic-app.sh), DMG with the Xipper background, an
# Applications link and the user notes (docs/forensic), SHA-256 checksum.
#   scripts/release-forensic.sh [suffix]   → dist/XipperForensic-VERSION[-suffix].dmg, plus the portable
#   xiz readers (scripts/build-xiz-portable.sh) in dist/xiz-VERSION/
set -euo pipefail
cd "$(dirname "$0")/.."
SUFFIX="${1:-}"
DIST="dist"
scripts/build-forensic-app.sh release
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" ".build/forensic-app/Xipper Forensic.app/Contents/Info.plist")
RELEASE="$VERSION${SUFFIX:+-$SUFFIX}"
NAME="XipperForensic-$RELEASE"
echo "==> packaging $NAME"

rm -rf "$DIST/$NAME" && mkdir -p "$DIST/$NAME"
ditto ".build/forensic-app/Xipper Forensic.app" "$DIST/$NAME/Xipper Forensic.app"
codesign --verify --deep --strict "$DIST/$NAME/Xipper Forensic.app"
cp docs/forensic/LEGGIMI.md "$DIST/$NAME/LEGGIMI.md"
cp docs/forensic/README.en.md "$DIST/$NAME/README.md"
[ -f docs/forensic/VALIDAZIONE.md ] && cp docs/forensic/VALIDAZIONE.md "$DIST/$NAME/VALIDAZIONE.md"
[ -f "$DIST/validation-$VERSION/RESULTS.md" ] || { echo "run scripts/forensic-validation.sh first"; exit 1; }
ln -s /Applications "$DIST/$NAME/Applicazioni"
mkdir -p "$DIST/$NAME/.background"
BG="docs/design/sprites/dmg-background.png"
sips -z 512 768 "$BG" --out "$DIST/bg1x.png" >/dev/null
sips -z 1024 1536 "$BG" --out "$DIST/bg2x.png" >/dev/null
tiffutil -cathidpicheck "$DIST/bg1x.png" "$DIST/bg2x.png" -out "$DIST/$NAME/.background/background.tiff" >/dev/null 2>&1
rm -f "$DIST/bg1x.png" "$DIST/bg2x.png"

VOLNAME="Xipper Forensic $RELEASE"
rm -f "$DIST/$NAME.dmg" "$DIST/$NAME-rw.dmg"
hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$DIST/$NAME" -format UDRW -fs HFS+ -ov "$DIST/$NAME-rw.dmg"
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$DIST/$NAME-rw.dmg" | awk '/Apple_HFS/ {print $1}')
sleep 1
osascript <<APPLESCRIPT || echo "(Finder layout skipped)"
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
        set position of item "Xipper Forensic.app" of container window to {189, 230}
        set position of item "Applicazioni" of container window to {576, 230}
        set position of item "LEGGIMI.md" of container window to {300, 392}
        set position of item "README.md" of container window to {468, 392}
        try
            set position of item "VALIDAZIONE.md" of container window to {636, 392}
            set position of item "LEGGIMI.md" of container window to {200, 392}
            set position of item "README.md" of container window to {384, 392}
            set position of item "VALIDAZIONE.md" of container window to {568, 392}
        end try
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
scripts/build-xiz-portable.sh "$VERSION" | tail -6
