# W9d Windows captures: the space bar's drag, the space menu, renaming, New Space

Build: Kite for Windows Release (MSVC, CEF 156) from `helix/W9d-space-editing` 3e2b217, on Gabe's PC. Each capture
used a fresh `%TEMP%\kite-w9d-cap-<guid>` profile (`KITE_SUPPORT_PATH`) holding
`windows/helix/states/three-spaces.json` as `session.json` (Personal 🏠 selected, Work with the briefcase symbol,
Reading 📚), except `new-space.png`, whose session is `three-spaces-new-space.json` in this folder (the same after
`kitecore space new Projects`: Projects right after Personal, selected, Personal's theme, no icon).

Every capture: `Kite.exe --capture X.png --window-size 1280,820 --capture-scale 2` (2560×1640), drawn over the solid
material, plus the flags below. Points are window points from the top-left, which for the bar are its own (the
sidebar starts at x 0); the bar is 770–820, the three cells at x 68, 102 and 136 (36 wide, centres 86, 120, 154),
y 778–812.

| file | flags | what it holds |
|---|---|---|
| rest.png | none | the three spaces at rest, Personal lit |
| drag.png | `--space-drag 1,150` | Personal's cell pressed at its centre (86,795) and dragged to x 150 in 8px steps, held: its icon is the ghost with the hover backing, centred on x 150; Work and Reading slid left into slots 0 and 1; the open slot is 2 |
| dropped.png | `--space-drop 1,150` | the same let go there and settled (0.2 s): Work, Reading, Personal, Personal still selected |
| menu.png | `--space-menu 1` | Personal's menu as a right-click on its cell opens it: Windows' own menu (dark, through uxtheme), read back with PrintWindow and composed with its bottom-left on the cell's centre, as Windows places one with no room under the pointer |
| rename.png | `--rename-space 1` | Rename Space… on Personal: the header's name field with the name all selected (grey: the quiet capture window doesn't have the keyboard), Done at the right, the chevron gone |
| new-space.png | none (session above) | after New Space: Projects' dot lit between Personal and Work, Personal's dark theme |

Not in the captures: the rename field's caret (its own visual, as the command bar's), the menu's DWM rounded
corners and shadow (PrintWindow draws the menu window's own pixels only), and the slides' motion. The menu was drawn
at this monitor's scale and resampled (bilinear) to 2×, so its text is softer than a 200% monitor would draw it.

Mac references don't exist yet: `review/w9d-mac-request.md` is the recipe.
