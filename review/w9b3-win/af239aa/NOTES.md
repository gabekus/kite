# W9b3 Windows check, UI gate fixes (af239aa)

Builds: MSVC /WX, Debug and Release, 0 warnings. KiteCoreTests reports 214 tests, 0 failed. ctest passes 2/2.

Captures: sidebar.json, `--capture --window-size 1280,820 --capture-scale 2`, plain, `--space-tip 1` and `--space-tip 2`, each in a fresh profile, exit 0. Each frame is the bounding box of the pixels that differ from the plain capture. Crops are in this folder: `win-tip-tip1/2.png` at the frame, and `-context` versions 12 pt wider each side, down to the window's bottom.

| | Frame (pt) | Centre vs cell | Gap above the cell | 42026f8 | Mac |
|---|---|---|---|---|---|
| Personal | x 0, y 748, 207.5 x 28 | 103.75 vs 103 | 2 pt | 204 x 28 at x 1 | 208 x 28 |
| Work | x 42.5, y 748, 189.5 x 28 | 137.25 vs 137 | 2 pt | 185.5 x 28 | 186 x 28 |

The bold names make both tips wider. The Personal tip now begins at the window's left edge: column 0 is #1E1E1E (the border's antialiased edge), with the fill from column 1, so the left end is drawn whole. Its centre is 0.75 pt right of the cell's, which suggests it is held inside the window.

## Colours (row 6 pt from the top): unchanged from 42026f8

| | Personal | Mac | Work | Mac |
|---|---|---|---|---|
| Fill | #1C1C1C | #1C1C1C | #620028 | #620028 |
| Border | #3E3E3E | #3E3E3E | #7A2648 | #7A2C49 |
| Chip | #E8E8E8 | #E8E8E8 | #EFE5E9 | #F0E6EA |
| Keycap | #DDDDDD | #DDDDDD | #E7D9DF | #E8DBDF |

## Chip face, 8x (`chip-face-8x.png`: Windows left, Mac right)

| | Disc ink (2x px) | Centre y (tip mid 28) | Disc colour |
|---|---|---|---|
| Windows Personal | 22 x 22 | 28 | #636363 |
| Mac Personal | 22 x 22 | 29 | #636363 |
| Windows Work | 23 x 22 | 28 | #D74B86 |
| Mac Work | 22 x 22 | 29 | #D74B86 |

The face is now a filled disc with the eyes and smile cut out, the same size and colour as the Mac's. It sits 1 px (0.5 pt) higher than the Mac's.
