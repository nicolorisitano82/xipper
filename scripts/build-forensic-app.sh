#!/bin/bash
# Builds "Xipper Forensic.app" (docs/XIPPER_FORENSIC.md §3.1) from the SwiftPM target XipperForensic,
# with the xipper-forensic CLI in Contents/Helpers, the disk helper (root LaunchDaemon registered with
# SMAppService: Contents/MacOS/xipper-forensic-helper + Contents/Library/LaunchDaemons), the Italian and English strings, signed with the
# self-signed "Xipper Self-Signed" identity like Xipper (no Developer ID, no notarization).
#   scripts/build-forensic-app.sh [debug|release]   → .build/forensic-app/Xipper Forensic.app
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
VERSION=$(sed -nE 's/.*toolVersion = "([0-9.]+).*/\1/p' Sources/ForensicKit/ForensicReport.swift)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
IDENTITY="Xipper Self-Signed"
KC="$HOME/Library/Keychains/xipper-signing.keychain-db"
OUT=".build/forensic-app"
APP="$OUT/Xipper Forensic.app"

swift build -c "$CONFIG" --product XipperForensic 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" | grep -v "debug note" || true
swift build -c "$CONFIG" --product xipper-forensic 2>&1 | grep -E "error|Build complete" || true
swift build -c "$CONFIG" --product xipper-forensic-helper 2>&1 | grep -E "error|Build complete" || true
BIN=$(swift build -c "$CONFIG" --show-bin-path)
[ -x "$BIN/XipperForensic" ] && [ -x "$BIN/xipper-forensic" ] && [ -x "$BIN/xipper-forensic-helper" ] || { echo "build failed"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
cp "$BIN/XipperForensic" "$APP/Contents/MacOS/XipperForensic"
cp "$BIN/xipper-forensic-helper" "$APP/Contents/MacOS/xipper-forensic-helper"
cp "$BIN/xipper-forensic" "$APP/Contents/Helpers/xipper-forensic"

# The disk helper accepts only the app and the CLI signed with the same certificate (self-signed: no
# Apple anchor to name, so the leaf certificate's hash). Unsigned builds get a requirement nothing meets.
CERT="$HOME/.xipper-signing/xipper-self-signed.cer.pem"
if [ -f "$KC" ] && [ -f "$CERT" ]; then
    LEAF=$(openssl x509 -in "$CERT" -outform der | shasum -a 1 | cut -d' ' -f1)
    REQ="(identifier \"app.xipper.forensic\" or identifier \"app.xipper.forensic.cli\") and certificate leaf = H\"$LEAF\""
else
    REQ="identifier \"app.xipper.forensic.unsigned\" and certificate leaf = H\"0000000000000000000000000000000000000000\""
fi
DAEMON="$APP/Contents/Library/LaunchDaemons/app.xipper.forensic.helper.plist"
plutil -create xml1 "$DAEMON"
plutil -insert Label -string app.xipper.forensic.helper "$DAEMON"
plutil -insert BundleProgram -string Contents/MacOS/xipper-forensic-helper "$DAEMON"
plutil -insert ProgramArguments -array "$DAEMON"
plutil -insert ProgramArguments -string xipper-forensic-helper -append "$DAEMON"
plutil -insert ProgramArguments -string "$REQ" -append "$DAEMON"
plutil -insert MachServices -dictionary "$DAEMON"
plutil -insert MachServices.app\\.xipper\\.forensic\\.helper -bool YES "$DAEMON"
plutil -insert AssociatedBundleIdentifiers -array "$DAEMON"
plutil -insert AssociatedBundleIdentifiers -string app.xipper.forensic -append "$DAEMON"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" App/XipperForensic/Resources/Info.plist > "$APP/Contents/Info.plist"
for l in App/XipperForensic/Resources/*.lproj; do
    n=$(basename "$l")
    mkdir -p "$APP/Contents/Resources/$n"
    for f in "$l"/*.strings; do [ -f "$f" ] && plutil -convert binary1 -o "$APP/Contents/Resources/$n/$(basename "$f")" "$f"; done
done
[ -f App/XipperForensic/Resources/AppIcon.icns ] && cp App/XipperForensic/Resources/AppIcon.icns "$APP/Contents/Resources/" \
    && /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" > /dev/null

if [ -f "$KC" ]; then
    security unlock-keychain -p "$(cat "$HOME/.xipper-signing/keychain-password")" "$KC"
    sign() { codesign --force --keychain "$KC" -s "$IDENTITY" --options runtime --timestamp=none "$@"; }
    sign -i app.xipper.forensic.cli "$APP/Contents/Helpers/xipper-forensic"
    sign -i app.xipper.forensic.helper "$APP/Contents/MacOS/xipper-forensic-helper"
    sign "$APP"
    codesign --verify --deep --strict "$APP"
else
    echo "no signing keychain: ad-hoc signature"
    codesign --force -s - "$APP/Contents/Helpers/xipper-forensic"
    codesign --force -s - -i app.xipper.forensic.helper "$APP/Contents/MacOS/xipper-forensic-helper"
    codesign --force -s - "$APP"
fi
echo "$APP"
