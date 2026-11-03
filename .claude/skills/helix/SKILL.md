---
name: helix
description: Build Kite for Windows from Kite for Mac one checkpoint at a time, through test, UI-match, adversarial-review and approval gates. Use for /helix, "next checkpoint", or planning Windows work.
---

# Helix: Kite for Windows, checkpoint by checkpoint

Read docs/helix.md (the process) and docs/windows-architecture.md (the rules)
first. Kite for Mac is the only reference; never use Arc for Windows.

## Arguments

- none: run the first `approved` checkpoint in windows/helix/checkpoints.md
  (or the first `planned` one if Gabe said to run autonomously).
- `plan SCREEN`: read the Mac code for SCREEN and propose 3–8 ordered
  checkpoints (skeleton first), each with a one-line description and the Mac
  files it ports. Add them to checkpoints.md as `planned` and stop.
- `W<n>`: run that checkpoint.

## Running a checkpoint

1. Mark it `in progress`. Branch `helix/W<n>-<slug>` from main.
2. Read the Mac sources it names and their tests. The reference is the spec:
   don't write a separate spec.
3. **Behaviour gate.** Port the Mac tests case for case into windows/tests
   (name the Swift test each one comes from), add the edge cases the Mac
   misses, and expose anything visible through `kitecore`. Implement until
   `ctest` passes. The model and its tests build anywhere:
   `cmake -S windows -B /tmp/kite-core && cmake --build /tmp/kite-core -j && ctest --test-dir /tmp/kite-core --output-on-failure`.
   Off Windows, also cross-compile the app with MinGW (`apt install g++-mingw-w64-x86-64`):
   `cmake -S windows -B /tmp/kite-mingw -DCMAKE_TOOLCHAIN_FILE="$PWD/windows/cmake/mingw-w64.cmake" && cmake --build /tmp/kite-mingw -j`.
   Windows CI then builds with MSVC `/W4 /WX`, runs ctest and launches Kite.exe.
4. **UI gate** (skip for logic-only checkpoints). Put the same session in both
   apps from windows/helix/states/ (copy it to `<profile>/session.json`), at the
   same window size in points and the same 2× scale:
   - Mac: `defaults delete dev.gabek.Kite.dev SidebarWidth`, then a test build
     with `KITE_DIAGNOSTICS=1 KITE_SUPPORT_PATH=$P KITE_WINDOW_SIZE=1280,820`
     (fresh `mktemp -d /tmp/k.XXXX` profile, per AGENTS.md), captured with
     `kite ui capture -o mac.png`.
   - Windows (any monitor; CI uploads one as the `kite-windows-capture` artifact):
     `Kite.exe --capture win.png --window-size 1280,820 --capture-scale 2`
     with `KITE_SUPPORT_PATH` set to a fresh profile holding the same session.
   Then spawn ONE fresh subagent as the visual reviewer.
   Give it only the two image paths, the checkpoint line, and these
   instructions: list every difference within what this checkpoint built, each
   with severity (blocker/major/minor) and location; anything fixable in code is
   a blocker; answer INVALID if the two show different states. Fix and recapture
   until there are no blockers or majors.
5. **Adversarial gate.** Spawn TWO fresh subagents in parallel, each given the
   diff (`git diff main...HEAD`), docs/windows-architecture.md and the Mac
   files ported, but NOT your reasoning or conclusions:
   - Reviewer A: correctness and parity with the Mac. Find behaviour that
     differs, missing edge cases, untested paths.
   - Reviewer B: architecture, layering, performance and code rules.
   Each returns APPROVE or a list of findings with file:line. Fix real findings,
   rerun the tests (and the UI gate if anything visible changed), and ask for
   another review until both approve. Answer findings you reject with the trace.
6. **Gabe gate.** Open a PR with the evidence: tests run, both captures and the
   visual verdict, both reviewers' final verdicts, and the Mac files followed.
   Mark the checkpoint `done (#PR)` once merged. In autonomous mode, continue
   with the next checkpoint on a branch stacked on this one.
7. Save any feedback Gabe gives into project memory and, if it's a rule,
   into docs/windows-architecture.md.

Never mark a gate passed that didn't run. If a gate can't run (no Windows
machine, no Mac), say which, and leave the checkpoint `in progress`.
