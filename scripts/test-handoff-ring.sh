#!/usr/bin/env bash
# End-to-end test of the handoff ring (UserHandoff.ringFunction) on single-page-app cases: it must settle on
# the real control, not on text that mentions it or a skeleton, follow the page as it redraws, find controls in
# same-origin frames, report a turned-off control with the page's reason, and count only real clicks on the
# ringed control. The cases are Tests/Browser/handoff/ring.html, run with the ring in the page's main world so
# the test can read where it settled (in Kite it runs in an isolated world; the code is the same). The last
# cases go through Kite's own handoff tool, in its isolated world, on Tests/Browser/handoff/settle.html, a page
# that redraws its controls on timers, and on Tests/Browser/handoff/tag.html: the tag's Skip and Done, steps Kite
# refuses or can't show, and no card in Kite's interface; and on Tests/Browser/handoff/frames.html, a control in a
# frame of another origin (the same site's, as Apple's sign-in form is, and another site's).
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
export KITE_SUPPORT_PATH=$P KITE_TEST_BLOCK_VIEWS_WINDOWS=1 TYPESAFE_API_KEY=x KITE_DIAGNOSTICS=1 KITE_TEST_ALLOW_FORM_PROFILE=1
python3 "$ROOT/Tests/Browser/handoff/server.py" "$PORT" 2>/dev/null &
SERVER=$!
# A second origin, for frames of another origin than the page's.
PORT2=$((PORT + 1))
python3 "$ROOT/Tests/Browser/handoff/server.py" "$PORT2" 2>/dev/null &
SERVER2=$!
"$APP/Contents/MacOS/Kite" --disable-backgrounding-occluded-windows >"$P/kite.log" 2>&1 &
PID=$!
cleanup() { kill $PID $SERVER $SERVER2 2>/dev/null; wait $PID 2>/dev/null; [[ -n "${KEEP:-}" ]] || rm -rf "$P"; }
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
ring frame-below text "Approve" true
expect "the first look scrolls a frame to a control below its fold" "p['frame'] and p['el'] == '#target' and p['ring'] == p['at']"
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
    # The step's line in handoff_status, polled (up to 10s) until it has PATTERN.
    step_has() {
        for _ in $(seq 50); do
            LINE=$("$CLI" call handoff_status '{}' | grep -E '^1\. \[') || true
            grep -qE "$1" <<<"$LINE" && return 0
            sleep 0.2
        done
        return 1
    }
    # Once the page has drawn its final button (#invite3) and the ring has had time to settle on it.
    for _ in $(seq 50); do [[ $(js "String(!!document.getElementById('invite3'))") == true ]] && break; sleep 0.2; done
    sleep 1
    "$CLI" click --selector ".help" --tab "$TAB" >/dev/null
    sleep 1
    if step_has '\[waiting\]'; then echo "ok   handoff: a click on text that mentions the control doesn't end the step"; passes=$((passes + 1));
    else echo "FAIL handoff: the help line ended the step: $LINE"; failures=$((failures + 1)); fi
    "$CLI" click --selector "#invite3" --tab "$TAB" >/dev/null
    if step_has '\[done\].*clicked'; then echo "ok   handoff: a click on the settled control ends the step"; passes=$((passes + 1));
    else echo "FAIL handoff: the button's click wasn't heard: $LINE"; failures=$((failures + 1)); fi

    # The tag beside the ring is the only place a step shows (no card over the page): its Skip and Done end the step,
    # a step Kite can't show is reported to Claude at once, and steps with nowhere to show are refused.
    pass() { echo "ok   $1"; passes=$((passes + 1)); }
    fail() { echo "FAIL $1"; failures=$((failures + 1)); }
    TAGPAGE="http://127.0.0.1:$PORT/tag.html"
    "$CLI" open "$TAGPAGE" --tab "$TAB" >/dev/null
    for _ in $(seq 25); do [[ $(js "String(!!window.tagBox)") == true ]] && break; sleep 0.2; done
    OUT=$("$CLI" call handoff "{\"reason\":\"Test\",\"tab\":\"$TAB\",\"steps\":[{\"instruction\":\"Run it\",\"command\":\"ls\"}]}" 2>&1 || true)
    grep -q "can't show a command" <<<"$OUT" && pass "handoff: a command step is refused" || fail "handoff: a command step: $OUT"
    OUT=$("$CLI" call handoff "{\"reason\":\"Test\",\"tab\":\"$TAB\",\"steps\":[{\"instruction\":\"Read this\"}]}" 2>&1 || true)
    grep -q "needs its control" <<<"$OUT" && pass "handoff: a step without a control is refused" || fail "handoff: a note step: $OUT"
    START=$(date +%s)
    OUT=$("$CLI" call handoff "{\"reason\":\"Test\",\"tab\":\"$TAB\",\"wait\":60,\"steps\":[{\"instruction\":\"Click it\",\"text\":\"Nowhere on this page\"}]}" 2>&1 || true)
    if grep -q "NOT SHOWN: Kite can't find its control" <<<"$OUT" && (( $(date +%s) - START < 15 )); then
        pass "handoff: a control that isn't on the page is reported at once, not waited on"
    else fail "handoff: a missing control ($(( $(date +%s) - START ))s): $OUT"; fi
    "$CLI" call handoff_status '{"cancel":true}' >/dev/null
    # No card over the page: nothing in Kite's own interface says "Claude needs you".
    "$CLI" call handoff "{\"reason\":\"Only you can approve\",\"tab\":\"$TAB\",\"steps\":[{\"instruction\":\"Approve it\",\"text\":\"Approve\"},{\"instruction\":\"Save it\",\"text\":\"Save\"}]}" >/dev/null
    sleep 1
    OUT=$("$CLI" ui tree '{"match":"Claude needs you"}' 2>&1 || true)
    grep -q 'Nothing matches "Claude needs you"' <<<"$OUT" && pass "no card in Kite's interface, only the ring on the page" \
        || fail "a card shows in Kite's interface: $OUT"
    # press WHICH: presses the tag's Done (its right end) or Skip (left of Done) beside control ID.
    press() {
        local box x y
        box=$(js "window.tagBox('$2')")
        x=$(python3 -c "import json,sys; b=json.loads(sys.argv[1]); off=24 if sys.argv[2]=='done' else 68; print(round((b['right']-off)*b['scale']))" "$box" "$1")
        y=$(python3 -c "import json,sys; b=json.loads(sys.argv[1]); print(round(b['y']*b['scale']))" "$box")
        "$CLI" call computer "{\"action\":\"left_click\",\"coordinate\":[$x,$y],\"tab\":\"$TAB\"}" >/dev/null
    }
    # The step's line in handoff_status: N PATTERN, polled.
    nth_has() {
        for _ in $(seq 50); do
            LINE=$("$CLI" call handoff_status '{}' | grep -E "^$1\. \[") || true
            grep -qE "$2" <<<"$LINE" && return 0
            sleep 0.2
        done
        return 1
    }
    press done approve
    nth_has 1 '\[done\].*pressed Done' && pass "the tag's Done ends the step" || fail "the tag's Done: $LINE"
    [[ $(js "String(window.menuOpen)") == true ]] && pass "a press on the tag isn't a press on the page (its menu stays open)" \
        || fail "the page heard the tag's press: presses $(js "JSON.stringify(window.presses)")"
    sleep 1
    press skip save
    nth_has 2 '\[skipped\].*skipped it' && pass "the tag's Skip skips the step (the ring moved on to it)" || fail "the tag's Skip: $LINE"

    # A control in a frame of another origin, which the top page's look can't reach: Kite looks in the frame. Another
    # port of 127.0.0.1 is the same site (the tab's own process, like idmsa.apple.com on appleid.apple.com);
    # localhost is another site (a renderer of its own, reached through its own session).
    # Taking the user to the step (Gabe, 5 Nov 2026: steps on other tabs, nothing ringed where he was). A test run's
    # Kite is never the active app, so it never waits for the user to stop typing.
    front() { "$CLI" tabs | awk '/^- tab / && /front/ {print $3; exit}'; }
    SIGNUP="http://127.0.0.1:$PORT/signup.html"
    "$CLI" open "$SIGNUP" --tab "$TAB" >/dev/null
    OTHER=$("$CLI" call tabs_create "{\"url\":\"http://127.0.0.1:$PORT/tag.html\",\"claude_folder\":false}" \
        | grep -oE '[0-9A-F]{8}-[0-9A-F-]{27}' | head -1)
    # The user is on a third tab with no step (Mouser, in Gabe's case).
    ELSEWHERE=$("$CLI" call tabs_create "{\"url\":\"http://127.0.0.1:$PORT/ring.html\",\"active\":true,\"claude_folder\":false}" \
        | grep -oE '[0-9A-F]{8}-[0-9A-F-]{27}' | head -1)
    sleep 1
    [[ "$(front)" == "$ELSEWHERE" ]] || fail "setup: the user's own tab isn't in front ($(front))"
    OUT=$("$CLI" call handoff "{\"reason\":\"Only you can\",\"steps\":[{\"instruction\":\"Create it\",\"tab\":\"$TAB\",\"text\":\"Create account\"},{\"instruction\":\"Approve it\",\"tab\":\"$OTHER\",\"text\":\"Approve\"}]}" 2>&1)
    [[ "$(front)" == "$TAB" ]] && grep -q "Kite brought step 1's tab" <<<"$OUT" \
        && pass "a handoff whose first step is on a background tab brings that tab to the front" \
        || fail "first step on a background tab: front $(front), $OUT"
    for _ in $(seq 25); do box=$(js "window.tagBox('create')"); grep -q '"left":[0-9]' <<<"$box" && break; sleep 0.2; done
    grep -q '"left":[0-9]' <<<"$box" && pass "its control is ringed with the tag beside it" || fail "no tag beside the control: $box"
    "$CLI" click --selector "#create" --tab "$TAB" >/dev/null
    for _ in $(seq 25); do [[ "$(front)" == "$OTHER" ]] && break; sleep 0.2; done
    [[ "$(front)" == "$OTHER" ]] && pass "finishing the last step on that tab takes the user on to the next step's tab" \
        || fail "after step 1, front is $(front), not the next step's tab"
    "$CLI" call handoff_status '{"cancel":true}' >/dev/null
    # A step whose control can't be ringed: Claude hears why, and no card or tag stands in for it on the page.
    "$CLI" call switch_tab "{\"tab\":\"$TAB\"}" >/dev/null
    OUT=$("$CLI" call handoff "{\"reason\":\"Only you enter cards\",\"tab\":\"$TAB\",\"steps\":[{\"instruction\":\"Card number\",\"selector\":\"#hiddencc\"}]}" 2>&1 || true)
    grep -q "NOT SHOWN: its control is on the page but hidden" <<<"$OUT" && pass "a hidden control is reported to Claude as hidden" \
        || fail "hidden control: $OUT"
    sleep 1.5
    [[ $(js "window.anyHandoff()") == none ]] && pass "nothing stands in for a step Kite can't ring: no card or tag on the page" \
        || fail "something shows for an unringable step: $(js "window.anyHandoff()")"
    "$CLI" call handoff_status '{"cancel":true}' >/dev/null
    # A new password's field: the tag is wider by its Suggest password button; with no password manager in this
    # profile, Kite doesn't click the field (no 1Password here to open), and the field is never read.
    "$CLI" call handoff "{\"reason\":\"Only you choose passwords\",\"tab\":\"$TAB\",\"steps\":[{\"instruction\":\"Pick a password\",\"selector\":\"#newpw\"}]}" >/dev/null
    for _ in $(seq 25); do pw=$(js "window.tagBox('newpw')"); grep -q '"left":[0-9]' <<<"$pw" && break; sleep 0.2; done
    "$CLI" call handoff_status '{"cancel":true}' >/dev/null
    "$CLI" call handoff "{\"reason\":\"Only you sign in\",\"tab\":\"$TAB\",\"steps\":[{\"instruction\":\"Pick a password\",\"selector\":\"#curpw\"}]}" >/dev/null
    for _ in $(seq 25); do cur=$(js "window.tagBox('curpw')"); grep -q '"left":[0-9]' <<<"$cur" && break; sleep 0.2; done
    width() { python3 -c "import json,sys; b=json.loads(sys.argv[1]); print(b['right']-b['left'])" "$1"; }
    (( $(width "$pw") > $(width "$cur") + 40 )) && pass "a new password's field offers Suggest password; a sign-in's doesn't" \
        || fail "tag widths: new password $pw, current password $cur"
    "$CLI" call handoff_status '{"cancel":true}' >/dev/null
    # handoff_status's wait is cut below MCP clients' timeouts.
    OUT=$("$CLI" call handoff_status '{"wait":600}' 2>&1)
    grep -q "1 of 1\|0 of 1" <<<"$OUT" && pass "handoff_status takes a wait of 600 (cut to 50 s) without an error" || fail "wait 600: $OUT"
    # Tab states: done is a green dot on the row; the form details round-trip.
    "$CLI" call tab_status "{\"tab\":\"$TAB\",\"state\":\"done\",\"note\":\"Account made\"}" >/dev/null
    sleep 0.5
    # The tab's row (its title, then its trailing views): a dot filled in system green (#32D74B in dark).
    ROW=$("$CLI" ui tree 2>&1 | grep 'SidebarLabel "Handoff: a new password"' | awk '{print $1}' | sed 's/\.[0-9]*$//' | head -1)
    OUT=$("$CLI" ui tree "{\"root\":\"$ROW\"}" 2>&1 | grep -B1 -E 'FillView .*bg=#(32D74B|34C759)' || true)
    grep -q 'DotView' <<<"$OUT" && ! grep -q 'DotView.*hidden=true' <<<"$OUT" && pass "tab_status done puts the green dot on the tab's row" \
        || fail "no done mark in the sidebar: $OUT"
    OUT=$("$CLI" call form_profile '{"action":"set","name":"Pat Doe","address":{"label":"home","street":"12 Example Ave","unit":"Apt 3B","city":"Queens","state":"NY","zip":"11101"}}' 2>&1)
    OUT2=$("$CLI" call form_profile '{"action":"check","label":"home","address":{"street":"12 Example Street","city":"Queens","state":"NY","zip":"11101"}}' 2>&1)
    grep -q 'address "home": street 12 Example Ave' <<<"$OUT" && grep -q "MISMATCH" <<<"$OUT2" \
        && pass "form_profile saves the user's details and flags a wrong street" || fail "form_profile: $OUT / $OUT2"
    OUT=$("$CLI" call form_profile '{"action":"set","phone":"4242 4242 4242 4242"}' 2>&1 || true)
    grep -q "never keeps" <<<"$OUT" && pass "form_profile refuses a card number" || fail "form_profile took a card number: $OUT"

    for case in "127.0.0.1|the same site's" "localhost|another site's"; do
        host=${case%%|*} kind=${case#*|}
        "$CLI" open "http://127.0.0.1:$PORT/frames.html?src=http://$host:$PORT2/form.html" --tab "$TAB" >/dev/null
        sleep 2
        OUT=$("$CLI" call handoff "{\"reason\":\"Only you can sign in\",\"tab\":\"$TAB\",\"steps\":[{\"instruction\":\"Sign in\",\"text\":\"Sign in\"}]}" 2>&1 || true)
        if grep -q "^1\. \[waiting\] Sign in ·" <<<"$OUT"; then pass "a control in $kind frame of another origin is found and ringed"
        else fail "a control in $kind frame: $OUT"; fi
        # The frame sits at (41, 61) in the page and its button at (20, 20), 120×30.
        scale=$(js "String(innerWidth > 1280 ? 1280 / innerWidth : 1)")
        x=$(python3 -c "print(round((41 + 80) * $scale))") y=$(python3 -c "print(round((61 + 35) * $scale))")
        "$CLI" call computer "{\"action\":\"left_click\",\"coordinate\":[$x,$y],\"tab\":\"$TAB\"}" >/dev/null
        nth_has 1 '\[done\].*clicked' && pass "a click on the ringed control in $kind frame ends the step" || fail "the click in $kind frame: $LINE"
        # A click that takes the frame to another page at once: only the binding hears it in time.
        "$CLI" call handoff "{\"reason\":\"Only you can go on\",\"tab\":\"$TAB\",\"steps\":[{\"instruction\":\"Continue\",\"text\":\"Continue\"}]}" >/dev/null
        y=$(python3 -c "print(round((61 + 85) * $scale))")
        "$CLI" call computer "{\"action\":\"left_click\",\"coordinate\":[$x,$y],\"tab\":\"$TAB\"}" >/dev/null
        nth_has 1 '\[done\].*clicked' && pass "a click that navigates $kind frame away still ends the step" || fail "the navigating click in $kind frame: $LINE"
    done
fi

echo "$passes of $((passes + failures)) checks passed"
[[ $failures -eq 0 ]]
