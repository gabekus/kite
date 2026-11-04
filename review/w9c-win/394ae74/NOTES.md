# W9c Windows captures (394ae74, review round 3)

All four captures come from the Release build at 394ae74 (MSVC `/W4 /WX`, 0 warnings). Each one is `Kite.exe --capture X.png --window-size 1280,820 --capture-scale 2` on a fresh temp profile, with `windows/helix/states/two-spaces.json` as `session.json`. For the Personal captures, `selectedSpaceID` is switched to Personal, and the file is read and written as UTF-8 so the 🏠 icon survives.

| File | State |
|---|---|
| rest.png | Personal selected, no swipe |
| swipe-next-120.png | Personal selected, `--swipe -120` |
| swipe-past-end-100.png | Work selected (the last space), `--swipe -100` |
| rest-work.png | Work selected, no swipe (the reference for the offsets) |

All four are pixel-identical to the 5484e2b captures. This round changed nothing a held swipe draws: the touchpad input, the clock's boost, the release's commit, the tests and the docs.

## Measurements (2x px; the sidebar is 480 px wide)

- **swipe-next-120:**
  - Personal's page is at **−240 px (−120 pt)**. The selected tab pill's right end is at 462 px at rest and 222 px here.
  - Work's page is at **+240 px (+120 pt)**. Work's header icon ink starts at 34 px in rest-work and at 274 px here.
  - The Mac's are −112 / +128 pt.
- **swipe-past-end-100:** the Work page is at **−89 px (−44.5 pt)**. The right ends of "Old pinned" go from 221 to 132 px and of "New Tab" from 179 to 90 px, against rest-work. The Mac's is 44.75 pt. The address field doesn't move.

The pages are 240 pt apart on both. Windows' pages sit 8 pt further on than the Mac's for the same 120 pt, which is unchanged from the earlier rounds.
