# Arc's window, measured

Arc 1.169 on macOS 15, measured on 2026-10-22 from the outside only: the accessibility tree (exact frames and
fonts), and pixel sampling of screenshots of a 2056×1285pt window on a 2× display. Nothing was decompiled, and no
Arc code, image or shader is in this repo. Everything is in points at 1×. Window coordinates start at the window's
top-left; sidebar coordinates assume the sidebar starts at x 0.

The window measured had a 365pt sidebar, which is a user-chosen width. Arc's default width wasn't measured.

Kite's tokens are in `Sources/KiteMac/Views/ArcMetrics.swift`, and each section below names the group it maps to.

## Window chrome (not applied here)

These belong to the `sidebar-traffic-lights` branch. They are recorded here so that branch can use them.

| | x | y | size |
|---|---|---|---|
| Close | 12 | 16 | 16×16 |
| Minimize | 32 | 16 | 16×16 |
| Zoom | 52 | 16 | 16×16 |

- The buttons are 20pt apart centre to centre (a 4pt gap), and centred at y 24.
- Hover on zoom shows its 14×16 inner glyph group at x 53.
- The sidebar toggle is a 32×32 button at x 71, y 7.5 (centre y 23.5), 3pt after the zoom button.

## Sidebar → `ArcMetrics.Sidebar`

**Padding:** 8pt on the left and on the right (to x 357 of 365) for the URL field, favourites, tab pills and
bottom bar. The back/forward/reload buttons end at 359, which is 6pt from the edge.

| Element | Frame | Notes |
|---|---|---|
| Top row | y 7.5, height 32 | Same row as the traffic lights |
| Sidebar toggle | 71, 7.5, 32×32 | |
| Back, forward, reload | x 259, 293, 327; 32×32 | 2pt apart. The glyphs are arrows (`arrow.left`/`arrow.right`/`arrow.clockwise`), not chevrons |
| URL field | 8, 46, 349×36 | Corner about 11 (a circle fit gives 12.5; Kite's 11 continuous fits 12.75). Fill is white at 10% over the tint. Text starts at x 20 (12pt in), 13pt regular, white at 60% |
| Favourites grid | 8, 90, 349×102 | 4 columns of 81.25×47 tiles, 8pt apart both ways (x 8, 97.5, 186.5, 276; y 90, 145). 18pt favicon. Same corner and fill as the URL field. 8pt above and below the grid |
| Space header | row y 200 to 239 | 26pt icon at 13, 205. Name at x 41, 13pt semibold, white at 45%, centred at y 218. Rows start 3pt below the header (y 239) |
| Tab row | 41pt apart | 36pt pill from x 8 to 357, centred in its row. 18pt favicon at x 17 (9pt inside the pill). Title at x 43 (8pt gap), 14pt regular, 86.5% grey. Selected and hover pills are white at about 10% |
| Folder row | as a tab row | Title 14pt semibold |
| Divider row | 25pt tall | 0.5pt line from x 18 to 347 (10pt inside the pills), white at about 8%, centred |
| New Tab row | as a tab row | `plus` glyph in the 18pt icon slot |
| Bottom bar | y 1235 to 1285 (50 tall) | 32×32 buttons at x 8 and 325, y 1244. The spaces strip is centred between them |

## Content card → `ArcMetrics.Content`

- The card starts exactly at the sidebar's edge (x 365) and leaves 10pt at the top, right and bottom. The web view
  is 1681×1265.
- Its corner is about 6 (a circle fit gives 6.5; Kite's 6 continuous fits 6.25).

## Material → `Theme.tint`, `NSVisualEffectView` in `BrowserWindowController`

- **Arc:**
  - **Tint:** a muted wash over translucency. For an indigo theme the sidebar is about `#252437` while the window
    is active and `#0B0A1C` while it's inactive.
  - **Gradient:** very soft. The red channel rises from 37 to 44 between the top and bottom of the sidebar, and to
    51 next to the card's right edge.
  - **Grain:** a standard deviation of about 0.5 levels per channel, so it's barely visible.
- **Kite:** the theme shader now draws translucently (premultiplied, alpha `Theme.tint`, default 0.55) over the
  system `.sidebar` behind-window material, which also darkens inactive windows.
  - Each space keeps its own `Theme`. The space button's context menu gets **Theme Color** (presets) and **Theme
    Intensity** (the tint).
  - `Theme.accent` gives the colour of the command bar's selected row.

## Command bar (⌘T) → `ArcMetrics.CommandBar`

| Element | Arc | Notes |
|---|---|---|
| Panel | 765 wide, x 645.5 to 1410.5 | Centred on the **window**, not the card. Top at y 474 in a 1285pt window (0.369 of the height) |
| Panel style | fill `#1B1B1B`, 1pt border white at about 22% | No dimming behind it (the page pixels are unchanged) and no shadow I could detect. Corner about 12 to 13.5 (the fit is unreliable because of the border) |
| Field | 63.5 tall | 18pt magnifier frame at x +22.5 (glyph about 11pt wide). Text field at x +52.5 (698 in the window), 23 tall. The placeholder font couldn't be read; Kite uses 18pt |
| Divider | y +63.5, 0.5pt | White at about 10%, 11pt in from the panel's edges |
| Rows | 50pt apart, starting 4.5pt under the divider | Rows are 750 wide, 7.5 in from the panel. The fill is 746×44.5, 2pt in from the row, with a corner of about 8 |
| Selected row | fill is the space's accent | White 24×24 icon tile with the favicon in the accent colour; white text; white 24×24 arrow box |
| Row content | | 16pt favicon at row x +16 (in a 24pt tile at +12). Title at row x +43 (696), 13pt medium, white at 80% (100% when selected). Right label ("Switch to Tab") 13pt medium at 33% and ends 7pt before a 24×24 `→` box, which ends 13pt inside the fill |
| Bottom | 9.5pt after the last row | |

## Arc vs Kite

Kite was built from this branch, run on WebKit with a fresh `KITE_SUPPORT_PATH` (`mktemp -d`) and a session seeded
to match Arc's layout, then resized to 2056×1285 with the sidebar at 365. Both were measured with the same
accessibility dumper and pixel scripts.

| Measure | Arc | Kite |
|---|---|---|
| Sidebar toggle | 71, 7.5, 32×32 | 71, 7.5, 32×32 |
| Back / forward / reload x | 259 / 293 / 327, y 7.5 | 259 / 293 / 327, y 7.5 |
| URL field | 8, 46, 349×36 | 8, 46, 349×36 |
| URL field corner (profile fit) | 12.5 | 12.75 to 13.75 (11 continuous) |
| Favourite tiles | 81.25×47 at x 8 / 97.5 / 186.5 / 276, y 90 / 145 | 81 to 81.5×47 at the same x and y |
| Space header | icon 13, 205; text x 41, centre y 218 | icon 13, 205; text x 41, centre y 218 |
| First pinned row | y 239 | y 239 |
| Row pitch / pill height | 41 / 36 | 41 / 36 |
| Favicon / title x | 17 / 43 | 17 / 43 |
| Tab font | 14 regular | 14 regular |
| Divider row | 25; line 18 to 347 | 25; line 18 to 347 |
| Bottom buttons | x 8 and 325, y 1244, 32×32 | x 8 and 325, y 1244, 32×32 |
| Content card | 365, 10, 1681×1265 | 365, 10, 1681×1265 |
| Card corner (fit) | 6.5 | 6.25 |
| ⌘T panel x | 645.5 to 1410.5 | 645.5 to 1410.5 |
| ⌘T panel top | 474 | 474 |
| ⌘T fill / border | 27 / about 80 | 27 / 77 |
| ⌘T divider y | 537.5 | 537.5 |
| ⌘T text field x | 698 | 698 |
| ⌘T first row icon | 669, 559, 16×16 | 669, 559, 16×16 |
| ⌘T title x | 696 | 696 |
| ⌘T selected fill y | 544 to 588.5 | 544.5 to 589 |
| ⌘T right label end / arrow box | 1357 / 1364 to 1388 | 1357 / 1364 to 1388 |
| ⌘T bottom padding | 9.5 | 9.5 |

## Not measurable without decompiling

- How strongly Arc mixes the tint over the material, and whether it is a mix at all or a blend mode. The vibrancy
  blur radius.
- The grain texture and its strength. Only its effect could be measured: about 0.5 levels of standard deviation.
- The number of gradient layers and where they sit.
- The ⌘T panel's exact shadow (none was visible) and its corner, which the border hides.
- The ⌘T placeholder's font size: the field's 23pt height suggests about 18pt.
- The selected tab pill's opacity. Only a hover pill could be isolated, at about 10% white.
- Arc's default sidebar width, light-theme fill opacities and every animation timing.
