# W9d Windows captures at b5b5870 (the UI gate's rename blockers)

Same six states, recipe and sessions as `review/w9d-win/NOTES.md` (Release build of `helix/W9d-space-editing` b5b5870,
fresh `KITE_SUPPORT_PATH` profiles, `--window-size 1280,820 --capture-scale 2`). rest, drag, dropped, menu and
new-space are byte-identical to 85c835c. Only `rename.png` changed.

rename.png against the Mac's `review/w9d-mac/rename.png`, in 2× px. The Mac's header is lower (its favorites row), so y
is measured from the selection's top:

| | Mac | Windows b5b5870 | Windows 85c835c |
|---|---|---|---|
| editor background x | 76–395 | 76–393 | none |
| editor background y | selection −4 … +39 (44 px), #1E1E1E | selection −4 … +39 (44 px), #1E1E1E | none |
| corners | square | square | |
| selection starts at x | 86 | 86 | 82 |
| name's ink starts at x | 88 | 88 | 84 |
| Done's ink | 398–455 | 400–455 | 401–457 |

What's left is font advances, not layout. The background's end follows the field's, which ends 2pt before Done's
frame. Done is the same frame on both, a whole point wide, ending 9pt before the cell's end. Segoe's "Done" and the
name are narrower than SF's, so Done's left edge, the field's end and the selection's right edge sit 2 px over.

The selection is the focused colour here (`--rename-space` draws the window as if it had the keyboard). The Mac's
background capture shows the unfocused grey, which the gate set aside.
