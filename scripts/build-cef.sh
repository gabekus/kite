#!/usr/bin/env bash
# Builds the pinned CEF from source with H.264 and AAC (proprietary_codecs), which
# the prebuilt Spotify distributions leave out. Without them sites that only serve
# H.264 (Reddit, X, Instagram, most news video) say the video can't be played.
#
# Takes ~5-8 hours on an M-series Mac and ~90 GB of disk at its peak. The result,
# a minimal distribution like the one scripts/fetch-cef.sh downloads, lands in
# ThirdParty/codecs/, where fetch-cef.sh picks it up instead of downloading.
#
# Usage: scripts/build-cef.sh [WORK_DIR]   (default ~/cef-build; delete it afterwards)
# Running it again resumes: the checkout and build output are reused.
set -euo pipefail

# Keep in step with scripts/fetch-cef.sh.
CEF_VERSION="156.0.7+g47dbc1d+chromium-156.0.8078.17"
CEF_BRANCH="8078"
CEF_COMMIT="47dbc1d"
CEF_PLATFORM="macosarm64"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${1:-$HOME/cef-build}"
NAME="cef_binary_${CEF_VERSION}_${CEF_PLATFORM}_minimal"
OUT="$ROOT/ThirdParty/codecs"

mkdir -p "$WORK" "$OUT"
cd "$WORK"
[[ -d depot_tools ]] || git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git
export PATH="$WORK/depot_tools:$PATH"
curl -fsSL -o automate-git.py \
    "https://raw.githubusercontent.com/chromiumembedded/cef/$CEF_COMMIT/tools/automate/automate-git.py"

# is_official_build matches the Spotify builds; PGO profiles are required with it.
export GN_DEFINES="is_official_build=true proprietary_codecs=true ffmpeg_branding=Chrome symbol_level=0"
export CEF_ARCHIVE_FORMAT=tar.bz2
python3 automate-git.py \
    --download-dir="$WORK/chromium_git" \
    --depot-tools-dir="$WORK/depot_tools" \
    --branch="$CEF_BRANCH" \
    --checkout="$CEF_COMMIT" \
    --arm64-build \
    --no-debug-build \
    --no-chromium-history \
    --with-pgo-profiles \
    --build-target=cefsimple \
    --minimal-distrib-only \
    --no-distrib-docs \
    --no-distrib-symbols

archive="$WORK/chromium_git/chromium/src/cef/binary_distrib/$NAME.tar.bz2"
if [[ ! -f "$archive" ]]; then
    echo "error: expected $archive; the built version doesn't match $CEF_VERSION:" >&2
    ls "$WORK/chromium_git/chromium/src/cef/binary_distrib" >&2
    exit 1
fi
cp "$archive" "$OUT/$NAME.tar.bz2"
echo "Built $OUT/$NAME.tar.bz2"
echo "Next: scripts/fetch-cef.sh (installs it into ThirdParty/cef), then rm -rf $WORK"
