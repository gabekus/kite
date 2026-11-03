# W9b2 space icons — Windows measurements (2ed8df4)

Captures: `Kite.exe --capture X.png --window-size 1280,820 --capture-scale 2` (2560x1640), Release build, each in a fresh temp profile. Measured in the 2x PNGs; pt = px / 2. Bar points are measured from the bar's top (the window's bottom 50 pt). "Ink" means pixels that differ from the background next to them by more than 40 levels (30 for the placeholder, 20 for pictures).

| Capture | State |
|---|---|
| a1-sidebar | sidebar.json (Personal selected, dark) |
| a2-two-spaces-work | two-spaces.json as is (Work selected, light) |
| b-two-spaces-personal | two-spaces.json with Personal selected (dark) |
| c1-picture-personal / c2-picture-work | Personal's icon `image:test.png`, SpaceIcons\test.png present (128x128 generated red/green/blue/yellow quadrants) |
| d1-missing-personal / d2-missing-work | the same, with SpaceIcons\test.png missing |

## Briefcase (Fluent E821)

| | Windows | Mac |
|---|---|---|
| Bar ink, lit (a2) | 30 x 28 px = 15 x 14 pt | 15 x 12.5 pt |
| Bar ink, greyed (a1, b) | 30 x 28 px = 15 x 14 pt | 15 x 12.5 pt |
| Bar ink centre | (137, 25) bar pt | (136.75, 25) |
| Lit colour, Work light | 215,75,134 (169 px solid) on 236,180,166 | 215,75,134 |
| Greyed colour, dark | 128,128,128 (126 px) / 129,129,129 (43 px) on 24,24,24 | 131,131,130 on 30,30,28 |
| Header ink, lit (a2) | 36 x 34 px = 18 x 17 pt, centre x 26 pt (box 13–39) | — |

## Picture (test.png)

| | Bar | Header |
|---|---|---|
| Side | 30 x 30 px (expected 30) | 36 x 36 px (expected 36) |
| Centre | (103, 25) bar pt (cell 85 + 18) | x 26 pt (13 + 13) |
| Corner, rows from the top | 24 26 28 30 … of 30 | 28 30 32 34 36 … of 36 |
| Lit quadrants (c1) | 255,0,0 / 0,255,0 / 0,0,255 / 255,255,0, exact | the same |

Greyed in the bar (c2, light): the quadrants read 153,123,114 / 214,183,174 / 143,111,102 / 239,209,200 over 236,181,164. Solving obs = 0.55·bg + 0.45·grey for each channel gives R/G/B greys of:
- red → 52/52/53
- green → 187/185/186
- blue → 29/25/26
- yellow → 243/243/244

The three channels agree within ±4, so the picture is colourless at 45 %. The greys follow luminance: red 52, green 187, blue 27, yellow 243.

## Missing picture (placeholder "photo")

| | Bar | Header |
|---|---|---|
| Ink | 24 x 24 px = 12 x 12 pt (0.8 of the 15 pt picture) | 30 x 30 px = 15 x 15 pt (0.8 of 18) |
| Centre | (103, 25) bar pt | x 26 pt |
| Colour, selected, dark (d1) | 151,151,151 on 24,24,24 | 153,153,153 on 29,29,29 |
| Colour, greyed, light (d2) | 181,138,127 on 236,181,164 | (Work's header shows the briefcase) |

## Differences from the Mac

- The briefcase inks 14 pt tall against the Mac's 12.5. The width matches at 15 pt, and so does the centre (0.25 pt off in x).
- The dark bar background is 24,24,24 where the Mac reference has 30,30,28. The greyed briefcase is 128–129 against the Mac's 131,131,130.
