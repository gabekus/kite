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

# One update at a time: two runs share $WT, and a second checkout mid-build
# mixes branches into one binary. mkdir is atomic (macOS has no flock).
LOCK="$WT.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    HOLDER="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [[ -n "$HOLDER" ]] && kill -0 "$HOLDER" 2>/dev/null; then
        echo "update-app.sh: another update is running (pid $HOLDER, $(cat "$LOCK/branch" 2>/dev/null || echo '?')). Try again when it finishes." >&2
        exit 1
    fi
    # Its holder died without cleaning up.
    rm -rf "$LOCK"
    mkdir "$LOCK"
fi
echo $$ > "$LOCK/pid"
echo "$BRANCH" > "$LOCK/branch"
trap 'rm -rf "$LOCK"' EXIT

git -C "$ROOT" fetch origin "$BRANCH"
if [[ ! -e "$WT/.git" ]]; then
    git -C "$ROOT" worktree add --detach "$WT" "origin/$BRANCH"
else
    git -C "$WT" checkout --detach --force "origin/$BRANCH"
    # Drop leftovers from the last branch; ignored files (.build) stay as the build cache.
    git -C "$WT" clean -fdq
fi

# Reuse this checkout's CEF rather than downloading it again.
if [[ ! -e "$WT/ThirdParty/cef" && -d "$ROOT/ThirdParty/cef" ]]; then
    mkdir -p "$WT/ThirdParty"
    ln -s "$ROOT/ThirdParty/cef" "$WT/ThirdParty/cef"
fi

"$WT/scripts/install-app.sh" ${INSTALL_ARGS[@]+"${INSTALL_ARGS[@]}"}
