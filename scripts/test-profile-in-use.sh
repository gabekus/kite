#!/usr/bin/env bash
# End-to-end test of what a Kite does when Chromium won't start (EngineFallback, main.swift):
# 1. A second Kite on a profile another Kite has open (CEF result 24) exits 75 within seconds, naming that Kite's
#    PID, and never falls back to WebKit. It used to retry, drop to WebKit and then hang before finishing launching,
#    and on the real profile that WebKit Kite took Claude's socket with empty carts (5 Nov 2026).
# 2. Chromium failing for any other reason (forced with KITE_TEST_CHROMIUM_FAIL=1, test profiles only) starts Kite
#    again on WebKit in a fresh process, which finishes launching: its socket answers and it says it fell back.
# Usage: scripts/test-profile-in-use.sh [APP]   (default build/Kite.app from bundle-app.sh debug; never /Applications)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/Kite.app}"
CLI="$APP/Contents/Helpers/kite"
# shellcheck source=lib/test-kite.sh
source "$(dirname "$0")/lib/test-kite.sh"
[[ -d "$APP/Contents/Frameworks/Chromium Embedded Framework.framework" ]] || { echo "needs a Chromium build of Kite" >&2; exit 2; }

P=$(kite_test_profile)
export KITE_SUPPORT_PATH=$P KITE_TEST_BLOCK_VIEWS_WINDOWS=1 TYPESAFE_API_KEY=x KITE_DIAGNOSTICS=1
kite_check_test_launch "$APP" "$P" || exit 2
PIDS=()
cleanup() {
    for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    sleep 1
    pkill -f "$P" 2>/dev/null || true
    [[ -n "${KEEP:-}" ]] || rm -rf "$P" "$P.second.log" "$P.fallback.log" "${Q:-}" 2>/dev/null || true
}
trap cleanup EXIT
failures=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi; }

# 1. The profile is open in a first Kite.
"$APP/Contents/MacOS/Kite" >"$P/kite.log" 2>&1 &
FIRST=$!
PIDS+=("$FIRST")
for _ in $(seq 60); do "$CLI" ui windows >/dev/null 2>&1 && break; sleep 0.5; done
"$CLI" ui windows >/dev/null 2>&1 || { tail -20 "$P/kite.log"; echo "the first Kite never answered" >&2; exit 1; }

start=$(date +%s)
status=0
perl -e 'alarm shift; exec @ARGV' 90 "$APP/Contents/MacOS/Kite" >"$P.second.log" 2>&1 || status=$?
took=$(( $(date +%s) - start ))
check "a second Kite on the open profile exits 75 (got $status, ${took}s)" '[[ $status == 75 ]]'
check "it says so in under 30 s" '[[ $took -lt 30 ]]'
check "it names the Kite that has the profile (PID $FIRST)" 'grep -q "already open in another Kite, PID $FIRST " "$P.second.log"'
check "it never falls back to WebKit" '! grep -q "WebKit" "$P.second.log"'
check "the first Kite still serves Claude" '"$CLI" server | grep -q "PID $FIRST "'

# 2. Chromium failing for another reason: WebKit, in a fresh process that finishes launching.
Q=$(kite_test_profile)
(
    export KITE_SUPPORT_PATH=$Q KITE_TEST_CHROMIUM_FAIL=1 KITE_CHROMIUM_ATTEMPT=4
    kite_check_test_launch "$APP" "$Q" || exit 2
    exec "$APP/Contents/MacOS/Kite" >"$P.fallback.log" 2>&1
) &
FALLBACK=$!
PIDS+=("$FALLBACK")
up=0
for _ in $(seq 60); do KITE_SUPPORT_PATH=$Q "$CLI" ui windows >/dev/null 2>&1 && { up=1; break; }; sleep 0.5; done
check "the WebKit fallback finishes launching (its socket answers)" '[[ $up == 1 ]]'
check "it's the same process, started again on WebKit" 'KITE_SUPPORT_PATH=$Q "$CLI" server | grep -q "PID $FALLBACK "'
check "it says it fell back" 'grep -q "KITE_TEST_MODAL: alert: Kite started on its backup engine" "$P.fallback.log"'

[[ $failures == 0 ]] || { echo "$failures failed" >&2; exit 1; }
echo "OK"
