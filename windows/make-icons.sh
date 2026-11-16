#!/bin/bash
# The two Windows icons, made once from the Mac artwork and committed: app.ico from the app icon
# (an AppIcon.icns from a built Xipper.app), xiz.ico from the XIZ document icon. Needs sips and
# Python with Pillow.   windows/make-icons.sh path/to/Xipper.app
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:?usage: windows/make-icons.sh path/to/Xipper.app}"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
sips -s format png "$APP/Contents/Resources/AppIcon.icns" --out "$T/app.png" > /dev/null
sips -s format png App/Xipper/DocumentIcons/xipper-xiz.icns --out "$T/xiz.png" > /dev/null
python3 -I - "$T/app.png" windows/res/app.ico "$T/xiz.png" windows/res/xiz.ico <<'PY'
import sys
from PIL import Image
for src, dst in ((sys.argv[1], sys.argv[2]), (sys.argv[3], sys.argv[4])):
    Image.open(src).convert("RGBA").save(dst, sizes=[(16, 16), (20, 20), (24, 24), (32, 32), (40, 40), (48, 48), (64, 64), (256, 256)])
PY
ls -l windows/res/*.ico
