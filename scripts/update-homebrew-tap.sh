#!/bin/bash
# Points the Homebrew tap (github.com/nicolorisitano82/homebrew-xipper) at a published release:
# the formula at the tag's source tarball, the cask at the release's DMG, each with its SHA-256.
# Run it after the GitHub release vVERSION exists with Xipper-VERSION.dmg attached.
#   scripts/update-homebrew-tap.sh            the version of App/Xipper.xcodeproj (MARKETING_VERSION)
#   scripts/update-homebrew-tap.sh 3.5.2      a given version
#   scripts/update-homebrew-tap.sh --dry-run  show the change, commit and push nothing
# Final releases only (betas are not in the tap). Needs git, curl and gh; brew for the checks.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
OWNER=nicolorisitano82
DRY=0
VERSION=""
for a in "$@"; do
    case $a in
        --dry-run) DRY=1 ;;
        [0-9]*) VERSION=$a ;;
        *) echo "usage: scripts/update-homebrew-tap.sh [VERSION] [--dry-run]"; exit 2 ;;
    esac
done
[ -n "$VERSION" ] || VERSION=$(grep -m1 'MARKETING_VERSION' App/Xipper.xcodeproj/project.pbxproj | sed -E 's/.*= ([^;]+);/\1/')
[[ $VERSION =~ ^[0-9]+(\.[0-9]+)+$ ]] || { echo "not a final version: $VERSION"; exit 2; }
TAG="v$VERSION"
TOKEN=$(gh auth token --user "$OWNER" 2>/dev/null || true)

# The tap: Homebrew's own copy when it is there (then `brew` sees the change at once), or a clone.
TAP="$(brew --repository 2>/dev/null || echo /nonexistent)/Library/Taps/$OWNER/homebrew-xipper"
if [ ! -d "$TAP/.git" ]; then
    TAP="$ROOT/.build/homebrew-xipper"
    [ -d "$TAP/.git" ] || git clone -q "https://github.com/$OWNER/homebrew-xipper.git" "$TAP"
fi
cd "$TAP"
[ -z "$(git status --porcelain)" ] || { echo "the tap at $TAP has uncommitted changes"; exit 1; }
git pull -q --ff-only 2>/dev/null || git -c credential.helper= pull -q --ff-only "https://x-access-token:$TOKEN@github.com/$OWNER/homebrew-xipper.git" main

# The release must exist: its tarball and its DMG are what users download.
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
SRC="https://github.com/$OWNER/xipper/archive/refs/tags/$TAG.tar.gz"
DMG="https://github.com/$OWNER/xipper/releases/download/$TAG/Xipper-$VERSION.dmg"
curl -fsSL -o "$W/src.tar.gz" "$SRC" || { echo "no source tarball for $TAG (is the tag pushed?)"; exit 1; }
SRC_SHA=$(shasum -a 256 "$W/src.tar.gz" | cut -d' ' -f1)
DMG_SHA=$(curl -fsSL "$DMG.sha256" 2>/dev/null | cut -d' ' -f1 || true)
if [ -z "$DMG_SHA" ]; then
    curl -fsSL -o "$W/x.dmg" "$DMG" || { echo "no Xipper-$VERSION.dmg in the release $TAG"; exit 1; }
    DMG_SHA=$(shasum -a 256 "$W/x.dmg" | cut -d' ' -f1)
fi
[[ $SRC_SHA =~ ^[0-9a-f]{64}$ && $DMG_SHA =~ ^[0-9a-f]{64}$ ]] || { echo "bad checksums"; exit 1; }

sed -i '' -E \
    -e "s|^  url \"https://github.com/$OWNER/xipper/archive/refs/tags/v[^\"]+\.tar\.gz\"|  url \"$SRC\"|" \
    -e "s|^  sha256 \"[0-9a-f]{64}\"|  sha256 \"$SRC_SHA\"|" Formula/xipper.rb
sed -i '' -E \
    -e "s|^  version \"[^\"]+\"|  version \"$VERSION\"|" \
    -e "s|^  sha256 \"[0-9a-f]{64}\"|  sha256 \"$DMG_SHA\"|" Casks/xipper.rb
grep -q "$SRC_SHA" Formula/xipper.rb && grep -q "$DMG_SHA" Casks/xipper.rb && grep -q "version \"$VERSION\"" Casks/xipper.rb \
    || { git checkout -q -- .; echo "the formula or the cask did not take the new values"; exit 1; }
if git diff --quiet; then echo "the tap already points at $VERSION"; exit 0; fi
git --no-pager diff --stat
git --no-pager diff

if command -v brew > /dev/null; then
    brew style Formula/xipper.rb Casks/xipper.rb
    HOMEBREW_NO_AUTO_UPDATE=1 brew audit --strict --formula "$OWNER/xipper/xipper" 2>&1 | grep -v -i 'gem\|bundle\|fund' || true
    HOMEBREW_NO_AUTO_UPDATE=1 brew audit --strict --cask "$OWNER/xipper/xipper" 2>&1 | grep -v -i 'gem\|bundle\|fund' || true
fi
if [ $DRY = 1 ]; then
    git checkout -q -- .
    echo "dry run: nothing committed"
    exit 0
fi
git add Formula/xipper.rb Casks/xipper.rb
git commit -q -m "Xipper $VERSION"
git push -q 2>/dev/null || git -c credential.helper= push -q "https://x-access-token:$TOKEN@github.com/$OWNER/homebrew-xipper.git" main
git -c credential.helper= fetch -q "https://x-access-token:$TOKEN@github.com/$OWNER/homebrew-xipper.git" main:refs/remotes/origin/main 2>/dev/null || true
echo "==> tap at Xipper $VERSION: $(git log --oneline -1)"
