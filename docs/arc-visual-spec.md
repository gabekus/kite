# Arc's window, measured

Arc 1.169 on macOS 15, measured on 2026-10-22. Most of it is from the outside: the accessibility tree (exact frames
and fonts), and pixel sampling of screenshots of a 2056×1285pt window on a 2× display. The theme shader section
comes from disassembling Arc's metallib and reading its asset catalog, with Gabe's approval. Only numbers are
recorded here: no Arc code, image, shader or texture is in this repo. Everything is in points at 1×. Window
coordinates start at the window's top-left; sidebar coordinates assume the sidebar starts at x 0.

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
| Tab row | 41pt apart | 36pt pill from x 8 to 357, centred in its row. 18pt favicon at x 17 (9pt inside the pill). Title at x 43 (8pt gap), 14pt regular, 86.5% grey. The selected pill is white at 20% (19 to 20.5% in Gabe's screenshot, and the same in an incognito window); a hover pill is about 10% |
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
  - **Glow:** a soft white light under the pointer, not a fixed part of the gradient. With the pointer off the
    sidebar there is none. A 2D Gaussian fitted to Gabe's screenshot (RMS error 1.5 levels):
    - **Size:** σ 110pt wide by 34pt tall, so its half-maximum ellipse is about 260×80pt.
    - **Strength:** it adds about 29 levels of neutral white at its centre, about 14% over a grey-green theme of
      `#30342D`.
    - **Position:** centred on the pointer.
- **Kite:** the theme shader now draws translucently (premultiplied, alpha `Theme.tint`, default 0.55) over the
  system `.sidebar` behind-window material, which also darkens inactive windows.
  - Each space keeps its own `Theme`. The space button's context menu gets **Theme Color** (presets) and **Theme
    Intensity** (the tint).
  - `Theme.accent` gives the colour of the command bar's selected row.
  - **Pointer light:** `ThemeView` follows the pointer over the sidebar with a tracking area. It draws the same
    Gaussian (σ 110×34pt, 14% white) in the theme shader and fades in and out over about 0.15s. It only shows in
    the key window, and only redraws when the pointer moves or the light is fading. On a light preset in Kite it
    added 30 levels at its centre.

## Arc's theme shader, from its metallib (decompiled)

What follows came from disassembling Arc's `ARC_WindowThemeUI` metallib (the AIR bitcode, read with LLVM) and
reading its asset catalog. It records numbers and structure only. No shader code or texture is in Kite.

- **Gradient layers:** a theme is one layer of up to **two linear gradients**, each with **two colours**, blended in
  **OKLab**.
  - Each gradient has its own start and end point in UV, and its factor is the projection onto that axis, clamped
    to 0...1.
  - The first gradient's factor is scaled by **4/3** before clamping, so it reaches its end colour at 75% of its
    axis.
  - The second gradient is composited *over* the first with source-over alpha.
  - A second layer slot exists only for crossfading between themes (a `progress` mix), not for stacking.
- **Tint over the material:** OKLab is converted to linear sRGB and then sRGB-encoded (the standard 0.0031308 /
  12.92 / 1.055 / 0.055 curve). The output is premultiplied with alpha = colour alpha × the layer's opacity. Arc
  draws no underlay of its own here, so the window's vibrancy shows through wherever alpha < 1.
  - The opacity is the theme editor's **intensity** (`intensityFactor`); the colours keep their own alpha too.
  - There's a separate `translucencyStyle` setting (`vibrant`, `opaque`, `clear`).
  - No blur happens in the shader. The blur is the system material's.
- **Grain:** the `grain_metal` texture is 200×200 at 1× and 100×100 at 2×, so one grain is one device pixel.
  - Uniform alpha **0.259**; grey with mean **0.73** and standard deviation **0.21**.
  - It is tiled with `fract(uv × repetitions)`, scaled by the theme's `noiseFactor`, and **multiply**-blended over
    the gradient: `o·g + o·(1 − g.a) + g·(1 − o.a)`, in premultiplied form.
  - Other overlay textures are `denim`, `sand` and `tweed`, crossfaded with the same `fromOverlayAlpha` and
    `toOverlayAlpha`.
- **Cutout:** Arc discards the pixels inside an axis-aligned rect (no rounded corners) where the web content sits.

Kite now does the grain the same way: per-pixel hash noise with the same mean and spread, multiply-blended at
0.259 × the theme's grain, where `Theme.grain` is Arc's `noiseFactor`. Kite keeps its own OKLab anchor blend for
its presets. Importing Arc's two-gradient geometry would need the gradients' start and end points, which the
importer doesn't keep yet.

## Command bar (⌘T) → `ArcMetrics.CommandBar`

| Element | Arc | Notes |
|---|---|---|
| Panel | 765 wide, x 645.5 to 1410.5 (764 measured between the inner edges of the border) | Centred on the **window**, not the card: an incognito capture with the same 365pt sidebar puts it at the same x, 646 to 1410. Its centre, 1028, is the window's; the card's centre would be 1205.5. Top at y 474 in a 1285pt window (0.369 of the height) |
| Panel style | fill `#1B1B1B` (`#181818` in an incognito window), 1pt border white at about 22% | No dimming behind it. A wide soft black shadow, measured over a `#28282A` page: it darkens the page by 35/29/23/18/10/6/2.5% at 1/20/30/40/60/80/100pt below the panel, by 26/17/13/10/5% at 1/20/30/40/60pt to the sides, and by 16% just above. A dark page hides it. Corner **10**, circular: over a light page, a circle fitted to the border's arc has radius 9.4 to 9.5 at the 1pt border's centre line (top-right and bottom-right corners), so the outer edge is 10 |
| Field | 63.5 tall | 18pt magnifier frame at x +22.5 (glyph about 11pt wide). Text field at x +52.5 (698 in the window), 23 tall. The placeholder "Search or Enter URL..." has a 10pt x-height, which is 18pt SF regular. It is white at about 25% (level 81 over the `#181818` fill) and 179.5pt wide |
| Divider | y +63.5, 0.5pt | White at about 10%, 11pt in from the panel's edges |
| Rows | 50pt apart, starting 4.5pt under the divider | Rows are 750 wide, 7.5 in from the panel. The fill is 746×44.5, 2pt in from the row, with a corner of about 8 |
| Selected row | fill is the space's accent | White 24×24 icon tile with the favicon in the accent colour; white text; white 24×24 arrow box |
| Row content | | 16pt favicon at row x +16 (in a 24pt tile at +12). Title at row x +43 (696), 13pt medium, white at 80% (100% when selected). Right label ("Switch to Tab") 13pt medium at 33% and ends 7pt before a 24×24 `→` box, which ends 13pt inside the fill |
| Bottom | 9.5pt after the last row | |
| Open and close | No animation | A 60fps screen recording of ⌘T in an incognito window: the panel is complete in the first frame it appears and gone in the next frame after Esc. Kite also shows and hides it with no transition |

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
| Selected tab pill | white at about 20% | white at 20% |
| ⌘T shadow, darkening at 1 / 20 / 30 / 60pt below | 35 / 29 / 23 / 10% | 38 / 32 / 26 / 12% (SwiftUI black at 0.9, radius 45, y 16) |
| ⌘T placeholder | 18pt, level 81 | 18pt, level 83 |
| ⌘T corner (circle fitted to the border's bright pixels) | 9.4 to 9.5 | 9.0 (Kite's value is 11.5, circular: SwiftUI's inner stroke sits differently, so the value was tuned until the fits matched) |

## Still unknown

- The default intensity of a new theme, and the system material Arc puts under it, which sets the blur radius.
- The pointer light's fade timing and whether it eases toward the pointer. Kite fades it over 0.15s and sticks it
  to the pointer.
- The ⌘T panel's exact shadow parameters (only its effect was measured).
- Arc's default sidebar width, light-theme fill opacities, and the space-switch and sidebar animation timings.
