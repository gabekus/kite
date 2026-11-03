# W9b2 round 3 (a300ec2) — Windows checks

Builds: MSVC /WX, Debug (54 s) and Release (63 s), 0 warnings. KiteCoreTests reports 204 tests, 0 failed, in both. ctest passes 2/2 in both. Smoke is 4/4 in both.

## Captures (`--capture`, 1280x820, scale 2, fresh profile each)

| Capture | Result |
|---|---|
| c1 Personal `image:test.png` (128 px quadrants) | Bar 30 x 30 px, centre (103, 25) bar pt. Header 36 x 36 px, centre x 26 pt. Quadrants exact (255,0,0 / 0,255,0 / 0,0,255 / 255,255,0). Corner rows 24/26/28/30 and 28/30/32/34/36. Same as rounds 1–2. |
| d1 file missing | Placeholder: bar 24 x 24 px (151 grey), header 30 x 30 px (153 grey) on the dark theme. Same as before. |
| f1 Personal `symbol:hare.fill` | Bar: the dot, 16 x 16 px = 8 pt, white, centre (103, 25). Header: a blank slot (0 ink pixels in x 13–39 pt); the name's first ink is at x 42 pt, the same as c1 and d1. Round 2 started it at 14 pt. |
| g1 3000x3000 PNG as test.png | Placeholder, identical to d1 (24 / 30 px, 151 / 153). Exit 0 in 184 ms: no hang. |

## Live (worker) path

The Release Kite.exe was launched normally, with no flags; KITE_SUPPORT_PATH pointed at a fresh profile holding the c1 state and the 128 px test.png. It opened behind the active window and was never given focus. The window was captured with PrintWindow(PW_RENDERFULLCONTENT) at 1x.

| Step | Bar picture (1x px) | Header picture | Responsive |
|---|---|---|---|
| +2 s | 15 x 15 at x 96–110, y 18–32 of the bar; quadrants exact | quadrants exact | yes |
| test.png deleted, +2 s | unchanged | unchanged | yes |
| pointer over the cell | unchanged | unchanged | yes |
| pointer away | unchanged | unchanged | yes |

The picture stayed after the file was deleted, because it is cached. The window was in the background, so the hover backing did not draw. These shots therefore confirm the cached picture through later composited frames, but not through a forced repaint of the bar. WM_CLOSE: exit 0 in 145 ms, 0 test Kite processes left, stderr empty.
