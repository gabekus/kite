# W9b4 Mac references: space symbols in the space bar and page header

From origin/main 46f2571, as a dev.gabek.Kite.dev debug bundle. Each run used a fresh test profile with
KITE_DIAGNOSTICS=1 and KITE_WINDOW_SIZE=1280,820 at 2×, with SidebarWidth reset (240pt sidebar), and started from
windows/helix/states/sidebar.json with space 2 (Work) set to `symbol:<name>`. Everything ran headless (a background
window, posted pointer moves, window capture with `kite ui capture`).

Per symbol:
- `<name>-spacebar-selected.png`: the space bar (window [0,770 240×50]) with space 2 selected.
- `<name>-spacebar-unselected.png`: the same after `switch_space` to space 1, so space 2 is greyed.
- `<name>-header.png`: the page header's icon slot (window [13,162 26×26]) with space 2 selected.

Geometry, from `kite ui tree`:
- Space 2's bar cell is `SpaceCellView` [119,778 36×34]; its centre is (137,795) in the window, (137,25) in the crop. The
  glyph is the 12.5pt bar icon.
- The header slot is `SpaceIconImageView` [13,162 26×26]; its centre is (26,175) in the window, (13,13) in the crop. The
  glyph is the 15pt header icon.

The ink box covers pixels more than 24 levels from the background (sampled at the region's top-left pixel). Its edges
are in points relative to the cell's or slot's centre (x right, y down). The ink colour is the pixel farthest from
the background, which is the glyph's solid colour.

Caveat: in the space-1-selected captures, the sampled background varies from run to run (#443835 to #6A4F46): the theme
had probably not finished its crossfade or the cell its wash 1.5 s after the switch. Read the unselected rows'
boxes as ±0.5pt.

| symbol | where | ink box (pt from centre) | size (pt) | ink colour | background |
|---|---|---|---|---|---|
