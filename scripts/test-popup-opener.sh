#!/usr/bin/env bash
# End-to-end test: a page's popup keeps window.opener, its postMessage reaches the opener and its
# window.close() closes it. This is what Sign in with Apple (appleid.auth.js, usePopup), Google
# Identity Services and OAuth popups need. The pages are Tests/Browser/popup-opener: an opener on
# http://127.0.0.1:A and a popup on http://localhost:B, so they're cross-origin.
# Usage: scripts/test-popup-opener.sh [APP]   (default build/Kite.app; never /Applications/Kite.app)
# Launches APP on a fresh test profile in the background and exits non-zero if any case fails.
# The last case leaves the popup open while seven other tabs are shown: Kite keeps only six pages
# live, and before the fix it hibernated the opener (reloading it) and cut the popup off, which is
# what macOS memory pressure did to Squarespace's "Verify to continue" during Sign in with Apple.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/Kite.app}"
[[ "$(cd "$APP" && pwd)" != /Applications/* ]] || { echo "test builds only, not $APP" >&2; exit 2; }
CLI="$APP/Contents/Helpers/kite"
PORT_A="${PORT_A:-18791}"; PORT_B=$((PORT_A + 1))

P=$(mktemp -d /tmp/k.XXXX)
[[ -d "$P" ]] || { echo "profile not a directory" >&2; exit 1; }
export KITE_SUPPORT_PATH=$P KITE_TEST_BLOCK_VIEWS_WINDOWS=1 TYPESAFE_API_KEY=x KITE_DIAGNOSTICS=1
python3 "$ROOT/Tests/Browser/popup-opener/server.py" "$PORT_A" "$PORT_B" &
SERVER=$!
"$APP/Contents/MacOS/Kite" --disable-backgrounding-occluded-windows >"$P/kite.log" 2>&1 &
PID=$!
cleanup() { kill $PID $SERVER 2>/dev/null; wait $PID 2>/dev/null; [[ -n "${KEEP:-}" ]] || rm -rf "$P"; }
trap cleanup EXIT
for _ in $(seq 60); do "$CLI" ui windows >/dev/null 2>&1 && break; sleep 0.5; done
grep -q "CefInitialize failed" "$P/kite.log" && echo "note: Chromium didn't start; this run is WebKit"

OPENER="http://127.0.0.1:$PORT_A/opener.html"
"$CLI" open "$OPENER" --here >/dev/null
TAB=$("$CLI" tabs | awk -v u="$OPENER" 'index($0, u) && /^- tab / {print $3; exit}')
[[ -n "$TAB" ]] || { "$CLI" tabs; echo "opener tab not found" >&2; exit 1; }

failures=0
# What the opener recorded for one case (kite js wraps the value in page-content tags).
results() { "$CLI" js "JSON.stringify(window.results['$1'] || null)" --tab "$TAB" 2>/dev/null | grep -E '^(\{|null)' | head -1; }
# Each case: click the control in the opener (a real click: popups need a user gesture), then wait
# for the popup's message and for the popup to close.
run_case() {
  local mode=$1 selector=$2 result=""
  "$CLI" click --selector "$selector" --tab "$TAB" >/dev/null
  for _ in $(seq 40); do
    result=$(results "$mode")
    [[ "$result" == *'"message":true'* && "$result" == *'"closed":true'* ]] && break
    # A target=_blank link has no handle to poll `closed`: its popup's tab going away is the close.
    if [[ "$mode" == link && "$result" == *'"message":true'* ]] && ! "$CLI" tabs | grep -q "mode=link"; then break; fi
    sleep 0.25
  done
  local popup_left; popup_left=$("$CLI" tabs | grep -c "mode=$mode" || true)
  if [[ "$result" == *'"message":true'* && "$popup_left" == 0 ]]; then
    echo "PASS $mode: opener got the popup's message and the popup closed"
  else
    echo "FAIL $mode: opener saw ${result:-nothing}; popup tabs left: $popup_left"
    failures=$((failures + 1))
  fi
}
front_is_opener() {
  local front; front=$("$CLI" tabs | awk '/front/ && /^- tab / {print $3; exit}')
  if [[ "$front" == "$TAB" ]]; then echo "PASS focus: the opener is in front again after $1"
  else echo "FAIL focus: after $1 the tab in front is ${front:-none}, not the opener"; failures=$((failures + 1)); fi
}
"$CLI" call switch_tab "{\"tab\":\"$TAB\"}" >/dev/null
run_case features "#features"
front_is_opener features
run_case tab "#tab"
run_case hop "#hop"
run_case link "#link"

# The user takes a while in the popup (Touch ID, a password) and looks at other tabs meanwhile.
"$CLI" open "$OPENER?delay=12000" --tab "$TAB" >/dev/null
"$CLI" call switch_tab "{\"tab\":\"$TAB\"}" >/dev/null
"$CLI" click --selector "#features" --tab "$TAB" >/dev/null
sleep 1
for i in 1 2 3 4 5 6 7; do
  other=$("$CLI" call tabs_create "{\"url\":\"http://127.0.0.1:$PORT_A/opener.html?other=$i\",\"active\":true}" | grep -o 'Tab [0-9A-F-]*' | head -1 | cut -c5-)
  "$CLI" call switch_tab "{\"tab\":\"$other\"}" >/dev/null
done
result=""
for _ in $(seq 60); do
  result=$(results features)
  [[ "$result" == *'"message":true'* && "$result" == *'"closed":true'* ]] && break
  sleep 0.5
done
if [[ "$result" == *'"message":true'* && "$result" == *'"closed":true'* ]]; then
  echo "PASS hidden: the opener stayed live behind seven other tabs and got the popup's message"
else
  echo "FAIL hidden: after seven other tabs the opener saw ${result:-nothing} (it was hibernated and reloaded)"
  failures=$((failures + 1))
fi
exit $((failures > 0))
