# Helix for Kite

How Kite for Windows is built from Kite for Mac: in small checkpoints, each of which
has to pass every gate before the next one starts. It's our version of Shopify's
internal [Helix](https://shopify.engineering/helix), which isn't public. The
idea is theirs. The tooling here is ours, built on Claude Code.

> An attempt is allowed to be wrong. It is not allowed to ship until it isn't.

## The reference is the spec

Kite for Mac is the reference for everything: behaviour, layout, sizes, colours
and motion. There are no separate spec files. For each checkpoint the agent
reads the Mac code it ports (`Sources/KiteCore`, `Sources/KiteMac`) and the
Mac tests that cover it. Arc for Windows is never a reference.

## Checkpoints

`windows/helix/checkpoints.md` is the ordered list. Each checkpoint has an id,
a one-line description Gabe can judge at a glance, the Mac sources it ports,
and its status: `planned`, `approved`, `in progress`, `in review (#PR)` (every
gate but Gabe's has passed and the PR is open), `done (#PR)` (merged). A
status can carry a note in brackets, such as what it's waiting on. Gabe approves
the order, or the agent proposes the next few, and he trims or reorders them.
The first checkpoint of a screen is its skeleton. Later ones add to it.

One checkpoint makes one commit (or a short series) and normally one PR.

## Gates, in order

A failed gate goes back to the agent with its findings, and the agent retries
for as long as it needs to. An agent can't override a gate.

1. **Behaviour.** The checkpoint's Mac tests are ported case for case into
   `windows/tests`, and edge cases the Mac doesn't test are added. Anything
   visible in the app is also reachable headless through `kitecore`, so a
   behaviour can be checked in milliseconds without a window. `ctest` must pass.
   Swift `KiteCore` tests that touch a shared format (`Tests/Fixtures`) must
   pass too. The model builds anywhere, so this gate also runs off Windows:
   `cmake -S windows -B /tmp/kite-core && cmake --build /tmp/kite-core && ctest --test-dir /tmp/kite-core`.
2. **UI match** (skipped for logic-only checkpoints). Kite for Mac and Kite for
   Windows are loaded with the same `session.json` from `windows/helix/states/`,
   at the same window size in points, and captured at the same scale (2×):
   - Mac (a Retina display, so 2×): a `KITE_DIAGNOSTICS=1` test build with
     `KITE_SUPPORT_PATH=<fresh profile>` and `KITE_WINDOW_SIZE=W,H`, captured
     with `kite ui capture`. The sidebar width comes from the dev bundle's
     defaults, so reset it first: `defaults delete dev.gabek.Kite.dev SidebarWidth`.
   - Windows (any monitor): `Kite.exe --capture C:\…\out.png --window-size W,H
     --capture-scale 2` (absolute paths) with `KITE_SUPPORT_PATH` set the same way. Kite lays
     the window out at 2× whatever the monitor's scale (a 200% display isn't
     needed) and saves the frame the window presents, so the pixels line up
     with the Mac's. A capture draws over the solid material fallback, while
     the Mac capture shows its blurred material, so the backdrop's tint is
     compared, not what's behind the window.
   A visual reviewer (a fresh subagent that sees only the two images and the
   checkpoint's description) lists every difference with a severity
   (blocker, major, minor) and a location. Anything fixable in code is a
   blocker by default. If the two captures show different states, it answers
   INVALID and the capture is redone, not argued. Only what the checkpoint built
   is compared.
3. **Adversarial review.** Two reviewers, each a fresh subagent with no access
   to the implementer's reasoning, read the diff against
   `docs/windows-architecture.md` and the Mac reference. One looks for
   correctness and parity bugs, the other for architecture, performance and
   layering. Both must approve. After fixes, affected tests rerun, and the UI
   gate reruns if anything visible changed.
4. **Gabe.** He approves the checkpoint (usually by merging its PR). In
   autonomous mode this gate is skipped and the other three still apply.

### Requesting Mac references

The Mac side of the UI gate runs in CI, so it doesn't wait for Gabe to be at his Mac. Branch
`review/<id>-mac-request` from main, add `review/<id>-mac-request/request.json` and push it.
`.github/workflows/mac-reference-captures.yml` then runs on the Mac runner (`MACOS_RUNNER`; a run
waits while the Mac sleeps), builds `scripts/bundle-app.sh debug` from the request's `base`
(default origin/main), takes each state with `scripts/mac-reference-captures.sh`, and pushes the
PNGs, `NAME.tree.txt` frames and a NOTES.md to `review/<id>-mac` (logs go to the run's artifact).
`gh workflow run "Mac reference captures" -f request_branch=review/<id>-mac-request` reruns one.

```json
{
  "id": "w9d", "title": "W9d Mac references: …", "base": "origin/main", "window_size": [1280, 820],
  "session": {"ref": "origin/helix/W9d-space-editing", "path": "windows/helix/states/three-spaces.json"},
  "tree_match": "SpaceCellView", "expect_frames": [[68, 778, 36, 34]],
  "states": [
    {"name": "rest", "holds": "the three spaces at rest"},
    {"name": "drag", "steps": [{"ui": "input", "args": {"from": [86, 795], "to": [150, 795], "steps": 10, "hold": 10}}],
     "hold": 10},
    {"name": "rename", "env": {"KITE_TEST_CONTEXT_MENU": "Rename Space…"},
     "steps": [{"ui": "input", "args": {"click": [86, 795], "button": "right"}}], "settle": 1}
  ]
}
```

Each state gets a fresh profile with its `session` (`ref` + `path` from any branch, or `inline`),
`defaults delete dev.gabek.Kite.dev SidebarWidth`, and `KITE_DIAGNOSTICS=1 KITE_WINDOW_SIZE=W,H`
plus its `env` (only the hooks the script's `HOOKS` list allows) and `profile_files` (`test-*`, and
`history.json`, checked like a session). Its
`steps` are `kite ui` actions (`{"ui": ACTION, "args": {…}}`) and pauses (`{"wait": s}`). The capture comes `settle`
seconds after the last step (default 1), or straight away when `hold` says the steps hold the state
that long. It's `kite ui capture '{"source":"in-process"}'` at 2×, with the tree's `tree_match`
frames read before and after. `expect_frames` are the frames your points assume, and NOTES.md
flags any the tree didn't show. `"capture": false` runs a state for its hook logs only, and
`"unverified"` / `"skip"` say what it can't show. The full format is at the top of the script.

Everything is headless: the build opens behind other windows and is never activated, input goes to
its window only, nothing records the screen. What needs a real screen (a real right-click menu,
`screencapture`, focus) isn't taken and is listed in NOTES.md as unverified. The script refuses a
request that could reach past that, before anything runs:
- a `base` older than its `SAFE_FLOOR` (test-safe mode) or not on one of origin's branches;
- a hook outside `HOOKS`, or an empty or blank hook value (Kite turns an empty hook off). Gabe's
  Claude home, Messages, media, imports, a global hotkey and the stand-ins for real services are
  refused; downloads, web apps, browser data and the pasteboard always point inside the profile;
- a session or `history.json` URL that isn't public http(s) or `about:` (a host whose last label is
  numeric, like `127.1` or `0x7f.1`, counts as an address), or a path-like value. `profileSettings`
  keeps only its `includesSearchSuggestions` booleans (download folders and the save-panel choice
  go), and every profile gets a fresh WebKit store that's deleted afterwards;
- keys (except exactly `{"keys":"cmd+t"}`, which opens Kite's own command bar, on a base with
  `TEXT_FLOOR`) or modifier flags; a click or drag that doesn't start on a visible view in
  `SAFE_TARGETS` (checked against the tree just before the step); a right- or ⌃-click without a
  non-empty `KITE_TEST_CONTEXT_MENU`, which logs the menu instead of showing it;
- text, except 1–40 of `A-Z a-z 0-9 space . _ -` straight after `cmd+t` or a plain click on a
  command-bar opener (`NewTabRowCell`; a background window drops that click, as the row doesn't take
  first mouse, so `cmd+t` is the one that works headless), into a visible `CommandBarField`: Kite's own command bar, which acts
  only on Return, and Return can't be sent. Text also needs a base with the script's `TEXT_FLOOR`
  (fix/test-safe-text-input), where a test-safe run inserts it into the bar's field editor without
  key events, so the input method (and a Japanese input source's candidate window) never sees it;
- the find bar's hooks, except `KITE_TEST_FIND` with a value under the same text rule or
  `KITE_TEST_FIND_OPEN` set to exactly `1`, one of them per state, on a base with the script's
  `FIND_FLOOR` (fix/test-find-hooks). On that base a test-safe run opens the bar as ⌘F does and sets
  its query through the field's own path, without key events. A state with either hook waits for Kite's
  `KITE_TEST_FIND: ready` line before its steps, and fails, uncaptured, without it.

The Mac job only reads the repository (no token left in its checkout); a GitHub-hosted job pushes
`review/<id>-mac`. Raise `SAFE_FLOOR` whenever new test-safety work lands in Kite.

Known gaps, which need changes in Kite rather than here:
- A public host name that resolves to a private address, a redirect, or an iframe can still reach
  the LAN from a test page. Kite needs to block private addresses itself on a test profile.
- The Default profile's WebKit store is `WKWebsiteDataStore.default()` for `dev.gabek.Kite.dev`,
  which Gabe's own dev runs share. A test profile needs a store of its own.
- `GIT_NO_LAZY_FETCH` only works with git 2.45 or newer; on older git the real guard against a
  fork-network commit is the check that the base is on one of origin's branches.

## Evidence

Every checkpoint's PR carries its evidence: the test run, both captures and
the visual verdict, and both reviewers' verdicts. Gabe's feedback goes into
project memory and `docs/windows-architecture.md`, so later checkpoints need
less of it.

## Running it

In Claude Code, in this repo: `/helix` (the skill in `.claude/skills/helix`)
runs the next approved checkpoint through the gates. `/helix plan SCREEN`
proposes checkpoints for a screen.

Where each gate runs:

| gate | where |
|---|---|
| behaviour | anywhere (the model and its tests are standard C++); the full app compiles off Windows with MinGW (`windows/cmake/mingw-w64.cmake`) and for real on Windows CI with MSVC |
| UI match | Gabe's Mac for the reference; Kite for Windows captures on Windows CI (or any Windows machine) |
| adversarial review | anywhere |
| Gabe | the PR |
