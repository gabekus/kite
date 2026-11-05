# W9e/W9f UI gate, review round 1: Windows captures at 53d0772c

These are the same five states and flags as `../305c916/`: 1280×820 at 2×, three-spaces.json. They are measured against review/w9e-mac and review/w9f-mac.

`crops/` shows each pair as Windows at 65d0f65 (the reviewed head), Windows now, and the Mac.

The Icon tab and bar glyphs were measured with the reviewer's `ink.py` at threshold 30, on the same cells. Remove a stale `.png.raw` cache before measuring.

| item | Mac | 65d0f65 | now |
|---|---|---|---|
| Icon tab, 28 glyphs (cols 5–8): area ratio | 1 | 0.47–2.21, mean 1.17, **19/28 off >15%**, box mean 1.17 | 0.78–1.07, mean 0.97, **1/28 off** (square.on.square.fill 0.78), box 0.92–1.01 |
| "Space name…" placeholder, create-empty (+levels) | +50 | +89 (regression) | +53 |
| Typed name, create-filled (peak contrast) | 233.9 | 206.2 | 240.7 (textColor black) |
| Swatch popover fill | the picker's grey (in-process 75) | (21,28,48) navy | (44,44,46), the picker's |
| Search field fill / line / bottom, over the popover | +13 / +32 / +62 on 75 | darker well 30 on 44 | +15 / +38 / +72 on 44 (same alphas) |
| Tabs track | +13, 1px lines | flat 0.10, no lines | the field's bezel |
| Knob | 20pt, 1pt in, 0.41, top highlight | 18pt, 2pt in, 0.30 | 20pt, 1pt in, 0.41, highlight |
| Divider | +35 on 75 (0.19) | 0.10 | +40 on 44 (0.19) |
| Car (category bar) | 16.5×13, area 103 | 15×14, area 72 | 15×14, area 104 |
| Bin | 13.5×15.5, area 92, weight 45.9 | 14×15, area 76.5, weight 37.8 | 14×15, area 95, weight 52.8 (≈45 at the Mac's contrast) |
| Label weight (title / subtitle / Profile / Choose a Theme / Cancel), dark | 1 | 0.84 / 0.75 / 0.80 / 0.76 / 0.70 | 0.84 / 0.91 / 1.02 / 0.95 / 0.90 |
| Label width (same) | 1 | 0.95 / 0.95 / 0.96 / 0.95 / 0.90 | 0.95 / 0.98 / 1.01 / 0.97 / 0.93 |

## What closed the text-weight gap

DirectWrite's grayscale enhanced contrast was tried at 1–6. It does nothing for light text on dark, and it adds under 5% for dark on light. Area is unchanged. It isn't used.

Segoe UI Variable's weight axis was raised instead: Regular 400→550, Medium 500→650, Semibold 600→700. That brings weight to 0.90–1.02 and widths within 1–7%. The title's Bold is already the axis maximum, so it stays at 0.84.

## Accepted as they are

- Grid emoji sit 0.3–0.7pt low.
- The focused name field sits 1pt low.
- In a dark space the Mac's capture draws Profile's face filled; Windows keeps the outline. This is a Mac-side question for Gabe.
