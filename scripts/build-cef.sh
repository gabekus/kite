#!/usr/bin/env bash
# Builds the pinned CEF from source with H.264 and AAC (proprietary_codecs), which
# the prebuilt Spotify distributions leave out. Without them sites that only serve
# H.264 (Reddit, X, Instagram, most news video) say the video can't be played.
# It also applies Kite's patches in patches/cef/ (to CEF's own source): see that
# folder's README for what each adds.
#
# Takes ~5-8 hours on an M-series Mac and ~90 GB of disk at its peak. The result,
# a minimal distribution like the one scripts/fetch-cef.sh downloads, lands in
# ThirdParty/codecs/, where fetch-cef.sh picks it up instead of downloading.
#
# Usage: scripts/build-cef.sh [WORK_DIR]   (default ~/cef-build; delete it afterwards)
# Stop it any time (ctrl-c); running it again resumes: the checkout and the
# finished part of the compile are reused.
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

# Chromium compiles ANGLE's Metal shaders, which needs Xcode's separate Metal toolchain.
if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    echo "error: Xcode's Metal toolchain is missing; run: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
fi

mkdir -p "$WORK" "$OUT"
cd "$WORK"
[[ -d depot_tools ]] || git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git
export PATH="$WORK/depot_tools:$PATH"
curl -fsSL -o automate-git.py \
    "https://raw.githubusercontent.com/chromiumembedded/cef/$CEF_COMMIT/tools/automate/automate-git.py"

# is_official_build matches the Spotify builds; PGO profiles are required with it.
export GN_DEFINES="is_official_build=true proprietary_codecs=true ffmpeg_branding=Chrome symbol_level=0"
export CEF_ARCHIVE_FORMAT=tar.bz2
AUTOMATE=(python3 automate-git.py
    --download-dir="$WORK/chromium_git"
    --depot-tools-dir="$WORK/depot_tools"
    --branch="$CEF_BRANCH"
    --checkout="$CEF_COMMIT"
    --arm64-build
    --no-debug-build
    --no-chromium-history
    --with-pgo-profiles)
CEF_SRC="$WORK/chromium_git/chromium/src/cef"

# Check out Chromium and CEF (CEF applies its own Chromium patches), without building.
"${AUTOMATE[@]}" --no-build --no-distrib

# Kite's patches, each once: a rerun finds them applied already.
for patch in "$ROOT"/patches/cef/*.patch; do
    if git -C "$CEF_SRC" apply --check -R "$patch" 2>/dev/null; then
        echo "Already applied: ${patch##*/}"
    else
        git -C "$CEF_SRC" apply "$patch"
        echo "Applied: ${patch##*/}"
    fi
done
# The patches add to CEF's C++ API; regenerate its C API and the wrappers between them.
(cd "$CEF_SRC" && python3 tools/version_manager.py -u)

# cefclient: make_distrib only packages the Release framework when cefclient.app
# was built. --force-build: without it a rerun on an unchanged checkout skips the build. Ninja
# only compiles what's left, so a resumed build picks up where it stopped. --no-update keeps
# the patched checkout as it is.
"${AUTOMATE[@]}" \
    --no-update \
    --build-target=cefclient \
    --minimal-distrib-only \
    --no-distrib-docs \
    --no-distrib-symbols \
    --force-build

archive="$WORK/chromium_git/chromium/src/cef/binary_distrib/$NAME.tar.bz2"
if [[ ! -f "$archive" ]]; then
    echo "error: expected $archive; the built version doesn't match $CEF_VERSION:" >&2
    ls "$WORK/chromium_git/chromium/src/cef/binary_distrib" >&2
    exit 1
fi
if ! tar -tjf "$archive" | grep -q "/Release/Chromium Embedded Framework.framework/"; then
    echo "error: $archive has no Release framework" >&2
    exit 1
fi
cp "$archive" "$OUT/$NAME.tar.bz2"
echo "Built $OUT/$NAME.tar.bz2"
echo "Next: scripts/fetch-cef.sh (installs it into ThirdParty/cef), then rm -rf $WORK"
