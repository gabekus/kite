# W9c Windows captures (fff59eb)

All captures come from the Release build at fff59eb (plain /WX). Each is `Kite.exe --capture X.png --window-size 1280,820 --capture-scale 2` in a fresh temp profile, with `windows/helix/states/two-spaces.json` as the session.

| File | State |
|---|---|
| swipe-next-120.png | Personal selected, `--swipe -120` |
| swipe-past-end-100.png | Work selected (the last space), `--swipe -100` |
| rest.png | Personal selected, no swipe |
| rest-work.png | Work selected, no swipe (reference for the offsets) |

## Measurements (2x px; the sidebar is 480 px wide)

- **swipe-next-120:**
  - Personal's page left edge is at **-240 px** (−120 pt). The selected tab pill's right end is at 463 px at rest and 223 px here.
  - Work's page left edge is at **+240 px** (+120 pt). Work's header icon ink starts at 34 px at rest and 274 px here.
- **swipe-past-end-100:** the Work page sits at **−89 px (−44.5 pt)**, measured from the right ends of "Old pinned" and "New Tab" (221→132 and 189→100 px). The address field doesn't move.
- **Bar cells** (sampled from the 2x captures):

| | Cell 1 (🏠) mean chroma / centre px | Cell 2 (drawn briefcase) strongest stroke |
|---|---|---|
| rest (Personal) | 66.1 / #E0A67B | #181818 (greyed, chroma 0 on the dark backdrop) |
| swipe-next-120 | 49.9 / #A37D66 | #A95974 (chroma 80) |
| Work selected | 53.3 / #D4B5AC (greyed over the light backdrop) | #D74B86 (chroma 140) |

The light is split mid-swipe: the briefcase stroke sits between greyed and lit, and the house is partly desaturated.
