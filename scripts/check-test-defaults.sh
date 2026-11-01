#!/usr/bin/env bash
# Checks that a test launch (KITE_SUPPORT_PATH) of a debug bundle keeps its settings out of the
# installed Kite's preferences: it writes a throwaway key and expects it in dev.gabek.Kite.dev only.
# Usage: scripts/check-test-defaults.sh [path/to/Kite.app]   (default: build/Kite.app from bundle-app.sh debug)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/Kite.app}"
ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
if [[ "$ID" == dev.gabek.Kite ]]; then
    echo "FAIL: $APP is dev.gabek.Kite; build it with scripts/bundle-app.sh debug" >&2
    exit 1
fi

PROFILE="$(mktemp -d /tmp/k.XXXX)"
[[ -d "$PROFILE" ]] || { echo "FAIL: no profile directory" >&2; exit 1; }
KEY="kiteTestDefaultsProbe$RANDOM$RANDOM"

KITE_SUPPORT_PATH="$PROFILE" KITE_DIAGNOSTICS=1 KITE_TEST_BLOCK_VIEWS_WINDOWS=1 TYPESAFE_API_KEY=dummy \
    KITE_TEST_DEFAULTS_PROBE="$KEY" "$APP/Contents/MacOS/Kite" >"$PROFILE/kite.log" 2>&1 &
PID=$!
cleanup() {
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    defaults delete "$ID" "$KEY" >/dev/null 2>&1 || true
    rm -rf "$PROFILE"
}
trap cleanup EXIT

for _ in $(seq 1 30); do
    defaults read "$ID" "$KEY" >/dev/null 2>&1 && break
    sleep 1
done

status=0
if defaults read dev.gabek.Kite "$KEY" >/dev/null 2>&1; then
    defaults delete dev.gabek.Kite "$KEY"
    echo "FAIL: the test launch wrote $KEY to dev.gabek.Kite (removed again)" >&2
    status=1
fi
if ! defaults read "$ID" "$KEY" >/dev/null 2>&1; then
    echo "FAIL: $KEY never reached $ID, so the probe didn't run" >&2
    status=1
fi
[[ $status == 0 ]] && echo "OK: a test launch of $ID wrote to $ID, not dev.gabek.Kite"
exit $status
