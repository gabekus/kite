# W9b3 Windows check (42026f8)

Captures: `Kite.exe --capture X.png --window-size 1280,820 --capture-scale 2` on sidebar.json, run plain, `--space-tip 1` and `--space-tip 2`. Each tip's frame is the bounding box of the pixels that differ from the plain capture.
- `win-tip-tip1.png` and `win-tip-tip2.png` are cropped at those frames.
- The `-context` crops are 12 pt wider on each side and run down to the window's bottom.

| | Windows frame (pt) | Cell | Centred | Gap above the cell | Mac frame |
|---|---|---|---|---|---|
| Personal | x 1, y 748, 204 x 28 | x 85, 36 wide (mid 103) | mid 103 | 2 pt (bottom 776) | 208 x 28 |
| Work | x 44.5, y 748, 185.5 x 28 | x 119 (mid 137) | mid 137.25 | 2 pt | 186 x 28 |

The Windows cells sit 40 pt further left than the Mac's (85/119 against 125/159), so the frames are compared relative to their cells. The live window rects are 204 x 28 at x 1 and 186 x 28 at x 44.

## Colours (row 6 pt from the top)

| | Windows Personal | Mac Personal | Windows Work | Mac Work |
|---|---|---|---|---|
| Fill | #1C1C1C | #1C1C1C | #620028 | #620028 |
| Border | #3E3E3E | #3E3E3E | #7A2648 | #7A2C49 |
| Chip | #E8E8E8 | #E8E8E8 | #EFE5E9 | #F0E6EA |
| Keycap | #DDDDDD | #DDDDDD | #E7D9DF | #E8DBDF |

The keycap reads "Alt" where the Mac shows "⌃".
