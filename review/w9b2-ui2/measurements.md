# W9b2 round 2 (b657107) — Windows checks

Builds: MSVC /WX, Debug and Release, 0 warnings. KiteCoreTests reports 203 tests, 0 failed, in both. ctest passes 2/2 in both. Smoke is 4/4 in both.

Captures: `--capture --window-size 1280,820 --capture-scale 2`, Release, one fresh temp profile each. Measured in the 2x PNGs (pt = px / 2; bar pt measured from the bar's top). `measure-raw.txt` has every line.

| Check | Round 1 (2ed8df4) | Round 2 (b657107) |
|---|---|---|
| Bar briefcase ink (a2) | 30 x 28 px, centre (137, 25) | 30 x 28 px, centre (137, 25) |
| Lit briefcase colour | 215,75,134 | 215,75,134 (169 px) |
| Header briefcase ink | 36 x 34 px | 36 x 34 px |
| Picture, bar / header (c1) | 30 / 36 px | 30 / 36 px, centres (103, 25) / x 26 |
| Lit quadrants | exact | 255,0,0 / 0,255,0 / 0,0,255 / 255,255,0, exact |
| Greyed picture (c2), grey implied at 45 % | 52/52/53, 187/185/186, 29/25/26, 243/243/244 | identical: colourless |
| Placeholder, bar / header (d1) | 24 / 30 px | 24 / 30 px, 151 / 153 grey on the dark theme |

## Extra cases

- **`image:CON.png`** (e1 Personal selected, e2 Work selected). The quadrant PNG was saved as `SpaceIcons\CON.png` with `cmd /c copy` to a `\\?\` path, because PowerShell's Copy-Item refuses reserved device names even with `\\?\`. A directory listing confirmed the file was there.
  - The captures exited 0 in 229 ms and 356 ms: no hang.
  - The picture draws exactly as test.png does: bar 30 px and header 36 px with exact quadrants (e1); greyed it is colourless at 45 % (e2, identical numbers to c2).
  - `CON.png` was deleted afterwards with `cmd /c del` on the `\\?\` path, and the folder listed empty.
- **`symbol:hare.fill`** (f1, f2). kitecore reports `"shows":"dot"`.
  - The bar shows the dot: 16 x 16 px = 8 pt, centre (103, 25). White when selected on dark (f1); greyed 180,138,126 on light (f2).
  - The header has no icon slot: "Personal" starts at x 14 pt (px 28), where it starts at x 41 pt after an icon (see con-hare-zoom.png).
