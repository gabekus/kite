#!/bin/zsh
# Builds and runs the DirectoryWatcher check (scripts/checks/directory-watcher/main.swift) in a scratch
# folder under /tmp (through the /tmp symlink, on purpose).
set -e
repo=${0:A:h:h:h}
work=$(mktemp -d /tmp/kite-watcher-check.XXXX)
trap 'rm -rf "$work"' EXIT
swiftc -swift-version 6 -o "$work/check" "$repo/Sources/KiteMac/DirectoryWatcher.swift" "$repo/scripts/checks/directory-watcher/main.swift"
mkdir "$work/root"
"$work/check" "$work/root"
