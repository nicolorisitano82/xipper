#!/bin/bash
# Builds XFHelperSpike.app (app + root LaunchDaemon for SMAppService) signed with the
# self-signed "Xipper Self-Signed" identity, like the Xipper release (scripts/release.sh).
set -euo pipefail
cd "$(dirname "$0")"
OUT=build/XFHelperSpike.app
IDENTITY="Xipper Self-Signed"
KC="$HOME/Library/Keychains/xipper-signing.keychain-db"
rm -rf build && mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Library/LaunchDaemons"

swiftc -O -o "$OUT/Contents/MacOS/XFHelperSpike" App.swift
swiftc -O -o "$OUT/Contents/MacOS/xipper-forensic-helper" Helper.swift

cat > "$OUT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.xipper.forensic.helperspike</string>
  <key>CFBundleName</key><string>XFHelperSpike</string>
  <key>CFBundleExecutable</key><string>XFHelperSpike</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
</dict></plist>
EOF

security unlock-keychain -p "$(cat "$HOME/.xipper-signing/keychain-password")" "$KC"
# Clients must be signed by the same leaf certificate (self-signed: no Apple anchor to name).
LEAF=$(openssl x509 -in "$HOME/.xipper-signing/xipper-self-signed.cer.pem" -outform der | shasum -a 1 | cut -d' ' -f1)
REQ="identifier \"com.xipper.forensic.helperspike\" and certificate leaf = H\"$LEAF\""

cat > "$OUT/Contents/Library/LaunchDaemons/com.xipper.forensic.helper.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.xipper.forensic.helper</string>
  <key>BundleProgram</key><string>Contents/MacOS/xipper-forensic-helper</string>
  <key>ProgramArguments</key><array>
    <string>xipper-forensic-helper</string>
    <string>$REQ</string>
  </array>
  <key>MachServices</key><dict><key>com.xipper.forensic.helper</key><true/></dict>
  <key>AssociatedBundleIdentifiers</key><array><string>com.xipper.forensic.helperspike</string></array>
  <key>StandardErrorPath</key><string>/tmp/xipper-forensic-helper.log</string>
</dict></plist>
EOF

sign() { codesign --force --keychain "$KC" -s "$IDENTITY" --options runtime --timestamp=none "$@"; }
sign -i com.xipper.forensic.helper "$OUT/Contents/MacOS/xipper-forensic-helper"
sign "$OUT"
codesign --verify --deep --strict "$OUT" && echo "signed: $OUT"
echo "client requirement: $REQ"
