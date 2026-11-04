# W9d Windows captures at 85c835c (after reviewers' round 1)

The same six states, recipe and session as `review/w9d-win/NOTES.md` (Release build of `helix/W9d-space-editing` 85c835c,
fresh `KITE_SUPPORT_PATH` profiles with `windows/helix/states/three-spaces.json`, or `../three-spaces-new-space.json`
for new-space; `--window-size 1280,820 --capture-scale 2`).

Byte for byte against the first round (3e2b217): rest, drag, dropped, menu and new-space are identical. Only
`rename.png` changed: the field is now its own visual in the page, and `--rename-space` draws it as the window with the
keyboard does, so the name's selection is the focused colour (#3F638B on the dark space) rather than the grey a quiet
capture's window got before. Its text and Done sit where they did.

`menu.png` is a PrintWindow of this machine's real Windows menu, so it isn't deterministic across machines: it depends
on the Windows version, its theme and the monitor's scale (it's resampled from that scale to 2×), and it has none of
DWM's rounded corners or shadow. Since round 1 the dark mode is set only while the menu is open and only on Windows 10
1903 (build 18362) or later.
