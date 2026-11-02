#!/usr/bin/env bash
# Downloads the pinned CEF (Chromium Embedded Framework) binary distribution
# into ThirdParty/cef and builds its static C++ wrapper library.
#
# Prefers a build with H.264/AAC from scripts/build-cef.sh (ThirdParty/codecs/)
# when there is one. The downloaded Spotify build has neither, so Reddit and other
# H.264-only video won't play with it.
set -euo pipefail

CEF_VERSION="156.0.7+g47dbc1d+chromium-156.0.8078.17"
CEF_PLATFORM="macosarm64"
CEF_SHA1="038a6ce70a814181f6a507d40155c81e80b328e3"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/ThirdParty/cef"
NAME="cef_binary_${CEF_VERSION}_${CEF_PLATFORM}_minimal"
ARCHIVE="$ROOT/ThirdParty/$NAME.tar.bz2"
CODECS_ARCHIVE="$ROOT/ThirdParty/codecs/$NAME.tar.bz2"
STAMP="$CEF_VERSION"
[[ -f "$CODECS_ARCHIVE" ]] && STAMP="$CEF_VERSION codecs"

if [[ -f "$DEST/.version" && "$(cat "$DEST/.version")" == "$STAMP" ]]; then
    echo "CEF $STAMP already present"
elif [[ -f "$CODECS_ARCHIVE" ]]; then
    rm -rf "$DEST" "$ROOT/ThirdParty/$NAME"
    tar -xjf "$CODECS_ARCHIVE" -C "$ROOT/ThirdParty"
    mv "$ROOT/ThirdParty/$NAME" "$DEST"
    echo "$STAMP" > "$DEST/.version"
else
    echo "note: no H.264/AAC in the downloaded CEF; scripts/build-cef.sh builds one with them"
    mkdir -p "$ROOT/ThirdParty"
    if [[ ! -f "$ARCHIVE" ]]; then
        url="https://cef-builds.spotifycdn.com/$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$NAME.tar.bz2")"
        echo "Downloading $url"
        curl -fL --progress-bar -o "$ARCHIVE.part" "$url"
        mv "$ARCHIVE.part" "$ARCHIVE"
    fi
    echo "$CEF_SHA1  $ARCHIVE" | shasum -a 1 -c -
    rm -rf "$DEST" "$ROOT/ThirdParty/$NAME"
    tar -xjf "$ARCHIVE" -C "$ROOT/ThirdParty"
    mv "$ROOT/ThirdParty/$NAME" "$DEST"
    echo "$STAMP" > "$DEST/.version"
    rm -f "$ARCHIVE"
fi

# libcef_dll_wrapper: CEF's C++ API on top of its C ABI, plus the framework loader.
if [[ ! -f "$DEST/build/libcef_dll_wrapper/libcef_dll_wrapper.a" ]]; then
    cmake -S "$DEST" -B "$DEST/build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DPROJECT_ARCH=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    cmake --build "$DEST/build" --target libcef_dll_wrapper
fi
echo "CEF ready at $DEST"
