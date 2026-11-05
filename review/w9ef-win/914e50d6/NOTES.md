# W9e/W9f UI gate, review round 2: Windows captures at 914e50d6

Same states, flags and measurement as `../53d0772c/`: the reviewer's `ink.py` at threshold 30, with each `.raw` cache cleared first. `crops/` sets Windows at 53d0772c, Windows now and the Mac side by side.

| item | Mac | 65d0f65 | 53d0772c | now |
|---|---|---|---|---|
| Icon tab, 28 measured (cols 5–8): any side off >15% | – | 21/28 | 2/28 (book 27%, cylinder 25%) | **0/28** (worst: moon 13%, bolt 11%) |
| Icon tab: area off >15% | – | 19/28 | 1/28 | 2/28 (square.on.square.fill 0.78, book.fill 0.84: outline stand-ins, stroke capped at 2pt) |
| book.fill box | 19×15 | 22×16 | 14.5×19 (closed, portrait) | 17.5×16 (open, E736) |
| cylinder.split.1x2.fill | 14×17 | – | 17.5×13.5 | 14×16.5 (Kite's shape) |
| scroll.fill | 17.5×17 | – | 15.5×19.5 | 17.5×17 (Kite's shape) |
| tram.fill | 14.5×20.5 | – | 16×18 | 14.5×20 (Kite's shape) |
| code sign | 23×15.5 | – | 20×17.5 | 23×15.5 (Kite's shape) |
| Cols 1–4 `.fill` outlines (archivebox, envelope, person.2, globe, leaf, cloud, map, flame…) | not in the Mac's capture | outline | outline | stroked to 0.677 of the box (unverified) |
| cloud.fill vs cloud | differ | identical | identical | stroked vs plain |
| Car weight (bar) | 33.2 | 25.2 | 45.6 | 34.6 |
| Bin weight | 45.9 | 37.8 | 52.8 | 45.1 |
| Page label weight (title / subtitle / Profile / Choose a Theme / Cancel) | 1 | 0.84 / 0.75 / 0.80 / 0.76 / 0.70 | 0.84 / 0.91 / 1.02 / 0.95 / 0.90 | 0.84 / 0.75 / 0.80 / 0.76 / 0.70 (weight axis reverted; Kite-wide checkpoint) |

## No Mac reference for columns 1–4 yet

The Mac's picker hangs centred under the header icon. That puts it about 147pt past the window's left edge, so the in-process capture (the window's own frame) cuts columns 1–4 off.

`window_size` can't help. The window is centred at its default size and then `setContentSize` keeps the origin, so a bigger window grows to the right while the popover stays outside the left edge.

Seeing those columns would need a change: move the test window to the screen's left edge, have Kite keep the popover inside its window on a test run, or have the capture draw past the window's frame. Each of those widens what a test run does, so it needs the safety review first.
