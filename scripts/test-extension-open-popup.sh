#!/usr/bin/env bash
# End-to-end test: an extension's chrome.action.openPopup() opens its popup. Chromium can't open
# it in Kite (Kite's tabs are in no window, so there's no toolbar to hang it from), which is why
# 1Password's "Unlock 1Password" button did nothing. The extension is
# Tests/Browser/extension-open-popup; its worker keeps Chromium's own openPopup, taken before
# Kite's script replaces it, so this also shows the failure Kite works around.
# Usage: scripts/test-extension-open-popup.sh [APP]   (default build/Kite.app; never /Applications/Kite.app)
# Launches APP on a fresh test profile in the background and exits non-zero if the popup doesn't open.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/Kite.app}"
[[ "$(cd "$APP" && pwd)" != /Applications/* ]] || { echo "test builds only, not $APP" >&2; exit 2; }
CLI="$APP/Contents/Helpers/kite"
EXT="$ROOT/Tests/Browser/extension-open-popup"
PORT="${PORT:-18795}"
# An unpacked extension's id comes from its folder's path.
ID=$(python3 -c 'import hashlib, os, sys
print("".join(chr(97 + int(c, 16)) for c in hashlib.sha256(os.path.realpath(sys.argv[1]).encode()).hexdigest()[:32]))' "$EXT")

P=$(mktemp -d /tmp/k.XXXX)
[[ -d "$P" ]] || { echo "profile not a directory" >&2; exit 1; }
export KITE_SUPPORT_PATH=$P KITE_TEST_BLOCK_VIEWS_WINDOWS=1 TYPESAFE_API_KEY=x KITE_DIAGNOSTICS=1
# The start page: the automation tools only open web addresses, so a local page goes on to the
# extension's (web-accessible) trigger page.
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$EXT" >/dev/null 2>&1 &
SERVER=$!
"$APP/Contents/MacOS/Kite" --disable-backgrounding-occluded-windows --load-extension="$EXT" >"$P/kite.log" 2>&1 &
PID=$!
cleanup() { kill $PID $SERVER 2>/dev/null; wait $PID 2>/dev/null; [[ -n "${KEEP:-}" ]] || rm -rf "$P"; }
trap cleanup EXIT
for _ in $(seq 60); do "$CLI" ui windows >/dev/null 2>&1 && break; sleep 0.5; done
if grep -q "CefInitialize failed" "$P/kite.log"; then echo "Chromium didn't start, and WebKit has no extensions" >&2; exit 1; fi

START="http://127.0.0.1:$PORT/trigger.html"
TRIGGER="chrome-extension://$ID/trigger.html"
"$CLI" open "$START" --here >/dev/null
TAB=$("$CLI" tabs | awk -v u="$START" 'index($0, u) && /^- tab / {print $3; exit}')
[[ -n "$TAB" ]] || { "$CLI" tabs; echo "start tab not found" >&2; exit 1; }
"$CLI" js "location.href = '$TRIGGER'" --tab "$TAB" >/dev/null
for _ in $(seq 20); do "$CLI" tabs | grep -q "$TRIGGER" && break; sleep 0.25; done
"$CLI" tabs | grep -q "$TRIGGER" || { "$CLI" tabs; echo "the tab didn't reach $TRIGGER" >&2; exit 1; }

# The worker's reply to `message`, and when the popup page last loaded (kite js waits only for a
# top-level await, and wraps values in page-content tags).
ask() {
  "$CLI" js "await new Promise((r) => chrome.runtime.sendMessage('$1', (v) => r(JSON.stringify(v))))" --tab "$TAB" 2>/dev/null |
    grep -E '^\{' | head -1
}
opened_at() {
  "$CLI" js "JSON.stringify({ at: (await chrome.storage.local.get('popupOpenedAt')).popupOpenedAt ?? 0 })" --tab "$TAB" 2>/dev/null |
    grep -E '^\{' | head -1
}

failures=0
echo "Chromium's own openPopup: $(ask native)"

# Kite's script reaches the worker once Kite's helper has attached to it.
replaced=""
for _ in $(seq 40); do
  replaced=$(ask replaced)
  [[ "$replaced" == *'"replaced":true'* ]] && break
  sleep 0.25
done
if [[ "$replaced" != *'"replaced":true'* ]]; then
  echo "FAIL replaced: Kite's script never replaced action.openPopup (${replaced:-no reply})"
  exit 1
fi

before=$(opened_at)
reply=$(ask kite)
after="$before"
for _ in $(seq 20); do
  after=$(opened_at)
  [[ "$after" != "$before" ]] && break
  sleep 0.25
done
if [[ "$reply" == *'"ok":true'* && "$after" != "$before" ]]; then
  echo "PASS openPopup: it resolved and the popup page loaded"
else
  echo "FAIL openPopup: replied ${reply:-nothing}; popup page loads ${before:-?} -> ${after:-?}"
  failures=$((failures + 1))
fi
exit $((failures > 0))
