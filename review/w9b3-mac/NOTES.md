# W9b3 Mac reference: the space name tip

Kite for Mac, main at f3c3d92, a `KITE_DIAGNOSTICS=1` debug build in the background. Its setup:
- `defaults delete dev.gabek.Kite.dev SidebarWidth` (nothing was set).
- A fresh `mktemp -d /tmp/k.XXXX` profile with `windows/helix/states/sidebar.json` as session.json.
- `KITE_WINDOW_SIZE=1280,820` at 2×.

Each cell was hovered with `kite ui pointer` at the cell's centre (Personal 143,795; Work 177,795), waiting 0.9 s.

## Files

- `tip-Personal.png`, `tip-Work.png`: the tip alone, at 2× (416×56 and 372×56 px).
  - They're cropped from `kite ui capture` of the main window at the panel's exact frame. That capture composites the child panel.
  - The corners show the window behind it, `#1F1F1D`.
- `tip-*-context.png`: the same, 12 pt wider each side and down to the space bar, so the cell and its hover fill are in view.
- `fade-*.txt`: the panel's alpha from `CGWindowListCopyWindowInfo`, sampled about every 6–10 ms. Time is from just before the hover.

## Frames (points)

| | Panel in the window (from its top-left) | Hovered cell (in the window) | Panel relative to the cell |
|---|---|---|---|
| Personal | x 39, y 748, 208 × 28 | x 125, y 778, 36 × 34 | centred (both mid-x 143); bottom 2 pt above the cell's top (776 vs 778) |
| Work | x 84, y 748, 186 × 28 | x 159, y 778, 36 × 34 | centred (mid-x 177); bottom 2 pt above the cell's top |

On screen the window was at 388,161 and the panels at 427,909 and 472,909.

## Fade-in

- **Delay:** 0.4 s after the hover (`ArcMetrics.spaceTipDelay`).
- **Duration:** 0.15 s (`NSAnimationContext` on the panel's `alphaValue`).
- **Curve:** I fitted the samples against Bézier curves, with the start time free and durations of 120–180 ms. Core Animation's **default** curve, (0.25, 0.1, 0.25, 1.0), fits best by an order of magnitude:

| Curve | Sum of squared error, Personal | Work |
|---|---|---|
| default (0.25, 0.1, 0.25, 1) at 150 ms | **0.0010** | **0.0017** |
| easeInEaseOut (0.42, 0, 0.58, 1) | 0.0122 | 0.0114 |
| easeOut (0, 0, 0.58, 1) | 0.0119 | 0.0134 |
| linear | 0.0433 | 0.0452 |

So the fade is eased, not linear. It's the default timing (fast start, long settle), not easeInEaseOut. Hiding is instant (`orderOut`, no fade).

## Colours (sRGB, from the 2× captures, row 6 pt from the top)

| | Personal (grey theme) | Work (red theme) |
|---|---|---|
| Pill fill | `#1C1C1C` | `#620028` |
| Border (1 pt, white 15% over the fill) | `#3E3E3E` | `#7A2C49` |
| Profile chip "Default" (white 90%) | `#E8E8E8` | `#F0E6EA` |
| Keycap "⌃" / number (white 85%) | `#DDDDDD` | `#E8DBDF` |
| Chip and keycap text and icon | the space's accent | the space's accent |

The pill's left and right ends are full semicircles (a Capsule, height 28). Keycaps are 18 × 18 with a 4 pt continuous corner. The chip is 21 tall.
