#!/usr/bin/env bash
# Takes Kite for Mac reference captures for a Helix UI gate (docs/helix.md), headless: test builds in the
# background, input posted to Kite's window only, captures drawn in-process. Nothing activates an app, moves the
# real pointer, opens a real menu or records the screen. Run by .github/workflows/mac-reference-captures.yml on the
# self-hosted Mac; it also runs by hand in any checkout but Gabe's own (~/dev/kite, kite-release, kite-cef).
#
# Usage: scripts/mac-reference-captures.sh REQUEST.json OUTDIR
#   Builds the checkout it runs in (scripts/bundle-app.sh debug, so dev.gabek.Kite.dev), then takes every state in
#   REQUEST.json and writes OUTDIR/NAME.png, NAME.tree.txt, NAME.steps.txt and NOTES.md (what gets published).
#   Kite's logs, full trees and the build log go to OUTDIR-logs/, which is never published.
#   KITE_ROOT overrides the checkout (default: the git top level of the current directory).
#   MACCAP_PROFILE_LIST names a file each test profile's path is appended to, so a cancelled run's profiles
#   can still be deleted (the workflow's cleanup step).
#   Exits non-zero if the build fails, a request is refused, or a state that should have been captured wasn't.
#
# REQUEST.json (the format is in docs/helix.md, "Requesting Mac references"):
# {
#   "id": "w9d",                                    lower case, the branch is review/<id>-mac-request
#   "title": "W9d Mac references: …",               NOTES.md's heading
#   "base": "origin/main",                          what the workflow builds (default origin/main; SAFE_FLOOR or newer)
#   "window_size": [1280, 820],                     points, KITE_WINDOW_SIZE (default 1280,820)
#   "session": {"ref": "origin/BRANCH", "path": "windows/helix/states/x.json"},   default session for every state
#   "tree_match": "SpaceCellView",                  what NAME.tree.txt reads (kite ui tree {"match": …})
#   "expect_frames": [[68,778,36,34], …],           frames the steps' points assume; flagged if the tree differs
#   "states": [{
#     "name": "drag",                               NAME.png; [a-z0-9._-]
#     "holds": "what the capture should show",
#     "session": {"ref": …, "path": …} | {"inline": {…session.json…}},           default: the top-level one
#     "env": {"KITE_TEST_CONTEXT_MENU": "1"},       only the hooks in HOOKS below
#     "profile_files": {"test-context-menu-pick": "Rename Space…"},              test-* files in the profile, and
#                                                   history.json (checked like a session, 1 MB at most)
#     "steps": [{"ui": "input", "args": {"from": [86,795], "to": [150,795], "steps": 10, "hold": 10}},
#               {"wait": 1}],                       kite ui ACTION ARGS (see STEPS below), or a pause
#     "settle": 1,                                  seconds between the last step and the capture (default 1;
#                                                   0 when "hold" is set)
#     "hold": 10,                                   the steps hold the state this long: capture inside it
#     "capture": true,                              false: run the steps for their logs only
#     "expect_frames": [],                          overrides the top-level one ([] checks nothing)
#     "unverified": "why",                          what this state can't show headless (listed in NOTES.md)
#     "skip": "why"                                 don't run it at all (listed as unverified)
#   }]
# }
#
# Safety rules this script enforces (Gabe's rules for his Mac; a refused request runs nothing):
# - Builds only from SAFE_FLOOR or newer: older Kites lack test-safe mode and could show real windows, alerts or
#   keychain prompts on Gabe's screen.
# - HOOKS: a request's env may only set the KITE_TEST_* hooks classified as safe below. The test paths are always
#   inside the profile.
# - Sessions: URLs must be public http(s) (or about:), no path-like values, profileSettings stripped, and every
#   profile's WebKit dataStoreID replaced with a fresh one whose store is deleted afterwards.
# - STEPS: clicks and drag starts must land on a visible view in SAFE_TARGETS (from the tree, just before the step);
#   right- and ⌃-clicks also need a non-empty KITE_TEST_CONTEXT_MENU. No keys or modifier flags. Text only as
#   [A-Za-z0-9 ._-]{1,40}, straight after a click on a COMMAND_BAR_OPENERS view, into a visible CommandBarField
#   (Kite's own command bar, which acts only on Return, and Return can't be sent), and only on a base that has
#   TEXT_FLOOR (the build inserts test-safe text without key events, so no input method).
# - Every test Kite is quit; the build's bundles are unregistered from Launch Services and deleted (never through a
#   symlink, never outside the checkout).
set -euo pipefail

# The oldest Kite this builds. Test-safe mode (WindowPresenter, d291111 and 811b5fb, 2026-11-04) keeps every window,
# alert and app launch off Gabe's screen; 7161b7d (KITE_SIGN_IDENTITY, the test keychain) is older and included.
# Raise it whenever new test-safety work lands in Kite. The workflow reads it from here.
SAFE_FLOOR=811b5fbaeeee6c0f5187661ecba992f5795e5623

# The oldest Kite a text step may run on: fix/test-safe-text-input (#374), where a test-safe `ui input` text goes
# straight into the command bar's field editor (insertText) and nowhere else. Before it, text was real key events
# through the input method, whose candidate window (a Japanese input source) could draw on Gabe's screen. A base
# without it can still take requests, just not text steps. If #374 lands by squash or rebase, set this to the commit
# it landed as on main.
TEXT_FLOOR=235b56ee38f5b6ae5b02932232e3c4b5062aead5

# Views a click, right-click (through showSidebarMenu's KITE_TEST_CONTEXT_MENU hook) or drag may start on. Each was
# read in the Mac source: no hookless NSMenu, no window drag. Add one only after the same check. Not safe, for
# example: the sidebar header's Developer and More buttons (SidebarHeader.swift, menu.popUp without the hook), the
# link preview's Share button (LinkPreviewCard.swift, popUpAtPointer at the REAL pointer), and the window background
# and page-top band (isMovableByWindowBackground, PageTopWindowDragger: a window-server drag follows the real
# pointer).
SAFE_TARGETS="SpaceCellView NewTabRowCell"
# The subset whose left click opens Kite's own command bar (NewTabRowCell.tapped: showCommandBar(.newTab)), the
# only place a text step may type. The sidebar's address field opens it too; add its tree class after checking it.
COMMAND_BAR_OPENERS="NewTabRowCell"

[[ $# == 2 ]] || { echo "usage: $0 REQUEST.json OUTDIR" >&2; exit 2; }
REQUEST="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
[[ -f "$REQUEST" ]] || { echo "no request at $1" >&2; exit 2; }
mkdir -p "$2"
OUT="$(cd "$2" && pwd)"
LOGS="$OUT-logs"
ROOT="${KITE_ROOT:-$(git rev-parse --show-toplevel)}"
ROOT="$(cd "$ROOT" && pwd -P)"
cd "$ROOT"

# Gabe's own checkouts and profile are never touched.
for own in "$HOME/dev/kite" "$HOME/dev/kite-release" "$HOME/dev/kite-cef"; do
    if [[ -d "$own" && "$ROOT" == "$(cd "$own" && pwd -P)" ]]; then
        echo "refusing to build in $own: use a worktree or the runner's workspace" >&2
        exit 2
    fi
done
if ! GIT_NO_LAZY_FETCH=1 git merge-base --is-ancestor "$SAFE_FLOOR" HEAD 2>/dev/null; then
    echo "refusing to build $(git rev-parse --short HEAD): it's older than SAFE_FLOOR $SAFE_FLOOR (no test-safe mode)" >&2
    exit 2
fi

APP="$ROOT/build/Kite.app"
CLI="$APP/Contents/Helpers/kite"
BUNDLE_ID=dev.gabek.Kite.dev
WORK="$(mktemp -d "${TMPDIR:-/tmp}/maccap.XXXXXX")"
mkdir -p "$LOGS" "$WORK/plan"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
PROFILE_LIST="${MACCAP_PROFILE_LIST:-}"

# Every launch (Kite, check-test-defaults.sh) starts from the runner's environment minus anything Kite reads.
SCRUB=(env -u KITE_SUPPORT_PATH)
while IFS='=' read -r key _; do
    if [[ "$key" =~ ^(KITE_|TYPESAFE_)[A-Za-z0-9_]*$ ]]; then SCRUB+=(-u "$key"); fi
done < <(env)

# tmo SECONDS CMD…: runs CMD, killed after SECONDS (macOS has no timeout(1)). 142 means it timed out.
tmo() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV or die "exec $ARGV[0]: $!\n"' "$s" "$@"; }

# The build may only be deleted where bundle-app.sh puts it: not through a symlink, not outside the checkout.
build_path_ok() {
    if [[ -L "$ROOT/build" || -L "$APP" ]]; then
        echo "refusing: $ROOT/build or $APP is a symlink" >&2; return 1
    fi
    if [[ -e "$ROOT/build" && "$(cd "$ROOT/build" && pwd -P)" != "$ROOT/build" ]]; then
        echo "refusing: $ROOT/build resolves outside $ROOT" >&2; return 1
    fi
    return 0
}

KITE_PID=""
PROFILE=""
STORES=""
# Quits the running test Kite, then any other Kite from this build (never another Kite), and deletes its profile
# and the WebKit stores its session named.
stop_kite() {
    if [[ -n "$KITE_PID" ]] && kill -0 "$KITE_PID" 2>/dev/null; then
        kill -TERM "$KITE_PID" 2>/dev/null || true
        for _ in $(seq 20); do kill -0 "$KITE_PID" 2>/dev/null || break; sleep 0.5; done
        kill -KILL "$KITE_PID" 2>/dev/null || true
        wait "$KITE_PID" 2>/dev/null || true
    fi
    KITE_PID=""
    pkill -KILL -f "^$APP/Contents/" 2>/dev/null || true
    if [[ -n "$PROFILE" && "$PROFILE" =~ ^/tmp/k\.[A-Za-z0-9]{4}$ && -d "$PROFILE" && ! -L "$PROFILE" ]]; then
        rm -rf "$PROFILE"
    fi
    PROFILE=""
    if [[ -n "$STORES" && -s "$STORES" ]]; then remove_stores "$STORES"; fi
    STORES=""
}
# Deletes the WebKit data stores named by the UUIDs in FILE (the session's randomized dataStoreIDs), only inside the
# test bundle's own WebKit folders.
remove_stores() {
    local root uuid found
    while IFS= read -r uuid; do
        [[ "$uuid" =~ ^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$ ]] || continue
        for root in "$HOME/Library/WebKit/$BUNDLE_ID" "$HOME/Library/HTTPStorages/$BUNDLE_ID" "$HOME/Library/Caches/$BUNDLE_ID"; do
            [[ -d "$root" && ! -L "$root" ]] || continue
            while IFS= read -r found; do
                if [[ "$found" == "$root/"* && ! -L "$found" ]]; then
                    rm -rf "$found"
                    echo "removed WebKit store $found" >>"$LOGS/datastores.txt"
                fi
            done < <(find "$root" -maxdepth 4 -type d -iname "$uuid" -prune -print 2>/dev/null)
        done
    done <"$1"
}
# One Kite only: the build's bundles are unregistered from Launch Services and deleted.
remove_build() {
    stop_kite
    build_path_ok || return 1
    if [[ -d "$APP" ]]; then
        while IFS= read -r bundle; do "$LSREGISTER" -u "$bundle" 2>/dev/null || true; done \
            < <(find "$APP" -name '*.app' -type d -prune -print; echo "$APP")
        rm -rf "$APP"
    fi
}
cleanup() { remove_build || echo "the build was left in place (see above)" >&2; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- Plan: validate the request and lay each state out as files for the loop below. ---
python3 -I - "$REQUEST" "$WORK/plan" "$ROOT" "$SAFE_TARGETS" "$TEXT_FLOOR" <<'PY'
import copy, ipaddress, json, os, re, subprocess, sys, urllib.parse, uuid
request_path, plan, root, safe_targets, text_floor = sys.argv[1:6]
def fail(message):
    sys.exit(f"request.json refused: {message}")
try:
    request = json.load(open(request_path, encoding="utf-8"))
except Exception as error:
    fail(f"not JSON ({error})")
if not isinstance(request, dict) or not isinstance(request.get("states"), list) or not request["states"]:
    fail("needs a non-empty \"states\" list")
NAME = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}")
if not NAME.fullmatch(str(request.get("id", ""))):
    fail("\"id\" must be lower case letters, digits, . _ or -")

# HOOKS: every KITE_TEST_* the Mac sources read (git grep -o 'KITE_TEST_[A-Z0-9_]*' Sources), classified.
#   value kinds: "text" one line; "flag" exactly 1; "number"; "name" a file name, given to Kite as $PROFILE/name;
#   "url" a public http(s) URL (the session rule).
HOOKS = {
    "KITE_TEST_CONTEXT_MENU": "text",          # logs a context menu instead of showing it; text = the item to pick
    "KITE_TEST_BOOST_MENU": "text",            # presses the Boost editor's menu items without the menu
    "KITE_TEST_ZAP_PICKER": ("1", "copy"),     # opens the Zap picker in its own (test-safe) window
    "KITE_TEST_LITTLE_PROFILE_PICK": "text",   # logs Little Kite's profile menu (KITE_TEST_LITTLE_PROFILE_MENU:) and picks
    "KITE_TEST_LITTLE_EXTENSIONS_BUTTON": "flag",
    "KITE_TEST_TIDY_TITLE": "text",            # a stand-in reply instead of asking Claude
    "KITE_TEST_ASSUME_VISIBLE": "flag",
    "KITE_TEST_REOPEN_MAIN_AFTER": "number",   # reopens the main window behind the user's
    "KITE_TEST_EXPORT_DATA_PATH": "name",      # Export Data writes here instead of a save panel
    "KITE_TEST_OPEN_URL": "url",               # opens a link as another app would
}
# Set by this script for every launch, never by a request.
OWNED = {"KITE_TEST_BLOCK_VIEWS_WINDOWS", "KITE_TEST_DOWNLOADS_PATH", "KITE_TEST_APPS_DIR", "KITE_TEST_DEFAULTS_PROBE",
         "KITE_TEST_PASTEBOARD"}   # PASTEBOARD: a pasteboard of the profile's own, never the clipboard
# Refused: they reach outside the profile or stand in for a real service.
REFUSED = {
    "KITE_TEST_GLOBAL_HOTKEY": "registers a system-wide hotkey",
    "KITE_TEST_IMPORT": "reads another browser's or Arc's data",
    "KITE_TEST_IMPORT_SIGNINS": "imports sign-ins (cookies)",
    "KITE_TEST_CLAUDE_HOME": "points Kite at a Claude home (Gabe's real ~/.claude by default)",
    "KITE_TEST_MESSAGES_DB": "reads a Messages database",
    "KITE_TEST_MEDIA_HOME": "reads a media folder",
    "KITE_TEST_INSTANT_LINKS_SEARCH_URL": "sends queries to a search endpoint",
    "KITE_TEST_LIVE_FOLDER_URL": "fetches a feed endpoint",
    "KITE_TEST_MAIL_ORIGIN": "fetches a mail feed endpoint",
    "KITE_TEST_SUGGEST_URL": "sends typing to a suggestion endpoint",
}
# KITE_TEST_MODAL and KITE_TEST_LITTLE_PROFILE_MENU are log-line prefixes Kite writes, not settings.

def size(value, where):
    if value is None:
        return None
    if not (isinstance(value, list) and len(value) == 2 and all(isinstance(v, (int, float)) and 200 <= v <= 4000 for v in value)):
        fail(f"{where}: window_size is [width, height] in points")
    return [int(v) for v in value]

def git(*args, lazy=True):
    env = dict(os.environ)
    if not lazy:
        env["GIT_NO_LAZY_FETCH"] = "1"
    return subprocess.run(["git", "-C", root, *args], capture_output=True, text=True, encoding="utf-8", env=env)

# --- URLs and sessions ---
BAD_SUFFIXES = (".localhost", ".local", ".internal", ".lan", ".home", ".corp", ".intranet", ".arpa", ".test",
                ".invalid", ".onion")
LABEL = re.compile(r"(?!-)[a-z0-9-]{1,63}(?<!-)")
# The last label must start with a letter: WebKit parses hosts WHATWG-style, so an all-numeric, octal or hex last
# label (127.1, 0177.0.0.1, 0x7f.1, 10.1, 192.168.1) makes the host an IPv4 address. xn-- still passes.
TLD = re.compile(r"[a-z][a-z0-9-]{0,62}(?<!-)")
def public_url(value):
    """None if value is a public http(s) URL or about:, else why not."""
    try:
        parts = urllib.parse.urlsplit(value)
        parts.port
    except ValueError:
        return "isn't a URL"
    scheme = parts.scheme.lower()
    if scheme == "about":
        return None
    if scheme not in ("http", "https"):
        return f"scheme {scheme or '(none)'} isn't http(s) or about"
    if parts.username is not None or parts.password is not None:
        return "has credentials"
    host = (parts.hostname or "").rstrip(".").lower()
    if not host:
        return "has no host"
    try:
        address = ipaddress.ip_address(host)
        return None if address.is_global else "is a private, loopback or reserved address"
    except ValueError:
        pass
    labels = host.split(".")
    if len(labels) < 2 or host == "localhost" or host.endswith(BAD_SUFFIXES) or not all(LABEL.fullmatch(l) for l in labels):
        return "isn't a public host name"
    if not TLD.fullmatch(labels[-1]):
        return "ends in a numeric label, so it's read as an IPv4 address"
    return None

URLISH = re.compile(r"^([a-z][a-z0-9+.-]*://|(https?|file|ftp|data|javascript|blob|wss?|chrome|chrome-extension|"
                    r"view-source|filesystem|about|kite[a-z-]*):)", re.I)
PATHKEY = re.compile(r"(path|directory|folder|file|dir|profile)$", re.I)
def check_session(node, key, where, problems):
    if isinstance(node, dict):
        for k, v in node.items():
            # Keys can be URLs too (history.json's entries are keyed by URL).
            if URLISH.match(str(k)):
                why = public_url(str(k))
                if why:
                    problems.append(f"{where} key {str(k)[:80]!r} {why}")
            check_session(v, str(k), f"{where}.{k}", problems)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            check_session(v, key, f"{where}[{i}]", problems)
    elif isinstance(node, str):
        if node and (key.lower().endswith("url") or URLISH.match(node)):
            why = public_url(node)
            if why:
                problems.append(f"{where} = {node[:80]!r} {why}")
        if PATHKEY.search(key) and ("/" in node or "\\" in node or node.startswith((".", "~"))):
            problems.append(f"{where} = {node[:80]!r} looks like a path")

def sanitize(data, where):
    """Checks a session and returns (copy with fresh dataStoreIDs and no profileSettings, the new IDs, notes)."""
    if not isinstance(data, dict):
        fail(f"{where}: the session isn't a JSON object")
    data = copy.deepcopy(data)
    notes = []
    for holder in (data, data.get("state") if isinstance(data.get("state"), dict) else {}):
        if "profileSettings" in holder:
            del holder["profileSettings"]      # per-profile download folders
            notes.append("profileSettings stripped")
    problems = []
    check_session(data, "", "session", problems)
    if problems:
        fail(f"{where}: " + "; ".join(problems[:5]))
    old = set()
    def collect(node):
        if isinstance(node, dict):
            for k, v in node.items():
                if k == "dataStoreID" and isinstance(v, str):
                    old.add(v)
                collect(v)
        elif isinstance(node, list):
            for v in node:
                collect(v)
    collect(data)
    fresh = {o: str(uuid.uuid4()).upper() for o in sorted(old)}
    def swap(node):
        if isinstance(node, dict):
            return {fresh.get(k, k): swap(v) for k, v in node.items()}
        if isinstance(node, list):
            return [swap(v) for v in node]
        return fresh.get(node, node) if isinstance(node, str) else node
    data = swap(data)
    if fresh:
        notes.append(f"{len(fresh)} dataStoreID(s) made fresh")
    return data, list(fresh.values()), notes

def on_origin(sha):
    out = git("for-each-ref", "--contains", sha, "--count=1", "refs/remotes/origin", lazy=False)
    return out.returncode == 0 and out.stdout.strip() != ""

def session(spec, where):
    if spec is None:
        return None, None
    if not isinstance(spec, dict):
        fail(f"{where}: session is {{\"ref\", \"path\"}} or {{\"inline\"}}")
    if "inline" in spec:
        if not isinstance(spec["inline"], dict):
            fail(f"{where}: inline session must be an object")
        return spec["inline"], "inline in request.json"
    ref, path = spec.get("ref"), spec.get("path")
    if not (isinstance(ref, str) and isinstance(path, str)) or ref.startswith("-") or ".." in path or path.startswith("/"):
        fail(f"{where}: session needs a \"ref\" and a relative \"path\"")
    if not re.fullmatch(r"[A-Za-z0-9._/-]+", ref):
        fail(f"{where}: bad ref {ref}")
    if git("rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}", lazy=False).returncode != 0 and ref.startswith("origin/"):
        branch = ref[len("origin/"):]
        if git("check-ref-format", "--branch", branch).returncode == 0:
            git("fetch", "--quiet", "--filter=blob:none", "origin", f"+refs/heads/{branch}:refs/remotes/origin/{branch}")
    sha = git("rev-parse", "--verify", "--quiet", "--end-of-options", f"{ref}^{{commit}}", lazy=False)
    if sha.returncode != 0:
        fail(f"{where}: no ref {ref}")
    sha = sha.stdout.strip()
    if not on_origin(sha):
        fail(f"{where}: {ref} ({sha[:7]}) isn't on any of origin's branches")
    shown = git("show", f"{sha}:{path}")
    if shown.returncode != 0:
        fail(f"{where}: no {path} on {ref}")
    try:
        data = json.loads(shown.stdout)
    except ValueError:
        fail(f"{where}: {path} on {ref} isn't JSON")
    return data, f"`{path}` from `{ref}` ({sha[:7]})"

# --- Steps ---
MODIFIERS = {"cmd", "command", "meta", "super", "win", "ctrl", "control", "⌃", "alt", "option", "opt", "shift"}
CONTROL = {"ctrl", "control", "⌃"}
def modifier_tokens(text, where):
    # As KeyChord.parse reads them: "+"-separated, case-insensitive.
    if not isinstance(text, str):
        fail(f"{where}: modifiers is a string like \"shift\"")
    tokens = [t.strip().lower() for t in text.split("+") if t.strip()]
    unknown = [t for t in tokens if t not in MODIFIERS]
    if unknown:
        fail(f"{where}: unknown modifier {unknown[0]!r}")
    return set(tokens)

def point(value, where):
    if not (isinstance(value, list) and len(value) == 2 and all(isinstance(v, (int, float)) for v in value)):
        fail(f"{where}: a point is [x, y]")
    return [value[0], value[1]]

# No "window": the target check reads the front browser window's tree, so input goes there too.
INPUT_KEYS = {"click", "button", "count", "modifiers", "from", "to", "steps", "hold", "scroll", "dx", "dy", "phase", "text"}
TEXT = re.compile(r"[A-Za-z0-9 ._-]{1,40}")
_text_fix = []
def has_text_fix():
    if not _text_fix:
        _text_fix.append(git("merge-base", "--is-ancestor", text_floor, "HEAD", lazy=False).returncode == 0)
    return _text_fix[0]
def check_step(action, args, menu_hook, where, previous):
    """Returns what must be true when the step runs: points on SAFE_TARGETS views, or (text) the command bar open."""
    if action == "trace" and "keys" in args:
        fail(f"{where}: trace keys aren't allowed (keys aren't reviewed for headless safety)")
    if action != "input":
        return []
    extra = set(args) - INPUT_KEYS
    if extra:
        fail(f"{where}: input {sorted(extra)[0]!r} isn't allowed (keys, flags and window aren't reviewed for headless safety)")
    kinds = [k for k in ("click", "from", "scroll", "text") if k in args]
    if len(kinds) != 1:
        fail(f"{where}: an input step is one click, one drag (from/to), one scroll or one text")
    if "text" in args:
        if set(args) != {"text"} or not isinstance(args["text"], str) or not TEXT.fullmatch(args["text"]):
            fail(f"{where}: text is 1–40 of A-Z a-z 0-9 space . _ - (no keys, no Return), on its own")
        if not (previous and previous[0] == "input" and "click" in previous[1]
                and previous[1].get("button", "left") == "left" and not previous[1].get("modifiers")):
            fail(f"{where}: text must come straight after a plain left click on a command-bar opener")
        # Text needs the build to insert it without key events (TEXT_FLOOR): checked once, on the checkout's HEAD.
        if not has_text_fix():
            fail(f"{where}: text steps need a base with fix/test-safe-text-input ({text_floor[:7]}), which this "
                 "base doesn't contain: without it the text goes through the input method")
        return [{"what": "text", "needs": "command bar"}]
    if "click" in args:
        at = point(args["click"], where)
        button = args.get("button", "left")
        if button not in ("left", "right"):
            fail(f"{where}: button is left or right")
        if args.get("count", 1) != 1:
            fail(f"{where}: only single clicks")
        mods = modifier_tokens(args.get("modifiers", ""), where)
        if (button == "right" or mods & CONTROL) and not menu_hook:
            fail(f"{where}: a right- or ⌃-click needs KITE_TEST_CONTEXT_MENU in env (a real menu needs a real screen)")
        return [{"point": at, "what": f"{button} click", "click": True}]
    if "from" in args:
        start = point(args["from"], where)
        point(args.get("to"), where)
        if "modifiers" in args:
            fail(f"{where}: drags take no modifiers")
        return [{"point": start, "what": "drag start"}]
    point(args["scroll"], where)
    return []

default_size = size(request.get("window_size"), "top level") or [1280, 820]
default_session = session(request.get("session"), "top level")
tree_match = request.get("tree_match")
if tree_match is not None and not isinstance(tree_match, str):
    fail("tree_match is a string")
def number(v):
    return str(int(v)) if float(v).is_integer() else f"{v:.2f}".rstrip("0").rstrip(".")

def frames(value, where):
    if not (isinstance(value, list) and all(isinstance(f, list) and len(f) == 4 and
            all(isinstance(v, (int, float)) for v in f) for f in value)):
        fail(f"{where}: expect_frames is a list of [x, y, width, height]")
    return [f"[{number(x)},{number(y)} {number(w)}×{number(h)}]" for x, y, w, h in value]

default_expect = frames(request.get("expect_frames") or [], "top level")

seen = set()
index = []
for i, state in enumerate(request["states"]):
    where = f"states[{i}]"
    if not isinstance(state, dict):
        fail(f"{where} is an object")
    name = state.get("name", "")
    if not NAME.fullmatch(str(name)) or name in seen or name in ("notes", "logs", "request"):
        fail(f"{where}: name must be unique, lower case, [a-z0-9._-]")
    seen.add(name)
    where = f"state {name}"
    env = state.get("env") or {}
    if not isinstance(env, dict):
        fail(f"{where}: env is an object")
    env_lines = []
    for key, value in env.items():
        if key in REFUSED:
            fail(f"{where}: {key} is refused ({REFUSED[key]})")
        if key in OWNED:
            fail(f"{where}: {key} is set by the script")
        kind = HOOKS.get(key)
        if kind is None:
            fail(f"{where}: env {key} isn't a hook this script allows (see HOOKS)")
        if not isinstance(value, str) or "\n" in value or "\0" in value or len(value) > 200:
            fail(f"{where}: env {key} must be a short one-line string")
        # Kite turns a hook off for an empty value (PageContextMenuItems.testMode): a right-click would then open a
        # real menu. Empty and blank values are refused for every hook.
        if not value.strip():
            fail(f"{where}: env {key} is empty or blank, which turns the hook off")
        if isinstance(kind, tuple):
            if value not in kind:
                fail(f"{where}: {key} is one of {', '.join(kind)}")
        elif kind == "flag" and value != "1":
            fail(f"{where}: {key} is 1")
        elif kind == "number" and not re.fullmatch(r"\d{1,3}(\.\d+)?", value):
            fail(f"{where}: {key} is a number of seconds")
        elif kind == "url" and public_url(value):
            fail(f"{where}: {key} {public_url(value)}")
        elif kind == "name":
            if not NAME.fullmatch(value):
                fail(f"{where}: {key} is a file name inside the profile ([a-z0-9._-])")
            value = "@profile/" + value
        env_lines.append(f"{key}={value}")
    files = dict(state.get("profile_files") or {}) if isinstance(state.get("profile_files") or {}, dict) else None
    if files is None:
        fail(f"{where}: profile_files is an object")
    for k, v in list(files.items()):
        if k == "history.json":
            # Browsing history (HistoryStore): checked like a session, so it can only name public pages.
            if isinstance(v, str):
                try:
                    v = json.loads(v)
                except ValueError:
                    fail(f"{where}: history.json isn't JSON")
            text = json.dumps(v, ensure_ascii=False)
            if len(text.encode("utf-8")) > 1_000_000:
                fail(f"{where}: history.json is over 1 MB")
            problems = []
            check_session(v, "", "history.json", problems)
            if problems:
                fail(f"{where}: " + "; ".join(problems[:5]))
            files[k] = text
        elif not (re.fullmatch(r"test-[a-z0-9-]+", k) and isinstance(v, str) and len(v) <= 10_000):
            fail(f"{where}: profile_files maps test-* names (or history.json) to text")
    steps = state.get("steps") or []
    if not isinstance(steps, list):
        fail(f"{where}: steps is a list")
    lines, shown = [], []
    previous = None
    menu_hook = bool(str(env.get("KITE_TEST_CONTEXT_MENU", "")).strip())
    for j, step in enumerate(steps):
        if not isinstance(step, dict):
            fail(f"{where}: steps[{j}] is an object")
        if "wait" in step:
            seconds = step["wait"]
            if not isinstance(seconds, (int, float)) or not 0 <= seconds <= 30:
                fail(f"{where}: wait is 0–30 seconds")
            lines.append(f"wait\t{seconds}\t\t")
            shown.append(f"wait {number(seconds)} s")
            previous = ("wait", {})
            continue
        action, args = step.get("ui"), step.get("args") or {}
        if action not in ("input", "tree", "pointer", "windows", "menu", "key_log", "trace"):
            fail(f"{where}: steps[{j}] is {{\"ui\": ACTION, \"args\": {{…}}}} (not capture) or {{\"wait\": s}}")
        if not isinstance(args, dict) or "action" in args or "save" in args:
            fail(f"{where}: steps[{j}].args is the action's JSON object, without action or save")
        checks = check_step(action, args, menu_hook, f"{where} steps[{j}]", previous)
        previous = (action, args)
        encoded = json.dumps(args, ensure_ascii=False, separators=(",", ":"))
        lines.append(f"ui\t{action}\t{encoded}\t{json.dumps(checks, separators=(',', ':')) if checks else ''}")
        shown.append(f"`kite ui {action} '{encoded}'`")
    hold = state.get("hold")
    if hold is not None and (not isinstance(hold, (int, float)) or not 0 < hold <= 10):
        fail(f"{where}: hold is up to 10 seconds")
    settle = state.get("settle", 0 if hold else 1)
    if not isinstance(settle, (int, float)) or not 0 <= settle <= 30:
        fail(f"{where}: settle is 0–30 seconds")
    data, source = session(state.get("session"), where) if "session" in state else default_session
    if data is None and not state.get("skip"):
        fail(f"{where}: no session (give one here or at the top level)")
    stores, notes = [], []
    if data is not None:
        data, stores, notes = sanitize(data, where)
    width, height = size(state.get("window_size"), where) or default_size
    folder = os.path.join(plan, f"{i:02d}")
    os.makedirs(os.path.join(folder, "files"))
    def write(file, text):
        with open(os.path.join(folder, file), "w", encoding="utf-8") as f:
            f.write(text)
    write("session.json", json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    write("datastores", "".join(s + "\n" for s in stores))
    write("env", "".join(line + "\n" for line in env_lines))
    write("steps", "".join(line + "\n" for line in lines))
    for k, v in files.items():
        write(os.path.join("files", k), v)
    expect = frames(state["expect_frames"], where) if "expect_frames" in state else default_expect
    write("expect.json", json.dumps(expect, ensure_ascii=False))
    write("meta.json", json.dumps({
        "name": name, "holds": str(state.get("holds", "")),
        "session": (source or "") + (f" ({', '.join(notes)})" if notes else ""), "env": env,
        "profile_files": files, "steps": shown, "settle": settle, "hold": hold,
        "capture": bool(state.get("capture", True)) and not state.get("skip"),
        "unverified": str(state.get("unverified") or ""), "skip": str(state.get("skip") or ""),
        "size": [width, height], "expect": expect,
    }, ensure_ascii=False))
    write("vars", f"NAME={name}\nWIDTH={width}\nHEIGHT={height}\nSETTLE={settle}\nHOLD={hold or 0}\n"
                  f"CAPTURE={1 if bool(state.get('capture', True)) else 0}\nSKIP={1 if state.get('skip') else 0}\n")
    index.append(folder)
with open(os.path.join(plan, "index"), "w") as f:
    f.write("".join(folder + "\n" for folder in index))
with open(os.path.join(plan, "request.json"), "w", encoding="utf-8") as f:
    json.dump({"id": request["id"], "title": request.get("title") or f"{request['id']} Mac references",
               "base": request.get("base") or "origin/main", "tree_match": tree_match},
              f, ensure_ascii=False)
PY

TREE_MATCH="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["tree_match"] or "")' "$WORK/plan/request.json")"
match_json() { python3 -I -c 'import json,sys; print(json.dumps({"match": sys.argv[1]}))' "$1"; }

# on_safe_target CHECKS TREEFILE CLASSES: prints "hit CLASS" when the check's point lands on a visible view of one of
# CLASSES (or, for a check without a point, when one is visible at all), else why not.
on_safe_target() {
    python3 -I - "$1" "$2" "$3" <<'PY'
import json, re, sys
checks, tree, safe = json.loads(sys.argv[1]), open(sys.argv[2], encoding="utf-8", errors="replace").read(), sys.argv[3].split()
# A tree line (UINode.line): path, class, then optional #identifier and "quoted label" (\" and \\ escaped, so a
# label can't fake a frame), then [x,y w×h] and attributes.
LINE = re.compile(r'\S+ (?P<cls>\S+)(?: #\S+)?(?: "(?:[^"\\]|\\.)*")? '
                  r'\[(?P<x>-?[\d.]+),(?P<y>-?[\d.]+) (?P<w>[\d.]+)×(?P<h>[\d.]+)\](?P<rest>.*)')
frames = []
for line in tree.splitlines():
    m = LINE.fullmatch(line.strip())
    if m and m["cls"] in safe and not re.search(r"\b(hidden=true|alpha=0|opacity=0)(\s|\Z)", m["rest"]):
        frames.append((m["cls"], [float(m[k]) for k in ("x", "y", "w", "h")]))
hit = None
for check in checks:
    if "point" not in check:
        hit = frames[0][0] if frames else None
        if not hit:
            print(f"no visible {' or '.join(safe)} for the {check['what']} step")
            sys.exit()
        continue
    x, y = check["point"]
    hit = next((c for c, (fx, fy, fw, fh) in frames if fx <= x < fx + fw and fy <= y < fy + fh), None)
    if not hit:
        print(f"the {check['what']} at {x:g},{y:g} isn't on a visible {' or '.join(safe)}")
        sys.exit()
print(f"hit {hit}")
PY
}

# --- Build once. Ad-hoc signed, so codesign never asks the keychain (its prompt would be on Gabe's screen). ---
echo "== building $(git rev-parse --short HEAD) as $BUNDLE_ID"
build_path_ok || exit 1
remove_build
"${SCRUB[@]}" KITE_SIGN_IDENTITY=- scripts/bundle-app.sh debug >"$LOGS/build.log" 2>&1 || { tail -40 "$LOGS/build.log" >&2; exit 1; }
build_path_ok || exit 1
[[ "$(cd "$APP" && pwd -P)" == "$ROOT/build/Kite.app" ]] || { echo "refusing to test $APP" >&2; exit 1; }
built_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
[[ "$built_id" == "$BUNDLE_ID" ]] || { echo "built $built_id, not $BUNDLE_ID" >&2; exit 1; }
ENGINE="WebKit (no CEF in ThirdParty/cef, as in CI)"
if [[ -d "$APP/Contents/Frameworks/Chromium Embedded Framework.framework" ]]; then ENGINE="Chromium (CEF)"; fi
# Its settings stay in dev.gabek.Kite.dev, never the installed Kite's dev.gabek.Kite.
"${SCRUB[@]}" scripts/check-test-defaults.sh "$APP" >"$LOGS/check-test-defaults.log" 2>&1 \
    || { cat "$LOGS/check-test-defaults.log" >&2; exit 1; }
{
    echo "sha=$(git rev-parse HEAD)"
    echo "engine=$ENGINE"
    echo "macos=$(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"
    echo "host=${RUNNER_NAME:-$(scutil --get ComputerName 2>/dev/null || hostname)}"
} >"$WORK/plan/build"

# --- Each state: a fresh profile, launch in the background, steps, frames, capture, quit. ---
failed=0
while IFS= read -r folder <&3; do
    # shellcheck disable=SC1091
    source "$folder/vars"
    echo "== $NAME"
    : >"$folder/status"
    if [[ "$SKIP" == 1 ]]; then echo skipped >"$folder/status"; continue; fi

    defaults delete "$BUNDLE_ID" SidebarWidth >/dev/null 2>&1 || true
    PROFILE="$(mktemp -d /tmp/k.XXXX)"
    [[ -d "$PROFILE" && ! -L "$PROFILE" ]] || { echo "profile isn't a directory" >&2; exit 1; }
    if [[ -n "$PROFILE_LIST" ]]; then echo "$PROFILE" >>"$PROFILE_LIST"; fi
    STORES="$folder/datastores"
    cp "$folder/session.json" "$PROFILE/session.json"
    cp "$folder/files/"* "$PROFILE/" 2>/dev/null || true
    mkdir -p "$PROFILE/Downloads" "$PROFILE/browsers"

    launch_env=("${SCRUB[@]}" KITE_SUPPORT_PATH="$PROFILE" KITE_DIAGNOSTICS=1 KITE_TEST_BLOCK_VIEWS_WINDOWS=1
                TYPESAFE_API_KEY=x KITE_WINDOW_SIZE="$WIDTH,$HEIGHT"
                KITE_TEST_DOWNLOADS_PATH="$PROFILE/Downloads" KITE_TEST_APPS_DIR="$PROFILE/apps"
                KITE_BROWSER_DATA_PATH="$PROFILE/browsers" KITE_TEST_PASTEBOARD="kite-test-$(basename "$PROFILE")")
    while IFS= read -r line; do
        if [[ "$line" == *=@profile/* ]]; then line="${line%%=*}=$PROFILE/${line#*=@profile/}"; fi
        if [[ -n "$line" ]]; then launch_env+=("$line"); fi
    done <"$folder/env"
    "${launch_env[@]}" "$APP/Contents/MacOS/Kite" </dev/null >"$PROFILE/kite.log" 2>&1 &
    KITE_PID=$!
    export KITE_SUPPORT_PATH="$PROFILE"   # so the CLI finds this profile's socket

    up=0
    for _ in $(seq 30); do   # each try waits up to 8 s for the socket itself
        if tmo 15 "$CLI" ui windows >"$folder/windows.txt" 2>&1; then up=1; break; fi
        kill -0 "$KITE_PID" 2>/dev/null || break
        sleep 0.5
    done
    if [[ "$up" != 1 ]]; then
        echo "failed: Kite's socket never answered (kite ui windows)" >"$folder/status"
        cp "$PROFILE/kite.log" "$LOGS/$NAME.kite.log" 2>/dev/null || true
        stop_kite; unset KITE_SUPPORT_PATH; failed=1; continue
    fi
    sleep 2   # the restored page and the theme settle

    # The steps' coordinates assume these frames; the tree says whether they're right.
    if [[ -n "$TREE_MATCH" ]]; then
        tmo 60 "$CLI" ui tree "$(match_json "$TREE_MATCH")" >"$folder/tree-launch.txt" 2>&1 || true
        python3 -I -c '
import json, sys
expect = json.load(open(sys.argv[1], encoding="utf-8"))
tree = open(sys.argv[2], encoding="utf-8", errors="replace").read()
print("\n".join(f for f in expect if f not in tree))' "$folder/expect.json" "$folder/tree-launch.txt" >"$folder/expect-missing"
    fi

    step_status=0
    refused=""
    last_hit=""   # the SAFE_TARGETS class the previous step clicked, for a text step
    : >"$folder/steps.out"
    while IFS=$'\t' read -r kind action args checks <&4; do
        [[ -n "$kind" ]] || continue
        if [[ "$kind" == wait ]]; then sleep "$action"; last_hit=""; continue; fi
        if [[ "$checks" == *'"needs":"command bar"'* ]]; then
            # Text only straight after a click on a command-bar opener, and only into Kite's own open command bar.
            if [[ -z "$last_hit" || " $COMMAND_BAR_OPENERS " != *" $last_hit "* ]]; then
                refused="the text step doesn't follow a click on a command-bar opener (${last_hit:-no safe click})"
            else
                # The bar opens a moment after the click: look for its field for up to 3 s.
                for _ in $(seq 15); do
                    tmo 60 "$CLI" ui tree "$(match_json CommandBarField)" >"$folder/targets.txt" 2>&1 || true
                    result="$(on_safe_target "$checks" "$folder/targets.txt" CommandBarField)"
                    if [[ "$result" == "hit "* ]]; then break; fi
                    sleep 0.2
                done
                if [[ "$result" != "hit "* ]]; then refused="$result"; fi
            fi
            last_hit=""
        elif [[ -n "$checks" ]]; then
            : >"$folder/targets.txt"
            for target in $SAFE_TARGETS; do
                tmo 60 "$CLI" ui tree "$(match_json "$target")" >>"$folder/targets.txt" 2>&1 || true
            done
            result="$(on_safe_target "$checks" "$folder/targets.txt" "$SAFE_TARGETS")"
            if [[ "$result" == "hit "* ]]; then last_hit="${result#hit }"; else refused="$result"; fi
        else
            last_hit=""
        fi
        if [[ -n "$refused" ]]; then echo "refused: $refused" >>"$folder/steps.out"; break; fi
        echo "\$ kite ui $action '$args'" >>"$folder/steps.out"
        tmo 60 "$CLI" ui "$action" "$args" >>"$folder/steps.out" 2>&1 || { step_status=$?; echo "(exit $step_status)" >>"$folder/steps.out"; }
    done 4<"$folder/steps"
    if [[ -n "$refused" ]]; then
        echo "failed: refused a step: $refused" >"$folder/status"
        cp "$PROFILE/kite.log" "$LOGS/$NAME.kite.log" 2>/dev/null || true
        stop_kite; unset KITE_SUPPORT_PATH; failed=1; continue
    fi
    held_from=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
    sleep "$SETTLE"

    tree_args='{}'
    if [[ -n "$TREE_MATCH" ]]; then tree_args="$(match_json "$TREE_MATCH")"; fi
    if [[ "$CAPTURE" == 1 ]]; then
        tmo 60 "$CLI" ui tree "$tree_args" >"$folder/tree-before.txt" 2>&1 || true
        if tmo 90 "$CLI" ui capture '{"source":"in-process"}' -o "$OUT/$NAME.png" >"$folder/capture.txt" 2>&1 && [[ -s "$OUT/$NAME.png" ]]; then
            echo captured >"$folder/status"
        else
            echo "failed: kite ui capture (exit $?): $(tail -3 "$folder/capture.txt" | tr '\n' ' ')" >"$folder/status"
            rm -f "$OUT/$NAME.png"; failed=1
        fi
        perl -MTime::HiRes=time -e 'printf "%.1f", time - shift' "$held_from" >"$folder/elapsed"
        tmo 60 "$CLI" ui tree "$tree_args" >"$folder/tree-after.txt" 2>&1 || true
        if [[ -f "$OUT/$NAME.png" ]]; then
            sips -g pixelWidth -g pixelHeight "$OUT/$NAME.png" 2>/dev/null \
                | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w "×" h}' >"$folder/pixels"
        fi
    else
        tmo 60 "$CLI" ui tree "$tree_args" >"$folder/tree-before.txt" 2>&1 || true
        echo "logged" >"$folder/status"
    fi
    tmo 60 "$CLI" ui tree '{"depth":40}' >"$LOGS/$NAME.tree-full.txt" 2>&1 || true
    if [[ "$step_status" != 0 ]]; then echo "a step exited $step_status (see $NAME.steps.txt)" >"$folder/step-warning"; fi

    grep -E '^KITE_TEST_[A-Z_]+:' "$PROFILE/kite.log" >"$folder/test-lines" 2>/dev/null || true
    cp "$PROFILE/kite.log" "$LOGS/$NAME.kite.log" 2>/dev/null || true
    stop_kite
    unset KITE_SUPPORT_PATH
done 3<"$WORK/plan/index"

# --- NOTES.md and the per-state frame files. ---
python3 -I - "$WORK/plan" "$OUT" <<'PY'
import json, os, re, sys
plan, out = sys.argv[1:3]
def read(*parts, default=""):
    try:
        return open(os.path.join(*parts), encoding="utf-8", errors="replace").read().strip()
    except FileNotFoundError:
        return default
request = json.load(open(os.path.join(plan, "request.json"), encoding="utf-8"))
build = dict(line.split("=", 1) for line in read(plan, "build").splitlines() if "=" in line)
folders = read(plan, "index").splitlines()
states = []
for folder in folders:
    meta = json.load(open(os.path.join(folder, "meta.json"), encoding="utf-8"))
    meta["status"] = read(folder, "status") or "not run"
    states.append((folder, meta))
    name = meta["name"]
    tree = []
    for label, file in (("at launch", "tree-launch.txt"), ("before the capture", "tree-before.txt"),
                        ("after the capture", "tree-after.txt")):
        text = read(folder, file)
        if text:
            tree.append(f"## {label}\n{text}\n")
    if tree:
        open(os.path.join(out, f"{name}.tree.txt"), "w", encoding="utf-8").write("\n".join(tree))
    steps_out = read(folder, "steps.out")
    if steps_out:
        open(os.path.join(out, f"{name}.steps.txt"), "w", encoding="utf-8").write(steps_out + "\n")

lines = [f"# {request['title']}", ""]
lines.append(f"Taken headless by `.github/workflows/mac-reference-captures.yml` (`scripts/mac-reference-captures.sh`) "
             f"on {build.get('host', 'the Mac runner')}, macOS {build.get('macos', '?')}.")
lines.append("")
lines.append(f"Build: a debug test bundle (dev.gabek.Kite.dev, ad-hoc signed) from {request['base']} "
             f"{build.get('sha', '?')[:7]} (`{build.get('sha', '?')}`), engine {build.get('engine', '?')}. Each state "
             f"used a fresh `mktemp -d /tmp/k.XXXX` profile with its session as session.json, "
             f"`defaults delete dev.gabek.Kite.dev SidebarWidth` first, `KITE_DIAGNOSTICS=1 KITE_TEST_BLOCK_VIEWS_WINDOWS=1 "
             f"TYPESAFE_API_KEY=x KITE_WINDOW_SIZE=W,H` (downloads, web apps and browser data inside the profile), and "
             f"Kite in the background throughout (never activated, input posted to its window only), quit afterwards.")
lines.append("")
pixels = sorted({read(f, "pixels") for f, m in states if read(f, "pixels")})
capture_notes = []
for folder, meta in states:
    for line in read(folder, "capture.txt").replace(out + "/", "").splitlines():
        line = re.sub(r"^Window \d+ ", "Window N ", line.replace(meta["name"] + ".png", "NAME.png"))
        if line and line not in capture_notes:
            capture_notes.append(line)
lines.append(f"**Capture path:** in-process, `kite ui capture '{{\"source\":\"in-process\"}}' -o NAME.png`, 2× "
             f"({', '.join(pixels) or 'no capture'}). Screen Recording is never used on the runner, so every PNG is "
             f"in-process: blurred materials are drawn unblurred, and Kite lists where they are:")
lines.append("")
lines += [f"> {line}" for line in capture_notes[:12]] or ["> (nothing reported)"]
lines.append("")
checked = [(m["name"], m["expect"], read(f, "expect-missing")) for f, m in states
           if m["expect"] and read(f, "status") not in ("", "skipped") and read(f, "tree-launch.txt")]
if checked:
    wrong = [(n, w) for n, _, w in checked if w]
    if wrong:
        lines.append("**Coordinates: CHECK.** The tree at launch didn't show frames the request's points assume: " +
                     "; ".join(f"{n}: {w.replace(chr(10), ', ')}" for n, w in wrong) +
                     ". Those states ran at the request's points anyway; read their `.tree.txt` and rerun with the tree's.")
    else:
        lines.append("**Coordinates:** at launch the tree showed every frame the request's points assume (" +
                     "; ".join(f"{n}: {', '.join(e)}" for n, e, _ in checked) + ").")
    lines.append("")
lines.append("| file | session | env | steps | holds | result |")
lines.append("|---|---|---|---|---|---|")
for folder, meta in states:
    env = ", ".join(f"`{k}={v}`" for k, v in meta["env"].items()) or "none"
    if meta["profile_files"]:
        env += "; profile: " + ", ".join(f"`{k}` = {v}" for k, v in meta["profile_files"].items())
    steps = "; then ".join(meta["steps"]) or "none"
    if meta["hold"]:
        steps += f"; captured {read(folder, 'elapsed') or '?'} s into the {meta['hold']:g} s hold"
    elif meta["steps"]:
        steps += f"; {meta['settle']:g} s later, the {'capture' if meta['capture'] else 'frames (no capture)'}"
    file = f"{meta['name']}.png" if meta["status"] == "captured" else f"{meta['name']}.png (none)"
    result = meta["status"]
    if meta["skip"]:
        result = f"skipped, unverified: {meta['skip']}"
    elif meta["unverified"]:
        result += f"; unverified: {meta['unverified']}"
    if read(folder, "step-warning"):
        result += f"; {read(folder, 'step-warning')}"
    cell = lambda s: s.replace("|", "\\|").replace("\n", " ")
    lines.append("| " + " | ".join(cell(c) for c in (file, meta["session"] or "", env, steps, meta["holds"], result)) + " |")
lines.append("")
logged = [(m["name"], read(f, "test-lines")) for f, m in states if read(f, "test-lines")]
if logged:
    lines.append("## Logged by the test hooks")
    lines.append("")
    for name, text in logged:
        lines.append(f"{name}:")
        lines.append("")
        lines.append("```")
        lines.append(text)
        lines.append("```")
        lines.append("")
match = request.get("tree_match")
if match:
    lines.append(f"## Frames (`kite ui tree '{{\"match\":\"{match}\"}}'`, window points)")
    lines.append("")
    for folder, meta in states:
        text = read(folder, "tree-after.txt") or read(folder, "tree-before.txt")
        if not text:
            continue
        label = "after the capture" if read(folder, "tree-after.txt") else "after the steps"
        lines.append(f"{meta['name']} ({label}; `{meta['name']}.tree.txt` has launch, before and after):")
        lines.append("")
        lines.append("```")
        lines += text.splitlines()[:40]
        lines.append("```")
        lines.append("")
unverified = [(m["name"], m["skip"] or m["unverified"]) for f, m in states if m["skip"] or m["unverified"]]
if unverified:
    lines.append("## Not verified headless")
    lines.append("")
    for name, why in unverified:
        lines.append(f"- {name}: unverified: needs a real screen. {why}")
    lines.append("")
lines.append("Each state's `kite ui` step output is in `NAME.steps.txt`. Kite's logs, full trees and the build log are "
             "in the workflow run's logs artifact (kept 7 days), not on this branch.")
open(os.path.join(out, "NOTES.md"), "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY

echo "== done: $OUT"
for f in "$WORK"/plan/*/status; do
    if grep -q '^failed' "$f"; then echo "$(sed -n 's/^NAME=//p' "$(dirname "$f")/vars"): $(cat "$f")" >&2; fi
done
exit $failed
