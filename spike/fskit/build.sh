#!/bin/zsh
# FSKit spike (docs/FSKIT.md): builds XipperFSSpike.app with XipperFS.appex, a read-only FSKit
# module that mounts any file as a volume holding one info.txt (path, size, first bytes).
# Usage: spike/fskit/build.sh [out-dir]   then   mount -F -t xipperfs <file> <mountpoint>
# Signing uses the Xipper self-signed identity: the extension starts but FSKit refuses it without
# a provisioning profile for com.apple.developer.fskit.fsmodule (see docs/FSKIT.md).
set -e
here=${0:A:h}
out=${1:-$here/build}
A=$out/XipperFSSpike.app
E=$A/Contents/Extensions/XipperFS.appex
rm -rf $A; mkdir -p $A/Contents/MacOS $E/Contents/MacOS
swiftc -parse-as-library -target arm64-apple-macos26.0 -O $here/XipperFS.swift -o $E/Contents/MacOS/XipperFS
swiftc -target arm64-apple-macos26.0 $here/Host.swift -o $A/Contents/MacOS/XipperFSSpike
cp $here/XipperFS-Info.plist $E/Contents/Info.plist
cp $here/Host-Info.plist $A/Contents/Info.plist
KC="$HOME/Library/Keychains/xipper-signing.keychain-db"
security unlock-keychain -p "$(cat "$HOME/.xipper-signing/keychain-password")" "$KC"
sign() { codesign --force --keychain "$KC" -s "Xipper Self-Signed" --options runtime --timestamp=none "$@"; }
sign --entitlements $here/fs.entitlements $E
sign $A
echo "built $A"
