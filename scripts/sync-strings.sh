#!/bin/zsh
# Merges the strings extracted by the last Debug build into each target's String Catalog
# (xcodebuild extracts them but, unlike the Xcode IDE, does not update the catalogs).
# Usage: scripts/sync-strings.sh   (after an xcodebuild Debug build into .build/xcode)
set -euo pipefail
cd "$(dirname "$0")/.."
inter=.build/xcode/Build/Intermediates.noindex/Xipper.build/Debug
for target in Xipper XipperFinder XipperPreview XipperThumbnail; do
    data=($(find "$inter/$target.build" -name '*.stringsdata'))
    xcrun xcstringstool sync "App/$target/Localizable.xcstrings" --stringsdata $data
    echo "$target: $(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))['strings']))" "App/$target/Localizable.xcstrings") strings"
done
