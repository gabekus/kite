#!/usr/bin/env bash
# End-to-end test that a page's JavaScript dialogs reach Claude (DialogLog), on a dev build with a fresh profile, driven
# through that build's own socket by one `kite mcp` session, as Claude Code drives it. The page is
# Tests/Browser/handoff/checkout-alert.html, whose Place Order answers with an alert, as Gabe's checkout did (5 Nov 2026):
#   1. Claude hands the user a step (the card field) and waits in handoff_status. The "user" (Kite's ui tool: a click
#      in the window, no real pointer) clicks Place Order and then OK on the page's alert. The wait must end early,
#      quoting the alert, and say the user dismissed it.
#   2. With no handoff, an alert the user answers reaches Claude on its next tool result, once.
#   3. One nobody answers reaches Claude once it has been open a few seconds; Claude answers it with handle_dialog.
#   4. The dialogs tool lists them all, with who answered each.
# Usage: scripts/test-dialogs.sh [APP]   (default build/Kite.app from scripts/bundle-app.sh debug; never /Applications)
# KEEP=1 keeps the profile; SHOTS=DIR saves screenshots of the step's tag while Claude looks and after.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/Kite.app}"
[[ "$(cd "$APP" && pwd)" != /Applications/* ]] || { echo "test builds only, not $APP" >&2; exit 2; }
CLI="$APP/Contents/Helpers/kite"
PORT="${PORT:-18797}"

P=$(mktemp -d /tmp/k.XXXX)
[[ -d "$P" ]] || { echo "profile not a directory" >&2; exit 1; }
export KITE_SUPPORT_PATH=$P KITE_TEST_BLOCK_VIEWS_WINDOWS=1 KITE_DIAGNOSTICS=1
python3 "$ROOT/Tests/Browser/handoff/server.py" "$PORT" 2>/dev/null &
SERVER=$!
"$APP/Contents/MacOS/Kite" --disable-backgrounding-occluded-windows >"$P/kite.log" 2>&1 &
PID=$!
cleanup() { kill $PID $SERVER 2>/dev/null; wait $PID 2>/dev/null; [[ -n "${KEEP:-}" ]] || rm -rf "$P"; }
trap cleanup EXIT
for _ in $(seq 60); do "$CLI" ui windows >/dev/null 2>&1 && break; sleep 0.5; done
grep -q "CefInitialize failed" "$P/kite.log" && echo "note: Chromium didn't start; this run is WebKit"

python3 - "$CLI" "http://127.0.0.1:$PORT/checkout-alert.html" "${SHOTS:-}" <<'PY'
import base64, json, os, re, subprocess, sys, threading, time
cli, url, shots = sys.argv[1], sys.argv[2], sys.argv[3]
mcp = subprocess.Popen([cli, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
next_id = [0]
failures, passes = [], [0]

def rpc(method, params):
    next_id[0] += 1
    mcp.stdin.write(json.dumps({"jsonrpc": "2.0", "id": next_id[0], "method": method, "params": params}) + "\n")
    mcp.stdin.flush()
    while True:
        message = json.loads(mcp.stdout.readline())
        if message.get("id") == next_id[0]:
            return message

def call(tool, arguments, shot=None):
    result = rpc("tools/call", {"name": tool, "arguments": arguments})["result"]
    text = "\n".join(c["text"] for c in result["content"] if c["type"] == "text")
    for c in result["content"]:
        if c["type"] == "image" and shot:
            open(shot, "wb").write(base64.b64decode(c["data"]))
    if result.get("isError"):
        text = "ERROR " + text
    return text

def check(name, ok, detail=""):
    if ok:
        passes[0] += 1
        print("ok   " + name)
    else:
        failures.append(name)
        print("FAIL " + name + "\n" + detail)

def ui(action, arguments=None):
    args = [cli, "ui", action] + ([json.dumps(arguments)] if arguments is not None else [])
    return subprocess.run(args, capture_output=True, text=True).stdout

def page_origin():
    # The front tab's page view in the window (its WebContentsViewCocoa that has a size).
    for line in ui("tree").splitlines():
        m = re.search(r"WebContentsViewCocoa \[([\d.]+),([\d.]+) (\d+)×(\d+)\]", line)
        if m and int(m.group(3)) > 1:
            return float(m.group(1)), float(m.group(2))
    raise SystemExit("no page view")

def sidebar_label():
    """The tab's row label in the sidebar: orange (#D97757) while it needs the user."""
    return next((l.strip() for l in ui("tree", {"match": "checkout that says no"}).splitlines() if "SidebarLabel" in l), "")

def answer_alert(wait_first=0.0, read=1.0):
    """The user: waits for the page's dialog sheet, reads it for a moment, then presses OK."""
    time.sleep(wait_first)
    for _ in range(60):
        m = re.search(r"window (\d+) \[SheetWindow\]", ui("windows"))
        if m:
            break
        time.sleep(0.2)
    else:
        print("no dialog sheet came up")
        return
    time.sleep(read)
    sheet = int(m.group(1))
    tree = ui("tree", {"window": sheet})
    b = re.search(r'AXButton "OK" \[([\d.]+),([\d.]+) ([\d.]+)×([\d.]+)\]', tree)
    x, y = float(b.group(1)) + float(b.group(3)) / 2, float(b.group(2)) + float(b.group(4)) / 2
    ui("input", {"window": sheet, "click": [x, y]})

rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test-dialogs", "version": "1"}})
opened = call("tabs_create", {"url": url, "active": True, "session": "Dialog test"})
tab = re.search(r"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}", opened).group(0)
time.sleep(1)

# 1. The user's step, then the page's alert: the wait wakes for it.
handed = call("handoff", {"reason": "Your card is yours to type.", "steps": [{"instruction": "Type your card", "tab": tab, "selector": "#card"}]})
hid = re.search(r"Handoff (h\d+)", handed).group(1)
x0, y0 = page_origin()
def user_places_order():
    time.sleep(2)
    ui("input", {"click": [x0 + 170, y0 + 156]})  # Place Order, at 40,140 260×32 in the page
    answer_alert(read=1.5)
threading.Thread(target=user_places_order, daemon=True).start()
started = time.time()
woke = call("handoff_status", {"id": hid, "wait": 40})
took = time.time() - started
print(f"     handoff_status returned after {took:.1f} s:\n" + "\n".join("     | " + l for l in woke.splitlines()))
check("a waiting handoff_status wakes on the page's alert", took < 15, woke)
check("its result quotes the alert", "Double check your credit card information" in woke, woke)
check("and names the step it came on", f"the user's step 1 of handoff {hid}" in woke, woke)
# A page's dialog ends the step it came up on (UserHandoff's ring: every step finishes by itself), so the handoff is done.
check("the dialog ended the step", "[done] Type your card (the page opened a dialog)" in woke, woke)
check("and says the user dismissed it", "The user dismissed it." in woke, woke)
check("and tells Claude to read the page", "work out what's wrong" in woke, woke)
if shots:
    time.sleep(1)
    call("screenshot", {"tab": tab, "format": "png"}, shot=os.path.join(shots, "1-claude-is-looking.png"))
row = sidebar_label()
check("the tab's row isn't orange (needs you) while Claude looks", "SidebarLabel" in row and "#D97757" not in row, row)

again = call("handoff_status", {"id": hid, "wait": 1})
check("the alert isn't reported twice", "Double check" not in again, again)
time.sleep(0.5)
row = sidebar_label()
check("with the step done, the row doesn't turn orange again", "SidebarLabel" in row and "#D97757" not in row, row)
if shots:
    time.sleep(1)
    call("screenshot", {"tab": tab, "format": "png"}, shot=os.path.join(shots, "2-waiting-again.png"))
call("handoff_status", {"id": hid, "cancel": True})

# 2. No handoff: the next tool result carries the dialog, once.
call("javascript", {"tab": tab, "code": "setTimeout(() => alert('Your session ends in 5 minutes'), 300); 1"})
answer_alert(read=0.5)
time.sleep(0.5)
first = call("tabs_context", {})
check("the next tool result carries the alert", "Your session ends in 5 minutes" in first and "The user dismissed it." in first, first)
second = call("tabs_context", {})
check("once", "Your session ends" not in second, second)

# 2b. One nobody answers is news once it has been open a few seconds, and Claude's own answer is put down to Claude.
call("javascript", {"tab": tab, "code": "setTimeout(() => confirm('Keep your cart?'), 300); 1"})
time.sleep(4)
pending = call("tabs_context", {})
check("an unanswered dialog reaches Claude after a few seconds, still open", "Keep your cart?" in pending and "still open" in pending, pending)
answered = call("handle_dialog", {"tab": tab, "accept": False})
check("handle_dialog answers it", "Dismissed the confirm dialog" in answered, answered)

# 3. The list.
listed = call("dialogs", {"tab": tab})
check("dialogs lists all three", listed.startswith("3 dialogs") and "Double check" in listed and "session ends" in listed, listed)
check("with who answered each", listed.count("The user dismissed it.") == 2 and "You dismissed it with handle_dialog." in listed, listed)
print(f"{passes[0]} passed, {len(failures)} failed")
mcp.stdin.close()
sys.exit(1 if failures else 0)
PY
