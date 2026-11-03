#!/usr/bin/env bash
# End-to-end test of the handoff ring (UserHandoff.ringFunction) on single-page-app cases: it must settle on
# the real control, not on text that mentions it or a skeleton, follow the page as it redraws, find controls in
# same-origin frames, and report a turned-off control with the page's reason. The cases are
# Tests/Browser/handoff/ring.html. The ring runs in the page's main world here so the test can read where it
# settled (in Kite it runs in an isolated world; the code is the same).
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
python3 "$ROOT/Tests/Browser/handoff/server.py" "$PORT" &
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
# kite js wraps the value in page-content tags: the value is the line after the opening tag.
js() { "$CLI" js "$1" --tab "$TAB" | sed -n '3p'; }
js "$RING" >/dev/null

failures=0
passes=0
n=0
# check NAME TEXT_OR_SELECTOR FIELD EXPECTED: draws case NAME, rings TEXT (or a selector starting with "css:"),
# waits for the ring to settle, and compares what it reports.
run() {
    local name=$1 target=$2 key=text value=$2
    [[ $target == css:* ]] && key=selector value=${target#css:}
    n=$((n + 1))
    js "draw('$name'); window.__kiteHandoff && window.__kiteHandoff.clear(); 1" >/dev/null
    local cfg="{step:'t$n',number:1,label:'Test',$key:$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$value"),scroll:false}"
    js "window.__ring($cfg)" >/dev/null
    sleep 0.8
    STATE=$(js "window.__ring($cfg)")
    SETTLED=$(js "settled()")
}
expect() { # DESCRIPTION ACTUAL PYTHON_CONDITION (on s = state, p = settled)
    if python3 -c "import json,sys; s=json.loads(sys.argv[1]); p=json.loads(sys.argv[2]); sys.exit(0 if ($3) else 1)" "$STATE" "$SETTLED"; then
        echo "ok   $1"; passes=$((passes + 1))
    else
        echo "FAIL $1: state $STATE, settled $SETTLED"; failures=$((failures + 1))
    fi
}

run mentions-only "Invite members"
expect "text that only mentions the control isn't ringed" x "not s['found'] and p['el'] is None"
# The button arrives on the page the help line is already on (and stays on): the ring moves to it.
js "draw('mentions-only'); window.__kiteHandoff.clear(); 1" >/dev/null
js "window.__ring({step:'late',number:1,label:'Test',text:'Invite members',scroll:false})" >/dev/null
sleep 0.5
js "app.insertAdjacentHTML('beforeend', '<button id=target>Invite members</button>'); 1" >/dev/null
sleep 0.8
STATE=$(js "window.__ring({step:'late',number:1,label:'Test',text:'Invite members',scroll:false})"); SETTLED=$(js "settled()")
expect "the ring moves to the control once the page draws it" x "s['found'] and p['el'] == '#target' and p['ring'] == p['at']"
# A skeleton, then the button, then the same button redrawn, faster than the ring settles.
js "draw('mentions-only'); window.__kiteHandoff.clear(); 1" >/dev/null
js "window.__ring({step:'redraw',number:1,label:'Test',text:'Invite members',scroll:false}); setTimeout(() => { app.innerHTML = '<button id=first>Invite members</button>'; }, 60); setTimeout(() => { app.innerHTML = '<button id=target>Invite members</button>'; }, 160); 1" >/dev/null
sleep 1
STATE=$(js "window.__ring({step:'redraw',number:1,label:'Test',text:'Invite members',scroll:false})"); SETTLED=$(js "settled()")
expect "a redrawn control: the ring follows to the final one" x "p['el'] == '#target' and p['ring'] == p['at']"
run label-and-button "Invite members"
expect "a real control beats a label that mentions it" x "p['el'] == '#target'"
run disabled-title "Remove member"
expect "a disabled control is reported with the page's reason" x "s['found'] and s['disabled'] and s['why'] == 'Only Super Administrators can remove members' and p['off']"
run aria-disabled "Transfer ownership"
expect "aria-disabled, with its description as the reason" x "s['disabled'] and s['why'] == 'Verify your email address first.'"
run enabled-twin "Save"
expect "of two controls that say the same, the usable one" x "p['el'] == '#target' and not s['disabled'] and not p['off']"
run hidden-first "css:button.go"
expect "a selector rings its first shown match" x "p['el'] == '#target'"
run in-frame "Approve"
expect "a control in a same-origin frame, ringed where it shows" x "p['frame'] and p['el'] == '#target' and p['ring'] == p['at']"
PROBE=$(js "draw('disabled-title'); window.__ring({step:'p',number:1,label:'x',text:'Remove member',probe:true})")
STATE=$PROBE; SETTLED='{}'
expect "a probe reports without drawing" x "s['found'] and s['disabled']"

echo "$passes of $((passes + failures)) checks passed"
[[ $failures -eq 0 ]]
