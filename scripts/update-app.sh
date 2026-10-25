#!/usr/bin/env bash
# Updates /Applications/Kite.app to the latest origin/main (or another branch,
# to test it). Builds in its own worktree (../kite-release), so whatever is
# checked out here is left alone. See install-app.sh for what happens when Kite
# is open, and for --restart.
# Usage: scripts/update-app.sh [--restart] [branch, default main]
set -euo pipefail

INSTALL_ARGS=()
if [[ "${1:-}" == "--restart" ]]; then
    INSTALL_ARGS+=(--restart)
    shift
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRANCH="${1:-main}"
WT="$(dirname "$ROOT")/kite-release"

git -C "$ROOT" fetch origin "$BRANCH"
if [[ ! -e "$WT/.git" ]]; then
    git -C "$ROOT" worktree add --detach "$WT" "origin/$BRANCH"
else
    git -C "$WT" checkout --detach --force "origin/$BRANCH"
fi

# Reuse this checkout's CEF rather than downloading it again.
if [[ ! -e "$WT/ThirdParty/cef" && -d "$ROOT/ThirdParty/cef" ]]; then
    mkdir -p "$WT/ThirdParty"
    ln -s "$ROOT/ThirdParty/cef" "$WT/ThirdParty/cef"
fi

"$WT/scripts/install-app.sh" ${INSTALL_ARGS[@]+"${INSTALL_ARGS[@]}"}
