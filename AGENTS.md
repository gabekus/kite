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
Accessibility (SwiftUI elements in `tree`) and Screen Recording (`capture`)
permission, which a test build inherits from the app that launched it. Clicks on
views that don't accept first mouse (the resize handle) are dropped while Kite is
in the background; `input` says so. See docs/automation.md for what else works in
the background.

For Arc, `kite probe Arc tree` gives the accessibility tree in the same window
points (roles and frames; text stays hidden unless `--text`, which is Gabe's
data), and `kite probe Arc capture --window N -o arc.png` captures one window
in the background. Use an Arc incognito window, and close it when done. These
need Accessibility and Screen Recording permission for the app running `kite`.

Fall back to screen recording or computer control only for what these can't
see (Arc's cursors and hover, system UI outside Kite), and say why in the PR.
