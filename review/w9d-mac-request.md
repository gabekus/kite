# W9d: Mac references wanted

For the W9d UI gate (PR "Windows W9d: …"): the Mac's captures of the states in `review/w9d-win/`, in the format of
`review/w9c-mac/NOTES.md`. Put the PNGs and a NOTES.md (build sha, capture path, the tree's frames you read) in
`review/w9d-mac/` on a branch `review/w9d-mac`.

## Setup, for every capture

- A debug test bundle (`dev.gabek.Kite.dev`) from origin/main (no Mac code changes in W9d).
- `defaults delete dev.gabek.Kite.dev SidebarWidth` (the 240pt sidebar).
- A fresh profile each time: `P=$(mktemp -d /tmp/k.XXXX)`, then
  `cp windows/helix/states/three-spaces.json "$P/session.json"` (from `helix/W9d-space-editing`; Personal 🏠
  selected, Work with symbol:briefcase, Reading 📚). For `new-space`, use `review/w9d-win/three-spaces-new-space.json`
  (on `review/w9d-win`) instead.
- Launch: `KITE_DIAGNOSTICS=1 KITE_SUPPORT_PATH=$P KITE_WINDOW_SIZE=1280,820` (plus `KITE_TEST_CONTEXT_MENU` where
  noted), Kite in the background throughout.
- Capture: `kite ui capture -o NAME.png` (2×, 2560×1640), the `in-process` source if `auto` doesn't return, as in
  W9c; say which in NOTES.md.
- Coordinates are window points from the top-left. With three spaces in a 240pt sidebar the bar is y 770–820 and the
  cells are x 68, 102 and 136 (36×34, y 778–812), centres (86,795) Personal, (120,795) Work, (154,795) Reading. Please
  check them against `kite ui tree` (the SpaceCellView frames) first and use the tree's centres if they differ.

## The states

| file | steps (after launch) | holds |
|---|---|---|
| rest.png | none | the three spaces at rest |
| drag.png | `kite ui input '{"from":[86,795],"to":[150,795],"steps":10,"hold":10}'`, then within the 10 s `kite ui capture -o drag.png` | Personal's icon picked up as the ghost (with its backing) at x 150, Work and Reading slid into slots 0 and 1 |
| dropped.png | `kite ui input '{"from":[86,795],"to":[150,795],"steps":10}'`, wait 1 s, capture | Work, Reading, Personal, Personal selected; please note the order `kite ui tree` reports |
| menu.png | real menu: right-click Personal's cell by hand (or `kite ui input '{"click":[86,795],"button":"right"}'` without `KITE_TEST_CONTEXT_MENU`, if the input sender comes back while the menu tracks), then `screencapture -x -o -R<window frame> menu.png` while it's open (NSMenu is modal; `kite ui capture` can't run under it). Also run once with `KITE_TEST_CONTEXT_MENU=1` and the same `ui input` right-click, and paste the logged `KITE_TEST_CONTEXT_MENU:` line into NOTES.md | the space menu over Personal's cell, and its items as AppKit logs them |
| rename.png | launch with `KITE_TEST_CONTEXT_MENU="Rename Space…"`, `kite ui input '{"click":[86,795],"button":"right"}'` (the hook picks the item), then capture | the header's rename field, the name all selected, Done at the right |
| new-space.png | none (the new-space session) | Projects' dot lit between Personal and Work |

Windows' side of each, for the record: `Kite.exe --capture X.png --window-size 1280,820 --capture-scale 2` with
`--space-drag 1,150`, `--space-drop 1,150`, `--space-menu 1`, `--rename-space 1`, or nothing (rest, new-space).

What to expect to differ, so it isn't argued in review: the menu is each platform's own (NSMenu, Win32's), and
Windows' composes its bottom-left on the cell's centre where the Mac's opens at the pointer; Windows' rename capture
greys the selection (its quiet window doesn't have the keyboard), as the Mac's should in the background.
