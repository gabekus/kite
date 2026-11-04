#!/usr/bin/env bash
# Takes Kite for Mac reference captures for a Helix UI gate (docs/helix.md), headless: test builds in the
# background, input posted to Kite's window only, captures drawn in-process. Nothing activates an app, moves the
# real pointer, opens a real menu or records the screen. Run by .github/workflows/mac-reference-captures.yml on the
# self-hosted Mac; it also runs by hand in any checkout but Gabe's own (~/dev/kite, kite-release, kite-cef).
#
# Usage: scripts/mac-reference-captures.sh REQUEST.json OUTDIR
#   Builds the checkout it runs in (scripts/bundle-app.sh debug, so dev.gabek.Kite.dev), then takes every state in
#   REQUEST.json and writes OUTDIR/NAME.png, NAME.tree.txt and NOTES.md, with full logs in OUTDIR/logs/.
#   KITE_ROOT overrides the checkout (default: the git top level of the current directory).
#   Exits non-zero if the build fails or a state that should have been captured wasn't.
#
# REQUEST.json (the format is in docs/helix.md, "Requesting Mac references"):
# {
#   "id": "w9d",                                    lower case, the branch is review/<id>-mac-request
#   "title": "W9d Mac references: …",               NOTES.md's heading
#   "base": "origin/main",                          what the workflow builds (default origin/main)
#   "window_size": [1280, 820],                     points, KITE_WINDOW_SIZE (default 1280,820)
#   "session": {"ref": "origin/BRANCH", "path": "windows/helix/states/x.json"},   default session for every state
#   "tree_match": "SpaceCellView",                  what NAME.tree.txt reads (kite ui tree {"match": …})
#   "expect_frames": [[68,778,36,34], …],           frames the steps' points assume; flagged if the tree differs
#   "states": [{
#     "name": "drag",                               NAME.png; [a-z0-9._-]
#     "holds": "what the capture should show",
#     "session": {"ref": …, "path": …} | {"inline": {…session.json…}},           default: the top-level one
#     "env": {"KITE_TEST_CONTEXT_MENU": "1"},       KITE_TEST_* only
#     "profile_files": {"test-context-menu-pick": "Rename Space…"},              test-* files in the profile
#     "steps": [{"ui": "input", "args": {"from": [86,795], "to": [150,795], "steps": 10, "hold": 10}},
#               {"wait": 1}],                       kite ui ACTION ARGS (any action but capture), or a pause
#     "settle": 1,                                  seconds between the last step and the capture (default 1;
#                                                   0 when "hold" is set)
#     "hold": 10,                                   the steps hold the state this long: capture inside it
#     "capture": true,                              false: run the steps for their logs only
#     "expect_frames": [],                          overrides the top-level one ([] checks nothing)
#     "unverified": "why",                          what this state can't show headless (listed in NOTES.md)
#     "skip": "why"                                 don't run it at all (listed as unverified)
#   }]
# }
set -euo pipefail

[[ $# == 2 ]] || { echo "usage: $0 REQUEST.json OUTDIR" >&2; exit 2; }
REQUEST="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
[[ -f "$REQUEST" ]] || { echo "no request at $1" >&2; exit 2; }
mkdir -p "$2"
OUT="$(cd "$2" && pwd)"
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

APP="$ROOT/build/Kite.app"
CLI="$APP/Contents/Helpers/kite"
BUNDLE_ID=dev.gabek.Kite.dev
LOGS="$OUT/logs"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/maccap.XXXXXX")"
mkdir -p "$LOGS" "$WORK/plan"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# tmo SECONDS CMD…: runs CMD, killed after SECONDS (macOS has no timeout(1)). 142 means it timed out.
tmo() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV or die "exec $ARGV[0]: $!\n"' "$s" "$@"; }

KITE_PID=""
PROFILE=""
# Quits the running test Kite, then any other Kite from this build (never another Kite).
stop_kite() {
    if [[ -n "$KITE_PID" ]] && kill -0 "$KITE_PID" 2>/dev/null; then
        kill -TERM "$KITE_PID" 2>/dev/null || true
        for _ in $(seq 20); do kill -0 "$KITE_PID" 2>/dev/null || break; sleep 0.5; done
        kill -KILL "$KITE_PID" 2>/dev/null || true
        wait "$KITE_PID" 2>/dev/null || true
    fi
    KITE_PID=""
    pkill -KILL -f "^$APP/Contents/" 2>/dev/null || true
    if [[ -n "$PROFILE" && "$PROFILE" == /tmp/k.* ]]; then rm -rf "$PROFILE"; fi
    PROFILE=""
}
# One Kite only: the build's bundles are unregistered from Launch Services and deleted.
remove_build() {
    stop_kite
    if [[ -d "$APP" ]]; then
        while IFS= read -r bundle; do "$LSREGISTER" -u "$bundle" 2>/dev/null || true; done \
            < <(find "$APP" -name '*.app' -type d -prune -print; echo "$APP")
        rm -rf "$APP"
    fi
}
cleanup() { remove_build; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- Plan: validate the request and lay each state out as files for the loop below. ---
python3 -I - "$REQUEST" "$WORK/plan" "$ROOT" <<'PY'
import json, os, re, subprocess, sys
request_path, plan, root = sys.argv[1:4]
def fail(message):
    sys.exit(f"request.json: {message}")
try:
    request = json.load(open(request_path, encoding="utf-8"))
except Exception as error:
    fail(f"not JSON ({error})")
if not isinstance(request, dict) or not isinstance(request.get("states"), list) or not request["states"]:
    fail("needs a non-empty \"states\" list")
NAME = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
if not NAME.match(str(request.get("id", ""))):
    fail("\"id\" must be lower case letters, digits, . _ or -")

def size(value, where):
    if value is None:
        return None
    if not (isinstance(value, list) and len(value) == 2 and all(isinstance(v, (int, float)) and 200 <= v <= 4000 for v in value)):
        fail(f"{where}: window_size is [width, height] in points")
    return [int(v) for v in value]

def git(*args):
    return subprocess.run(["git", "-C", root, *args], capture_output=True, text=True, encoding="utf-8")

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
    if not (isinstance(ref, str) and isinstance(path, str)) or ref.startswith("-") or ".." in path:
        fail(f"{where}: session needs a \"ref\" and a \"path\"")
    if git("rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}").returncode != 0 and ref.startswith("origin/"):
        branch = ref[len("origin/"):]
        if git("check-ref-format", "--branch", branch).returncode == 0:
            git("fetch", "--quiet", "--filter=blob:none", "origin", f"+refs/heads/{branch}:refs/remotes/origin/{branch}")
    sha = git("rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}")
    if sha.returncode != 0:
        fail(f"{where}: no ref {ref}")
    shown = git("show", f"{sha.stdout.strip()}:{path}")
    if shown.returncode != 0:
        fail(f"{where}: no {path} on {ref}")
    try:
        data = json.loads(shown.stdout)
    except ValueError:
        fail(f"{where}: {path} on {ref} isn't JSON")
    return data, f"`{path}` from `{ref}` ({sha.stdout.strip()[:7]})"

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
    if not NAME.match(str(name)) or name in seen or name in ("notes", "logs", "request"):
        fail(f"{where}: name must be unique, lower case, [a-z0-9._-]")
    seen.add(name)
    where = f"state {name}"
    env = state.get("env") or {}
    if not isinstance(env, dict):
        fail(f"{where}: env is an object")
    for key, value in env.items():
        if not re.match(r"^KITE_TEST_[A-Z0-9_]+$", key) or key == "KITE_TEST_BLOCK_VIEWS_WINDOWS":
            fail(f"{where}: env may only set KITE_TEST_* hooks, not {key}")
        if not isinstance(value, str) or "\n" in value or "\0" in value:
            fail(f"{where}: env {key} must be a one-line string")
    files = state.get("profile_files") or {}
    if not isinstance(files, dict) or not all(re.match(r"^test-[a-z0-9-]+$", k) and isinstance(v, str) for k, v in files.items()):
        fail(f"{where}: profile_files maps test-* names to text")
    steps = state.get("steps") or []
    if not isinstance(steps, list):
        fail(f"{where}: steps is a list")
    lines, shown = [], []
    menu_hook = "KITE_TEST_CONTEXT_MENU" in env
    for j, step in enumerate(steps):
        if not isinstance(step, dict):
            fail(f"{where}: steps[{j}] is an object")
        if "wait" in step:
            seconds = step["wait"]
            if not isinstance(seconds, (int, float)) or not 0 <= seconds <= 30:
                fail(f"{where}: wait is 0–30 seconds")
            lines.append(f"wait\t{seconds}")
            shown.append(f"wait {number(seconds)} s")
            continue
        action, args = step.get("ui"), step.get("args") or {}
        if action not in ("input", "tree", "pointer", "windows", "menu", "key_log", "trace"):
            fail(f"{where}: steps[{j}] is {{\"ui\": ACTION, \"args\": {{…}}}} (not capture) or {{\"wait\": s}}")
        if not isinstance(args, dict) or "action" in args or "save" in args:
            fail(f"{where}: steps[{j}].args is the action's JSON object, without action or save")
        # A real context menu is modal and would come up on the screen: only the logging hook may take one.
        opens_menu = action == "input" and "click" in args and (
            args.get("button") == "right" or "ctrl" in str(args.get("modifiers", "")))
        if opens_menu and not menu_hook:
            fail(f"{where}: a right-click needs KITE_TEST_CONTEXT_MENU in env (a real menu needs a real screen)")
        encoded = json.dumps(args, ensure_ascii=False, separators=(",", ":"))
        lines.append(f"ui\t{action}\t{encoded}")
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
    width, height = size(state.get("window_size"), where) or default_size
    folder = os.path.join(plan, f"{i:02d}")
    os.makedirs(os.path.join(folder, "files"))
    def write(file, text):
        with open(os.path.join(folder, file), "w", encoding="utf-8") as f:
            f.write(text)
    write("session.json", json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    write("env", "".join(f"{k}={v}\n" for k, v in env.items()))
    write("steps", "".join(line + "\n" for line in lines))
    for k, v in files.items():
        write(os.path.join("files", k), v)
    expect = frames(state["expect_frames"], where) if "expect_frames" in state else default_expect
    write("expect.json", json.dumps(expect, ensure_ascii=False))
    write("meta.json", json.dumps({
        "name": name, "holds": str(state.get("holds", "")), "session": source, "env": env,
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

# --- Build once. Ad-hoc signed, so codesign never asks the keychain (its prompt would be on Gabe's screen). ---
echo "== building $(git rev-parse --short HEAD) as $BUNDLE_ID"
remove_build
env -u KITE_BUNDLE_ID -u KITE_UPDATE_FEED -u KITE_HARDENED_RUNTIME -u KITE_PROVISIONING_PROFILE \
    KITE_SIGN_IDENTITY=- scripts/bundle-app.sh debug >"$LOGS/build.log" 2>&1 || { tail -40 "$LOGS/build.log" >&2; exit 1; }
[[ "$(cd "$APP" && pwd -P)" != /Applications/* ]] || { echo "refusing to test $APP" >&2; exit 1; }
built_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
[[ "$built_id" == "$BUNDLE_ID" ]] || { echo "built $built_id, not $BUNDLE_ID" >&2; exit 1; }
ENGINE="WebKit (no CEF in ThirdParty/cef, as in CI)"
[[ -d "$APP/Contents/Frameworks/Chromium Embedded Framework.framework" ]] && ENGINE="Chromium (CEF)"
# Its settings stay in dev.gabek.Kite.dev, never the installed Kite's dev.gabek.Kite.
scripts/check-test-defaults.sh "$APP" >"$LOGS/check-test-defaults.log" 2>&1 || { cat "$LOGS/check-test-defaults.log" >&2; exit 1; }
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
    [[ -d "$PROFILE" ]] || { echo "profile isn't a directory" >&2; exit 1; }
    cp "$folder/session.json" "$PROFILE/session.json"
    cp "$folder/files/"* "$PROFILE/" 2>/dev/null || true

    # Only this run's settings reach Kite: every inherited KITE_* is dropped first.
    launch_env=(env)
    while IFS='=' read -r key _; do
        if [[ "$key" == KITE_* || "$key" == TYPESAFE_* ]]; then launch_env+=(-u "$key"); fi
    done < <(env)
    launch_env+=(KITE_SUPPORT_PATH="$PROFILE" KITE_DIAGNOSTICS=1 KITE_TEST_BLOCK_VIEWS_WINDOWS=1 TYPESAFE_API_KEY=x
                 KITE_WINDOW_SIZE="$WIDTH,$HEIGHT")
    while IFS= read -r line; do
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
        tmo 60 "$CLI" ui tree "$(python3 -I -c 'import json,sys; print(json.dumps({"match": sys.argv[1]}))' "$TREE_MATCH")" \
            >"$folder/tree-launch.txt" 2>&1 || true
        python3 -I -c '
import json, sys
expect = json.load(open(sys.argv[1], encoding="utf-8"))
tree = open(sys.argv[2], encoding="utf-8", errors="replace").read()
print("\n".join(f for f in expect if f not in tree))' "$folder/expect.json" "$folder/tree-launch.txt" >"$folder/expect-missing"
    fi

    step_status=0
    : >"$folder/steps.out"
    while IFS=$'\t' read -r kind action args <&4; do
        [[ -n "$kind" ]] || continue
        if [[ "$kind" == wait ]]; then sleep "$action"; continue; fi
        echo "\$ kite ui $action '$args'" >>"$folder/steps.out"
        tmo 60 "$CLI" ui "$action" "$args" >>"$folder/steps.out" 2>&1 || { step_status=$?; echo "(exit $step_status)" >>"$folder/steps.out"; }
    done 4<"$folder/steps"
    held_from=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
    sleep "$SETTLE"

    match_json='{}'
    [[ -n "$TREE_MATCH" ]] && match_json="$(python3 -I -c 'import json,sys; print(json.dumps({"match": sys.argv[1]}))' "$TREE_MATCH")"
    if [[ "$CAPTURE" == 1 ]]; then
        tmo 60 "$CLI" ui tree "$match_json" >"$folder/tree-before.txt" 2>&1 || true
        if tmo 90 "$CLI" ui capture '{"source":"in-process"}' -o "$OUT/$NAME.png" >"$folder/capture.txt" 2>&1 && [[ -s "$OUT/$NAME.png" ]]; then
            echo captured >"$folder/status"
        else
            echo "failed: kite ui capture (exit $?): $(tail -3 "$folder/capture.txt" | tr '\n' ' ')" >"$folder/status"
            rm -f "$OUT/$NAME.png"; failed=1
        fi
        perl -MTime::HiRes=time -e 'printf "%.1f", time - shift' "$held_from" >"$folder/elapsed"
        tmo 60 "$CLI" ui tree "$match_json" >"$folder/tree-after.txt" 2>&1 || true
        if [[ -f "$OUT/$NAME.png" ]]; then
            sips -g pixelWidth -g pixelHeight "$OUT/$NAME.png" 2>/dev/null \
                | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w "×" h}' >"$folder/pixels"
        fi
    else
        tmo 60 "$CLI" ui tree "$match_json" >"$folder/tree-before.txt" 2>&1 || true
        echo "logged" >"$folder/status"
    fi
    tmo 60 "$CLI" ui tree '{"depth":40}' >"$LOGS/$NAME.tree-full.txt" 2>&1 || true
    [[ "$step_status" == 0 ]] || echo "a step exited $step_status (see $NAME.steps.txt)" >"$folder/step-warning"

    stop_kite_log="$PROFILE/kite.log"
    grep -E '^KITE_TEST_[A-Z_]+:' "$stop_kite_log" >"$folder/test-lines" 2>/dev/null || true
    cp "$stop_kite_log" "$LOGS/$NAME.kite.log" 2>/dev/null || true
    stop_kite
    unset KITE_SUPPORT_PATH
done 3<"$WORK/plan/index"

# --- NOTES.md and the per-state frame files. ---
python3 -I - "$WORK/plan" "$OUT" <<'PY'
import json, os, sys
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

size = states[0][1]["size"] if states else [1280, 820]
lines = [f"# {request['title']}", ""]
lines.append(f"Taken headless by `.github/workflows/mac-reference-captures.yml` (`scripts/mac-reference-captures.sh`) "
             f"on {build.get('host', 'the Mac runner')}, macOS {build.get('macos', '?')}.")
lines.append("")
lines.append(f"Build: a debug test bundle (dev.gabek.Kite.dev, ad-hoc signed) from {request['base']} "
             f"{build.get('sha', '?')[:7]} (`{build.get('sha', '?')}`), engine {build.get('engine', '?')}. Each state "
             f"used a fresh `mktemp -d /tmp/k.XXXX` profile with its session as session.json, "
             f"`defaults delete dev.gabek.Kite.dev SidebarWidth` first, `KITE_DIAGNOSTICS=1 KITE_TEST_BLOCK_VIEWS_WINDOWS=1 "
             f"TYPESAFE_API_KEY=x KITE_WINDOW_SIZE=W,H`, and Kite in the background throughout (never activated, input "
             f"posted to its window only), quit afterwards.")
lines.append("")
pixels = sorted({read(f, "pixels") for f, m in states if read(f, "pixels")})
capture_notes = []
for folder, meta in states:
    for line in read(folder, "capture.txt").replace(out + "/", "").splitlines():
        line = line.replace(meta["name"] + ".png", "NAME.png")
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
             "in the workflow run's artifact, not on this branch.")
open(os.path.join(out, "NOTES.md"), "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY

echo "== done: $OUT"
for f in "$WORK"/plan/*/status; do
    if grep -q '^failed' "$f"; then echo "$(sed -n 's/^NAME=//p' "$(dirname "$f")/vars"): $(cat "$f")" >&2; fi
done
exit $failed
