# W9b2 round 4 (7ee2e1d) — Windows checks

Builds: MSVC /WX, Debug and Release, 0 warnings. KiteCoreTests reports 209 tests, 0 failed. ctest passes 2/2 in both. Smoke is 4/4 in both.

## Captures (`--capture`, 1280x820 at 2x): identical to round 3

| | Result |
|---|---|
| a2 bar briefcase (lit) | 30 x 28 px, centre (137, 25) bar pt, 215,75,134 |
| b bar briefcase (greyed, dark) | 30 x 28 px, 128–129 grey on 24,24,24 |
| a2 header briefcase | 36 x 34 px, centre x 26 pt |
| c1 picture | bar 30 px, header 36 px, quadrants exact |
| c2 picture greyed | implied greys at 45 %: 52/52/53, 187/185/186, 29/25/26, 243/243/244 (colourless) |
| d1 placeholder | bar 24 px (151), header 30 px (153) |
| g1 3000 px PNG | placeholder, identical to d1; exit 0 in 183 ms |
| f1 `symbol:hare.fill` | bar dot 16 px; header blank slot (kitecore `"shows":"blank"`), name ink from 42 pt |
| h1 `"icon": ""` (icon-less) | bar dot; header has no slot (kitecore `"shows":"none"`), name ink from 14 pt |

A session with the `icon` key removed entirely is rejected at launch: exit 4, "couldn't read the session: not a Kite session". So h1 uses an empty icon string.

## Live (worker path; normal launch, test window in front)

- **(a) PASS.** `image:missing.png` shows the placeholder at +2 s.
  - Over 10 s of hovering the bar's cells (202 moves 40 ms apart, 202 samples), the placeholder was present in every sample: always 54 grey pixels, never 0.
  - CPU afterwards: main process 0 ms in 5 s.
- **(b) FAIL.** After copying a valid 128 px PNG to `SpaceIcons\missing.png`, the picture did not appear on hover redraws.
  - Hovering demonstrably redraws the bar: cell 2's backing ring goes from luma 43.4 to 60.2.
  - 29 hover in/out cycles over 15 s: still the placeholder (first run: 5 s plus 10 more hovers, same result).
  - It appears only after a selection change (Ctrl+Shift+S to Work and back) or a relaunch.
  - CPU stays idle: 16 ms in 5 s.
- **(c) PASS.**
  - A valid picture is drawn 4 ms after the window appears (worker decode).
  - It survives deleting the file plus 5 hover redraws.
  - A 3000 px PNG gives the placeholder at +3 s and after 5 hover redraws, with 47 ms CPU in 5 s idle.
  - Every run closed cleanly with WM_CLOSE (exit 0, about 140–164 ms), stderr empty.
