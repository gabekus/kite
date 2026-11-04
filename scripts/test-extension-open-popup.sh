#!/usr/bin/env bash
# End-to-end test: an extension's chrome.action.openPopup() opens its popup. Chromium can't open
# it in Kite (Kite's tabs are in no window, so there's no toolbar to hang it from), which is why
# 1Password's "Unlock 1Password" button did nothing. The extension is
# Tests/Browser/extension-open-popup; its worker keeps Chromium's own openPopup, taken before
# Kite's script replaces it, so this also shows the failure Kite works around. It also checks the
# popup is sized to its page (220×80), as Chrome sizes popups, not left at the 800×600 most.
# Usage: scripts/test-extension-open-popup.sh [APP]   (default build/Kite.app; never /Applications/Kite.app)
# Launches APP on a fresh test profile in the background and exits non-zero if the popup doesn't
# open or isn't sized to its page.
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
# Chromium's helpers can still be writing to the profile as Kite exits.
cleanup() { kill $PID $SERVER 2>/dev/null; wait $PID 2>/dev/null; [[ -n "${KEEP:-}" ]] || rm -rf "$P" 2>/dev/null || true; }
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
  "$CLI" js "JSON.stringify(await chrome.storage.local.get(['popupOpenedAt', 'popupPage']))" --tab "$TAB" 2>/dev/null |
    grep -E '^\{' | head -1
}
# Asks the worker to open its popup (`message`), and checks the popup page that then loads.
run_case() {
  local message=$1 page=$2 label=$3 before after reply
  before=$(opened_at)
  reply=$(ask "$message")
  after="$before"
  for _ in $(seq 20); do
    after=$(opened_at)
    [[ "$after" != "$before" ]] && break
    sleep 0.25
  done
  if [[ "$reply" == *'"ok":true'* && "$after" != "$before" && "$after" == *"\"/$page\""* ]]; then
    echo "PASS $label"
  else
    echo "FAIL $label: replied ${reply:-nothing}; popup page loads ${before:-?} -> ${after:-?}"
    failures=$((failures + 1))
  fi
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

run_case kite popup.html "openPopup: it resolved and the popup page loaded"

# The open popup's viewport: popup.html's body is 220×80 with no margin.
size=""
for _ in $(seq 20); do
  size=$("$CLI" js "JSON.stringify(chrome.extension.getViews().filter((w) => w.location.pathname === '/popup.html').map((w) => [w.innerWidth, w.innerHeight]))" --tab "$TAB" 2>/dev/null |
    grep -E '^\[' | head -1)
  [[ "$size" == '[[220,80]]' ]] && break
  sleep 0.25
done
if [[ "$size" == '[[220,80]]' ]]; then
  echo "PASS popup size: the popover fits its page (220×80)"
else
  echo "FAIL popup size: the popup's viewport is ${size:-unknown}, not [[220,80]]"
  failures=$((failures + 1))
fi

# Last: the tab's own popup stays set for the rest of the run.
run_case tab tab-popup.html "tab popup: it opened the popup set for the active tab"
exit $((failures > 0))
