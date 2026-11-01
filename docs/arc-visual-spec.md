# Arc's window, measured

Arc 1.169 on macOS 15, measured on 2026-10-22. Most of it is from the outside: the accessibility tree (exact frames
and fonts), and pixel sampling of screenshots of a 2056×1285pt window on a 2× display. The theme shader section
comes from disassembling Arc's metallib and reading its asset catalog, with Gabe's approval. Only numbers are
recorded here: no Arc code, image, shader or texture is in this repo. Everything is in points at 1×. Window
coordinates start at the window's top-left; sidebar coordinates assume the sidebar starts at x 0.

The window measured had a 365pt sidebar, which is a user-chosen width. Arc's default width wasn't measured.

Kite's tokens are in `Sources/KiteMac/Views/ArcMetrics.swift`, and each section below names the group it maps to.

**How colours were matched.** Every level and hex here is a screen capture, Arc's and Kite's alike, and each
went through the same capture pipeline on the same display. On this Mac a capture reads dark colours about 10 to
15 levels lighter than the CSS value (CSS `#202122` captures as `#2B2C2D`), so a captured hex isn't the colour
Arc asked for. Kite's colours were therefore tuned until **Kite's capture matched Arc's capture**, rather than by
copying a captured hex into code.
- **⌘T fill:** captures at 27 in both.
- **⌘T placeholder:** 83 in Kite against Arc's 81.
- **⌘T shadow:** compared as darkening fractions at the same distances.
- **Translucent white fills:** the opacities (URL field 10%, selected pill 20%, hover 10%) are ratios between two
  captured levels, so a profile shift that is close to linear over a small range moves them only a little.
- **Arc's real theme values:** grey 0 to 0.1, intensity 0.8 to 1, noise 0, and the semantic palette. These come
  from Arc's settings file, not captures, so they are exact.

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
| Tab row | 41pt apart | 36pt pill from x 8 to 357, centred in its row. 18pt favicon at x 17 (9pt inside the pill). Title at x 43 (8pt gap), 14pt regular, 86.5% grey. The selected pill is white at 20% (19 to 20.5% in Gabe's screenshot, and the same in an incognito window); a hover pill is about 10%. Light themes differ: see *Tab pill fills* below |
| Folder row | as a tab row | Title 14pt semibold |
| Divider row | 25pt tall | 0.5pt line from x 18 to 347 (10pt inside the pills), white at about 8%, centred |
| New Tab row | as a tab row | `plus` glyph in the 18pt icon slot |
| Bottom bar | y 1235 to 1285 (50 tall) | 32×32 buttons at x 8 and 325, y 1244. The spaces strip is centred between them |

## Content card → `ArcMetrics.Content`

- The card starts exactly at the sidebar's edge (x 365) and leaves 10pt at the top, right and bottom. The web view
  is 1681×1265.
- Its corner is about 6 (a circle fit gives 6.5; Kite's 6 continuous fits 6.25).

## Sidebar resize zone → `ArcMetrics.Content.resizeZone*`

Measured on 2026-10-23 by moving the pointer 0.5pt at a time across Arc 1.169's edge (an incognito window,
1285pt tall, card from x 294) and reading the system cursor after each move. Arc's binary agrees on the mechanism.

| | Arc |
|---|---|
| Across | `resizeLeftRight` from 4pt left of the card's edge to 4pt right of it, over the page (x 290 to 297.5 for a card at 294; x 295 to 302.5 for one at 299) |
| Down | 1pt inside the card's top and bottom: y 11 to 1273.5 for a card from 10 to 1275. Same across at y 20, 640 and 1272 |
| Sidebar hidden | none, anywhere (Arc hides the region with the sidebar) |
| Hover reveal | the same 8pt, straddling the floating card's right edge (x 314 to 321.5 for a card ending at 318; 401 to 408.5 for one ending at 405), at the docked zone's height (y 11 to 1273.5), not the floating card's (5 to 1280) |
| Window inactive | none (tracking options 0x227: entered/exited, moved, cursor update, key window only, visible rect) |

- In the binary, `Arc.SidebarResizeRegionView` is its own view, framed by the window layout controller and hidden
  with the sidebar. Its `cursorUpdate:` sets `NSCursor.resizeLeftRight`. It carries a pan recognizer for the drag and
  a two-click recognizer.
- Dragging it while peeking (synthetic drags, 23 Oct 2026, second pass): the card's right edge follows the pointer.
  The card stays out with the pointer anywhere mid-drag, 1500pt away included. Released away from the card, it stays
  out until the pointer comes back to it and leaves. The peek and the docked sidebar share one width: 500 set
  peeking docks at 500, and 400 set docked peeks to 405. Widths 164 to 500. Under 82 mid-drag the card disappears; a
  release there leaves it at 164, still out (docked, the same release hides the sidebar). The binary's pan handler has
  the same 82, 164 and 500.
- Kite's handle straddles the card's edge the same way and sits above the page and the glow. It keeps cursor rects
  and invalidates them whenever the handle moves, so the zone follows a drag and the hide/show slide.

## Material → `Theme.tint`, `NSVisualEffectView` in `BrowserWindowController`

- **Arc:**
  - **Tint:** a muted wash over translucency. For an indigo theme the sidebar is about `#252437` while the window
    is active and `#0B0A1C` while it's inactive.
  - **Gradient:** very soft. The red channel rises from 37 to 44 between the top and bottom of the sidebar, and to
    51 next to the card's right edge.
  - **Grain:** a standard deviation of about 0.5 levels per channel, so it's barely visible.
  - **No pointer light:** Arc draws no light or glow that follows the pointer over the sidebar (Gabe, 31 Oct
    2026). An earlier pass fitted a Gaussian (σ 110×34pt, 14% white) to a bright patch in one screenshot and
    took it for one. Kite drew it until PR "Remove the sidebar pointer light"; don't add it back.
- **Kite:** the theme shader now draws translucently (premultiplied, alpha `Theme.tint`, default 0.55) over the
  system `.sidebar` behind-window material, which also darkens inactive windows.
  - Each space keeps its own `Theme`. The space button's context menu gets **Theme Color** (presets) and **Theme
    Intensity** (the tint).
  - `Theme.accent` gives the colour of the command bar's selected row.

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
| Panel style | A translucent dark panel: the page under it shows through blurred (about 25pt) at about 11%, so it reads `21 + 0.106 × page` per channel (48 over white, 48/21/20 over red, `#181818` over a page Chromium draws as a bare solid colour). 1pt border white at about 22%, and 0.5pt of black just outside it | No dimming behind it. A wide soft black shadow, measured over a `#28282A` page: it darkens the page by 35/29/23/18/10/6/2.5% at 1/20/30/40/60/80/100pt below the panel, by 26/17/13/10/5% at 1/20/30/40/60pt to the sides, and by 16% just above. A dark page hides it. Corner **12**, circular, from the decompiled `SuggestionsView`. Before the decompile: over a light page, a circle fitted to the border's arc has radius 9.4 to 9.5 at the 1pt border's centre line (top-right and bottom-right corners), so the outer edge is 10 |
| Field | 63.5 tall | Measured from 2x captures of an incognito window, from the border's outer edge. **Magnifier:** not SF Symbols' `magnifyingglass` (its handle is longer and heavier at every size and weight). A ring of mid-radius 4.65 with its centre at 30.6, 30.75, and a handle ending 8.6 from the centre at 45°, both 1.4 wide with round ends, white at 100%. Bounding box 25.5 to 37.5 each way. **Placeholder** "Search or Enter URL...": 18pt SF **medium** (179pt of ink, which is CoreText's width for medium; regular is 174.8). Ink from x 52, cap top 24.5, baseline 38.5; white at about 25% in captures (the asset `CommandBarPlaceholderPlaceholderText` says 30%). **Caret:** x 51.5, y 24 to 45, 1pt wide |
| Divider | y +63.5, 0.5pt | White at 10% (asset `CommandBarHairlineDividerColor`, and +23 levels over `#181818` in a capture), 11.5pt in from the border's outer edge on both sides |
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
| ⌘T corner | 12, circular (decompiled; a circle fit to the border gives 9.4) | 12, circular |

## From Arc's binary (decompiled with Ghidra 12.1.4)

Gabe approved decompiling Arc. The Ghidra project, the decompiled output and the scripts are in `~/rea-arc/decomp`
on Gabe's Mac, and none of them are in this repo. The binary is stripped, so only a few functions have names, and
most values can't be tied to a specific screen.

**⌘T panel**
- `CommandBar.SuggestionsView.updateLayer` sets `layer.cornerRadius = 12` and `maskedCorners = 0xc` (only the
  bottom pair rounded in the layer's coordinates). It sets no `cornerCurve`, so the corner is circular.
- Kite's ⌘T panel is now a circular 12. The light-page fit above, which suggested about 10, read low, most
  likely because of the border.

**Window materials** (`NSVisualEffectView`)
- Most calls pass the material and blending mode through from a configuration value.
- Two call sites hard-code a pair:
  - `.popover` (6) with `.withinWindow` (1) and `isEmphasized = true`;
  - `.windowBackground` (12) with `.behindWindow` (0).
- Which one draws the sidebar couldn't be pinned down. Kite keeps `.sidebar` behind the window, which matches
  the captures.

**Animation vocabulary** (SwiftUI `Animation` calls, with the most frequent values first)

| API | Values (count) |
|---|---|
| `spring(response:dampingFraction:blendDuration:)` | 0.5, 1.0, 0 (13); 0.3, 0.6, 0 (9); 0.15, 0.95, 0 (8); 0.28, 0.63, 0 (6); 0.18, 0.8, 0 (6); 1.25, 0.9, 0 (5); 0.4, 0.75, 0.1 (5); 0.25, 0.9, 0 (5); 0.2, 0.6, 0 (5) |
| `easeInOut(duration:)` | 0.15 (16), 0.18 (13), 0.16 (11), 0.2 (8), 0.12 (6) |
| `easeOut(duration:)` | 0.12 (8), 0.1 (7), 0.125 (3) |
| `easeIn(duration:)` | 0.15 (6), 0.1 (3) |
| `timingCurve` | (0.25, 0.1, 0.25, 1) — the CSS `ease` curve — at 0.3s (12), and also at 0.4, 0.25 and 0.2s |
| `interpolatingSpring(mass:stiffness:damping:initialVelocity:)` | 8 one-offs, for example (1, 500, 25, 10) and (2, 200, 20, 1) |

- Arc's house spring is critically damped with a 0.5s response. Quick fades are easeInOut at 0.15 to 0.18s.
- The ⌘T panel itself doesn't animate (see the recording above).
- These aren't applied to the space switch yet: the binary doesn't say which of them drives it.

**Sidebar hide and show (⌘S)** (AppKit, not SwiftUI, so it isn't in the table above)
- Both directions run one `NSAnimationContext` group: `duration` 0.08, `allowsImplicitAnimation`, and a
  `CAMediaTimingFunction` with control points (0.25, 0.46, 0.45, 0.94).
- Inside the group Arc sets the sidebar's frame and the web content container's frame once, then calls
  `layoutSubtreeIfNeeded` once. Core Animation draws the frames between; nothing lays out per frame.
- The sidebar slides with the content's edge. It doesn't fade.
- On show, the sidebar is first laid out at its starting place and committed, then animated in.
- A hidden sidebar has a hover reveal: a floating sidebar container (`floatingSidebarContainer`). The binary
  suggested it slides in on the same 0.08s curve, but recordings show a spring on the way in (see *Sidebar peek*).

**Sidebar peek** (two 60fps recordings of an Arc incognito window, 23 Oct 2026, 1.75px per pt)
- With the sidebar hidden there are no traffic lights anywhere, even with the pointer in the top-left corner.
  They exist only inside the sidebar.
- Resting the pointer on the window's left edge brings the sidebar in as a floating card over the page.
  - The card is inset 5pt from the window's left, top and bottom. It is as wide as the docked sidebar, and its
    contents sit exactly where they do docked, shifted with the card.
  - It has rounded corners and a 1pt border at about 20% white.
- **Delay:** 0.17 to 0.22s from the pointer reaching the edge to the first moved frame (three peeks). That
  includes a frame or two of display latency.
- **In:** right edge 17 → 67 → 225 → 377 → 494 → 572 → 619 → 646 → 652 → 657 → 653 → 650 → 648 → 646 → 645 → 644px,
  one frame apart. It overshoots about 1.5% and settles by about 0.25s. The best fit among the springs in the
  binary is `spring(response: 0.18, dampingFraction: 0.8)`, at RMS 0.009. The 0.08s curve fits worse, at 0.043,
  and can't overshoot.
- **Out:** starts about 2 frames after the pointer leaves the card. "Leaves" is 75pt past its right edge: with the
  pointer jumped there and held 0.6s, a card ending at 318 stayed out to x 392 and went at 394; one ending at 405
  stayed to 479.5 and went at 480 (pointer sweep, 23 Oct 2026). `ArcMetrics.Sidebar.peekHoverMargin`.
  It takes 0.07 to 0.08s with no overshoot, which is the toggle's 0.08s curve.
- **Docking:** a peeking card docks with ⌘S or the View menu. It grows out to the window's edges in about 0.08s.
- **Not observed:** how wide the edge trigger is (the pointer was pinned against the screen edge each time), and
  the card's shadow and exact corner radius.
- Two other window-layout animations aren't part of the toggle:
  - a 0.2s relayout on the same curve when the home view's width changes;
  - a 0.12s linear, auto-reversing 1.015× scale "bump" of the window contents when a Bool state turns on.

## Traffic lights and tab drag (Arc incognito window, 31 Oct 2026)

**Tab pill fills → `TabPillFill` in `SidebarView.swift`, `ArcMetrics.Sidebar`** (31 Oct 2026)
- **Hover, measured:** a flat fill with no blur or material, there in the first capture after the pointer
  arrives (captures are about 0.15s apart, so a fade shorter than that can't be ruled out) and gone the same way.
  Incognito window: (12,15,20) under the pill becomes (36,39,44), white at 10%. Gabe's grey space: 79 becomes 96,
  also 10%, with its selected tab at 113 (20%). The × appears on hover.
- **Colours, from the binary:** the tab cell's background picks `TabCellBackgroundCurrent` for the selected tab
  and, on hover, a colour its caller passes in, which is `SidebarItemBackground`. Their asset values:
  - `SidebarItemBackground` (hover): dark (0.98,0.984,1) at 10%; light (0.055,0.059,0.063) at 5%.
  - `TabCellBackgroundCurrent` (selected): dark (0.98,0.984,1) at 20%; light white at 85%.
- So on a light theme a hovered tab gets a faint dark wash, not white. Kite used to scale its dark-theme white up
  3.5 times on light themes (35% on hover, 70% selected), which read as a light frosted patch.
- **Not observed:** Arc on a light theme. Incognito is always dark and Gabe's Arc spaces are all dark or grey,
  so the light values come from the assets only.

**Traffic lights → `ArcMetrics.Window.trafficLightHoverArea`, `TrafficLights.swift`**
- **Away from the lights:** all three are grey, (89,90,89) over the sidebar's (14,15,19). That holds whether
  or not Arc is frontmost.
- **Pointer anywhere in one rectangle:** all three show colour and their marks, whether or not Arc is
  frontmost. The rectangle runs from window x 12 to 72 and y 17 to 30 inclusive, gaps between buttons
  included. Colours: close (140,26,16), minimize (143,89,28), zoom (97,197,85).
- **Binary:** next to the standalone buttons Arc calls `setAlphaValue:`. The value is picked from
  `currentDrawingAppearance` (0.33 or 0.1), and is 1.0 on hover.

**Tab drag** (three recordings plus a window-list poll; the recorder skips frames where only the cursor moves,
so timings are ±0.3s)
- **Inside the sidebar:** one run showed a translucent full-width copy of the row, × included, following the
  pointer, and a white insertion line with a small circle at its left end marking the slot. The other rows
  don't slide apart, and on drop the list reorders in a frame or two. Another run showed nothing but the
  cursor, so this may depend on speed or start point.
- **Out over the page:**
  - About 1.1s after the pointer crosses the sidebar edge, a portrait card replaces the row copy in a single
    frame. It's about 170×250pt, near-black, with rounded corners, a favicon square and the bold white title,
    centred.
  - The pointer stays on the title line, about 25pt left of centre.
  - No soft shadow shows, but the binary's drag window sets one (y −30, radius 19).
  - The page dims in that same frame, and a thin light line appears at the sidebar edge.
- **Back into the sidebar:** at the edge the card turns back into a translucent row-sized pill. The page
  brightens only after the drop.
- **Dropped over the page:** cancelled. No new window and no split; the tab stays where it was.
- **Windows during a drag:** 0.5 to 0.9s after mouse-down, Arc opens three, all gone after the drop:
  - a full-screen window at layer 500, which is where the card is drawn;
  - a 30pt strip on the sidebar's right edge;
  - an 80pt strip just off the window's left edge.
- **Binary:**
  - A real `NSDraggingSession` with a bitmap of the row (`cacheDisplayInRect:toBitmapImageRep:`).
  - A borderless, mouse-transparent `ArcDraggingWindow` showing a snapshot, with a rounded shadow path.
  - Two clear floating child panels registered for drags (`SidebarDragRegionWindow`,
    `SidebarItemDragTargetWindow`).
- **Not observed yet:**
  - What the edge strips accept: other windows, other spaces, split view.
  - What triggers the card: time or distance.
  - The return animation.
  - Kite's own drag, which needs Kite in front.

## Animations, from 60fps recordings of Arc

Recorded on Gabe's main Arc window, capturing only thin strips with no titles (the space-header row, and a 6pt
strip near the bottom of the sidebar). The videos were deleted after measuring. Each motion was fitted against
the springs and eases in Arc's binary (see the vocabulary table above).

| Motion | Arc, as recorded | Best fit | Kite now |
|---|---|---|---|
| Space switch (⌘⌥→), theme colour | 64 / 73 / 78 / 87 / 91 / 98% per frame, settled by about 0.12s | `spring(response: 0.15, dampingFraction: 0.95)` (RMS 0.078; CSS ease at 0.1 to 0.12s is equivalent). Arc uses this spring 8 times | Same spring (`ArcMetrics.Motion`), settling within 0.3s. Recorded: 20 / 51 / 61 / 83 / 93 / 98% per frame |
| Sidebar hide (⌘S), card edge | 365 → 236 → 106 → 46 → 20 → 10pt, 1 frame apart (about 80ms). Re-recorded: 365 → 289 → 115.5 → 42 → 10pt | Arc's own 0.08s on (0.25, 0.46, 0.45, 0.94), see above | Same group, 0.08s on that curve. Recorded at 120fps: 0.17 / 0.36 / 0.54 / 0.68 / 0.86 / 0.92 / 0.96 / 0.99 / 1, RMS 0.004 to Arc's curve |
| Sidebar show | 10 → 145 → 292 → 340 → 362 → 365pt. Re-recorded: 10 → 113.5 → 275.5 → 331 → 362 → 365pt | Same | Same, RMS 0.004 |
| ⌘T open and close | Instant | — | Instant |

## Extensions in the toolbar → `ExtensionsToolbarItems`, `ExtensionsMenu`

Measured on Arc 1.169 with the masked probe (roles and frames only) on a window with the content toolbar showing
(sidebar hidden), Oct 2026. Window points; the toolbar row is y 10–42.

| | Arc | Kite |
|---|---|---|
| Pinned extension icon | 16×16 at y=18, pitch 36 | Same: 16pt icons in 36×32 slots |
| Extensions button | 32×28 at y=12, left edge 12 after the last icon | Same (Kite: 1148 → 1160) |
| Button to Site Controls' icon | 12 (1973 → 1985) | 12 (1192 → 1204) |
| Menu | AXPopover 262×486 hanging from the button, content inset 13 | SwiftUI popover, 262 wide, inset 13 |
| Menu tiles | 48×32, 4 columns on a 56 pitch, rows on a 40 pitch; pinned tiles carry a 14×14 button at the tile's (37, 21) | Same grid; pinned tiles show a 14pt pin badge there |
| Cursor over the items | Arrow (cursorprobe) | Arrow (`kite ui pointer`) |

Not measured (text wasn't read): what the menu's top row of four 48.75×32.75 buttons, its second section (three
208×33 rows) and its two bottom buttons (82×32, 32×32) do. Kite leaves them out; pin, on/off, options and remove
are in each tile's right-click menu instead. Arc's hover reveal in the sidebar URL row: none found.

## Spaces (Arc 1.169, 31 Oct 2026)

**Paging → `SpacePages`, `SpaceSwipeController`, `KiteCore.SpaceSwipe`**
- **Binary:** the sidebar under the URL field is `SidebarPagingContainerViewController`, an `NSCollectionView`
  with a horizontal `SidebarPagingContainerCollectionViewLayout` inside `SidebarPagingContainerScrollView`. Each
  space is a `SidebarSpaceViewController` page. The favorites are their own item
  (`SidebarPagingContainerAppTrayCollectionViewItem`).
- The scroll view's `scrollWheel:` doesn't scroll it: on macOS 14 and later it forwards the event to the window's
  `contentViewController` (`WindowViewController`, which has its own `scrollWheel:`), and its clip view's
  `constrainBoundsRect:` returns the current visible rect, so only code moves the pages. Type names nearby:
  `PagingDragBuffer`, `PagingPosition`, `PagingTransitionConfiguration`.
- **Accessibility tree** (Gabe's main window, three spaces, sidebar 313 wide, frames only):
  - The collection list is 939×1153 at x −313: three 313pt pages side by side, the second one showing.
  - Its first section is the favorites, 313×63 at (0, 82), and it stays at x 0. The pages are the second section.
  - The page shown is (0, 145, 313×1090): space name at y 154, rows from y 181.
  - So pages are the full sidebar width and slide under the fixed favorites.
- **Not measured yet:** the swipe's physics (Arc ignores synthetic trackpad events, and a recording of Gabe's own
  swipes is pending), whether a keyboard or strip switch slides the pages, and the settle animation. Kite's
  pages follow the fingers 1:1, rubber-band past the ends with AppKit's constant (0.55), land on the neighbour
  past half a page or on a flick over 300pt/s, and settle with the space-switch spring below.

**Space strip**
- In the accessibility tree it is an `AXCollectionList` in a 229×50 scroll area at (42, 1235), between the two
  32pt buttons at x 8 and 273. Its items aren't exposed.
- In Gabe's window it draws nothing at all with three spaces, before and after a synthetic hover. Why is still
  open (a setting, or hover only).

**Space header and context menu → `SpaceHeader`, `SpaceContextMenu`** (binary strings, 1 Nov 2026)
- The header's actions are `didClickEditSpaceStyle`, `didClickEditableIcon` / `didCloseIconPicker`,
  `didBeginEditingSpaceName`, `didRenameSpace` and `didCancelRenameSpace`: the name is edited in place, and the
  icon is a button that opens an icon picker.
- `SidebarSpaceState+SpaceContextMenu.swift` holds the space context menu, with items Rename, New Folder, Share,
  delete, Manage Spaces, Show/Hide Space Header, live folders, profile, Edit Theme Color, Change Space Icon and
  "Export … into Folder". The order and the exact Rename/delete titles weren't read.
- Neither could be opened from outside: Arc ignored a right-click posted to its process, and Spaces → Rename
  Space pressed through accessibility did nothing visible while Arc was in the background.
- **Kite:** the strip icon and the header share one menu (Rename Space, New Folder, Edit Theme Color, Change
  Space Icon, Delete Space). Rename edits the header in place: Return or clicking away keeps it, Escape cancels.
  Unverified: whether Arc also starts a rename on double-click.

**Theme editor → `ThemeEditor`, `ArcMetrics.ThemeEditor`** (Spaces → Edit Theme…, tree plus one capture)
- An `AXPopover`, 382×534, hanging off the sidebar's right edge (x 313). Opened from the menu with the pointer
  away, its bottom sat on the window's bottom (y 751 to 1285); opened the same way a few minutes later it sat
  at y 158, so something else decides its height.
- Content 356×508 inset 13. From the popover's corner:
  - A 340×340 dot-grid image at (21, 21), with one round handle per colour (about 45pt, a 5pt white ring).
  - Three 32×32 buttons at (135, 45), (175, 45), (215, 45) on the grid: sparkles, sun and moon (auto, light, dark
    by their glyphs), the selected one on a faint fill.
  - "Remove" and "Add" (− and +), 32×32, at (155, 313) and (195, 313).
  - Presets: "Move to previous/next preset page" arrows 32×32 at (21.5, 377) and (328.5, 377); 24pt swatches
    29.5 apart from (61, 381), nine to a page, labelled "Set space color to Catalog color".
  - A 224×56 slider at (31, 437), drawn as a wave over a track with a tall white thumb.
  - A dial of dots, an 80×36 slider at (271, 469) under an 80×36 "Cycle noise texture" button at (271, 425).
- **Kite:** the same frames (checked with `kite probe` on a test build: popover 382×534, content 356×508 at 13,
  bottom on the window's). Unmeasured, so chosen: the grid's mapping (angle is hue, distance is chroma, the
  appearance buttons set lightness), the wave slider as the theme's intensity and the dial as its grain, at most
  three colours, and Kite's own presets on one page.
## Downloads (Arc 1.171 binary, assets and menu bar, 31 Oct 2026)

- Menu: Window › **View Downloads…** ⇧⌘J, next to Open Library… ⇧⌘L (read from Arc's menu bar through AX, no
  items pressed). Arc's own copy: "Opens the Downloads section of your Library", so ⇧⌘J lands on the Library's
  Downloads page (`HomeButton/DownloadsPageReducer`, `DownloadsContentView`, `DownloadCell`).
- Sidebar: `DownloadsUI.DownloadToLibrary` animates a file icon (`DownloadIconView`,
  `ProjectileIconKeyframeAnimation`, `animateDownload(source:destination:)`, SF Symbol `arrow.down.circle` nearby)
  into the Library button (`DownloadBin`), which carries a `DownloadProgressBadge`. Geometry and timing: unknown.
- Context menu ("Download Context Menu"): Open, Copy, Show in Finder, Hide from Arc, Move to Trash, Cancel download
  (from the localisation comments; exact titles are short inline strings not in the dump).
- Row text: subtitles for generic / paused / cancelled / failed downloads, "Failed to Download", speed "e.g. 3 MB/s",
  "Download from [source domain]", file-type copy for PDF, disk image, movie, video, image, audio, archive, zip,
  empty-state "File deleted or moved".
- Colours (Assets.car): `DownloadItemBackgroundHovered` light p3 0.96 grey / dark p3 0.12;
  `DownloadItemBackground` light sRGB white / dark p3 0.05 (Little Arc tray); `DownloadProgressBarBackground` light sRGB
  (0.808, 0.843, 0.906) / dark (0.443, 0.467, 0.510).
- Quit with downloads running: alert "Downloads in progress" (not built in Kite yet).

Kite (`DownloadsView.swift`): no Library yet, so the bottom bar's leading button (where Arc's Library button sits)
shows the progress ring and opens a popover list. Row size, ring size and popover width are Kite's, unmeasured.

## Little Arc → `ArcMetrics.LittleWindow`, `LittleKiteWindowController` (Arc 1.171, 31 Oct 2026)

Measured from a Little Arc window Gabe had open: `kite probe Arc tree` (roles and frames only, no `--text`) and a
background `screencapture -l<window id>` at 2x, toolbar strip only. Nothing in Arc was pressed or focused.

- Window: no sidebar, no content card. A 47pt toolbar, then the page edge to edge (`AXWebArea` at 0,47, full
  width, to the bottom). The open window was 1784×1245; Arc's defaults hold `LittleBrowserWindow_size` = {1495, 1245}
  and its binary names `.littleWindowAutosaveFrame`, so the size is remembered across Little Arc windows. Arc's
  first-run size wasn't found; Kite starts at 1495×1245 (shrunk to the screen) and remembers the last frame.
- Traffic lights: 16×16 at x 9/29/49, y 15.5 (centre 17, 23.5), 3pt left of and 0.5pt above the main window's.
  Hover area not swept (needs `cursorprobe`); Kite moves the main window's by the same offset.
- Back: 16×16 button at 79.5, 15.5. No forward or reload buttons.
- URL pill (`LittleBrowserCommandBarPlaceholderBackground`): x 107 to 7.5pt short of the Open In box, y 8, 31pt
  tall, corner about 5pt (antialiased 2x edge, ±1pt). Colour assets in `ARC_LittleBrowser.bundle` (`assetutil`):
  dark p3 (0.98, 0.984, 1) at 0.10, hovered 0.15; light p3 (0.055, 0.059, 0.063) at 0.06, hovered 0.10. Inside:
  the profile indicator (14pt image at x 121 + name), the host text (16pt line, centred between the indicator and
  the trailing buttons), an extensions button (23×19 at 1530.5) and a copy-link button (16×16, right edge 7.5pt in).
- Open In box: x from pill end + 7.5 to 7pt from the window edge, y 7.5, 30.5pt tall, corner about 6.5pt,
  0.5pt border. "Open in" dim (#9495A4 on Arc's box), the space name bright and bold, a "⌘O" keycap 15.5pt tall,
  a divider, then a 16pt chevron 6pt from the right edge ("reveals more 'Open In' destinations"). The box fill was
  #040832 on a purple space; whether it is derived from the space colour is unverified.
- Strings: the NUX "Links Open in Little Arc" with "Click Open in … to move this page in a full window, or ⌘W to
  close"; "Opens your current Little Arc tab in the Space of your choosing"; window title "Little Arc " + page title.
- Menu: File › "New Little Arc Window" ⌥⌘N, identifier `newLittleBrowserWindow`, action `showLittleArc`
  (MainMenu.nib); read through AX by Gabe's session.
- Setting: Preferences → Links, "Links from other apps open in Little Arc", key `openExternalLinksInLittleBrowserEnabled`
  (in the defaults key table at `FUN_1005a2c1c`). Gabe's value is 1. The registered default wasn't found in the
  binary; Kite defaults it on, since Arc shows the "Links Open in Little Arc" NUX on the first external link
  (`littleBrowserNUXPresentationCount`).

Kite's differences: no profile indicator (no profiles) and no extensions button in the pill; the chevron is a plain
menu of spaces, not Arc's searchable `LittleBrowserMoveMenuWindow`; no downloads tray; no auto-archive of Little
windows ("Archive Little Arcs after:"); no global hotkey.
## History, ⌘Y (Arc 1.171 menu bar and strings, 1 Nov 2026)

- Menu (read from Arc's menu bar through AX, nothing pressed): **Archive** › Go Back ⌘[, Go Forward ⌘], —,
  **View History** ⌘Y, View Archive…, Clear Archive.
- Arc's shortcut list describes ⌘Y as "Opens your History in a new Today tab"; its action id is `viewHistory`.
  The strings also hold `chrome://history`, so the tab is Chromium's own history page, not an Arc view.
- Kite's CEF (Alloy style) has no chrome://history, so Kite draws a native page over a blank tab at
  `kite://history` (`HistoryPageView`), following Chromium's history page: search, day cards headed
  "Today - Saturday, October 31, 2026", rows with time, icon, title and site, and a per-row menu. Sizes are
  Kite's; Chromium's page wasn't measured in Arc.

## Windows: New Window ⌘N, Blank Window ⌃⌘N (Arc 1.171 menu bar and strings, 1 Nov 2026)

- Menu (read through AX, nothing pressed): File › New Tab… ⌘T, New Window ⌘N, Blank Window ⌃⌘N, New Incognito
  Window ⇧⌘N, New Little Arc Window ⌥⌘N. Action ids `newWindow`, `newBlankWindow`.
- Window kinds (AX identifiers in the strings): `bigBrowserWindow`, `bigIncognitoBrowserWindow`,
  `standaloneBrowserWindow`, `littleBrowserWindow`; window types `standard`, `incognito`, `little`,
  `standaloneSidebar`; `SidebarContext` coding keys `Global`, `Standalone`, `Incognito`;
  `StandardWindowState`, `FocusedSpaceCodingKeys` and `SidebarSpaceState` live in `SharedWindowFeature`.
  Read as: normal windows share the global sidebar and keep their own focused space; a blank window is a
  standalone-sidebar window whose tabs are titled "Explore" ("Title for Explore tabs in a standalone-sidebar
  window"), archived with source `standaloneSidebar`, and movable to the global sidebar
  (`MoveItemsToGlobalDestinationConfiguration`).
- Restore: setting "When opening Arc, restore windows from previous session" (`windowRestorationSetting`,
  `restoreWindowsOnNextLaunch`); Arc's `NSQuitAlwaysKeepsWindows` is 1 on Gabe's Mac.
- Not observed (only one Arc window was open): which space and tab a new window opens on, whether Arc opens
  the command bar (`showCommandBar` is among `initialAppearanceActions`), the blank window's look, and what
  Arc does when two windows select the same tab (`ContentPlaceholderSourceData` hints at a placeholder).

## Hover cards / 5-Second Previews → `LinkPreview` (KiteCore), `LinkPreviewController` (Arc 1.171 binary, 1 Nov 2026)

Strings, settings key names and disassembly only (`~/rea-arc/arc-strings.txt`, `~/rea-arc/decomp/arc.s`, selector
stubs resolved through `__objc_stubs`/`__objc_selrefs`). Arc wasn't touched, and Gabe has the feature off
(`hoverCardsEnabled` = 0), so nothing was recorded on screen.

- What it is: an Arc Max feature, "5-Second Previews: speedy summaries when you hover and hold Shift over any link"
  (strings ~75914, ~80521). Module `HoverCards`: `HoverCardsController`, `HoverCardWindow`, `HoverCardPopover`,
  `HoverCardView` with `TitleView`, `BannerImageView`, `LinkView`, `SnapshotView`, `SummaryView`, `LoadingView`,
  `ShareButton`, `DetailRow` (~41980–42033). The summary is AI: a prompt asks for JSON with `quickSummary` (3–8
  words), 2–4 `details` (label, SF Symbol icon, 5–10 word info) and `blocked` (~80907). Footer "AI Summary by Arc
  Browser"; failure text "No preview available". Instant (no ⇧) cards on supported domains: news.ycombinator.com,
  X tweet links, Google results (CSS selectors listed at ~80920). Settings key `hoverCardsEnabled`.
- Trigger: the event handler takes `modifierFlags` (device-independent) `== 0x20000`, ⇧ alone, OR'd with the
  supported-domain check (`0x1020b7c40`). The local event monitor mask is 0x401022: left mouse down, mouse moved,
  flags changed, scroll wheel (`addLocalMonitorForEventsMatchingMask:` at `0x1020b6474`).
- Timing: the hover publisher is debounced `.milliseconds(100)` (`0x1020b5a10`); other strides 0.05 s and 0.15 s in
  `beginTracking(url:)`; an `asyncAfter` of 0.2 s (`0x1020b7374`); the window fades with `NSAnimationContext`
  duration 0.15 to alpha 1 (`didLoad(request:)`, `0x1020b97ec`). Card content: `spring(response 0.4, damping 0.75,
  blend 0.1)`, `easeIn(0.15)`, scale from 0.8 (0.001 for a centred anchor), offsets ±30.
- Geometry: `.frame(maxWidth: 300, maxHeight: 400)` (800 when anchored at centre) (`0x1020a2e70`); rounded rectangle
  radius 12, continuous (0 in one mode) (`0x1020a2950`); shadow black 12 %, radius 6, x 2, y 2 (`0x1020aa96c`);
  banner image frame 149.5 or 100 tall with radius 6. The window is the card frame inset by −30 on each side
  (`CGRectInset` at `0x1020ba04c`), borderless, clear, not opaque, `animationBehavior` none, added as a child window.
  While the card is open the mouse handler builds an `NSBezierPath` from the card's corners (24pt past its edge)
  and keeps the card while the pointer is inside it (`0x1020b7d24`–`0x1020b7e50`). A second path shows it in an
  `NSPopover` (`.transient`, `showRelativeToRect:… preferredEdge: maxY`).

Kite's slice: ⇧ alone over a link (WebKit's private `_webView:mouseDidMoveOverElement:withFlags:userInfo:`, which
also gives the link's box; Chromium's `OnStatusMessage`, at the pointer), 100 ms debounce, then a 300pt card 8pt
below the link (above when there's no room), max 400 tall, radius 12, Arc's shadow, 30pt window inset, 0.15 s fade,
spring scale from 0.8. It shows the page's og:image, title, description and site, read from the page's `<head>` with
no cookies. Closes 0.2 s after the pointer leaves the link unless it's in the link-to-card corridor (24pt slack), on
a click, scroll, Esc or other key, or when the window resigns key. Inferred, not from Arc: the 8pt gap, left-edge
alignment, flipping, the popover material and 0.5pt border, fonts (Arc's view uses 11–16pt sizes; which goes where
is unknown) and the `linkPreviewsEnabled` default (off, as Arc's `hoverCardsEnabled` and Gabe's Arc; Kite menu › Link Previews turns it on).

## Still unknown

- The default intensity of a new theme, and the system material Arc puts under it, which sets the blur radius.
- The ⌘T panel's exact shadow parameters (only its effect was measured).
- Arc's default sidebar width, light-theme fill opacities, and the space-switch animation timing.
- The space swipe's physics and settle, and what Arc's space strip shows (see *Spaces*).
