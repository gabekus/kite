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
   - Windows (a monitor at 200% scale): `Kite.exe --capture out.png
     --window-size W,H --capture-scale 2` with `KITE_SUPPORT_PATH` set the same
     way. `--capture-scale` fails the run if the monitor isn't at 200%, so the
     pixels line up with the Mac's.
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
| UI match | Gabe's Mac for the reference, a Windows machine at 200% for Kite for Windows |
| adversarial review | anywhere |
| Gabe | the PR |
