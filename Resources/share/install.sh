#!/usr/bin/env bash
# Installs the Kite.app next to this script, then offers to set it up with Claude.
# Run it from Terminal: bash install.sh
# (Double-clicking a downloaded script gets blocked by macOS, running it with bash doesn't.)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/Kite.app"
if [[ ! -d "$SRC" && -f "$HERE/Kite.zip" ]]; then
    ditto -x -k "$HERE/Kite.zip" "$HERE"
fi
if [[ ! -d "$SRC" ]]; then
    echo "error: Kite.app isn't next to this script ($HERE)." >&2
    exit 1
fi

# /Applications needs an admin account; work Macs often don't give you one.
DEST_DIR=/Applications
if [[ ! -w "$DEST_DIR" ]]; then
    DEST_DIR="$HOME/Applications"
    mkdir -p "$DEST_DIR"
fi
DEST="$DEST_DIR/Kite.app"

if [[ -e "$DEST" ]]; then
    id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$id" != "dev.gabek.Kite" ]]; then
        echo "error: $DEST exists and isn't Kite ($id). Move it first." >&2
        exit 1
    fi
    if pgrep -f "$DEST/Contents/MacOS/Kite" >/dev/null; then
        echo "Kite is open. Quit it (⌘Q), then run this again."
        exit 1
    fi
    echo "Replacing the Kite in $DEST_DIR (your tabs and settings stay)."
    rm -rf "$DEST"
fi

echo "Installing Kite to $DEST_DIR…"
ditto "$SRC" "$DEST"
# This build isn't notarized yet, and macOS refuses to open downloaded apps that aren't.
# The quarantine flag is what marks it as downloaded; removing it is the same as
# System Settings › Privacy & Security › Open Anyway.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "Opening Kite…"
open "$DEST"

KITE="$DEST/Contents/Helpers/kite"
cat <<EOF

Kite is installed. To let Claude use it:
  1. In Kite's menu bar, choose Kite › Allow Claude to Control the Browser.
  2. Then set it up with Claude (it walks you through the rest).

EOF
read -r -p "Set Kite up with Claude Code now? [Y/n] " answer || answer=n
if [[ -z "$answer" || "$answer" =~ ^[Yy] ]]; then
    exec "$KITE" setup
fi
echo "Later, run: \"$KITE\" setup"
echo "Using the Claude app instead? Paste it the guide: \"$KITE\" setup --print | pbcopy"
