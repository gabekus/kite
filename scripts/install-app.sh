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

# Package.swift links the ad blocker only when its static library exists, and leaves it out
# silently otherwise, so a fresh checkout (like ../kite-release) used to ship with no ad
# blocking at all. Build the library first, then check the binary really links it.
ADBLOCK_LIB="Sources/KiteAdblock/rust/target/lib/libkite_adblock.a"
if [[ ! -f "$ADBLOCK_LIB" ]]; then
    scripts/build-adblock.sh
fi
links_adblock() { [[ $(nm build/Kite.app/Contents/MacOS/Kite 2>/dev/null | grep -c ka_engine_) -gt 0 ]]; }
scripts/bundle-app.sh release
if ! links_adblock; then
    # SwiftPM can reuse a manifest evaluated before the library existed.
    echo "note: Kite built without the ad blocker; rebuilding with a fresh manifest" >&2
    swift build -c release --manifest-cache none --product Kite
    scripts/bundle-app.sh release
fi
if ! links_adblock; then
    echo "error: build/Kite.app doesn't link the ad blocker (no ka_engine_ symbols); not installing" >&2
    exit 1
fi
# Copy aside first, then rename, so a waiting swap never sees a half-copied app.
rm -rf "$STAGED.tmp"
ditto build/Kite.app "$STAGED.tmp"
rm -rf "$STAGED"
mv "$STAGED.tmp" "$STAGED"
version="$(git rev-parse --short HEAD)"

# Moves the staged build into place, if one is still waiting. Several waiters can wake at
# once (each install while Kite was open left one), so each first claims the staged build
# with a single rename: only one of them gets it, and the rest find nothing to do. Checking
# for it and then deleting Kite.app let a second waiter delete the app the first had just
# moved in.
#
# Never while a Kite from $DEST is running: deleting the bundle under a running Kite leaves it
# on an unlinked executable, and macOS then can't resolve its path, so Kite turns away every
# Accessibility client (window managers like Hammerspoon and Raycast stop moving its windows)
# until it's relaunched. That happened when Kite was quit and reopened within the waiter's 1s poll.
kite_running() { pgrep -f "^$DEST/Contents/MacOS/Kite( |\$)" >/dev/null; }
swap() {
    local claimed="$DEST_DIR/.Kite.app.swapping.$$"
    kite_running && return 1
    mv "$STAGED" "$claimed" 2>/dev/null || return 0
    rm -rf "$DEST"
    mv "$claimed" "$DEST"
    # Make Finder, the Dock and Spotlight pick up the new icon now, not after a relaunch.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
    touch "$DEST"
}

# Swaps in the background as soon as no Kite from $DEST is running. A later install replaces
# the staged build. One waiter is enough: an earlier one would move in whatever is staged
# anyway, so it's replaced rather than joined. It waits for every Kite from $DEST, not one pid:
# a Kite reopened in the meantime runs the old build, so the swap waits for that one to quit too.
WAITER="$DEST_DIR/.Kite.app.waiter"
stage_for_quit() {
    if [[ -f "$WAITER" ]]; then
        read -r old_pid < "$WAITER" || true
        if kill -0 "${old_pid:-0}" 2>/dev/null && ps -o command= -p "$old_pid" | grep -q "Kite.app.new"; then
            kill "$old_pid" 2>/dev/null || true
        fi
    fi
    nohup bash -c "
        $(declare -f kite_running swap)
        DEST='$DEST' DEST_DIR='$DEST_DIR' STAGED='$STAGED'
        until swap; do sleep 1; done
        rm -f '$WAITER'
    " >/dev/null 2>&1 &
    echo "$!" > "$WAITER"
    disown
}

# Just this install's process: test builds elsewhere share the bundle id.
pid="$(pgrep -f "^$DEST/Contents/MacOS/Kite( |\$)" | head -1 || true)"
if [[ -z "$pid" ]] && swap; then
    echo "Installed $DEST ($version)"
    exit 0
fi

if [[ "$RESTART" == 0 || -z "$pid" ]]; then
    stage_for_quit
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
if kill -0 "$pid" 2>/dev/null || ! swap; then
    stage_for_quit
    echo "error: Kite didn't quit (or was opened again); $version is staged and goes in when it quits" >&2
    exit 1
fi
echo "Installed $DEST ($version)"
open "$DEST"
