#!/usr/bin/env bash
# Builds a release Kite.app and packs it into a folder you can hand someone:
#   dist/Kite/            Kite.app, install.sh, README.md, SETUP.md
#   dist/Kite-<version>-<commit>.zip   the same folder, zipped
# They unzip it and run `bash install.sh`, which installs Kite and starts `kite setup`
# (Claude Code with Resources/SETUP.md).
#
# Signing is bundle-app.sh's: a Developer ID cert when there is one. The app is then notarized
# and stapled (scripts/notarize.sh), so Gatekeeper opens it. KITE_SKIP_NOTARIZE=1 skips that for a
# local test, and install.sh still clears the quarantine flag for such a build.
#
# Builds into this checkout's build/, so run it in its own worktree, not in one that
# install-app.sh or update-app.sh are using. It never touches /Applications.
# Usage: scripts/package-share.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -d ThirdParty/cef/Release ]]; then
    echo "error: no CEF in ThirdParty/cef: run scripts/fetch-cef.sh (or symlink another checkout's), or the build is WebKit-only" >&2
    exit 1
fi

# The shared Kite updates itself from GitHub Releases (Sparkle, docs/updates.md), so this is the
# last build anyone has to be sent by hand.
export KITE_UPDATE_FEED="${KITE_UPDATE_FEED:-https://github.com/gabekus/kite/releases/latest/download/appcast.xml}"

# Notarization needs the notarytool profile; check it now rather than after a long build.
[[ "${KITE_SKIP_NOTARIZE:-}" == 1 ]] || scripts/notarize.sh --check
export KITE_HARDENED_RUNTIME=1

# The ad blocker links only when its library exists (see install-app.sh).
ADBLOCK_LIB="Sources/KiteAdblock/rust/target/lib/libkite_adblock.a"
[[ -f "$ADBLOCK_LIB" ]] || scripts/build-adblock.sh
links_adblock() { [[ $(nm build/Kite.app/Contents/MacOS/Kite 2>/dev/null | grep -c ka_engine_) -gt 0 ]]; }
scripts/bundle-app.sh release
if ! links_adblock; then
    swift build -c release --manifest-cache none --product Kite
    scripts/bundle-app.sh release
fi
links_adblock || { echo "error: build/Kite.app doesn't link the ad blocker" >&2; exit 1; }

codesign --verify --deep --strict build/Kite.app
TEAM="$(codesign -dv build/Kite.app 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [[ -z "$TEAM" || "$TEAM" == "not set" ]]; then
    echo "warning: Kite.app isn't signed with a Developer ID; the keychain will ask again on every update" >&2
fi
if [[ "${KITE_SKIP_NOTARIZE:-}" == 1 ]]; then
    echo "warning: not notarized (KITE_SKIP_NOTARIZE=1), so macOS blocks it unless install.sh runs" >&2
else
    scripts/notarize.sh build/Kite.app
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Kite.app/Contents/Info.plist)"
commit="$(git rev-parse --short HEAD)"
OUT="$ROOT/dist/Kite"
rm -rf "$OUT"
mkdir -p "$OUT"
ditto build/Kite.app "$OUT/Kite.app"
cp Resources/share/install.sh Resources/share/README.md Resources/SETUP.md "$OUT/"
chmod +x "$OUT/install.sh"
echo "$version ($commit), built $(date -u +%Y-%m-%dT%H:%MZ)" > "$OUT/VERSION"

ZIP="$ROOT/dist/Kite-$version-$commit.zip"
rm -f "$ZIP"
# ditto keeps the bundle's symlinks and signatures intact; plain zip breaks the framework.
ditto -c -k --sequesterRsrc --keepParent "$OUT" "$ZIP"
echo "Built $OUT"
echo "Zipped $ZIP ($(du -h "$ZIP" | cut -f1))"
