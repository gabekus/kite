# Notes for agents working on Kite

## Matching Arc

Kite copies Arc 1:1 for now (layout, spacing, sizes, motion and behaviour), and
gets trimmed from there later. Never build Arc behaviour from memory or a guess
about what Arc does. Look at it first.

Before building:
- Record Arc doing the thing, and go through the frames.
- Measure geometry from Arc's accessibility tree (frames and roles only).
- Check the mechanism in Arc's binary. Decompiled output lives outside this
  repo, under `~/rea-arc` on the dev Mac.
- Write down what you observed and where it came from (see
  `docs/arc-visual-spec.md`).

After building:
- Verify Kite's real behaviour the same way, with a recording or a debug log.
  A clean build or green CI doesn't prove behaviour.
- In the PR, say what the evidence was and flag anything that's still
  unverified.

Recordings, screenshots and the accessibility tree don't show the pointer or
cursor zones. Anything that depends on hover (cursors, resize zones, hover
states, tooltips, hover reveals) needs a pointer sweep on both Arc and Kite:
move the pointer in small steps and read the system cursor or state at each.

Never commit Arc's code, shaders or assets. Kite is open source: record only
measured numbers, and reimplement from them.

## Testing on the Mac

Launch test builds with `KITE_SUPPORT_PATH` set to a fresh empty directory
(`mktemp -d`), never a real profile. Check the path is a directory first: if it
isn't, Chromium silently falls back to the user's own Chromium profile.
