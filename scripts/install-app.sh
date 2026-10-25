#!/usr/bin/env bash
# Builds a release Kite.app and installs it to /Applications, the one Kite
# that gets used and tested. If that Kite is running, the new build is staged
# next to it and swapped in as soon as Kite quits, so nothing is interrupted.
# With --restart it quits Kite instead (which saves the session), swaps it, and
# opens it again, so tabs come back.
# Usage: scripts/install-app.sh [--restart] [destination dir, default /Applications]
set -euo pipefail

RESTART=0
if [[ "${1:-}" == "--restart" ]]; then
    RESTART=1
    shift
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="${1:-/Applications}"
DEST="$DEST_DIR/Kite.app"
STAGED="$DEST_DIR/.Kite.app.new"
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
# Copy aside first, then rename, so a waiting swap never sees a half-copied app.
rm -rf "$STAGED.tmp"
ditto build/Kite.app "$STAGED.tmp"
rm -rf "$STAGED"
mv "$STAGED.tmp" "$STAGED"
version="$(git rev-parse --short HEAD)"

# Moves the staged build into place, if one is still waiting.
swap() {
    [[ -d "$STAGED" ]] || return 0
    rm -rf "$DEST"
    mv "$STAGED" "$DEST"
    # Make Finder, the Dock and Spotlight pick up the new icon now, not after a relaunch.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
    touch "$DEST"
}

# Just this install's process: test builds elsewhere share the bundle id.
pid="$(pgrep -f "^$DEST/Contents/MacOS/Kite( |\$)" | head -1 || true)"
if [[ -z "$pid" ]]; then
    swap
    echo "Installed $DEST ($version)"
    exit 0
fi

if [[ "$RESTART" == 0 ]]; then
    # Swap once Kite quits. A later install replaces the staged build, and
    # whichever waiter runs first moves in the newest one.
    nohup bash -c "
        while kill -0 $pid 2>/dev/null; do sleep 1; done
        $(declare -f swap)
        DEST='$DEST' STAGED='$STAGED' swap
    " >/dev/null 2>&1 &
    disown
    echo "Kite is open, so $version is staged and goes in when you quit Kite"
    exit 0
fi

echo "Quitting Kite to update it"
# A normal quit, so Kite saves its session first.
osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid).terminate"
for _ in $(seq 60); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
done
if kill -0 "$pid" 2>/dev/null; then
    echo "error: Kite didn't quit within 30s; the update is staged and goes in when it does" >&2
    exit 1
fi
swap
echo "Installed $DEST ($version)"
open "$DEST"
