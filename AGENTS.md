# Notes for agents working on Kite

## Matching Arc

Kite copies Arc 1:1 for now (layout, spacing, sizes, motion and behaviour), and
gets trimmed from there later. Never build Arc behaviour from memory or a guess
about what Arc does. Look at it first.

Before building:
- Record Arc doing the thing, and go through the frames.
- Measure geometry from Arc's accessibility tree (frames and roles only):
  `kite probe Arc tree` (see "Reading Kite and Arc without the screen" below).
- Check the mechanism in Arc's binary. Decompiled output lives outside this
  repo, under `~/rea-arc` on the dev Mac.
- Write down what you observed and where it came from (see
  `docs/arc-visual-spec.md`).

After building:
- Verify Kite's real behaviour with the `ui` tool (tree, capture, pointer,
  trace) or a debug log. A clean build or green CI doesn't prove behaviour.
- In the PR, say what the evidence was and flag anything that's still
  unverified.

Recordings, screenshots and the accessibility tree don't show the pointer or
cursor zones. Anything that depends on hover (cursors, resize zones, hover
states, tooltips, hover reveals) needs a pointer sweep on both Arc and Kite.
On Kite that's `kite ui pointer` (synthetic, no real pointer). On Arc it's
still a real-pointer sweep with `~/rea-arc/tools/cursorprobe`, only while
Gabe says it's OK to use his Mac.

Never commit Arc's code, shaders or assets. Kite is open source: record only
measured numbers, and reimplement from them.

## Testing on the Mac

Launch test builds with `KITE_SUPPORT_PATH` set to a fresh empty directory
(`mktemp -d`), never a real profile. Check the path is a directory first: if it
isn't, Chromium silently falls back to the user's own Chromium profile.

Use `mktemp -d /tmp/k.XXXX`: the automation socket lives in the profile, and
socket paths are limited to 104 bytes.

Only the installed Kite (`dev.gabek.Kite` at /Applications/Kite.app) may open the
real profile: any other build started without `KITE_SUPPORT_PATH` (or with it
pointing at the real profile) exits at once with a `Kite: refusing to start …`
line (`RealProfileGuard`). A script that launches Kite sources
`scripts/lib/test-kite.sh`, makes its profile with `kite_test_profile` and calls
`kite_check_test_launch "$APP" "$P"` right before the launch;
`scripts/check-launch-guards.sh` (in CI) fails any script that doesn't.

If Kite's tools look wrong (old tools, empty carts, the WebKit engine), run
`kite server`: it names the PID, app and start time of whatever serves the
automation socket, and `kite` and `kite mcp` warn whenever that isn't
/Applications/Kite.app.

`KITE_SUPPORT_PATH` doesn't cover UserDefaults: those follow the bundle ID. Test
with `scripts/bundle-app.sh debug`, whose bundle is `dev.gabek.Kite.dev`, never a
`dev.gabek.Kite` bundle (release builds, /Applications/Kite.app), which would
change the installed Kite's settings. `scripts/check-test-defaults.sh` checks it.

Connect Claude and Set Up Claude leave Gabe's Claude setup alone on a test
profile or a worktree build (`ClaudeSetupGuard`): otherwise they point Claude at
a build that gets deleted and his `kite` server stops connecting. To test those
steps, redirect them with `KITE_CLAUDE_BIN` (a fake `claude`),
`KITE_CLAUDE_DESKTOP_CONFIG` and `KITE_BIN_DIR`.

## Reading Kite and Arc without the screen

Don't switch apps, record the screen or drive Gabe's mouse and keyboard to see
what Kite does. Kite reports on its own interface through the `ui` tool on its
local bridge (MCP `ui`, or `kite ui ACTION '{json}'`). It never focuses Kite,
moves the real pointer or touches other apps, and it works while Kite is in the
background or covered.

Launch a test build ready for it:

```bash
P=$(mktemp -d /tmp/k.XXXX)
KITE_SUPPORT_PATH=$P KITE_DIAGNOSTICS=1 .build/debug/Kite &
export KITE_SUPPORT_PATH=$P   # so the CLI finds the same socket
.build/debug/kite-cli ui windows
```

In a dev build the CLI is `.build/debug/kite-cli`; in Kite.app it's
`Contents/Helpers/kite`. The examples below call it `kite`.

`KITE_DIAGNOSTICS=1` only counts with `KITE_SUPPORT_PATH`. On a real profile
Gabe turns on Kite menu → Diagnostics for Claude (with Claude's control on).

| To check | Use |
|---|---|
| Geometry, materials, corner radii, colours, fonts, hidden state | `kite ui tree '{"match":"Sidebar"}'`, then `{"root":"0.3"}` for a subtree; `"layers":true` for Core Animation layers |
| Exact pixels and colours (blur, Metal and web content included) | `kite ui capture '{"region":[0,0,240,120]}' -o crop.png`, or `{"pixels":[[12,40]]}` for sRGB hex only |
| Cursors, resize zones, hover areas | `kite ui pointer '{"from":[230,300],"to":[250,300],"steps":20}'` |
| Shortcuts and key routing | `kite ui menu` (flags shortcuts that fire while typing, and conflicts), `kite ui input '{"keys":"cmd+s"}'`, `kite ui key_log` |
| Animations and frame timing | `kite ui trace '{"keys":"cmd+s","seconds":1}'`: every animation's duration and curve, sampled frames with progress, late frames |
| Clicks and drags in Kite's chrome | `kite ui input '{"click":[120,60]}'`, `{"from":[…],"to":[…]}` |

Points are window points from the window's top-left corner, the same in every
action and in `kite probe`. Web page content is read with the page tools
(`read_page`, `screenshot`), not `ui`.

A `KITE_DIAGNOSTICS=1` run opens behind other windows and never activates. It needs
Accessibility (SwiftUI elements in `tree`), which a test build inherits from the app
that launched it. `capture` uses Screen Recording the same way when it's granted, and
otherwise draws the window in-process (`--in-process`; blurred materials come out
unblurred, and it lists where they are). Clicks on
views that don't accept first mouse (the resize handle) are dropped while Kite is
in the background; `input` says so. See docs/automation.md for what else works in
the background.

For Arc, `kite probe Arc tree` gives the accessibility tree in the same window
points (roles and frames; text, accessibility identifiers and other attributes
stay hidden unless `--text`, which is Gabe's data: Arc puts tab titles in its
identifiers), and `kite probe Arc capture --window N -o arc.png` captures one window
in the background. Use an Arc incognito window, and close it when done. These
need Accessibility and Screen Recording permission for the app running `kite`.

Observe Arc headlessly, always (Gabe's standing rule, 3 Nov 2026): never take
over his screen, focus or input to watch Arc. Open an incognito window through
an AX menu press and park it off screen, send keys only to Arc's process
(`CGEvent.postToPid`), read results from its accessibility tree, and if Arc
takes focus (opening the command bar does), hand it straight back to the app
that was in front. Favorites only exist in regular windows: compare their
titles in-process and print positions and labels, never titles.

Fall back to screen recording or computer control only for what these can't
see (Arc's cursors and hover, system UI outside Kite), only with Gabe's OK at
the time, and say why in the PR.

## CI

Before pushing Swift changes, build locally: the repo's pre-push hook runs
`swift build --build-tests` (incremental, usually seconds). Enable it once per
clone, which covers its worktrees: `git config core.hooksPath .githooks`.

CI (`.github/workflows/ci.yml` for macOS, `ci-windows.yml`) restores the `.build` cache saved by the
latest main run, and `scripts/ci-restore-mtimes.sh` makes that build
incremental, so a PR recompiles only what it changed. Docs-only changes skip
the macOS job, and Windows runs only when KiteCore, Tests or Package.swift
change. The macOS runner label comes from the `MACOS_RUNNER` repo variable
(default `macos-15`), and Windows from `WINDOWS_RUNNER`; fork PRs always use GitHub's runners.
