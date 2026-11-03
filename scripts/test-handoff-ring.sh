#!/usr/bin/env bash
# End-to-end test of the handoff ring (UserHandoff.ringFunction) on single-page-app cases: it must settle on
# the real control, not on text that mentions it or a skeleton, follow the page as it redraws, find controls in
# same-origin frames, report a turned-off control with the page's reason, and count only real clicks on the
# ringed control. The cases are Tests/Browser/handoff/ring.html, run with the ring in the page's main world so
# the test can read where it settled (in Kite it runs in an isolated world; the code is the same). The last
# cases go through Kite's own handoff tool, in its isolated world, on Tests/Browser/handoff/settle.html, a page
# that redraws its controls on timers.
# Usage: scripts/test-handoff-ring.sh [APP]   (default build/Kite.app; never /Applications/Kite.app)
# RING_SOURCE=path/to/UserHandoff.swift tests another version of the ring (an older one should fail).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/Kite.app}"
[[ "$(cd "$APP" && pwd)" != /Applications/* ]] || { echo "test builds only, not $APP" >&2; exit 2; }
CLI="$APP/Contents/Helpers/kite"
PORT="${PORT:-18795}"

P=$(mktemp -d /tmp/k.XXXX)
[[ -d "$P" ]] || { echo "profile not a directory" >&2; exit 1; }
export KITE_SUPPORT_PATH=$P KITE_TEST_BLOCK_VIEWS_WINDOWS=1 TYPESAFE_API_KEY=x KITE_DIAGNOSTICS=1
python3 "$ROOT/Tests/Browser/handoff/server.py" "$PORT" 2>/dev/null &
SERVER=$!
"$APP/Contents/MacOS/Kite" --disable-backgrounding-occluded-windows >"$P/kite.log" 2>&1 &
PID=$!
cleanup() { kill $PID $SERVER 2>/dev/null; wait $PID 2>/dev/null; [[ -n "${KEEP:-}" ]] || rm -rf "$P"; }
trap cleanup EXIT
for _ in $(seq 60); do "$CLI" ui windows >/dev/null 2>&1 && break; sleep 0.5; done
grep -q "CefInitialize failed" "$P/kite.log" && echo "note: Chromium didn't start; this run is WebKit"

PAGE="http://127.0.0.1:$PORT/ring.html"
"$CLI" open "$PAGE" --here >/dev/null
TAB=$("$CLI" tabs | awk -v u="$PAGE" 'index($0, u) && /^- tab / {print $3; exit}')
[[ -n "$TAB" ]] || { "$CLI" tabs; echo "test tab not found" >&2; exit 1; }

RING=$(python3 - "${RING_SOURCE:-$ROOT/Sources/KiteCore/Automation/UserHandoff.swift}" <<'PY'
import sys
s = open(sys.argv[1]).read()
print("window.__ring = " + s.split('static let ringFunction = #"""')[1].split('"""#')[0].strip() + "; 1")
PY
)
# A page script's value: kite js wraps it in page-content tags.
js() { "$CLI" js "$1" --tab "$TAB" | awk '/^<untrusted-page-content/ {on = 1; next} /^<\/untrusted-page-content>/ {on = 0} on'; }
quote() { python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"; }
js "$RING" >/dev/null

failures=0
passes=0
STATE='{}' SETTLED='{}'
check() { python3 -c "import json,sys; s=json.loads(sys.argv[1] or '{}'); p=json.loads(sys.argv[2] or '{}'); sys.exit(0 if ($1) else 1)" "$STATE" "$SETTLED"; }
# expect DESCRIPTION CONDITION: polls (up to 3s) until CONDITION holds on s (what the ring reported) and p
# (where it settled), so the test doesn't race the ring's own timing.
expect() {
    for _ in $(seq 15); do
        STATE=$(js "window.__ring(window.__cfg)"); SETTLED=$(js "settled()")
        check "$2" && { echo "ok   $1"; passes=$((passes + 1)); return; }
        sleep 0.2
    done
    echo "FAIL $1: state $STATE, settled $SETTLED"; failures=$((failures + 1))
}
# ring CASE KEY VALUE [SCROLL]: draws a case and rings a text, selector or marker on it.
ring() {
    js "draw('$1'); window.__kiteHandoff && window.__kiteHandoff.clear(); scrollTo(0, 0);
        window.__cfg = {step: 's' + Math.random(), number: 1, label: 'Test', $2: $(quote "$3"), scroll: ${4:-false}};
        window.__ring(window.__cfg); window.__cfg.scroll = false; 1" >/dev/null
}

ring mentions-only text "Invite members"
sleep 0.6
expect "text that only mentions the control isn't ringed" "not s['found'] and p['el'] is None"
js "app.insertAdjacentHTML('beforeend', '<button id=target>Invite members</button>'); 1" >/dev/null
expect "the ring moves to the control once the page draws it, and stays off the help line" "p['el'] == '#target' and p['ring'] == p['at']"
ring mentions-only text "Invite members"
js "setTimeout(() => { app.innerHTML = '<button id=first>Invite members</button>'; }, 60);
    setTimeout(() => { app.innerHTML = '<button id=target>Invite members</button>'; }, 160); 1" >/dev/null
expect "a control redrawn while it settles: the ring lands on the final one" "p['el'] == '#target' and p['ring'] == p['at']"
js "app.innerHTML = '<button id=redrawn>Invite members</button>'; 1" >/dev/null
expect "a ringed control the page replaces: the ring follows" "p['el'] == '#redrawn'"
ring label-and-button text "Invite members"
expect "a real control beats a label that mentions it" "p['el'] == '#target'"
ring split-words text "Continue with Google"
expect "words split across blocks inside a button" "p['el'] == '#target'"
ring long-label text "Delete"
expect "a control whose words start with the text" "p['el'] == '#target'"
ring disabled-title text "Remove member"
expect "a disabled control is reported with the page's reason" "s['found'] and s['disabled'] and s['why'] == 'Only Super Administrators can remove members' and p['off']"
ring aria-disabled text "Transfer ownership"
expect "aria-disabled, with its description as the reason" "s['disabled'] and s['why'] == 'Verify your email address first.' and p['off']"
"$CLI" click --selector "#target" --tab "$TAB" >/dev/null
sleep 0.3
expect "a click on a turned-off control doesn't count" "s['done'] is None"
ring enabled-twin text "Save"
expect "of two controls that say the same, the usable one" "p['el'] == '#target' and not s['disabled'] and not p['off']"
"$CLI" click --selector "button[disabled]" --tab "$TAB" >/dev/null 2>&1 || true
"$CLI" click --selector "#target" --tab "$TAB" >/dev/null
expect "a click on the ringed control counts" "s['done'] == 'click'"
ring hidden-first selector "button.go"
expect "a selector rings its first shown match" "p['el'] == '#target'"
ring closed-menu marker "m1"
sleep 0.6
expect "a marked control that's hidden isn't swapped for another with its words" "not s['found'] and p['el'] is None"
ring far-below text "Save changes" true
expect "the first look scrolls a control that settles later into view" "p['el'] == '#target' and p['at'][1] < 900"
ring in-frame text "Approve"
expect "a control in a same-origin frame, ringed where it shows" "p['frame'] and p['el'] == '#target' and p['ring'] == p['at']"
js "document.getElementById('frame').contentWindow.scrollTo(0, 0); document.getElementById('frame').style.height = '10px'; 1" >/dev/null
expect "a frame's control outside the frame's view isn't ringed" "p['el'] == '#target' and p['ring'] is None"
js "window.__kiteHandoff.clear(); draw('disabled-title'); 1" >/dev/null
STATE=$(js "window.__ring({step: 'p', number: 1, label: 'x', text: 'Remove member', probe: true})")
SETTLED=$(js "JSON.stringify({ drew: !!window.__kiteHandoff.host })")
if check "s['found'] and s['disabled'] and not p['drew']"; then echo "ok   a probe reports without drawing"; passes=$((passes + 1));
else echo "FAIL a probe reports without drawing: $STATE $SETTLED"; failures=$((failures + 1)); fi

# Through Kite's handoff tool, in its isolated world, on a page that redraws on timers. (These use the ring
# built into APP, not RING_SOURCE.)
if [[ -z "${RING_SOURCE:-}" ]]; then
    SETTLE="http://127.0.0.1:$PORT/settle.html"
    "$CLI" open "$SETTLE" --tab "$TAB" >/dev/null
    "$CLI" call handoff "{\"reason\":\"Test\",\"tab\":\"$TAB\",\"steps\":[{\"instruction\":\"Invite\",\"text\":\"Invite members\"}]}" >/dev/null
    sleep 4
    status() { "$CLI" call handoff_status '{}' | sed -n 2p; }
    "$CLI" click --selector ".help" --tab "$TAB" >/dev/null
    sleep 1
    if status | grep -q '\[waiting\]'; then echo "ok   handoff: a click on text that mentions the control doesn't end the step"; passes=$((passes + 1));
    else echo "FAIL handoff: the help line ended the step: $(status)"; failures=$((failures + 1)); fi
    "$CLI" click --selector "#invite3" --tab "$TAB" >/dev/null
    sleep 1
    if status | grep -q '\[done\].*clicked'; then echo "ok   handoff: a click on the settled control ends the step"; passes=$((passes + 1));
    else echo "FAIL handoff: the button's click wasn't heard: $(status)"; failures=$((failures + 1)); fi
fi

echo "$passes of $((passes + failures)) checks passed"
[[ $failures -eq 0 ]]
