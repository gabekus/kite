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
#     "env": {"KITE_TEST_CONTEXT_MENU": "1"},       only the hooks in HOOKS below (KITE_TEST_CONTEXT_MENU exactly
#                                                   "1": a menu is logged, nothing in it runs); the find bar's:
#            {"KITE_TEST_FIND": "domain"}           the bar open searching for this ([A-Za-z0-9 ._-]{1,40}, as text), or
#            {"KITE_TEST_FIND_OPEN": "1"}           the bar open and empty; one of the two, on a base with FIND_FLOOR,
#                                                   and the capture waits for Kite's "KITE_TEST_FIND: ready" line;
#                                                   the sidebar's (SIDEBAR_FLOOR, waits for "KITE_TEST_SIDEBAR: ready"):
#            {"KITE_TEST_ICON_PICKER": "Work"}      the icon picker open for the space with this name (text rule), or
#            {"KITE_TEST_NEW_SPACE": "1",           Create a Space, optionally with
#             "KITE_TEST_NEW_SPACE_NAME": "Notes",  its name field holding this (text rule) and
#             "KITE_TEST_NEW_SPACE_THEME": "4"}     preset 1-7 picked, the theme editor open; no other hook and no
#                                                   input steps beside these
#     "profile_files": {"test-name": "text"},       test-* files in the profile (never test-context-menu-pick),
#                                                   and history.json (checked like a session, 1 MB at most)
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
# - Sessions: URLs must be public http(s) (or about:), no path-like values, profileSettings cut to its includesSearchSuggestions booleans, and every
#   profile's WebKit dataStoreID replaced with a fresh one whose store is deleted afterwards.
# - STEPS: clicks and drag starts must land on a visible view in SAFE_TARGETS (from the tree, just before the step).
#   Every right-click needs KITE_TEST_CONTEXT_MENU exactly "1" and no test-context-menu-pick file, so the menu
#   it builds is logged and nothing in it runs (PageContextMenuItems.testPick runs the item a pick file, or any other
#   hook value, names: on a SpaceCellView, Edit Theme Color…, What's This Space For?…, New Profile…, Change Space
#   Icon…); any other value and the pick file are refused for every state, whatever its steps. A right-click (and
#   nothing else: no left click, ⌃-click, double click or drag) may also land on a RIGHT_CLICK_TARGETS row, without
#   modifiers, as the state's first step (waits aside). Every click and drag start is checked with Kite's own hit test
#   (ui hit, on a base with HIT_FLOOR) just before it's sent: the view AppKit hits must be the approved view itself,
#   or for a row's right-click a RIGHT_CLICK_INSIDE view whose superviews up to the row are too. The step then goes
#   to the window the tree and the hit test read, with that view as its "expect" (EXPECT_FLOOR), so Kite hit-tests
#   again and sends the press in one main-thread turn, or sends nothing and the state fails. No `ui pointer` steps
#   (synthetic hover: a favorite's preview, the space tip window, ⇧ link previews). No keys or modifier flags: no
#   ⌃-click either (a right-click reaches the same menus through the views' own rightMouseDown and the hook, while a
#   ⌃-left-click could also meet AppKit's own context-menu handling, which no hook covers). Text only as
#   [A-Za-z0-9 ._-]{1,40}, straight after ⌘T (the only key chord allowed) or a click on a COMMAND_BAR_OPENERS view,
#   into a visible CommandBarField
#   (Kite's own command bar, which acts only on Return, and Return can't be sent), and only on a base that has
#   TEXT_FLOOR (the build inserts test-safe text without key events, so no input method).
# - Find bar: KITE_TEST_FIND, whose value follows the text rule above ([A-Za-z0-9 ._-]{1,40}: no control characters,
#   no Return), or KITE_TEST_FIND_OPEN, exactly 1; never both in one state, and only on a base that has FIND_FLOOR
#   (test-safe only, the build opens the bar with ⌘F's own showFind and sets the query through the field's
#   stringValue and search, without key events). A state fails, uncaptured, if Kite doesn't write
#   "KITE_TEST_FIND: ready" within FIND_READY_SECONDS.
# - Sidebar: KITE_TEST_ICON_PICKER (a space's name, under the text rule), or KITE_TEST_NEW_SPACE exactly 1 with
#   optionally KITE_TEST_NEW_SPACE_NAME (the text rule) and KITE_TEST_NEW_SPACE_THEME (one of 1-7); the picker never
#   beside the page's hooks, NAME and THEME never without NEW_SPACE, no other KITE_TEST_* hook beside them, no input
#   steps (no click, drag, key or text) in such a state, and only on a base that has SIDEBAR_FLOOR (test-safe only, the
#   build opens them through the store paths a click takes and the popovers from their own views, without events). A
#   state fails, uncaptured, if Kite doesn't write "KITE_TEST_SIDEBAR: ready" within SIDEBAR_READY_SECONDS, if that
#   line doesn't match SIDEBAR_READY_OK (Kite isn't the active app; the popover, if any, is the main window's child),
#   or if Kite writes "KITE_TEST_SIDEBAR: changed" (the state went, or Kite became active) by just after the capture.
# - Every test Kite is quit; the build's bundles are unregistered from Launch Services and deleted (never through a
#   symlink, never outside the checkout).
set -euo pipefail

# The oldest Kite this builds. Test-safe mode (WindowPresenter, d291111 and 811b5fb, 2026-11-04) keeps every window,
# alert and app launch off Gabe's screen; 7161b7d (KITE_SIGN_IDENTITY, the test keychain) is older and included.
# Raise it whenever new test-safety work lands in Kite. The workflow reads it from here.
SAFE_FLOOR=811b5fbaeeee6c0f5187661ecba992f5795e5623

# The oldest Kite a text step may run on: fix/test-safe-text-input (#374), where a test-safe `ui input` text goes
# straight into the command bar's field editor (insertText, its text checking off) and nowhere else, and keys that
# type a character are refused. Before it, text was real key events
# through the input method, whose candidate window (a Japanese input source) could draw on Gabe's screen. A base
# without it can still take requests, just not text steps. If #374 lands by squash or rebase, set this to the commit
# it landed as on main.
TEXT_FLOOR=92611226a9834ac52b95a77268bf1f5647f08490

# The oldest Kite the find-bar hooks (KITE_TEST_FIND, KITE_TEST_FIND_OPEN) may run on: fix/test-find-hooks (#384).
# There, on a test-safe run only, once the main window's selected page has loaded, the window runs ⌘F's showFind and
# FindBar.setQuery (the field's stringValue, then the search a keystroke runs: no key events, no input method, no
# menu, nothing activated), then writes "KITE_TEST_FIND: ready: …" on stderr. Older Kites ignore the hooks, so the
# capture would show no bar. 3a9a2f1 (the review's hardening) opens the bar with Ask on Page always off, so captures
# don't depend on the runner's saved askOnPageEnabled and the Ask button (which runs Claude) never shows, and turns
# Writing Tools off. 0586646 keeps a covered page answering. 8b84c62 (fix/test-find-hook-fallback) is the first where
# the hooks give a ready line headless: no page loads on the runner (W21 timed out on 46ed602 and d8e9ec7), so after
# 20 s Kite opens the bar anyway and writes "KITE_TEST_FIND: ready (fallback, the page never loaded): …". 9b086b8 makes
# a fallback query only set the field's text, with no search, so that line is its only ready line (no result line
# after it; the capture shows the query and no counter). If that branch lands by squash or rebase, set this to the
# commit it landed as on main.
FIND_FLOOR=9b086b836c07ad064b047523fe04fbd38207fefb

# The oldest Kite a click or drag may run on: ci/right-click-row-targets 5117e20 (`ui hit`), the window frame view's
# hitTest at a point, as NSWindow.sendEvent does for a mouse down, with nothing sent. A frame in `ui tree` doesn't say
# what a click reaches: the tree reports frames unclipped (the next space's list sits one sidebar-width to the right,
# clipped by a layer mask, over the page) and hidden only from isHidden, so a view's frame can be "visible" where
# AppKit hits the web view instead. If that branch lands by squash or rebase, set this to the commit it landed as.
HIT_FLOOR=5117e208294a3c212895b52b28b09192864bc50f
# The oldest Kite a click or drag may run on, too: ci/capture-hardening 0201403, `ui input`'s "expect". Kite hit-tests
# the press point (the chain `ui hit` reports) and sends the mouse down in the same main-thread turn, with no
# suspension between (UIInputSender.checkExpectation), so the view the script approved is the view the press reaches;
# a `ui hit` answer alone is a socket round trip (~100-300 ms) older than the press. It also refuses a left press on a
# view that could move the window (mouseDownCanMoveWindow, in a window movable by its background). Older Kites ignore
# "expect" and send anyway, so clicks and drags are refused there. If that branch lands by squash or rebase, set this
# to the commit it landed as on main.
EXPECT_FLOOR=02014036530de2327bbbb55f7dc345fc6063c4ed
# How long a state waits, after Kite's socket answers, for that ready line. Kite writes it by 20 s after launch at the
# latest (FindTestHook.pageLoadTimeout: a find result, or the fallback when the page never loads), and
# FindTestHookTests checks that this stays at least 5 s above that.
FIND_READY_SECONDS=30

# The oldest Kite the sidebar's hooks (KITE_TEST_ICON_PICKER, KITE_TEST_NEW_SPACE, KITE_TEST_NEW_SPACE_NAME,
# KITE_TEST_NEW_SPACE_THEME) may run on: ci/test-hooks-icon-picker-create-space (#412). There, on a test-safe run only,
# a second after the main window is up, Kite opens Change Space Icon…'s picker for the named space through
# BrowserStore.requestIconPicker (the space menu's path), or Create a Space through beginNewSpace (+ › New Space's),
# sets its name field through the field's binding (no key events, no input method), picks the preset for the draft as
# the theme editor's swatch does and opens the theme editor from Choose a Theme's own row view. Nothing is pressed,
# activated or fronted. It writes "KITE_TEST_SIDEBAR: ready: …" once the popover shows (or the page is up), and
# `kite ui capture`'s in-process render draws the open popover over the window. Older Kites ignore the hooks, so the
# capture would show neither. If that branch lands by squash or rebase, set this to the commit it landed as on main.
SIDEBAR_FLOOR=7ad37b80584e50f8279dbca429d42e6bcebb460f
# How long a state waits, after Kite's socket answers, for that ready line (or its "failed" line). Kite writes one by
# 11 s after its window is up (SidebarTestHook.readyTimeout after a 1 s delay), and SidebarTestHookTests checks that
# this stays at least 5 s above that.
SIDEBAR_READY_SECONDS=20
# What Kite's ready line must start with (an ERE, for bash's =~): Kite isn't the active app, and the hook's popover, if
# it has one, is a child window of the main window at normal level, 0 (SidebarTestHook.Shown, whose facts come before
# any name). A higher level could put the popover over Gabe's windows: such a state fails, and needs a test-safe level
# fix in Kite, not a looser check. A key popover window in an inactive app can't take the keyboard from another app.
# SidebarTestHookTests matches it against the lines Kite writes.
SIDEBAR_READY_OK='^KITE_TEST_SIDEBAR: ready: app active no; (no popover|popover key (yes|no), level 0, parent the main window); '

# Views a click, right-click (through showSidebarMenu's KITE_TEST_CONTEXT_MENU hook) or drag may start on. Each was
# read in the Mac source: no hookless NSMenu, no window drag. Window drag: the browser window is movable by its
# background (BrowserWindowController.swift:168), but AppKit moves it from a press only when the view hit returns true
# from mouseDownCanMoveWindow, and both return false: SpaceCellView (SidebarSpaceBar.swift:334; its hitTest, 388,
# answers itself for any point inside it) and NewTabRowCell, a SidebarRowCell (SidebarListCells.swift:41, 1217). The
# hit test below requires the view hit to be that view itself for every left press; the press goes to the window by
# sendEvent (UIInputSender.swift), never through the window server's drag regions; PageTopWindowDragger's performDrag
# arms only on a page's top band (PageTopWindowDragger.swift:24-27, 45-53); and Kite's "expect" refuses a left press
# on any view that could move the window. Add one only after the same check. Not safe, for
# example: the sidebar header's Developer and More buttons (SidebarHeader.swift, menu.popUp without the hook), the
# link preview's Share button (LinkPreviewCard.swift, popUpAtPointer at the REAL pointer), and the window background
# and page-top band (isMovableByWindowBackground, PageTopWindowDragger: a window-server drag follows the real
# pointer).
SAFE_TARGETS="SpaceCellView NewTabRowCell"
# The subset whose left click opens Kite's own command bar (NewTabRowCell.tapped: showCommandBar(.newTab)), the
# only place a text step may type. The sidebar's address field opens it too; add its tree class after checking it.
COMMAND_BAR_OPENERS="NewTabRowCell"

# Sidebar rows that take a right-click only, and only to log their menu: a right-click (button right, no modifiers,
# the state's first step) in a state whose env has KITE_TEST_CONTEXT_MENU exactly "1" and whose profile has no
# test-context-menu-pick file. Left clicks (TabRowCell and FavoritePaneView select a tab, which loads its page;
# FolderRowCell opens or closes the folder), ⌃-clicks, double clicks (rename) and drags (moves) stay refused.
# Read in the Mac source, unchanged from SAFE_FLOOR to main edbbdc3 (so no floor of its own):
# - SidebarListCells.swift:149-158: TabRowCell's and FolderRowCell's rightMouseDown only builds menu(for:) (inside
#   the pill, acceptsPress) and calls showSidebarMenu; selecting, toggling and renaming are mouseDown/mouseUp (left)
#   only (113-147, tapped 615 and 937). SidebarFavorites.swift:483-500: FavoritePaneView's rightMouseDown the same;
#   it selects only on a left mouseUp (471-475). No Kite view overrides rightMouseUp.
# - SidebarKit.swift:658-680: showSidebarMenu returns before NSMenu.popUpContextMenu whenever
#   PageContextMenuItems.testMode is set (KITE_TEST_CONTEXT_MENU non-empty on a KITE_SUPPORT_PATH profile), logs the
#   items, and runs one only when PageContextMenuItems.testPick() (PageContextMenuItems.swift:134-142) names one:
#   the profile's test-context-menu-pick file, or the hook's value when it isn't "1". Hence exactly "1", no file.
# - Building the menus (contextMenu(at:) 627 and 948, menu(for:) 488) makes ClosureMenuItems (SidebarKit.swift:346)
#   from the store's state; their handlers (pasteboard, store changes, Claude) run only when picked.
# - UIInputSender.swift:55-64, 304-318: the right-click's down goes to Kite's window by window.sendEvent and its up
#   by NSApp.postEvent to the same windowNumber; nothing reaches the window server, so no hover (mouseEntered, a
#   favorite's preview) or activation follows (UIPointerProbe.swift:52), and a direct sendEvent skips the local
#   monitors (BrowserWindowController.swift:258-263). BrowserWindow.sendEvent intercepts left mouse events only.
RIGHT_CLICK_TARGETS="TabRowCell FolderRowCell FavoritePaneView"
# What `ui hit` may report between the view hit and the row it approved, for a row's right-click: views with no menu
# of their own, which pass a right-click up to their superview (NSView.rightMouseDown with menu(for:) nil):
# SymbolButton (SidebarKit.swift:131, overrides only left presses), and the containers SidebarPassthroughView and
# GroupHeaderView (SidebarKit.swift:23, SidebarListCells.swift:713), which hit-test to nothing themselves. A row's
# other views (FillView, SidebarLabel, SidebarImageView, FaviconImageView, DotView, PeekBadgeView, ClaudeRingView,
# ClaudeMarkView, SidebarRingView) hit-test to nothing, so a hit test never names them. Refused: the rename field
# (RenameField, and its field editor, which has a real menu), SwiftUI islands (Island<…>, the speaker), any view
# added later. SAFE_TARGETS clicks and every left click and drag must hit the approved view itself.
RIGHT_CLICK_INSIDE="SymbolButton SidebarPassthroughView GroupHeaderView"

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
python3 -I - "$REQUEST" "$WORK/plan" "$ROOT" "$SAFE_TARGETS" "$TEXT_FLOOR" "$FIND_FLOOR" "$HIT_FLOOR" "$EXPECT_FLOOR" \
    "$SIDEBAR_FLOOR" <<'PY'
import copy, ipaddress, json, os, re, subprocess, sys, urllib.parse, uuid
request_path, plan, root, safe_targets, text_floor, find_floor, hit_floor, expect_floor, sidebar_floor = sys.argv[1:10]
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
#   "url" a public http(s) URL (the session rule); "findtext" a text step's text (TEXT below).
HOOKS = {
    # Logs a context menu instead of showing it. Exactly 1: any other value, like a test-context-menu-pick file
    # (refused below), names an item, which Kite then runs (PageContextMenuItems.testPick).
    "KITE_TEST_CONTEXT_MENU": "flag",
    "KITE_TEST_BOOST_MENU": "text",            # presses the Boost editor's menu items without the menu
    "KITE_TEST_ZAP_PICKER": ("1", "copy"),     # opens the Zap picker in its own (test-safe) window
    "KITE_TEST_LITTLE_PROFILE_PICK": "text",   # logs Little Kite's profile menu (KITE_TEST_LITTLE_PROFILE_MENU:) and picks
    "KITE_TEST_LITTLE_EXTENSIONS_BUTTON": "flag",
    "KITE_TEST_TIDY_TITLE": "text",            # a stand-in reply instead of asking Claude
    "KITE_TEST_ASSUME_VISIBLE": "flag",
    "KITE_TEST_REOPEN_MAIN_AFTER": "number",   # reopens the main window behind the user's
    "KITE_TEST_EXPORT_DATA_PATH": "name",      # Export Data writes here instead of a save panel
    "KITE_TEST_OPEN_URL": "url",               # opens a link as another app would
    "KITE_TEST_FIND": "findtext",              # the find bar open with this query, which only searches the page
    "KITE_TEST_FIND_OPEN": "flag",             # the find bar open and empty
    "KITE_TEST_ICON_PICKER": "findtext",       # Change Space Icon…'s picker open for the space with this exact name
    "KITE_TEST_NEW_SPACE": "flag",             # Create a Space open for a new draft space
    "KITE_TEST_NEW_SPACE_NAME": "findtext",    # its name field's value (set, not typed)
    "KITE_TEST_NEW_SPACE_THEME": ("1", "2", "3", "4", "5", "6", "7"),   # this preset picked, the theme editor open
}
# The find bar's hooks: a base without FIND_FLOOR ignores them (no bar would show), so they're refused there.
FIND_HOOKS = {"KITE_TEST_FIND", "KITE_TEST_FIND_OPEN"}
# The sidebar's hooks: a base without SIDEBAR_FLOOR ignores them (no popover or page would show), so they're refused
# there. NEW_SPACE_VALUES only go with KITE_TEST_NEW_SPACE (Kite turns them all off otherwise).
SIDEBAR_HOOKS = {"KITE_TEST_ICON_PICKER", "KITE_TEST_NEW_SPACE", "KITE_TEST_NEW_SPACE_NAME", "KITE_TEST_NEW_SPACE_THEME"}
NEW_SPACE_VALUES = {"KITE_TEST_NEW_SPACE_NAME", "KITE_TEST_NEW_SPACE_THEME"}
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
    """Checks a session and returns (copy with fresh dataStoreIDs and profileSettings cut down, the new IDs, notes)."""
    if not isinstance(data, dict):
        fail(f"{where}: the session isn't a JSON object")
    data = copy.deepcopy(data)
    notes = []
    for holder in (data, data.get("state") if isinstance(data.get("state"), dict) else {}):
        if "profileSettings" in holder:
            # ProfileSettings holds downloadDirectory and promptsForDownload (a save panel), which go; only the
            # includesSearchSuggestions booleans stay (a fixture turns them off so no network rows appear).
            settings = holder["profileSettings"]
            kept = {}
            if isinstance(settings, dict):
                for store, values in settings.items():
                    if isinstance(values, dict) and isinstance(values.get("includesSearchSuggestions"), bool):
                        kept[str(store)] = {"includesSearchSuggestions": values["includesSearchSuggestions"]}
            dropped = not isinstance(settings, dict) or any(
                not isinstance(v, dict) or set(v) - {"includesSearchSuggestions"} for v in settings.values())
            if kept:
                holder["profileSettings"] = kept
            else:
                del holder["profileSettings"]
            if dropped:
                notes.append("profileSettings cut to includesSearchSuggestions")
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
INPUT_KEYS = {"click", "button", "count", "modifiers", "from", "to", "steps", "hold", "scroll", "dx", "dy", "phase", "text",
              "keys"}
# The one key chord allowed: ⌘T, which opens Kite's own command bar (New Tab…). In a background test-safe window it
# goes down UIInputSender's key-equivalent path to the menu item, and the bar is a view inside the window that's
# only given the first responder: nothing is posted to the window server, made key, fronted or activated
# (fix/test-safe-text-input 9261122: UIInputSender.swift:216-221, 226-266; MainMenu.swift:166;
# BrowserWindowController.swift:265-272, 387-390, 1048-1065, 1089-1105, 1303-1305; WindowPresenter.swift:7-13).
OPENER_KEYS = "cmd+t"
TEXT = re.compile(r"[A-Za-z0-9 ._-]{1,40}")
_text_fix = []
def has_text_fix():
    if not _text_fix:
        _text_fix.append(git("merge-base", "--is-ancestor", text_floor, "HEAD", lazy=False).returncode == 0)
    return _text_fix[0]
_hit_fix = []
def has_hit_fix():
    # Checked once, on the checkout's HEAD; a HIT_FLOOR missing from the clone counts as not there.
    if not _hit_fix:
        _hit_fix.append(git("merge-base", "--is-ancestor", hit_floor, "HEAD", lazy=False).returncode == 0)
    return _hit_fix[0]
_expect_fix = []
def has_expect_fix():
    # Checked once, on the checkout's HEAD; an EXPECT_FLOOR missing from the clone counts as not there.
    if not _expect_fix:
        _expect_fix.append(git("merge-base", "--is-ancestor", expect_floor, "HEAD", lazy=False).returncode == 0)
    return _expect_fix[0]
def needs_hit(where):
    if not has_hit_fix():
        fail(f"{where}: clicks and drags need a base with `ui hit` ({hit_floor[:7]}), which this base doesn't contain: "
             "without it a click can't be checked against what AppKit would hit")
    if not has_expect_fix():
        fail(f"{where}: clicks and drags need a base with `ui input`'s \"expect\" ({expect_floor[:7]}), which this base "
             "doesn't contain: without it the hit test and the press aren't one step, and Kite ignores the check")
_find_fix = []
def has_find_fix():
    # Checked once, on the checkout's HEAD; a FIND_FLOOR missing from the clone counts as not there.
    if not _find_fix:
        _find_fix.append(git("merge-base", "--is-ancestor", find_floor, "HEAD", lazy=False).returncode == 0)
    return _find_fix[0]
_sidebar_fix = []
def has_sidebar_fix():
    # Checked once, on the checkout's HEAD; a SIDEBAR_FLOOR missing from the clone counts as not there.
    if not _sidebar_fix:
        _sidebar_fix.append(git("merge-base", "--is-ancestor", sidebar_floor, "HEAD", lazy=False).returncode == 0)
    return _sidebar_fix[0]
def check_step(action, args, menu_refused, where, previous, row_menu):
    """Returns what must be true when the step runs: points on SAFE_TARGETS views, or (text) the command bar open.
    menu_refused is None when the state's env and profile make a context menu only log itself, else what's missing.
    row_menu is None when a right-click here may also land on a RIGHT_CLICK_TARGETS row, else why not."""
    if action == "trace" and "keys" in args:
        fail(f"{where}: trace keys aren't allowed (keys aren't reviewed for headless safety)")
    if action == "pointer":
        # Synthetic hover (UIPointerProbe): mouseEntered and mouseMoved straight to tracking-area owners, with its
        # modifiers held. That previews favorites, shows the space tip window and, with ⇧, opens link previews
        # (LinkPreviewWindow), none of it checked against SAFE_TARGETS. No request has used one (W12's and W13's hover
        # states are skipped).
        fail(f"{where}: pointer steps aren't allowed (synthetic hover reaches views no one reviewed for headless safety)")
    if action != "input":
        return []
    extra = set(args) - INPUT_KEYS
    if extra:
        fail(f"{where}: input {sorted(extra)[0]!r} isn't allowed (keys, flags and window aren't reviewed for headless safety)")
    kinds = [k for k in ("click", "from", "scroll", "text", "keys") if k in args]
    if len(kinds) != 1:
        fail(f"{where}: an input step is one click, one drag (from/to), one scroll, one text or ⌘T")
    if "keys" in args:
        if args != {"keys": OPENER_KEYS}:
            fail(f"{where}: the only keys allowed are {OPENER_KEYS!r} on their own (opening the command bar)")
        if not has_text_fix():
            fail(f"{where}: {OPENER_KEYS} needs a base with fix/test-safe-text-input ({text_floor[:7]})")
        return [{"what": OPENER_KEYS, "opens": "command bar"}]
    if "text" in args:
        if set(args) != {"text"} or not isinstance(args["text"], str) or not TEXT.fullmatch(args["text"]):
            fail(f"{where}: text is 1–40 of A-Z a-z 0-9 space . _ - (no keys, no Return), on its own")
        after_click = (previous and previous[0] == "input" and "click" in previous[1]
                       and previous[1].get("button", "left") == "left" and not previous[1].get("modifiers"))
        after_keys = previous and previous[0] == "input" and previous[1] == {"keys": OPENER_KEYS}
        if not (after_click or after_keys):
            fail(f"{where}: text must come straight after {OPENER_KEYS} or a plain left click on a command-bar opener")
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
        # No modifiers, ⌃ included. Kite takes a ⌃-click as a right-click (SidebarRowCell.mouseDown,
        # SpaceCellView.mouseDown), but it's a left mouse down with the control flag, and AppKit may show the view's
        # menu(for:) itself for one (a real NSMenu, which no test hook sees) before mouseDown runs. A right-click
        # reaches the same menu only through the view's own rightMouseDown and showSidebarMenu's hook.
        if mods:
            fail(f"{where}: no modifiers on a click (for a ⌃-click's menu, send a right-click)")
        if button == "right" and menu_refused:
            fail(f"{where}: a right-click needs {menu_refused}")
        needs_hit(where)
        check = {"point": at, "what": f"{button} click", "click": True}
        # Rows (RIGHT_CLICK_TARGETS) take a plain right-click that only logs their menu; anything else is checked
        # against SAFE_TARGETS alone, so a row refuses it. The runner sees "rows" and nothing else.
        if button == "right":
            why = row_menu or ("it has modifiers" if mods else None)
            if why:
                check["rows_refused"] = why
            else:
                check["rows"] = True
        return [check]
    if "from" in args:
        start = point(args["from"], where)
        point(args.get("to"), where)
        if "modifiers" in args:
            fail(f"{where}: drags take no modifiers")
        needs_hit(where)
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
        elif kind == "findtext" and not TEXT.fullmatch(value):
            fail(f"{where}: {key} is 1–40 of A-Z a-z 0-9 space . _ - (the rule for text)")
        elif kind == "name":
            if not NAME.fullmatch(value):
                fail(f"{where}: {key} is a file name inside the profile ([a-z0-9._-])")
            value = "@profile/" + value
        if key in FIND_HOOKS and not has_find_fix():
            fail(f"{where}: {key} needs a base with fix/test-find-hooks ({find_floor[:7]}), which this base doesn't "
                 "contain: without it Kite ignores the hook")
        if key in SIDEBAR_HOOKS and not has_sidebar_fix():
            fail(f"{where}: {key} needs a base with ci/test-hooks-icon-picker-create-space ({sidebar_floor[:7]}), "
                 "which this base doesn't contain: without it Kite ignores the hook")
        env_lines.append(f"{key}={value}")
    if FIND_HOOKS <= set(env):
        fail(f"{where}: KITE_TEST_FIND and KITE_TEST_FIND_OPEN are one or the other, not both")
    find_hook = bool(FIND_HOOKS & set(env))
    sidebar_hook = bool(SIDEBAR_HOOKS & set(env))
    if "KITE_TEST_ICON_PICKER" in env and (SIDEBAR_HOOKS - {"KITE_TEST_ICON_PICKER"}) & set(env):
        fail(f"{where}: KITE_TEST_ICON_PICKER and the KITE_TEST_NEW_SPACE hooks are one or the other, not both")
    if NEW_SPACE_VALUES & set(env) and "KITE_TEST_NEW_SPACE" not in env:
        fail(f"{where}: KITE_TEST_NEW_SPACE_NAME and _THEME only go with KITE_TEST_NEW_SPACE set to 1")
    if sidebar_hook and set(env) - SIDEBAR_HOOKS:
        fail(f"{where}: a sidebar hook goes alone: no {', '.join(sorted(set(env) - SIDEBAR_HOOKS))} beside it")
    if sidebar_hook and find_hook:
        fail(f"{where}: a sidebar hook and a find-bar hook are one or the other, not both")
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
        elif k == "test-context-menu-pick":
            fail(f"{where}: profile_files can't have test-context-menu-pick (Kite runs the menu item it names)")
        elif not (re.fullmatch(r"test-[a-z0-9-]+", k) and isinstance(v, str) and len(v) <= 10_000):
            fail(f"{where}: profile_files maps test-* names (or history.json) to text")
    steps = state.get("steps") or []
    if not isinstance(steps, list):
        fail(f"{where}: steps is a list")
    lines, shown = [], []
    previous = None
    # A context menu only logs itself when the hook is on and nothing names an item to run
    # (PageContextMenuItems.testPick). HOOKS and profile_files above already refuse the rest; checked again here,
    # where it decides a right-click.
    if "KITE_TEST_CONTEXT_MENU" not in env:
        menu_refused = "KITE_TEST_CONTEXT_MENU set to 1 in env (a real menu needs a real screen)"
    elif env["KITE_TEST_CONTEXT_MENU"] != "1":
        menu_refused = "KITE_TEST_CONTEXT_MENU exactly 1 (any other value picks a menu item)"
    elif "test-context-menu-pick" in files:
        menu_refused = "no test-context-menu-pick file (it picks a menu item)"
    else:
        menu_refused = None
    row_menu = menu_refused
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
        if sidebar_hook and action == "input":
            fail(f"{where}: a state with a sidebar hook takes no input steps (the hook's state is what's captured)")
        if action not in ("input", "tree", "pointer", "windows", "menu", "key_log", "trace"):
            fail(f"{where}: steps[{j}] is {{\"ui\": ACTION, \"args\": {{…}}}} (not capture) or {{\"wait\": s}}")
        if not isinstance(args, dict) or "action" in args or "save" in args:
            fail(f"{where}: steps[{j}].args is the action's JSON object, without action or save")
        # Rows only for the state's first step (waits aside): nothing an earlier step opened (the command bar, a
        # popover) can be over the row, and the row is as the session laid it out.
        first = row_menu if row_menu else ("a step comes before it (a row's right-click is the state's first step)"
                                           if any(not line.startswith("wait\t") for line in lines) else None)
        checks = check_step(action, args, menu_refused, f"{where} steps[{j}]", previous, first)
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
                  f"CAPTURE={1 if bool(state.get('capture', True)) else 0}\nSKIP={1 if state.get('skip') else 0}\n"
                  f"FIND={1 if find_hook else 0}\nSIDEBAR={1 if sidebar_hook else 0}\n")
    index.append(folder)
with open(os.path.join(plan, "index"), "w") as f:
    f.write("".join(folder + "\n" for folder in index))
with open(os.path.join(plan, "request.json"), "w", encoding="utf-8") as f:
    json.dump({"id": request["id"], "title": request.get("title") or f"{request['id']} Mac references",
               "base": request.get("base") or "origin/main", "tree_match": tree_match},
              f, ensure_ascii=False)
PY

TREE_MATCH="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["tree_match"] or "")' "$WORK/plan/request.json")"
# The match trees are read whole (max_nodes 5000); a cut-short one is refused where it decides a step.
match_json() { python3 -I -c 'import json,sys; print(json.dumps({"match": sys.argv[1], "max_nodes": 5000}))' "$1"; }

# on_safe_target CHECKS TREEFILE CLASSES [PATHFILE]: prints "hit CLASS" when the check's point lands on a visible view
# of one of CLASSES (or, for a check without a point, when one is visible at all), else why not. With PATHFILE, the
# hit view's tree path is written there.
on_safe_target() {
    python3 -I - "$1" "$2" "$3" "${4:-}" <<'PY'
import json, re, sys
checks, tree, safe = json.loads(sys.argv[1]), open(sys.argv[2], encoding="utf-8", errors="replace").read(), sys.argv[3].split()
# A tree line (UINode.line): path, class, then optional #identifier and "quoted label" (\" and \\ escaped, so a
# label can't fake a frame), then [x,y w×h] and attributes.
LINE = re.compile(r'(?P<path>\S+) (?P<cls>\S+)(?: #\S+)?(?: "(?:[^"\\]|\\.)*")? '
                  r'\[(?P<x>-?[\d.]+),(?P<y>-?[\d.]+) (?P<w>[\d.]+)×(?P<h>[\d.]+)\](?P<rest>.*)')
frames = []
for line in tree.splitlines():
    if line.strip().startswith("…"):
        print(f"the tree for {' or '.join(safe)} was cut short ({line.strip()[:60]})")
        sys.exit()
    m = LINE.fullmatch(line.strip())
    if m and m["cls"] in safe and not re.search(r"\b(hidden=true|alpha=0|opacity=0)(\s|\Z)", m["rest"]):
        frames.append((m["cls"], [float(m[k]) for k in ("x", "y", "w", "h")], m["path"]))
hit, path = None, ""
for check in checks:
    if "point" not in check:
        hit = frames[0][0] if frames else None
        if not hit:
            print(f"no visible {' or '.join(safe)} for the {check['what']} step")
            sys.exit()
        continue
    x, y = check["point"]
    hits = [(c, p) for c, (fx, fy, fw, fh), p in frames if fx <= x < fx + fw and fy <= y < fy + fh]
    hit, path = hits[0] if hits else (None, "")
    if check.get("rows") and len(hits) > 1:
        # A row in a hidden list (another space's) can share a visible one's frame: which one AppKit hits is unclear.
        print(f"the {check['what']} at {x:g},{y:g} is on {len(hits)} views ({', '.join(f'{c} {p}' for c, p in hits)})")
        sys.exit()
    if not hit:
        why = f" (not a row: {check['rows_refused']})" if check.get("rows_refused") else ""
        print(f"the {check['what']} at {x:g},{y:g} isn't on a visible {' or '.join(safe)}{why}")
        sys.exit()
if sys.argv[4]:
    open(sys.argv[4], "w", encoding="utf-8").write(path)
print(f"hit {hit}")
PY
}

# tree_window FILE…: prints the window number every tree or hit answer in FILE names ("Window N, …"), or nothing
# when they don't all name the same one.
tree_window() {
    python3 -I - "$@" <<'PY'
import re, sys
found = set()
for path in sys.argv[1:]:
    found |= set(re.findall(r"^Window (\d+), ", open(path, encoding="utf-8", errors="replace").read(), re.M))
print(found.pop() if len(found) == 1 else "")
PY
}

# hit_json CHECKS WINDOW: the `ui hit` arguments for the check's point in that window.
hit_json() {
    python3 -I -c 'import json,sys; c = next(c for c in json.loads(sys.argv[1]) if "point" in c)
print(json.dumps({"window": int(sys.argv[2]), "point": c["point"]}))' "$1" "$2"
}

# with_window ARGS WINDOW: the step's `ui input` arguments aimed at that window.
with_window() {
    python3 -I -c 'import json,sys; a = json.loads(sys.argv[1]); a["window"] = int(sys.argv[2])
print(json.dumps(a, ensure_ascii=False, separators=(",", ":")))' "$1" "$2"
}

# with_expect ARGS WINDOW PATH CLASS ALLOWED: the step's `ui input` arguments aimed at that window, with the approved
# view as "expect" (EXPECT_FLOOR): Kite hit-tests again as it sends the press, and sends nothing if the view hit isn't
# that view (or, with ALLOWED, views of those classes inside it).
with_expect() {
    python3 -I -c 'import json,sys; a = json.loads(sys.argv[1]); a["window"] = int(sys.argv[2])
a["expect"] = {"path": sys.argv[3], "class": sys.argv[4], "inside": sys.argv[5].split()}
print(json.dumps(a, ensure_ascii=False, separators=(",", ":")))' "$1" "$2" "$3" "$4" "$5"
}

# hit_reaches CHECKS HITFILE WINDOW PATH CLASS ALLOWED: prints "ok" when Kite's own hit test (`ui hit`, in HITFILE)
# in WINDOW reaches the approved view (PATH, CLASS from the tree): the view hit is that view, or a view of ALLOWED
# whose superviews up to it are of ALLOWED too, none hidden; else why not. Anything it can't read is refused.
hit_reaches() {
    python3 -I - "$1" "$2" "$3" "$4" "$5" "$6" <<'PY'
import json, re, sys
checks, text, window, path, cls, allowed = (json.loads(sys.argv[1]), open(sys.argv[2], encoding="utf-8", errors="replace").read(),
                                            sys.argv[3], sys.argv[4], sys.argv[5], set(sys.argv[6].split()))
x, y = next(c["point"] for c in checks if "point" in c)
where = f"the {next(c['what'] for c in checks if 'point' in c)} at {x:g},{y:g}"
windows = re.findall(r"^Window (\d+), ", text, re.M)
if windows != [window]:
    print(f"{where}: the hit test didn't answer for window {window} ({text.strip()[:120]!r})")
    sys.exit()
head = re.search(r"^Hit at \(.*\): (.*)$", text, re.M)
if not head:
    print(f"{where}: no hit test answer ({text.strip()[:120]!r})")
    sys.exit()
if head[1].strip() == "nothing.":
    print(f"{where} hits nothing")
    sys.exit()
LINE = re.compile(r"(?P<path>\S+) (?P<cls>\S+) \[(?P<frame>-?[\d.]+,-?[\d.]+ [\d.]+×[\d.]+)\](?P<hidden> hidden=true)?")
chain = []
for line in text[head.end():].strip().splitlines():
    m = LINE.fullmatch(line.strip())
    if not m:
        print(f"{where}: couldn't read the hit test's line {line.strip()[:80]!r}")
        sys.exit()
    chain.append(m)
for m in chain:
    if m["hidden"]:
        print(f"{where} reaches a hidden {m['cls']} ({m['path']})")
        sys.exit()
    if m["path"] == path:
        if m["cls"] != cls:
            print(f"{where}: the hit test has a {m['cls']} at {path}, not the {cls} the tree showed")
        else:
            print("ok")
        sys.exit()
    if m["cls"] not in allowed:
        print(f"{where} reaches a {m['cls']} ({m['path']}), not the {cls} at {path}")
        sys.exit()
print(f"{where} reaches {chain[0]['cls'] if chain else 'nothing'} ({chain[0]['path'] if chain else '-'}), "
      f"which isn't inside the {cls} at {path}")
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

    # A find-bar hook opens the bar once the page has loaded and writes "KITE_TEST_FIND: ready: …" (for a query,
    # when its search has come back): no steps and no capture until then.
    if [[ "$FIND" == 1 ]]; then
        ready=0
        for _ in $(seq $((FIND_READY_SECONDS * 5))); do
            if grep -q '^KITE_TEST_FIND: ready' "$PROFILE/kite.log" 2>/dev/null; then ready=1; break; fi
            kill -0 "$KITE_PID" 2>/dev/null || break
            sleep 0.2
        done
        if [[ "$ready" != 1 ]]; then
            echo "failed: no 'KITE_TEST_FIND: ready' line from Kite in $FIND_READY_SECONDS s (the find bar didn't open)" >"$folder/status"
            grep -E '^KITE_TEST_[A-Z_]+:' "$PROFILE/kite.log" >"$folder/test-lines" 2>/dev/null || true
            cp "$PROFILE/kite.log" "$LOGS/$NAME.kite.log" 2>/dev/null || true
            stop_kite; unset KITE_SUPPORT_PATH; failed=1; continue
        fi
    fi
    # A sidebar hook opens the icon picker or Create a Space a second after the window is up and writes
    # "KITE_TEST_SIDEBAR: ready: …" once it shows, or "failed: …" when it didn't: no steps and no capture until then.
    if [[ "$SIDEBAR" == 1 ]]; then
        ready=0
        for _ in $(seq $((SIDEBAR_READY_SECONDS * 5))); do
            if grep -q '^KITE_TEST_SIDEBAR: ready' "$PROFILE/kite.log" 2>/dev/null; then ready=1; break; fi
            grep -qE '^KITE_TEST_SIDEBAR: (failed|refused)' "$PROFILE/kite.log" 2>/dev/null && break
            kill -0 "$KITE_PID" 2>/dev/null || break
            sleep 0.2
        done
        ready_line="$(grep -a -m1 '^KITE_TEST_SIDEBAR: ready' "$PROFILE/kite.log" 2>/dev/null || true)"
        if [[ "$ready" != 1 ]]; then
            echo "failed: no 'KITE_TEST_SIDEBAR: ready' line from Kite in $SIDEBAR_READY_SECONDS s (see test-lines)" >"$folder/status"
        elif [[ ! "$ready_line" =~ $SIDEBAR_READY_OK ]]; then
            # Kite was the active app, or the popover isn't the main window's child: nothing is captured.
            echo "failed: Kite's ready line isn't a background run's: ${ready_line:0:300}" >"$folder/status"
            ready=0
        fi
        if [[ "$ready" != 1 ]]; then
            grep -E '^KITE_TEST_[A-Z_]+:' "$PROFILE/kite.log" >"$folder/test-lines" 2>/dev/null || true
            cp "$PROFILE/kite.log" "$LOGS/$NAME.kite.log" 2>/dev/null || true
            stop_kite; unset KITE_SUPPORT_PATH; failed=1; continue
        fi
    fi

    step_status=0
    refused=""
    last_hit=""   # the SAFE_TARGETS class the previous step clicked, for a text step
    : >"$folder/steps.out"
    while IFS=$'\t' read -r kind action args checks <&4; do
        [[ -n "$kind" ]] || continue
        pressed=0   # 1: a checked click or drag, sent with "expect"
        if [[ "$kind" == wait ]]; then sleep "$action"; last_hit=""; continue; fi
        if [[ "$checks" == *'"needs":"command bar"'* ]]; then
            # Text only straight after a click on a command-bar opener, and only into Kite's own open command bar.
            if [[ -z "$last_hit" || ( "$last_hit" != "cmd+t" && " $COMMAND_BAR_OPENERS " != *" $last_hit "* ) ]]; then
                refused="the text step doesn't follow a click on a command-bar opener (${last_hit:-no safe click})"
            else
                # The bar opens a moment after the click: 15 looks 0.2 s apart, each tree read capped at 5 s.
                for _ in $(seq 15); do
                    tmo 5 "$CLI" ui tree "$(match_json CommandBarField)" >"$folder/targets.txt" 2>&1 || true
                    result="$(on_safe_target "$checks" "$folder/targets.txt" CommandBarField)"
                    if [[ "$result" == "hit "* ]]; then break; fi
                    sleep 0.2
                done
                if [[ "$result" != "hit "* ]]; then
                    refused="$result"
                else
                    # The text goes to the window whose command bar the tree showed.
                    win="$(tree_window "$folder/targets.txt")"
                    if [[ "$win" =~ ^[0-9]+$ ]]; then args="$(with_window "$args" "$win")"
                    else refused="the CommandBarField tree didn't name one window"; fi
                fi
            fi
            last_hit=""
        elif [[ "$checks" == *'"opens":"command bar"'* ]]; then
            last_hit="cmd+t"   # the planner allowed exactly {"keys":"cmd+t"} here, on a base with TEXT_FLOOR
        elif [[ -n "$checks" ]]; then
            # The planner marks a plain right-click, as the state's first step with KITE_TEST_CONTEXT_MENU exactly 1
            # and no pick file, with "rows": only that one may also land on a RIGHT_CLICK_TARGETS row.
            classes="$SAFE_TARGETS"
            if [[ "$checks" == *'"rows":true'* ]]; then classes="$SAFE_TARGETS $RIGHT_CLICK_TARGETS"; fi
            : >"$folder/targets.txt"
            for target in $classes; do
                tmo 60 "$CLI" ui tree "$(match_json "$target")" >>"$folder/targets.txt" 2>&1 || true
            done
            : >"$folder/hit-path"
            result="$(on_safe_target "$checks" "$folder/targets.txt" "$classes" "$folder/hit-path")"
            if [[ "$result" == "hit "* ]]; then
                target="${result#hit }"
                target_path="$(cat "$folder/hit-path")"
                # What AppKit would hit there, in the window the trees read (a frame in the tree isn't proof: frames
                # are unclipped and hidden is only isHidden). Only a row's right-click may hit a RIGHT_CLICK_INSIDE
                # view inside the row; everything else must hit the approved view itself.
                allowed=""
                if [[ "$checks" == *'"rows":true'* && " $RIGHT_CLICK_TARGETS " == *" $target "* ]]; then allowed="$RIGHT_CLICK_INSIDE"; fi
                win="$(tree_window "$folder/targets.txt")"
                if [[ ! "$win" =~ ^[0-9]+$ ]]; then
                    refused="the $target trees didn't name one window"
                elif [[ ! "$target_path" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
                    refused="no tree path for the $target"
                else
                    tmo 60 "$CLI" ui hit "$(hit_json "$checks" "$win")" >"$folder/hit.txt" 2>&1 || true
                    reached="$(hit_reaches "$checks" "$folder/hit.txt" "$win" "$target_path" "$target" "$allowed")"
                    if [[ "$reached" == ok ]]; then
                        last_hit="$target"
                        # The press goes to the window just hit-tested, and Kite checks the same view as it sends it.
                        args="$(with_expect "$args" "$win" "$target_path" "$target" "$allowed")"
                        pressed=1
                    else
                        refused="$reached"
                    fi
                fi
            else
                refused="$result"
            fi
        else
            last_hit=""
        fi
        if [[ -n "$refused" ]]; then echo "refused: $refused" >>"$folder/steps.out"; break; fi
        echo "\$ kite ui $action '$args'" >>"$folder/steps.out"
        status=0
        tmo 60 "$CLI" ui "$action" "$args" >"$folder/step.out" 2>&1 || status=$?
        cat "$folder/step.out" >>"$folder/steps.out"
        if [[ "$status" != 0 ]]; then
            step_status=$status
            echo "(exit $status)" >>"$folder/steps.out"
            # A press Kite refused (its "expect" didn't hold) or may not have sent: the state didn't happen.
            if [[ "$pressed" == 1 ]]; then
                refused="the press failed or Kite refused it (exit $status): $(tail -c 300 "$folder/step.out" | tr '\n' ' ')"
                echo "refused: $refused" >>"$folder/steps.out"
                break
            fi
        fi
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
        # Kite looks every 0.2 s, after its ready line, for the state going (a transient popover closing, the page
        # ending) or Kite becoming active, and writes "changed": then the capture may not show the state, so it's dropped.
        if [[ "$SIDEBAR" == 1 && -f "$OUT/$NAME.png" ]]; then
            sleep 0.5
            changed="$(grep -a -m1 '^KITE_TEST_SIDEBAR: changed' "$PROFILE/kite.log" 2>/dev/null || true)"
            if [[ -n "$changed" ]]; then
                echo "failed: the hook's state didn't hold through the capture: ${changed:0:300}" >"$folder/status"
                rm -f "$OUT/$NAME.png"; failed=1
            fi
        fi
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
