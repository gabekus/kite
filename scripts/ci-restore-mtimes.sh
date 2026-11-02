#!/bin/bash
# CI only. Makes a .build restored from cache usable for an incremental build.
#
# A fresh checkout gives every file the same "now" mtime, so SwiftPM and the
# Swift driver would treat every source as changed and rebuild everything.
# Instead every tracked file gets one fixed old mtime (the same one the cached
# build saw), and only files that changed since the cached build's commit get
# the current time, so just those (and their dependents) recompile.
#
# Without a usable cache it still normalizes mtimes, so the build this run
# saves for main is keyed to the same fixed mtime.
set -euo pipefail

FIXED=200101010000 # 2001-01-01, touch -t format
cd "$(git rev-parse --show-toplevel)"

git ls-files -z | xargs -0 touch -h -t "$FIXED"

built_file=.build/ci-built-sha
if [[ ! -d .build ]]; then
  echo "No cached build: cold build."
  exit 0
fi
if [[ ! -f $built_file ]]; then
  echo "Cached build has no commit stamp: discarding it."
  rm -rf .build
  exit 0
fi

built=$(cat "$built_file")
if ! git cat-file -e "${built}^{commit}" 2>/dev/null; then
  git fetch --quiet --filter=blob:none origin "$built" 2>/dev/null || true
fi
if ! git cat-file -e "${built}^{commit}" 2>/dev/null; then
  echo "Cached build's commit $built is unknown: discarding the cache."
  rm -rf .build
  exit 0
fi

changed=$(git diff --name-only "$built" HEAD -- | while read -r f; do [[ -e $f ]] && echo "$f"; done)
count=$(printf '%s' "$changed" | grep -c . || true)
echo "Cached build is from ${built:0:9}; $count file(s) changed since then."
if [[ -n $changed ]]; then
  printf '%s\n' "$changed" | tr '\n' '\0' | xargs -0 touch -h
fi
