# W9b3 Windows check, UI gate round 2 (c770c94)

Builds: MSVC /WX, Debug and Release, 0 warnings. KiteCoreTests reports 214 tests, 0 failed. ctest passes 2/2. Smoke is 4/4 in each config.

## Captures (sidebar.json, 1280x820 at 2x)

Each frame is the bounding box of the pixels that differ from the plain capture.

| | Frame (pt) | Centre vs cell | Gap | af239aa | Mac |
|---|---|---|---|---|---|
| Personal (`--space-tip 1`) | x 0, y 748, 208.5 x 28 | 104.25 vs 103 | 2 pt | 207.5 | 208 |
| Work (`--space-tip 2`) | x 41.5, y 748, 191.5 x 28 | 137.25 vs 137 | 2 pt | 189.5 | 186 |

Colours on the row 6 pt from the top are unchanged:
- Personal: fill #1C1C1C, border #3E3E3E, chip #E8E8E8, keycap #DDDDDD. All four equal the Mac's.
- Work: fill #620028, border #7A2648 (Mac #7A2C49), chip #EFE5E9 (Mac #F0E6EA), keycap #E7D9DF (Mac #E8DBDF).

The bold "Default" makes the chip 138 px wide (134 at af239aa).

kitecore `sidebar` gives cell 2's tip as `{"accent":"#D74B86","fill":"#620028","height":28,"keys":["Alt","2"],"name":"Work","profile":"Default","top":-22}`. A top of −22 from the bar's top (770) puts it at y 748.

## Live (`live-*.png`)

The session renames space 2 to "Work" followed by U+1F4BC. The window was 1280x820 at 100 %.

- **Draws, with its fade:** WS_VISIBLE 406 ms after the hover, first pixel change at 416 ms. The fade alpha is 0.06, 0.15, 0.30, 0.44, 0.57, 0.69, 0.76, 0.87, 0.93, 0.96, 0.98, 1.00 at 0, 10, 20, 30, 40, 50, 60, 75, 90, 105, 120 and 150 ms: eased, about 0.8 at 64 ms.
- **Rect:** 213 x 28 at client (31, 748). It is wider because of the emoji name.
- **Styles:** ex 0x082800A0 (LAYERED, TRANSPARENT, NOREDIRECTIONBITMAP, TOOLWINDOW, NOACTIVATE; not topmost). GetLayeredWindowAttributes gives alpha 255, flags LWA_ALPHA.
- **Pointer over the tip's area:** WindowFromPoint returns KiteBrowserWindow, not the tip.
- **Under another window:** a plain green window of mine covered client x 0–420, y 700–776, with Kite in the background. After hovering cell 2, the tip is visible (431 ms) at the same rect, but the tip's area shows 5040 green pixels and 0 tip-fill pixels (`live-occluded.png`). It is not drawn over the other window. In the z-order the window directly below the tip is Kite (indexes 50 and 51).
- **Emoji:** drawn in colour, a brown case with an orange clasp (`live-tip2-front-6x.png`). It looks dimmed, though: its browns (#764956 to #7D4F59) are blended toward the #620028 fill, roughly half opacity, while "Work" is full white.
- **Exit:** WM_CLOSE gives exit 0 in 137 ms; stderr is empty.
