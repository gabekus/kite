#!/usr/bin/env bash
# Builds a release Kite.app and installs it to /Applications, so Kite opens
# from the Dock, Launchpad and Spotlight like any other app.
# Usage: scripts/install-app.sh [destination dir, default /Applications]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="${1:-/Applications}"
DEST="$DEST_DIR/Kite.app"
cd "$ROOT"

scripts/bundle-app.sh release

# Only replace an earlier Kite build, never some other app with the same name.
if [[ -e "$DEST" ]]; then
    id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$id" != "dev.gabek.Kite" ]]; then
        echo "error: $DEST exists and isn't Kite ($id); move it first" >&2
        exit 1
    fi
    if pgrep -xq Kite; then
        echo "error: Kite is running; quit it first" >&2
        exit 1
    fi
    rm -rf "$DEST"
fi

ditto build/Kite.app "$DEST"
# Make Finder, the Dock and Spotlight pick up the new icon now, not after a relaunch.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
touch "$DEST"
echo "Installed $DEST"
