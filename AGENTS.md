# Kite: notes for agents

## Copy Arc from evidence, never from inference

Kite recreates Arc. Before building or changing anything that copies Arc's look or behaviour, find out what Arc
actually does, and say how you know:

- **Watch it:** a screen recording or screenshots of an Arc test window (never Gabe's own windows, titles or URLs).
- **Measure it:** frames, roles and visibility through the Accessibility API.
- **Read it:** Arc's binary, with Ghidra or otool. That work and its output stay in `~/rea-arc`, and no Arc code,
  shader or asset is ever copied into this repo; only numbers and behaviour are written down.

A line marked "Inferred" in `~/rea-arc/arc-findings.md`, or anything that only sounds plausible, is not evidence.
Check it first. If you can't get evidence, say so rather than filling the gap.

Each Arc-parity PR says what its evidence was (a recording, AX frames, or binary function addresses). Numbers go in
`docs/arc-visual-spec.md`, marked as observed or as read from the binary.

Why (Gabe, 2026-10-23): the traffic lights moved into the sidebar on the strength of an inference that Arc
repositions the window's own buttons, and they then stayed visible with the sidebar hidden. Arc's binary shows it
does something else: it hides the window's real buttons and draws its own.
