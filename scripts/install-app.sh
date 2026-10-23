#!/usr/bin/env bash
# Builds a release Kite.app and installs it to /Applications, so Kite opens
# from the Dock, Launchpad and Spotlight like any other app. If that copy of
# Kite is running, it's quit (which saves the session) after the build, swapped,
# and opened again, so tabs come back.
# Usage: scripts/install-app.sh [destination dir, default /Applications]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="${1:-/Applications}"
DEST="$DEST_DIR/Kite.app"
cd "$ROOT"

# Only replace an earlier Kite build, never some other app with the same name.
if [[ -e "$DEST" ]]; then
    id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$id" != "dev.gabek.Kite" ]]; then
        echo "error: $DEST exists and isn't Kite ($id); move it first" >&2
        exit 1
    fi
fi

scripts/bundle-app.sh release
ditto build/Kite.app "$DEST_DIR/.Kite.app.new"

# Just this install's process: test builds elsewhere share the bundle id.
pid="$(pgrep -f "^$DEST/Contents/MacOS/Kite( |\$)" | head -1 || true)"
if [[ -n "$pid" ]]; then
    echo "Quitting Kite to update it"
    # A normal quit, so Kite saves its session first.
    osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid).terminate"
    for _ in $(seq 60); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done
    if kill -0 "$pid" 2>/dev/null; then
        rm -rf "$DEST_DIR/.Kite.app.new"
        echo "error: Kite didn't quit within 30s; quit it and run this again" >&2
        exit 1
    fi
fi

rm -rf "$DEST"
mv "$DEST_DIR/.Kite.app.new" "$DEST"
# Make Finder, the Dock and Spotlight pick up the new icon now, not after a relaunch.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
touch "$DEST"
echo "Installed $DEST ($(git rev-parse --short HEAD))"
if [[ -n "$pid" ]]; then
    open "$DEST"
fi
