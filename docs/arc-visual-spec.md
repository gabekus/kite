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
| New tab row | Rows below slide 41pt down; the new row fades in | 0.12s on (0.25, 0.1, 0.25, 1), RMS 0.018 | Same (`SidebarRowsAnimator`), traced: 0.12s on that curve, plus a 0.12s opacity 0→1 on the new row |
| Closed tab row | The row fades out in place while the rows below slide 41pt up over it | Same curve, RMS 0.011 | Same, traced: 0.12s slide, 0.12s opacity 1→0 on the closed row |

### Sidebar rows (Arc 1.171, 1 Nov 2026)

- **Mechanism** (the Arc 1.169 binary in the existing Ghidra project, `~/rea-arc/decomp/out6`; recorded on 1.171): the sidebar is an `NSOutlineView` fed by
  `ARCUI.OutlineViewDiffableDataSource`. `applySnapshot(_:animatingDifferences:)` runs
  `NSAnimationContext.runAnimationGroup` with `setDuration:` 0.12 and no timing function of its own (so the
  default, (0.25, 0.1, 0.25, 1)), and inside it `beginUpdates`, the diff, `endUpdates`. Inserts pass
  `NSTableViewAnimationEffectFade` (1). Removals pass `effectFade | slideUp` (0x11), or `effectFade` alone when a
  count in the diff is under 2 (what it counts isn't pinned down). Moves use `moveItemAtIndex:` in the same group.
- **Recording** (Arc incognito window, a ScreenCaptureKit capture of the sidebar at 120Hz, test pages only,
  frames under `~/rea-arc/recordings/tab-anim`): a tab added by AppleScript at the top pushed the rows below 41pt down
  in about 0.11s; a selected tab closed by AppleScript faded in place while the next row slid up over it, and the
  selection pill jumped to the next tab at once and slid with it. Fits: 0.12s on the default curve, RMS 0.018 (insert)
  and 0.011 (close); easeInEaseOut fits at 0.034 to 0.040.
- **Not observed:** the × button and ⌘T paths (both go through the same snapshot, but weren't recorded), the
  `slideUp` case on removal, and a drag reorder.
- **Kite:** SwiftUI's `List` inserts and removes rows with no animation even inside `withAnimation` (a logging build
  showed options 0, outside any animation group), so `SidebarRowsAnimator` gives the sidebar's table Arc's group and
  options after any state change that adds, removes or moves rows. SwiftUI makes a new row's view after the table has
  animated, so the new row gets its own 0.12s opacity animation on the group's curve.

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
- Quit with downloads running: "Downloads in progress" (see its own section below).

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

## Archive: View Archive…, Clear Archive (Arc 1.171 menu bar and strings, 1 Nov 2026)

- Menu (AX, nothing pressed): Archive › … View History ⌘Y, **View Archive…**, **Clear Archive**, neither with a
  shortcut. Action ids `viewArchive`, `clearArchive` (arc-strings.txt ~34940, 34985). Descriptions: "Opens the
  Archive, where all your closed tabs live.", "Clears all tabs in the Archive." (~80672, 80735).
- Storage: `StorableArchive` / `ArchivedItem` with `archivedAt`, `ArchiveReason`, `ArchivedItemSource` (~38820,
  74723); Kite now stamps `archivedAt` and a reason (manual / auto) on each archived tab.
- The view lives in Arc's Library ("Arc Home"): `HomeButton/Pages/Archive/ArchiveReducer.swift`,
  `ArchiveContentView.swift`, `ArchivePage.swift` (~82492–82516). Strings there: sections "Today", "Yesterday",
  "Earlier This Week" (~82481–82490; `ArchiveUiTimeBucket`); filter button "Filter Archived Tabs" with
  `line.3.horizontal.decrease.circle`, groups "Where was the tab?" (space, plus Little Arc) and "How was the tab
  closed?" ("Auto-Closed", "Manually Closed"), active filters as "Remove %@ Filter" chips (~82455, 82509–82516);
  search empty state "No results found for …"; row accessory buttons Restore (`arrow.uturn.left`) and Delete,
  the same two in a row's menu ("Restore/Delete menu item in archive page"); empty state "Nothing here yet!" /
  "Hover your mouse over a tab and press the [×] to archive it."
- Restore toast "Tab restored to <space>" (with a ". Click to view." variant), so Restore puts the tab back in its
  space without switching to it (~76150). Clear: "Are you sure you'd like to Clear Archive?" / "This action is
  permanent." (~82747), then a toast confirming the clear (its text isn't in the strings; Kite says "Archive
  cleared").
- Inferred or unverified: headings past "Earlier This Week" (Kite groups by month); the unfiltered page title
  (string value missing; Kite says "Archive"); what a plain click on a row does (Kite opens the page, like
  History); where in the space a restored tab lands (Kite: its old position); the Delete icon (Kite: trash); all
  sizes. Kite has no Little Arc filter (Little Kite doesn't archive).

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

## Peek → `LinkPeek` (KiteCore), `LinkPeekView`, `BrowserWindowController+LinkPeek` (Arc 1.171 binary, 1 Nov 2026)

Arc's Peek is `ModalContent.ModalV2HostView` in its `popover` layout mode (the cases are `popover`, `fullbleed`;
arc-strings.txt ~166470). Decompiled in `~/rea-arc/decomp/out2/objc-setShadowRadius.txt` (FUN_101717e60),
`objc-setCornerRadius.txt` (FUN_101716678), `objc-setShadowOpacity.txt` (FUN_101713230) and
`out5/peek1-3.txt` (FUN_101715a98, FUN_101716134, FUN_101717608, FUN_1017156ac, FUN_100a05154, `mouseDown:`).
Not to be confused with Kite's sidebar peek (`Peek`, `PeekCard`), the hidden sidebar's hover reveal.

- Routing (strings ~80486): "Open a Peek window when clicking on links to other sites", "Note: This only affects
  Favorites and Pinned tabs", "Open a Peek window when clicking on links with Shift held". The shift setting is
  `disableShiftClickToOpenLinksInModal` (absent from Gabe's defaults, so shift-click peeks). How Arc defines
  "other site" isn't in the strings; Kite compares registrable domains (`SignInHandoff.site`). **[inferred]**
- Card (FUN_101715a98): 80% of the host's width, centred, 12pt from its top and bottom (height − 24). Kite's
  host is the content card's area. Whether Arc's host is the content card or the whole window: **unverified**.
- Corner radius 8 (popover; 10 fullbleed) (FUN_101717608, FUN_101716678).
- Shadow (FUN_101717e60): black, opacity 0.3, radius 4, offset (0, 1) in the flipped host (fullbleed: 0.475, 22, (0, 14)).
- Border view behind the card: frame outset 0.5pt, white fill, 2pt border, black at 0.25 alpha (faded by the
  swipe-to-dismiss tug: (1 − tug/44) × 0.25) (FUN_101717730). Kite draws a 0.5pt black@25% hairline.
- Buttons (`onClose`, `onExpand`, `onAddToSplit`; FUN_101716134): a column 120pt wide, 13pt right of the card,
  top-aligned with it, 90pt tall with two buttons and 135pt with three (so 45pt a row). The split button shows
  only when the parent can take another pane (`numberOfPanels < maximumNumberOfPanels`), titled "Create Split
  View" or "Add to Split View" with `square.split.1x2` (strings ~75323). Hidden, the column sits under the
  card's right edge (x = card.maxX − 120) and slides out. The buttons' size, fill and the close/expand symbols
  and titles are **not measured**: Kite uses 30pt circles, `xmark`, `arrow.up.left.and.arrow.down.right`,
  "Close", "Open as Tab".
- Dismiss (`DismissMechanism`, ~166430): escapeKeyPressed, clickedCloseButton, clickedBackground (host
  `mouseDown:` outside the card in popover mode), pressedCloseTabHotkey (⌘W), swipedRightToDismiss, redoClose.
  Help text: "Exit the current context. Such as closing a Peek window or exiting fullscreen."
- Motion (FUN_101713230 + FUN_100a05154, a `CASpringAnimation` built from a damping ratio and response:
  stiffness (2π/response)², damping 4π·ratio/response): popover open 0.865 / 0.245s, close 0.895 / 0.225s
  (fullbleed 0.885 / 0.18, 0.9 / 0.18). The transform tweens from the source (`tweenFromSource`:
  `sourceRectInWindow`, `sourceCornerRadius`, `sourceSnapshot`), scale = source width / card width
  (FUN_1017156ac). Kite has no link frame, so it grows from 20% at the pointer and fades in over 0.1s **[differs]**.
- Not built yet: the peeked item in the sidebar (`peekedPinnedSidebarItemID`, `ModalV2SidebarBadgeView`),
  swipe right to dismiss (`minimumDismissTranslation`, `tugRubberbanding`), undo "re-opening a closed Peek",
  the dismiss confirmation for unsaved pages (`awaitingDismissConfirmation`), any scrim behind the card.
## Pinned URL reset and Reveal Tab (Arc 1.171 menu bar and binary, 1 Nov 2026)

- Tabs menu (AX, read-only, `menudump`): … Next Tab ⌥⌘↓, Previous Tab ⌥⌘↑, Reveal Tab in Sidebar (no key), —,
  Item 1/2/3, Clear Today ⇧⌘K, Reset all tabs in this Space (no key). No "reset tab" item in any menu.
- Binding names and descriptions (`arc-strings.txt`): `resetTab` 34996, "Reset tab to original URL." 80755;
  `resetSpace` 34981, "Resets all your pinned tabs in the current Space." ~80729; `revealTabInSidebar` 67594,
  "Reveals the current tab in your Sidebar." 80697. Menu title comment: "Title to reset Pinned Tabs while on a
  focused list" 62244.
- Model: `savedURL` (66907), `TabNavigatedAwayFromSavedURLHeuristic` (44184), `copySavedURLFromOriginalTab`.
- Row state (`Browser/Sidebar/SidebarCells/TabCellState.swift`, fields at 149996): `canResetTab`,
  `resetTabTitle`, `resetTabIcon`, `resetItemShortcut`. In the disassembly (`decomp/arc.s` 707906 and 888387)
  the two `resetTabTitle` values sit side by side with one comment ("String that describes the action of
  going back to a website"): "Back to Pinned URL" and "Separate From Pinned Tab". The same file has the
  fallback title "Pinned URL" ("Fallback title for a page's pinned URL title").
- Context menu strings (`SidebarMenu+MoveMenu.swift` area, 84933): Edit Pinned Page / "Edit the pinned URL",
  "Replace Pinned URL with Current" (built later, see "Edit Pinned Page" below).
- Kite: `BrowserTab.pinnedURL` (set when a tab is pinned or favorited, cleared when unpinned; old sessions take
  the current page), `BrowserState.resetTab`, `resetPinnedTabs`, `separateFromPinnedTab`, `revealTab`
  (`KiteCore/PinnedURL.swift`).
- Inferred, not observed: the navigated-away rule (Kite ignores fragment, trailing slash, `www.` and
  http/https); the reset icon (`arrow.uturn.backward`) and its place left of the close button on hover;
  "Separate From Pinned Tab" as a context-menu item (in Arc it is an alternate title of the same button, the
  trigger unknown); Reveal opening enclosing folders and showing a hidden sidebar; no highlight on reveal
  (TabCellState has `shouldPerformUserAttentionAnimation` and `tabHighlightState`, use unknown). Arc had no
  window open, so none of this was seen on screen.
## Edit Pinned Page: Edit… and Replace Pinned URL with Current (Arc 1.171 binary, 1 Nov 2026)

Strings and disassembly only (`~/rea-arc/arc-strings.txt`, `~/rea-arc/decomp/arc.s`; short titles are Swift
immediates decoded from the `mov`/`movk` pairs before each `NSLocalizedString` call). Arc wasn't touched.

- Submenu: `SidebarMenu+TabContextMenu.swift` builds a submenu titled **Edit Pinned Page** (comment "Title of
  pinned URL submenu", `0x102ec7348`) behind a condition on the item (`b.ne` at `0x102ec7310`, not decoded), and
  fills it from one function (`0x102eb73c0`, its only caller is `0x102ec7498`): **Edit…** (immediate, comment
  "Edit the pinned URL") and **Replace Pinned URL with Current** (comment "Replace the Pinned Tab with the current
  page"). Both items are built with the same arguments and no branch between them, so Replace is always listed.
- Dialog (`SharedWindowFeature/WindowData+Dialogs.swift`, `0x10292b86c`–`0x10292bc54`), built like Arc's Rename
  Tab… dialog next to it: title **Edit Pinned URL** (comment "Title of Edit Pinned URL dialog."), a line **This is
  what opens first when you click this tab or its favicon.** (passed as the text field's first argument; Rename
  passes nil there), a field with placeholder **Enter a URL…** holding the URL, and buttons **Save** ("Button that
  updates the pinned URL") and **Cancel**. A 392.0 constant sits in the call that shows it (the width, inferred).
- Command bar (not built): "Replace Pin with Current Page" ("Action to replace a pinned tab with a different url")
  and "Replace Pinned Tab with the Current Site" (strings ~79423, ~79443).
- Kite: `BrowserState.editPinnedURL(_:to:)` (a URL or bare host, never a search: `URLInput.url`),
  `replacePinnedURLWithCurrent(_:)`, `hasPinnedURL(tab:)` (`KiteCore/PinnedURL.swift`); `EditPinnedPageMenu` in the
  pinned tab row's and favorite tile's context menus; the dialog is an `NSAlert` sheet like Kite's Rename Tab….
- Inferred, not observed: favorites get the submenu too (Arc has one tab context menu and favorites keep a pinned
  URL); the submenu's place in the menu; Save leaving the tab on its current page (so "Back to Pinned URL" then
  offers the new one); what Arc does with input that isn't a URL (Kite beeps and keeps the old one).

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

## Rename tab and Collapse Pinned Tabs (Arc 1.171 menu bar, strings and disassembly, 1 Nov 2026)

- View menu (AX, nothing pressed): "Collapse Pinned Tabs", no shortcut, right after Show Toolbar ⇧⌘D. Strings
  "Collapse Pinned Tabs" / "Expand Pinned Tabs" (menu item titles), selectors `collapsePinnedSection:` and
  `expandPinnedSection:`, `collapsePinnedSectionEnabled`. State: window data key
  `spacesWithCollapsedPinnedSections` (per space), `PinnedSectionExpansionState`, toggle sources
  `PinnedSectionToggledSource`, sidebar action `didClickPinnedTabsExpansionToggler`, AX id
  `sidebarSpacePinnedTabsExpansionToggler`. The space header view has `pinnedSectionExpansionState`,
  `chevronContainerView`, `chevronWidthConstraint` and `chevronView`, so the toggle is a chevron in the header.
- Rename: the sidebar item menu has "Rename…" (comment "Rename a tab"), decoded from Swift small-string
  immediates near `ContextMenus/SidebarMenu+PlatformGeneration.swift` in `~/rea-arc/decomp/arc.s`
  (around line 12252170). Command-bar action "Rename Current Tab…" ("Action to rename current tab in the
  sidebar"), action id `renameCurrentTab` (`RenameCurrentTabCodingKeys`), shortcut-list description "Rename the
  current tab." (arc-strings.txt ~80753); not in the menu bar and no default key found. Dialog
  (`WindowData+Dialogs.swift`, arc.s ~`0x10292bfa0`): title "Rename Tab…", placeholder "Keep it short and
  sweet!", buttons "Rename" and "Cancel". In-place hint "Double-click to rename" ("Subtitle shown on tab with
  hint on how to rename tab", `RenameTabHint`, `WindowData+RenameHints.swift`).
- Kite: in-place edit in the row (Rename…, double-click, or the command when the sidebar shows); Arc's dialog
  when the sidebar is hidden or the tab is a favorite or split pane. The name lives in `BrowserTab.customTitle`.
- Inferred, not observed (Arc's sidebar was hidden in every open window, and Arc isn't driven): the chevron's
  place and look, that it shows on hover, that a collapsed section still shows the selected pinned tab (Kite
  does, as Arc's collapsed folders do), whether Arc's in-place editor selects the text, what an empty name
  does (Kite goes back to the page title), the hover hint's timing (not built), and whether Arc keeps the
  collapsed set per window (Kite saves it with the shared sidebar).
## Import from Arc: what Arc keeps where (Arc 1.171 files, defaults and strings, 1 Nov 2026)

Key names and structure only, read from Arc's files in ~/Library/Application Support/Arc; nothing of the
user's is copied. Test fixtures are made up.

- `StorableSidebar.json`: a split view is a sidebar item whose `data` is `splitView` with `layoutOrientation`
  (`horizontal` / `vertical`), `focusItemID`, `timeLastActiveAt` and `itemWidthFactors`, a flat
  `[itemID, factor, ...]` list (Swift's encoding of a dictionary with non-string keys). On Gabe's Mac it held
  one entry for a two-pane split, so Arc may leave panes out; Kite gives missing panes what's left of 1
  (inferred). Children are the panes' tab items, in order.
- `StorableArchiveItems.json` (`version` 1): `items` is a flat `[id, object, ...]` list. Each object has
  `archivedAt` (seconds since 2001), `reason` (`manual`, `auto`, `clearButton`), `source` (`space` with the
  space ID in `_0`, `littleArc`, `unknown`) and `sidebarItem`, a sidebar item whose `data` is `tab`
  (`savedURL`, `savedTitle`, `timeLastActiveAt`). Only tab items were seen.
- History is Chromium's: the `urls` table of `User Data/Default/History` (`url`, `title`, `visit_count`,
  `last_visit_time` in microseconds since 1601, `hidden`).
- Defaults (`company.thebrowser.Browser`, names and plain booleans only): `shouldWarnBeforeQuitting`,
  `openExternalLinksInLittleBrowserEnabled`, `nativeAdBlockEnabled`, `topBarURLEnabled` (booleans), and
  `autoArchiveTimeThresholdsPerProfile`, a JSON string `{"thresholds":[...]}`. The list was empty on Gabe's
  Mac (Arc's default), so the element encoding (profile, then a case name such as `sevenDays`, next to
  `thresholds` in arc-strings.txt ~165658) is inferred.
- `StorableLinkRouting.json` holds Air Traffic Control rules (`rules[].sourceComponents[].componentType.urlMatch`,
  `destination.space`). Kite has no link routing yet, so it isn't imported.

## View › Developer: Inspect Elements, JavaScript Console, Network Inspector (Arc 1.171, 1 Nov 2026)

- Menu (menudump, AX, nothing pressed): View › Developer = View Source ⌥⌘U, Developer Tools ⌥⌘I, Inspect
  Elements ⌥⌘C, JavaScript Console ⌥⌘J, Network Inspector (no shortcut), Allow JavaScript from Apple Events,
  Turn on Developer Mode for this site ⌃⌥⌘D.
- Strings (`~/rea-arc/arc-strings.txt`): action ids `inspectElements`, `javaScriptConsole`, `networkInspector`
  (~176572); shortcut descriptions "Opens the element inspector.", "Opens the JavaScript console." (~80689) and
  "Opens the network inspector developer tool." (~80758); analytics `devToolsInspectElementsOpened`,
  `devToolsJavascriptConsoleOpened`, `devToolsNetworkPanelOpened` (~160538).
- Mechanism in Kite (not Arc's code): Chromium's DevTools frontend embedder API, the calls Chrome makes for
  ⌥⌘C/⌥⌘J (`DevToolsAPI.enterInspectElementMode()`, `DevToolsAPI.showPanel('console' | 'network')`; both names
  are in CEF 156's binary), run in the DevTools page after it calls `InspectorFrontendHost.loadCompleted()`.
- Not observed in Arc (would need pressing its menu): whether Arc's DevTools is docked or a window, and which
  panel Arc's picker leaves showing. Kite keeps its own DevTools window.

## Split View: top/bottom layout and drop-to-split → `SplitLayout.swift` (KiteCore), `SplitDropZonesView` (Arc strings and 1.169 decompile, 1 Nov 2026)

Arc wasn't driven; nothing here is from a recording.

- **Orientation** [str]: `SplitViewLayoutOrientation` is `horizontal` / `vertical` (arc-strings.txt ~156440); one split is one row or
  one column. Kite already stored and rendered both (`SplitView.orientation`, `SplitPanesView`); this adds ways to get a vertical one.
- **Command bar actions** [str, arc-strings.txt 68850–68852 and 79417–79456]: IDs `newVerticalSplitView`, `convertToVerticalSplitView`,
  `convertToHorizontalSplitView`; titles "Add Vertical Split View", "Convert to Vertical Split View", "Convert to Horizontal Split
  View"; trigger phrases "New Vertical Split View", "Flip to vertical/horizontal split view". They aren't in MainMenu.nib's View menu, so
  Kite keeps them as hidden menu items the command bar still finds (MainMenu's `commandBarOnly`, marked with `CommandBarKeywords`). Kite matches titles only, not the
  trigger phrases. **Inferred:** Add Vertical Split View on a side-by-side split turns it top/bottom (a split has one orientation).
- **Drop a link on the content** [str + dec]: the window-contents split delegate has `onDropURL`, `onDropSidebarItem`,
  `onDidUpdateSplitViewProposedDropTarget` and `onDidAdjustLayoutOrientation` (arc-strings.txt ~176689). `ARCUI.SplitViewController`
  registers its view (a `DraggingDestinationForwardingView`) for two pasteboard types (@100a496f8). Its `draggingEntered:` (@100a54404)
  runs only with `allowInteractivePaneInsertion` on, asks the delegate whether to take an outside drag, and sizes the proposed pane
  as **width / (panes + 1)** by full height. Fields `dropRegion`, `dropRegionInsertionIndex`, `insertContent` / `replaceContent`,
  `verticalLayoutOrientationFromDragAllowed`, `shouldDisplayDraggerPaneForSecondaryAxis` (~155594). The placeholder is
  `SplitViewContentPlaceholderView.BorderView`: border **2**, corner **6** (@1001da6d0; colour set by the caller, not traced).
- **Kite:** four 64pt strips along the content card's edges take a dragged http(s) link (not files). A single page takes all four edges
  (left/right → side by side, top/bottom → top/bottom); a split takes only the two ends of its own axis; four panes take none. The
  new pane gets an equal 1/(n+1) share and focus. The strips answer hit tests only while the mouse button is held after the click,
  so clicks and hovers reach the page (checked with `ui pointer` / `ui input`).
- **Unverified / guessed:** the strip width (Arc's drop regions weren't traced), the placeholder colour (Kite uses the accent colour,
  12% fill), whether Arc also lets a centre drop replace a pane (`replaceContent`), and whether Arc turns a side-by-side split into a
  top/bottom one on a top/bottom drop (Kite refuses it).

## Split View: geometry and motion → `ArcMetrics.Split`, `SplitPanesView` (Arc 1.171 incognito capture + 1.169/1.171 decompile, 1 Nov 2026)

Sources: **[cap]** one Arc incognito window (2056×1285pt, dark) on local fixture pages, View › Add Split View pressed through AX,
recorded with a ScreenCaptureKit stream of that window only (frames every ~17–25ms) plus `screencapture -l`; **[dec]** Ghidra on
`~/rea-arc/decomp/Arc-arm64` (`ARCUI.SplitViewController`).

- **Gap = divider** [cap + dec]: 10pt between panes (pane 1 ends at x 1163, pane 2 starts at 1173, at 2×). `SplitViewController`'s
  init sets `draggerHandleWidth` = **10.0** and `draggerHandleHitTargetOutset` = **0** (@100a50820), so the divider's hit area is
  exactly the 10pt gap. The gap shows the window background (sampled #0d0e11, the same as the sidebar).
- **Pane cards** [cap]: each pane is its own card, inset 10pt from the window's top, right and bottom and starting at the sidebar's
  edge, like a single page; all four corners of every pane are rounded, including the corners facing the divider (same radius as
  the single-page card). Two panes split the width evenly (873.5pt each of 1757).
- **Grip** [cap + dec]: 2×24pt, centred in the gap (pixels x 2333–2336, y 1261–1308 at 2×), white ~18–20% on the dark window
  (sampled ≈#373739 on #0d0e11): matches `DragHint` and the decompiled 2×24 / corner 1 pill.
- **Minimum pane width** [dec]: `minimumPaneWidth` = **220.0** (@100a50820; ARCUI's default, no other writer found).
- **Centre snap** [dec, pan handler @100a50d3c, 100a51b90–100a51c4c]: while dragging, the divider's offset from the middle of its two
  panes is `position − pairLength × 0.5`; under **14pt** it snaps to the middle. Entering the snap plays
  `NSHapticFeedbackManager` alignment feedback (the call also checks the drag's velocity against 120pt/s; Kite plays it on entering the
  snap regardless).
- **Double-click on a divider** [dec, @100a51d34 → closure @100a52084]: both panes beside it get half their combined share
  (`fmul 0.5`), the others are untouched; the layout update runs animated (`@100a49224(1,1,1)`): `NSAnimationContext` duration
  **0.2s** (0x3fc999999999999a), timing **easeOut**, `allowsImplicitAnimation` (@100a4ffd8).
- **Dragging** [dec]: the pan handler relayouts with animation off (`@100a49224(0,1,0)`): panes follow the pointer, no easing.
- **Add Split View** [cap]: no animation. The first frame after the menu press already has the final two-pane layout; the only motion
  afterwards is the new pane's command bar appearing.
- **Kite**: gap 10, grip unchanged, minimum pane 220, the 14pt centre snap with an alignment haptic, and double-click to even out a pair
  animated 0.2s ease-out. Adding and closing panes stay instant.
- **Not observed / unverified**: closing a pane (View › Close this Split Pane) and adding a third pane were pressed but Arc had lost
  the front by then and didn't act, so their motion isn't recorded (Kite keeps them instant, like add); a real divider drag (needs the
  real pointer) and the cursor/hover zone (no pointer sweep on Arc: the hit width is from the decompile only); filling the new pane from
  its command bar (Arc's bar ignores an AX value + AXConfirm, and the window had lost the front before a Return could reach it).

## Library: Open Library… ⇧⌘L (Arc 1.171 menu bar, strings, MainMenu.nib, assets, 1 Nov 2026) → `LibraryView`

Nothing in Arc was pressed or opened; Arc's Library itself was never on screen, so no geometry was measured.
- Menu (AX, read-only): Window › … Remove Window from Set, —, **Open Library…** ⇧⌘L, **View Downloads…** ⇧⌘J,
  **View Easels…**, **View Media…**, **View Boosts…**, —, Bring All to Front. Archive › View Archive… (no shortcut).
- MainMenu.nib (`strings`): item "View Library", ids `openLibrary` / `viewLibrary`, SF Symbol `archivebox`, search
  title "Library"; the downloads item `openDownloads` / `viewDownloads` with `arrow.down.circle`; the actions are
  `toggleLibrary:`, `toggleDownloads:`, `viewArchive`, `viewEaselsAndNotes:`, `viewScreenshotsAndCaptures:`, `viewBoosts`.
- In the browser window, not a window of its own: `Arc/WindowState+Library.swift` (arc-strings.txt ~61918); the main
  window controller holds `homeViewComponent`, `homeWidth`, `$__lazy_storage_$_homeSidebarMenuController` next to
  `sidebar`, `windowContentsContainer` and the paging controller (~149539–149560, ~150100–150113); window action
  `preloadHome` (~176459). The Library has its own page list (`HomeButton._AnimatedPageSidebarItemView`,
  `PageSidebarItem.swift`, ~82466) and an exit control ("Button; Exit the Library", "Menu item title to exit the
  Library", ~62220, ~82547). Kite draws it over the window's sidebar and card, which fade out under it.
- Pages (`HomePageID`, ~82334–82342): `EaselsAndNotesPage`, `DownloadsPage`, `ArchivePage`, `MediaPage`, `BoostsPage`,
  `SpacesPage`; Lottie icons in ARC_HomeButton.bundle: easels, downloads, archive, screenshots, boosts, spaces
  (128×128, 60 fps). No History page: Arc's history is ⌘Y, chrome://history in a tab. Kite lists Downloads, then
  Archive, in that enum order; the on-screen order of Arc's list is inferred from the enum.
- Remembered page: `lastSelectedHomePage` in StorableHome.json (`HomePreferencesClient`); Gabe's value is
  `DownloadsPage`. Kite keeps `LibraryLastPage` in its defaults with Arc's raw values.
- Downloads page copy: empty state subtitle "Come back after you've found some cool stuff to save." (title value not in
  the strings), "Filter Downloads" with a profiles section (Kite has no profiles, so no filter).
- Colours (ARC_HomeButton Assets.car): Foreground / 2 / 3 black or white at 1, 0.6, 0.45; Background / 2 / 3 at
  0.07–0.20; `LibraryItemOutline` black 0.03 / white 0.08. Not applied yet: Kite's pages keep their own colours.
- Inferred or unverified: the transition, all sizes, the exit control's look and label (Kite: "Exit Library" with an
  arrow at the bottom of the list), page icons (Kite: SF Symbols), and whether Arc leaves the Library when a tab is
  selected (Kite does). ⇧⌘J still opens Kite's downloads popover, though Arc's copy says it "Opens the Downloads
  section of your Library": follow-up.

## Expand Current Split (Arc 1.171 menu bar; Arc 1.169 binary, decompiled; 1 Nov 2026)

- View menu (AX via `menudump`, nothing pressed): Add Split View, Close this Split Pane, Separate Page from
  Split View, **Expand Current Split**: no shortcut. MainMenu.nib: selector `maximizeCurrentSplitViewPane:`,
  no key-binding ID; the command bar's ID is `expandSplitViewPane`, icon `arrow.up.left.and.arrow.down.right`,
  search terms "Expand; Expand Split View; Maximize" (`~/rea-arc/notes/split-view.md` §2).
- Mechanism (Ghidra, `~/rea-arc/decomp/ghidra`): `MainWindowController.maximizeCurrentSplitViewPane:`
  (@10031b87c) only posts a notification. The window contents controller observes it
  (`maximizeFocusedSplitViewNotificationToken`; registered in FUN_1004842f4, handler FUN_1004856b8) and calls a
  split view controller method with `animated: true` and a per-pane closure (FUN_1004859cc) that returns
  width factor **1.0 for the pane whose content ID is the focused one and 0.0 for every other pane**.
- So the panes all stay in the split (unlike Separate); the focused one fills it. The handler reads no
  state, so running it again does nothing new: it isn't a toggle.
- Validation (`MainWindowController` menu validation, arc.s ~805743 / Ghidra FUN_102952338): the item is
  enabled when the window's split has more than one pane (`count > 1`), whether or not it's expanded.
- How Arc brings the other panes back, and the animation's duration, weren't traced; no string for
  "Collapse"/"Restore" split exists. `ExpandedCodingKeys` belongs to other types (not split view).
- Kite: `SplitView.expandedTabID` (per split, saved, decodes as nil from older sessions); the stored
  `widthFactors` are left alone and the layout uses 1/0 (`layoutFactors`). The hidden panes and dividers are
  hidden. Running it again does nothing, as in Arc. Inferred, so the user is never stuck: focusing another
  pane of the split, dragging a divider, adding a pane, or closing the expanded pane brings the split back
  with its old widths. The change is immediate (Arc animates; duration unknown).
## Capture → `CaptureOverlayView`, `BrowserWindowController+Capture`, `KiteCore/Capture` (Arc 1.171, 1 Nov 2026)

Nothing in Arc was pressed or watched: menu bar read through AX, the rest from the binary, its strings and
ARC_Capture.bundle's asset catalog. Line numbers are `~/rea-arc/arc-strings.txt`; addresses are Arc-arm64.

- Menu: File › Share…, Capture…, Capture Full Page, Capture in Portrait Mode, Save Page As, Print, no
  shortcuts (menudump). Shortcut ids `capturePage`, `captureFullPage` (34939, 34995, in the shortcut-id list
  beside `addSplitView`, `archiveTab`); descriptions "Capture a part of the page, then save it or add it to an
  Easel.", "Capture full page.", "Capture in Portrait Mode." (80669–80754). Also "Hold Command and Shift to
  start a Capture." (80630, setting `dragToCaptureDisabled`).
- Area: tooltips "Click or drag to capture a portion of this page" / "Drag to capture a portion of this page"
  (79199–79202) in `ContentCaptureOverlayBubble`; views `ContentCaptureView`, `DimmedBackgroundView`; cursor
  image `camera-cross-cursor` (53×50 pt). Colour assets (ARC_Capture.bundle): BlurredBackground light white
  33%, dark black 25%; OverlayBubbleBlue P3 (0, 0.278, 1, 0.5); OverlayBubblePink P3 (1, 0.6, 0.6, 0.5);
  OverlayBubbleText P3 (0.204, 0.021, 0.58); ImageViewBackground white / sRGB (0.082, 0.11, 0.188);
  Background white / (0.071, 0.059, 0.18). Clicking captures a hovered element
  (`WebContentState+HoveredCapture.swift`).
- After an area capture Arc shows `contentCapturePopover` (`ContentCaptureViewController`: `CapturedImageView`,
  `CapturedImageActionsView`, `CaptureImageMenuView` for Easels). Action descriptions: copy, save as a file,
  send via iMessage, retake, edit (62280–62287). Copy toast "Copied Image" (immediate string at 0x1018e4b10,
  case `captureCopied`).
- Save (FUN_100421970): `NSSavePanel` sheet, PNG only, title "Save Capture Image", name "Capture-" +
  `yyyy-MM-dd-HHmmss` + ".png".
- Full page (`handleCaptureAction(_:)` in WindowState+Capture.swift, from 0x1001ffbec): toast "Capture in
  Progress", a Combine delay `FullPageCaptureDelay` of 0.5 s (0x100201f54), the PNG written to
  `NSFileManager.temporaryDirectory` + a name built from the title with `[^a-zA-Z0-9\-_ ]` removed and the
  date format `'·' h.mma '·' MM-dd`, then toast "Screenshot Copied to Clipboard" with a button "to save the
  screenshot copied to a file" (76207–76209); failures "Failed to Save" (`failedToSaveCaptureToDisk`).
- Portrait Mode: settings `portraitCaptureBackground` ("Use Website Color" / "Use Desktop Wallpaper"),
  `portraitCaptureColorPercentage`, `portraitCaptureHidesWatermark`, image `ArcCaptureWatermark`; its frame,
  padding and output size weren't found, so Kite doesn't have it yet.
- Inferred, not seen: how the title and date join in the full-page name (Kite: "Title · 3.45PM · 11-01.png"),
  the Save button's title (Kite: "Save"), that the clipboard gets the image and the file, the popover's layout and
  button styles, the selection outline (Kite: 1 pt white 90%), where the hint bubble sits, and what the 0.5 s
  delay is for.

## Developer Mode for a site, ⌃D (Arc 1.171 menu bar, strings, assets and defaults key names, 1 Nov 2026)

- Menu: View › Developer › "Turn on Developer Mode for this site", AXMenuItemCmdModifiers 12 (⌃, no ⌘) on D,
  last in the submenu after Allow JavaScript from Apple Events (`menudump View`). The off title is "Turn off
  Developer Mode for this site" (arc-strings.txt 62211–62214). Command name `toggleDeveloperMode` (67583).
- State: per host. `DeveloperModeClient.setDeveloperModeStatusForHost` (73577), stored in
  `StorableDeveloperModeState.json` as `state.enabledHosts[]` (key paths only read), app state
  `developerModeEnabledForHosts` (64267). Kite keys by the URL's lowercased host without the port (inferred
  from "ForHost"; Arc's port handling not checked).
- What it changes, from the strings: `BrowserNavigationButtons` has `isInDeveloperMode` and `reloadState`
  (150804) and buttons `reloadButton`, `thinReloadButton`, `forceReloadButton`, `reloadOptionsButton`
  (150778–150781). Its strings (62987–62994): "Refresh options button" / "A button that shows a list of reload
  options.", "Refresh (Ignore Cache)", "Clear Cookies and Refresh", `devModeReloadState`, "Reload this page".
  `DeveloperTabReloadSetting` lives in `BrowserNavigationButtonsFeature.swift` with cases `reload`,
  `forceReload` (82636–82638, 176095–176096); persisted as the user default `devModeReloadState`.
  Assets: `icon-browser-navigation-reload` 26×26, `icon-browser-navigation-force-reload` 22×15 (a loop ending
  in an arrow down to a bar). Site Controls also has a Developer Mode row with on/off subtitles (63725,
  73687–73688); the subtitle text isn't in the strings dump.
- Not found: nothing ties Developer Mode to a console pane, an error indicator or a full-URL/port display
  (the full URL is the separate toolbar setting `toolbarShowFullURLsEnabledPreference`). Kite builds only what
  the strings show.
- Inferred, not seen: the options button sits right of reload as a chevron (Kite: 16×32 menu button, reload
  shifts left); picking Reload or Refresh (Ignore Cache) both does it and makes it the button's action, with a
  checkmark on the current one; Clear Cookies and Refresh is one-shot. Arc's geometry in Developer Mode was not
  measured (no Arc window was in Developer Mode, and Arc isn't driven).
## Print ⌘P (Arc 1.171 menu bar, strings and ArcCore, 1 Nov 2026)

- Menu bar (`menudump File`): the last item of the File group is **Print**, no ellipsis, ⌘P (mods=0).
  Kite's item is now "Print" too (it was "Print…").
- `arc-strings.txt` 34978 `printPage` (key binding name), 80726 its description "Prints the current page, or save
  it as a PDF.", 176531 `printCurrentTab` (command), 190604 `printPage:` (the menu action; `decomp/arc.s`
  805358 only checks it in menu validation). No `printOperation`, `NSPrintOperation`, `NSPrintPanel`, `PDFKit`
  or `PrintPreview` in Arc's own binary: Arc doesn't build its own print sheet.
- ArcCore (Arc's Chromium) has Chromium's print stack, including its print preview: `PrintPreviewUI`,
  `chrome://print`, `printing.print_preview_disabled`, `runModalWithPrintInfo:` (the system dialog), and
  locale.pak has the preview's strings ("Save as PDF", "Pages per sheet", "Print using system dialog").
  So Arc's ⌘P most likely opens Chromium's print preview (a dialog over the page, with "Save as PDF").
  Not observed: Arc wasn't driven.
- Kite (`printPage(_:)`, `makePrintOperation`): the standard macOS print sheet on the window, with a page
  preview, on both engines. WebKit gives `WKWebView.printOperation(with:)`, paged to the paper's width like
  Safari. Chromium prints the page to PDF over DevTools (`Page.printToPDF`, the sheet's paper size, Chrome's
  0.4 in margins, no backgrounds or header/footer) and PDFKit prints that. CEF's own `Print()` for a child
  browser opens an app-modal panel with no preview, which is what Kite had before.

## Site Control Center → `SiteControlsView`, `SiteControlsPopover` (Arc 1.169 binary + masked probe, 1 Nov 2026)

Sources: `~/rea-arc/arc-strings.txt` 73677–73738 (module `SiteControlCenter`: `SiteControlCenterActionButton`,
`…BoostsView`, `…ExtensionsView`, `…SettingsView`, `…FooterView`, `SiteSetting+Display.swift`), 63716–63727, and
62174–62181 / 63025 ("Site Control Center" button label). Short English strings are Swift immediates, decoded from
`~/rea-arc/decomp/arc.s` at the `NSLocalizedString` calls next to each comment string (e.g. 0x10137d758, 0x1013722f4,
0x10055d594). Geometry: `~/rea-arc/notes/extensions.md` (masked probe, the 262×486 popover) and
`~/rea-arc/notes/arc-visual-pass2.md` (toolbar sliders icon). Arc was not driven for this.

- Opened by the "Site Control Center" button: in the toolbar (the sliders icon), and in the sidebar URL row a 30×30
  button revealed on hover at the row's right end (pitch 28, after a 16-char "Copy Current URL" button).
- Popover 262 wide, hosting view inset 13, sections 10 further in (216 wide). Top to bottom: four 48.75×32.75 action
  buttons on a 56 pitch (tooltips: Copy URL, Share, Capture / full-page capture / Portrait Mode, New Boost; assets
  `copy-url`, `share`, `window-screenshot-icon`, `capture-full-page`); Boosts and Extensions sections; a "Settings"
  section (header 216×17, hover text "More") of 208×33 rows on a 43 pitch; a footer with an 82×32 security button
  ("Secure" / "Insecure", `lock.fill` / `lock.slash.fill`) and a 32×32 `ellipsis` menu: Clear Cache, Clear Cookies,
  Manage Boosts…, New Boost, Manage Extensions…, Add Extension…, All Site Settings….
- Settings rows (`SiteSetting+Display`): "Block Ads & Trackers" subtitled On / Off; "Developer Mode" On / Off;
  "Block Pop-ups" (asserts "Popup blocking is not supported in Arc."); "Preview" (sidebar preview) Enabled /
  Disabled; permissions subtitled "Allowed" / "Blocked". Permission names come from
  `ArcPermissionRequestType+Utils` ("camera", "microphone", "location", "notifications", … lower case); how the
  row capitalises them wasn't seen. A row click sends `didChangeSiteSetting`. Symbols in the settings view:
  `shield.fill`, `hammer.fill`, `filemenu.and.cursorarrow`, `gearshape.fill`.
- Toolbar placement (probe): popover top 4pt above the bar's bottom (y 38), right edge on the window's right edge.

| | Arc | Kite (measured with `kite ui tree` / `kite probe`) |
|---|---|---|
| Popover | 262 wide, hosting inset 13 | 262 wide, hosting 236 at 13 |
| Action buttons | 48.75×32.75, pitch 56, 23 from the popover's left | 49×33, pitch 56, at 23 |
| Settings rows | 208×33, pitch 43 | 208×33 (same row view, measured before the Kite-only Zoom row was removed), pitch 43 |
| Footer | 82×32 left, 32×32 right, both 23 from the edges | Same |
| From the toolbar | top y 38, right edge = window's | top 38, right edge 1280 of 1280 |

Kite differs: no Boosts, capture, Developer Mode or sidebar preview; extensions stay in their own popover; action row
has only Copy URL and Share; the Settings rows are Arc's Block Ads & Trackers plus four permission rows, shown
always (Arc's choice of rows wasn't observed); a permission that's still at "ask" says "Ask". Row styling (icon
circle, fonts, hover fill) is Kite's: Arc's text and pixels weren't read.

## Site permission prompt → `PermissionPromptView`, `PermissionPromptCard` (Arc 1.171 binary, 1 Nov 2026)

Sources: `~/rea-arc/arc-strings.txt` 41475–41484 and 79942–79967 (module `PermissionRequests`:
`PermissionRequestState`, `PermissionRequestAction`, `PermissionRequestDialogView`, `PermissionRequestPopoverView.swift`),
63660–63713 (`ArcPermissionRequestType+Utils` display names), 171998 / 176424 (`permissionRequest` beside
`siteControlCenter` and `translateBubble` in the window's state), 194633 (`webContents:willAskForPermission:withRequests:…`).
Short strings are Swift immediates decoded from `~/rea-arc/decomp/arc.s`; the rest is Ghidra output of the functions
named below (read-only run of `DumpAround.java`). Arc wasn't driven, and no prompt was open to probe.

- Text (0x101eb9934): one request: "Allow %@ to access your %@?" with the lower-case type name (`camera`, `microphone`,
  `location`, `notifications`… from 0x10055b8ac–0x10055bd38); notifications alone: "Allow %@ to send you notifications?"
  (also "…download multiple files?", "…store files on your device?", "…know when you're actively using this device?",
  "Make %@ your default mail app?"). Several requests use the access sentence with a joined list (the join, 0x101eb9848,
  wasn't read; Kite writes "camera and microphone"). The site is its title or "this website"; the site part gets its
  own font and colour (an attributed string, 0x101eba00c).
- Buttons (0x101eb6c50, 0x101eb6cf0): "Allow" ("Button to allow permission") and "Not Now" ("Button to deny
  permission"). No "Block", "Don't Allow" or "Remember this decision" strings exist.
- Footer (0x101eb7acc): "Click the lock to change this any time", with the word "lock" replaced by the `lock.fill`
  symbol as a text attachment.
- Icon (0x101eb82b0): the request type's icon (single request), a shared icon for several.
- Placement, from Little Arc (`LittleWindowViewController.permissionRequestView`, 0x10002b8d4): a
  `PermissionRequestDialogView` with corner radius 12, content insets 4 on every side, a 5 pt value (read as the
  shadow radius) and a black shadow at 0.2; pinned leading and top to the page container at static constants + 8 (the
  constants weren't read). It appears with 0x101cb203c: scale 0.8 → 1 about its left-middle point plus opacity 0 → 1,
  0.1 s ease in-out. Where the main window puts it wasn't found in the binary; Kite uses the same card at the page's
  top-leading corner.

| | Arc | Kite (measured with `kite ui tree` / `trace`, Chromium build) |
|---|---|---|
| Card | radius 12, inset 4, shadow black 0.2 r5 | radius 12, inset 4, shadow black 0.2 r5 |
| Position | page container leading/top + (constant + 8) | page top-leading + 8 (card at 352,18 on a page at 344,10) |
| Appear | scale 0.8 about left-middle + fade, 0.1 s ease in-out | same (trace: 0.1 s, curve 0.42,0,0.58,1, x fixed at 352) |

Kite differs: the card's width (300 + insets), fonts, icon circle and button styles are Kite's (Arc's SwiftUI body
wasn't read); "Not Now" stores Block for the site (Arc's response type for it wasn't read; its footer says the choice
can be changed later, so it reads as a stored answer); the site is named by its host (and port), not its title; only
camera, microphone, location and notifications are handled, other types keep Chromium's default; no prompt over a
Peek; on WebKit only camera and mic, asked every time.

## Mini Player and auto picture in picture → `MiniPlayerView`, `MediaStateScript` (Arc 1.171 strings, assets, disassembly, 1 Nov 2026)

- Modules (arc-strings.txt 82066-82130): `MediaControlsFeature` (`MiniPlayerFeature.swift`, `MiniPlayerView.swift`,
  `MediaControlsView.swift`, `MiniPlayerState+Observations.swift`) and `PictureInPicture` (`PIPWindowController`,
  `DocumentPiPWindowController`). Mini player media types `AudioVideo` and `Recording` (43012). Actions
  `toggleMuteStatusRequested`, `backToTabRequested`, `backToPIPRequested`; state `activeMediaControls`,
  `maxActiveMediaControls`, `miniPlayerMarqueeTitleEnabled` (174040-174130).
- Strings in `MiniPlayerView.swift`: "Close Mini Player", "Open Picture in Picture", "Back to Tab", "Adjust Tab Volume",
  "Toggle Microphone", "Toggle Camera", "Previous Track", "Next Track", "Play"/"Pause" (tooltips).
- Disassembly (`~/rea-arc/decomp/arc.s` 9577000-9600000, the MiniPlayerView/MediaControlsView bodies; constants read off
  `fmov`/`mov` before each SwiftUI call):
  - card: `RoundedRectangle(cornerRadius: 8, style: .continuous)`, stroke 0.5 pt, `Color.white.opacity(0.1)` in dark,
    clear in light; rows `frame(height: 33)` with `padding(.horizontal, 10)` (title row) and `8` (controls row);
    `GeometryProxy` width compared with 160 and 126 (controls dropped when narrow).
  - title row: artwork/favicon 16×16 clipped to radius 4 in a 24×24 frame; title Text; `pip` symbol at 12 pt and `xmark`
    at 14 pt, whose opacity/width switch 0↔1 / 0↔24 (shown on hover).
  - controls: 24×24 buttons, 16×16 symbol frames, `Font.system(size: 14, weight: .medium)`; symbols `backward.end.fill`,
    `play.fill`/`pause.fill`, `forward.end.fill`, `speaker.slash.fill`/`speaker.wave.1/2/3.fill` (+ Slider for volume),
    `mic.fill`/`mic.slash.fill`, `video.fill`/`video.slash.fill`.
  - `MediaControlsView`: height 33, `Animation.spring(response: 0.25, dampingFraction: 0.9)`.
  - `PlaybackControlForeground` (ARC_MediaControlsFeature.bundle Assets.car): light black 50%, dark white 66%.
- Auto PiP settings (key names only): `autoPipGloballyDisabled` (absent from Gabe's defaults, so off: auto PiP on),
  `autoPipDisabledForHosts`, `autoPipDisabledDeadlines`, `useChromiumAutoPiP`, `useChromiumAutoPiPForGMeetOnly`,
  `autoPictureInPictureOnWindowOccluded`; PiP window toggle "Open automatically" next to "Picture-in-picture on <host>".
- Not observed (no Arc mini player was on screen; Arc wasn't driven): its position in the sidebar (Kite puts it above
  the space bar), the card fill colour (Kite uses the address field's fill), the title font (a CTFont; Kite uses 12 pt
  medium), button hover fills, which controls drop at 160 / 126, and whether closing the player pauses (Kite pauses).


## Check for Updates (Arc 1.171 Info.plist, menu bar and strings, 1 Nov 2026)

- Menu (read through AX, nothing pressed): Arc › … Import from Another Browser…, **Check for Updates…** (no
  shortcut, enabled), then a separator and Services.
- Mechanism: Sparkle (`Contents/Frameworks/Sparkle.framework`; `SPUUpdater`, `SPUUpdaterDelegate` in the strings).
  Info.plist: `SUFeedURL` = an appcast on releases.arc.net, `SUPublicEDKey` (EdDSA-signed updates),
  `SUEnableAutomaticChecks` = 1, `SUAutomaticallyUpdate` = 1, `SUScheduledCheckInterval` = 28800 (8 hours).
- Arc draws its own Sparkle UI (`SoftwareUpdaterClient.CustomUserDriver`, `UpdaterWindowView`, `UpdaterStatusView`,
  `ReleaseNotesView`; arc-strings.txt around lines 80110-80250): "Checking for updates..." with a cancel button;
  "Your browser is up to date"; "A new version is available" (fallback title) with release notes and buttons to
  install, download, or "remind me to download and install the update later"; on an error, "Download manually";
  "Ready to Install" / "Install and Relaunch".
- Sidebar banner: `SidebarBanner` cases `UpdateAvailableBanner` / `UpdateCompleteBanner`
  (`SoftwareUpdateBannerUpdateAvailableView`, `…V2View`, `…UpdateSummaryView`), "Update available",
  settings keys `autoUpdateBannerDismissalCount`, `canShowUpdateBanner`, `currentUpdateAvailableSince`. A dialog
  "Arc is ready to update!" / "Restart required." also exists (lines ~61403-61407). Not observed on screen.
- Kite: no release pipeline, notarisation or appcast yet, and gabekus/kite has no GitHub releases (1 Nov 2026), so
  Kite › Check for Updates… asks `api.github.com/repos/gabekus/kite/releases/latest`, compares the tag with
  CFBundleShortVersionString (`AppVersion` in KiteCore) and shows Arc's states in a small window
  (`UpdaterWindow`): checking, up to date, no releases yet, a new version (notes, Remind Me Later, View Release,
  Download when a .dmg/.zip is attached, opened in a Kite tab), and errors (Download manually, Try Again). Window
  size and layout are Kite's; Arc's updater window wasn't measured. No background checks or banner yet.

## Air Traffic Control → `AirTrafficControl` (KiteCore), `AirTrafficControlWindow` (Arc 1.171 binary strings and disassembly, 1 Nov 2026)

Sources: `~/rea-arc/arc-strings.txt` and `~/rea-arc/decomp/arc.s` (short SwiftUI string literals decoded from the
`mov`/`movk` immediates in `PreferencesFeature/LinkRoutingDialog.swift`'s code, around 0x10200bd38–0x1020155xx).
Arc was not opened or driven, so no geometry was measured.

- Module `LinkRouting` (`LinkRoutingClient.swift`, `LinkRoutingEditor.swift`), saved to `StorableLinkRouting.json`
  (strings 67179, 80045–80055). Client API: `currentState`, `stateStream`, `addRule`, `updateDefaultDestination`,
  `updateState`.
- Model, from the reflection field names (strings 170798–170819) and coding keys (41563–41578):
  `StorableLinkRoutingState { version, rules, defaultDestination }`;
  `LinkMatchingRule { sourceComponents, destination }`; `LinkSourceComponent.componentType` has one case,
  `urlMatch`; `LinkSourceTextMatchingStyle` is `matches` | `contains`; `LinkDestination` is `space` | `littleArc`
  | `profile` | `mostRecent`.
- **No source-app condition.** The only component type is `urlMatch`, and no sender/source-app string appears
  in the module, so routing by the app a link came from isn't in this Arc. Kite doesn't build it.
- Editor actions (strings 170798–170808): `addRule`, `updateDestination`, `updateTextMatchingStyle`,
  `updateTextMatchingPattern`, `delete`, `updateDefaultDestination`, `onUpdateFocusedRuleId`, `onClose`.
- Dialog views (41821–41831): `LinkRoutingDialog`, `DefaultRuleView`, `LinkMatchingRuleView`,
  `LinkMatchingRuleComponentView` (`showPlusButton`, `title`, `iconName`), `LinkMatchingRuleDestinationView`,
  `LinkMatchingRuleDestinationPickerView`.
- Dialog text: "Air Traffic Control", "Routes let you choose where specific sites open inside Arc. For example,
  you can route Spotify links to always open inside your Personal space.", "New Route", "Default", "URL" with
  SF Symbol `link`, "Is equal to" / "Contains", placeholder "arc.net", "Open in", "Little Arc", "Open in Space",
  "Most Recent Space", symbols `airplane.circle`, `arrow.turn.down.right`, `minus.circle.fill`, and a Done button
  (`onClickDone`). Opened from Preferences → Links → "Air Traffic Control…" and the command bar action
  `openAirTrafficControl` ("Action to open Air Traffic Control routes.").
- Analytics enums: `LinkRoutingWindowType` littleArc / mainWindow / customSpace, `LinkRoutingURLMatchType`
  equals / contains, `LinkRoutingRuleChangeType` added / removed / changed (strings 69697–69701, 161652–161656).
- Settings key: only `openExternalLinksInLittleBrowserEnabled` in Arc's defaults; the routes and default live in
  the JSON file. Kite treats an unset default as that setting (Little Kite when on, Most Recent Space when off).
- Inferred, not found in the binary: rules are checked in order and the first match wins; a rule's several URL
  components match when any one does; "Is equal to" compares the site (host without www.) or the whole link
  ignoring scheme, www. and a trailing slash; "Contains" is a case-insensitive substring of the link; a route to a
  deleted space is skipped; only http(s) links are routed. Kite has no profiles, so there's no profile destination.

## Boosts (Arc 1.171, read 1 Nov 2026)

Sources: `~/rea-arc/tools/menudump Window` (AX, nothing pressed), strings in `Contents/Resources/Base.lproj/MainMenu.nib`
and `~/rea-arc/arc-strings.txt` (line numbers below), asset names from `ARC_BoostsEditor.bundle/Assets.car`.

- Menu bar: Window › **View Boosts…** (no shortcut), after View Downloads…, View Easels…, View Media…. Its copy
  says it opens the Library's Boosts pane (arc-strings ~62221).
- MainMenu.nib also has **New Boost** (`newBoost`, outlet `newBoostMenuItem`) and **Edit Boost** (`editBoost`)
  with the command-bar keywords "Boost; New Boost; Create boost; extension; Boost the Current Page; Edit Boost",
  and **Boost Gallery** (`openBoostGallery`). None of the three shows in the menu bar (menudump), so they're
  command-bar actions (Arc also has a `hiddenMenuItem` outlet, ~149700).
- Other entry points: the site control centre's Boosts section with a new-Boost button and a "Manage Boosts"
  footer item (~73700–73727), and a context menu titled "Customize Page" (~84895). Not built in Kite.
- Editor: its own window (`BoostsEditorWindowController`, ~73423) with a code input panel
  (`BoostsEditorCodeInputPanel`, `CodeType`), the JS placeholder "your javascript here", buttons "Refresh this
  Page", "Rename this Boost", "Delete this Boost", "Show/Hide Developer Tools" (~73396–73407). The v2 editor
  serves code from `arc://boost/v2/css/` and `arc://boost/v2/js/` (~73420). Colour wheel, font, text size/case
  and Zap/selector picker controls are the rest of the editor (`BoostsEditor*`, ~37700–37818).
- Delete asks "Delete this Boost?" / "Deleting a Boost can't be undone." (~61502–61507). Rename has its own
  alert with cancel and done buttons (~61510).
- Library page: empty state "Nothing Boosted Yet!", row buttons delete, rename, disable, enable (~82519–82525).
- Storage: `StorableBoostsData.json` and a `localBoostsData` directory, `locallyEnabledBoostIDs` (~67162,
  ~71519). Applied per page by `BoostsClient.applyToWebContent` / `WebContentState+Boosts.updateBoosts(for:)`;
  a Boost "will run only on" its site (~82390). "Boosts can't be installed or used in Incognito Mode" (~61492).

Kite (`KiteCore/Boosts.swift`, `KiteMac/BoostsModel.swift`, `Views/BoostsViews.swift`): code Boosts and zaps, in
`boosts.json` (each Boost has `css`, `js` and `zaps`; see Zap below). Inferred, not seen in Arc: the domain is the host without `www.` and matches exactly; CSS goes in
at document start and JS runs at DOMContentLoaded, in the page's world, top frame only; New Boost is offered on
any web page and Edit Boost opens the site's newest Boost; the new Boost's name is its domain (Arc's default
title string is inlined, so unknown); the editor's sizes and layout are Kite's (Arc's weren't measured). Kite
leaves out a Boost's JavaScript when it doesn't parse (shown under the editor), since its document-start
scripts share one source with the ad blocker's.

## Sound effects → `SoundEffects` (KiteCore), `SoundEffectPlayer` (Arc 1.171 strings, files, defaults and disassembly, 1 Nov 2026)

- Setting: "Play Arc sound effects" next to "Haptic feedback when reordering tabs" (strings 80425–80426). Keys
  `playUserInterfaceSoundsDisabled` and `tabReorderingHapticsDisabled` (strings 64175, 64204), stored in Arc's
  defaults beside `machineID`, `hoverCardsEnabled` and friends. Neither key is set in Gabe's Arc, so both are at
  Arc's default: sounds on, haptics on. Kite's `soundEffectsEnabled` is on unless turned off.
- Sound files in `ARC_SoundEffects.bundle` (names and `afinfo` only; nothing copied): `capture.wav` (WAVE, 2 ch,
  48 kHz, 24-bit, 0.634 s) and `event.m4a` (AAC, 2 ch, 44.1 kHz, 3.52 s).
- One effect. `sound(forEffect:)` (SoundEffectClientImpl.swift, 0x101cb7c38) doesn't branch on the effect: it
  builds the URL for the small string "capture" with type "audio/vnd.wave" and caches the player by filename
  (`soundsByFilename`). Nothing loads `event.m4a` through this client; where it's used, if anywhere, wasn't found.
- Playing (0x101cb8190): get the player, `setVolume:` 0.7 (`0x3f333333`), play. The client also has `preload`,
  `setIsEnabled` and `isEnabled`.
- Who plays it: `WindowState` holds the `soundEffectClient` dependency, used from WindowState+Capture.swift (its
  unimplemented-dependency stub sits among the capture code, 0x10020b870). So the sound goes with Capture.
  Which capture paths play it (region, full page) and at what moment wasn't traced. Kite plays it, inferred, when
  either Capture… or Capture Full Page has the image.
- Kite's capture sound is its own, made in code (`SoundEffects.shutter`): two clicks 70 ms apart, each high-passed
  noise from a fixed-seed generator with a 6 / 9 ms exponential decay over a 210 / 160 Hz sine thump, 0.5 ms
  fade-in, peak 0.9, 48 kHz 16-bit mono, the same 0.634 s as Arc's file. Rendered to a WAV in memory at first use.
- Haptics: Arc's `tabReorderingHapticsDisabled` sits next to `dropHapticSubject` and `dropHapticSubscription`
  (strings 154777–154779; presumably the drop haptic when reordering). Not built in Kite: tab reordering belongs to the tab-drag work.
## Tidy Tabs → `TidyTabs`, `TodayTabGroup` (KiteCore), `TodayDivider`, `TabGroupHeaderRow` (Arc 1.171 strings and disassembly, 1 Nov 2026)

Nothing in Arc was pressed or run. The only open Arc window had its sidebar hidden, so no Arc geometry was measured.

- **Setting:** `tidyTabsEnabled` (arc-strings.txt 64303), toggled by `onToggleTidyTabsEnabled` (69096), feature id
  `tidy_tabs` (69679). Gabe's Arc: `tidyTabsEnabled = 1`, so Kite defaults it on (Kite menu → Tidy Tabs).
- **Button:** `SidebarTidyButton` with a `TidyTabsButtonImageView` (30863) in `UnpinnedSectionHeaderCellView`, the
  Today divider row, next to `SidebarClearButton`. Title "Tidy" (inline string at `0x100187624`, comment "Button
  Title; Tidy unpinned tabs in this space"), tooltip "Organize Today Tabs" ("Tooltip; Use LLM to organize unpinned
  tabs in this space", `0x100187548`). The button runs `rotationAnimation` / `rotationBackAnimation` on
  `transform.rotation.z` (`0x10030f9c4`). State: `canAutoOrganizeTodayTabs`, `shouldShowAutoOrgButton`,
  `autoOrgTabsEnabled` (176294–176317); action `onDidClickAutoOrganize` (176650). Clear Today's button option list
  includes `tidyAndClear` (176321).
- **Mechanism:** `WindowData+TabGroups.swift` `createUnpinnedTabGroups()` (`0x1029f13c8`) builds a prompt with
  "Here are my tabs, in the format 'id: title':" (`0x1029f15a0`) and asks for "Your array of group assignments, as
  valid JSON within a ```code block```:" (`0x1029f1678`). The rest of the prompt is an obfuscated string ("Failed
  to decode obfuscated string.") and wasn't decoded; Kite's prompt is its own. Leftover tabs go to a group named
  "Other" (inline `0x1029f2f6c`, comment "Tab group of miscellaneous tabs"). Error type `TabGroupingWithAIError`.
- **Result: headers, not folders.** Groups show as `TabGroupHeaderCellView` rows (sidebar item kind
  `tabGroupHeader`, 161196) in Today. Header menu "Remove header" (`0x102ecb8e0`, menu "Tab Group Context Menu"),
  undo "Remove Header" (`0x102a07b90`); a close button with tooltip "Close tab group" (`0x100048650`, "Tooltip for
  the button to close a group of tabs in the sidebar.", action `clearTabGroup`). Undo of a tidy is "Tidy Tabs"
  (`0x102a07ac4`, "Undo prompt for tidying explore tabs"). Toast "No tab groups found" (`0x1018e5af8`) when the
  model returns none. Analytics `auto_organize_tab_groups_completed`, `remove_tab_group_header_tapped`.
- **Kite:** the divider row shows a "Tidy" button while the pointer is on it (and spins while Claude works). It
  sends the unpinned tabs that aren't under a header (title and host, numbered, wrapped as untrusted) to Kite's
  built-in Claude (`claude -p --model haiku`, no tools, no session kept), then moves each group's tabs together,
  in the model's order, under a header. Tabs opened meanwhile stay on top. A header's tabs are members by id; the
  header sits above the first member and goes when its last tab leaves Today. Edit › Undo Tidy Tabs and Undo
  Remove Header restore the order and headers.
- **Kite's own, unverified against Arc:** the button's size, icon (SF `wand.and.stars`; Arc's image isn't known),
  colours and hover reveal; the header row's height (25, the divider's), font and close button; the minimum of 3
  tabs (`canAutoOrganizeTodayTabs`'s rule isn't in the strings); showing the divider row with no pinned tabs so the
  button has somewhere to be. Arc's Clear button on the same row isn't in Kite yet.
## Tidy Downloads → `TidyDownloads` (KiteCore), `DownloadTidier` (Arc 1.171 strings, defaults and disassembly, 1 Nov 2026)

Sources: `~/rea-arc/arc-strings.txt` 62139-62161, 76073, 76141-76144, 39896, 43295, 174650-174675, 160610, 73907,
75911; `~/rea-arc/decomp/arc.s` 738300-739230 (the request builder, in `AppState+OnDeterminingFilename.swift`);
`defaults read company.thebrowser.Browser` (key names and booleans only).

- Setting: `renameDownloadsEnabled` (Arc Max, "Auto-Renamed Tabs and Downloads"); **1 in Gabe's Arc**, so Kite's
  `tidyDownloadsEnabled` defaults on. Kite menu › Tidy Downloads (Rename with Claude) turns it off until there's a
  Settings window. Feature flag `rename-downloads-using-ai`.
- Request: `beginRename(browserContextID:downloadID:defaultFilename:sourceUrl:webContentsTitle:referrerTitle:)`
  sends the original filename, the source tab title and the source domain, asks for a "helpful, concise and
  readable" name of 2-4 words (keep informative names, drop IDs and "(1)"/"(copy)" cruft, shorten dates and drop
  seconds, fix casing and spacing, add context from the tab title when the name says nothing), answers as JSON
  `{newName}` in the user's language. Kite's prompt follows those rules in its own words and examples.
- Guard: Arc refuses an empty name or one starting with "." ("Tried to auto-rename file to empty filename or
  filename starting with '.'"). Kite also keeps the original extension exactly (tar.gz as one), strips `/ : \`,
  caps the name at 120 characters, and renames with `renamex_np(RENAME_EXCL)` to a free "Name 2.ext", so nothing
  is ever overwritten.
- Feedback: toast "Download renamed!" with an Undo accessory (`arrow.uturn.backward`,
  `DownloadRenamedToastContentOptions`); Undo shows "Download name reverted!". Kite reuses its toast with that
  symbol in the share button's place.
- When: Arc builds the request while Chromium determines the filename (`AppState+OnDeterminingFilename`), so the
  file lands under the new name. **Kite renames after the download completes** (the engines pick the path
  synchronously today), then shows the toast. Inferred, not verified: that Arc holds the download for the answer.
- Not built: Arc's sidebar banner for renamed downloads (`DownloadRenameItemState`, `didClickUndoDownloadRename`,
  `didDismissDownloadRenameBanner`), the `DownloadRenamePreview` settings illustration, rename analytics.
  Arc's model runs on its server; Kite's is Claude Code on the fast model (`claude -p --model haiku`, no tools, no
  MCP servers, 30 s limit).
## AppleScript dictionary → `Resources/Kite.sdef`, `AppleScript.swift` (Arc 1.171 sdef, Info.plist, nib, strings, 1 Nov 2026)

- `Arc.app/Contents/Info.plist`: `NSAppleScriptEnabled` 1, `OSAScriptingDefinition` `Arc.sdef` (read with
  `defaults read`). Kite's Info.plist now has the same two keys, pointing at `Kite.sdef`.
- `Arc.app/Contents/Resources/Arc.sdef` (197 lines, read only; Arc wasn't run and no script was sent to it), one
  "Standard Suite":
  - `make` (NSCreateCommand), `count` (NSCountCommand), `close` (`coreclos`).
  - `application` (`capp`): `windows` (cocoa key `appleScriptWindows`, front to back), `name`, `frontmost`,
    `version`, `quit`, and a write-only `tabs` element "to create new Little Arc tabs" (line 44).
  - `window` (`WiND`): `tabs` (rw), `spaces`, `id` (text), `name`, `index`, `closeable`, `minimizable`, `minimized`,
    `resizable`, `visible`, `zoomable`, `zoomed`, `active tab`, `active space`, `incognito`, `mode` ("normal" or
    "incognito", settable only when the window is made), responds to `close`.
  - Tab commands `select` (`CrSelect`), `go back` (`CrSuBack`), `go forward` (`CrSuFwd `), `reload` (`CrSuRlod`),
    `stop` (`CrSustop`), `execute` (`CrSuExJa`, parameter `javascript` `JvSc`, result text).
  - `tab` (`tAbB`): `id` (text), `title`, `URL` (rw), `loading`, `location` ("topApp", "pinned" or "unpinned").
  - `space` (`sPaC`): `id`, `title`, `tabs`; command `focus` (`SpaFocus`).
  Kite's sdef has the same classes, terms and four-character codes (descriptions rewritten), so an Arc script
  works after changing the application name.
- `arc-strings.txt` 63011 "Please provide a valid URL property for the make new tab command." (Arc's reply to
  `make new tab` without a usable URL): Kite's reply is the same.
- View › Developer (`menudump View`): Allow JavaScript from Apple Events is after Network Inspector, no shortcut.
  `MainMenu.nib`: action `allowJavascriptFromAppleEvents:`, no identifier (Network Inspector's is
  `networkInspector`), so Kite's item has no key-binding id. `decomp/out2/objc-setState.txt` 1536: menu validation
  sets the item's check mark from a stored value. ArcCore holds Chromium's pref
  `browser.allow_javascript_apple_events` (per profile, off by default in Chromium); no key for it in
  `defaults read company.thebrowser.Browser`. Kite keeps it per profile too (`BrowserState
  .allowsJavaScriptFromAppleEvents`, in session.json), off by default. Arc also has a launch flag
  `--enable-applescript-javascript` (strings 65137); Kite has no equivalent.
- Not found: Arc's error text for `execute` while the item is off (no such string in Arc or ArcCore). Kite's
  wording is its own ("Executing JavaScript through AppleScript is turned off…", error -1743).
- Inferred, not observed (Arc wasn't scripted): which tabs a window lists. Kite lists the sidebar's tabs
  (favorites, then the current space's pinned and unpinned tabs); a space lists its pinned and unpinned tabs.
  `make new tab` in a window opens it at the top of the unpinned tabs and selects it, like ⌘T. A window's `id`
  is its window number.
- Not in Kite yet: setting a tab's `location`, and the space `focus` command (spaces belong to another thread).
## Ask on Page → `AskOnPage` (KiteCore), `FindBar`, `AskOnPagePanel`, `AskOnPageClaude` (Arc 1.171 strings, defaults and disassembly, 1 Nov 2026)

- Setting: `askOnPageEnabled` (plain boolean, `defaults read company.thebrowser.Browser`) is **0** in Gabe's Arc, so
  Kite's `askOnPageEnabled` defaults off; Kite menu › Ask on Page (⌘F) turns it on, like Link Previews (#92).
  Preferences copy (arc-strings.txt ~80512): "Press Command + F on any page to ask a question and let Max answer it
  for you in seconds." So it lives in the ⌘F find bar, not a separate shortcut.
- Placeholder (disassembly `0x10214f664`, small-string immediates): feature off → "Find in page…"; on, not in a
  conversation → "Find or ask…"; in a conversation → "Ask a question…" (literal at `0x1039f4420`).
- Find vs ask (`0x10214f534`): with the feature on, a query that is non-blank after trimming whitespace and whose
  search finished with `numMatches == 0` is a question; otherwise it is one only while `isInConversation`.
  AskInPage state field names (arc-strings.txt ~172100): `numMatches activeMatchOrdinal quotesSearched
  isInConversation hasAnimatedIn messages fractionOfContextUsed startTime loading found notFound`; actions
  `onQueryUpdated onDidClickFindQuote onDidUpdateChat onDidRequestNextResult onDidRequestPreviousResult
  onShouldResetToFindInPage onDidAskLLM onDidRequestDismiss`.
- ⌘F inside the field: Arc's field is `CommandFTextField` with an `onCommandF` closure
  (`arc_performFindPanelAction:` at `0x100107e7c`). Kite: ⌘F while in a conversation goes back to find (inferred
  pairing with `onShouldResetToFindInPage`).
- Answer: `AskInPageConversationView` with `MessageView`, `QuoteView`, `FindQuoteButton`, `PulseModifier` (type
  names ~42130). Arc's model prompt (AskInPageChat.swift, ~81000) asks for a verbatim quote in `<excerpt>` tags on
  its own line, then a ≤10-word answer with the key term bold, Markdown, and saying when it's a guess. Kite's prompt
  is its own wording of that behaviour. UI strings used word for word: "Quote not found. Make sure it’s accurate!"
  (with `exclamationmark.triangle.fill`, `0x102154a24`), "Sorry, I encountered an error", "Sorry, I can’t read this
  type of page.", "This page was long, so I read the first …" (interpolated; Kite shows a percentage, inferred
  from `fractionOfContextUsed`).
- Inferred or unmeasured: the field clears after a question is sent (the "Ask a question…" placeholder implies it);
  the panel sits 6pt under the bar at the bar's width, 12pt padding, max 420pt tall, same navy as the bar (Arc's
  panel was never opened here, so none of its geometry, colours, fonts or animation is measured); Kite doesn't
  find-as-you-type while in a conversation; one question at a time. Arc's context limit is in tokens (Tiktoken);
  Kite sends the first 60,000 characters of `document.body.innerText`.

## Import from Another Browser → `BrowserImport` (KiteCore), `BrowserImportController` (Arc 1.171 menu bar, strings, assets, 1 Nov 2026)

- Menu (menudump, nothing pressed): Arc › Set as Default Browser, separator, **Import from Another Browser…** (no
  shortcut), Check for Updates…. Kite puts it just before Check for Updates…; the id `importFromAnotherBrowser` moves
  there from File › Import from Arc… (now `importFromArc`).
- Dialog (arc-strings.txt ~81440-81455, `ImportMenuFeature/ImportDialog.swift`): title "Import from your old browser",
  intro "Import everything you need from your old browser to hit the ground running with Arc."; a Safari screen titled
  "Import from Safari" with "To import Safari browser history, Arc will need Full Disk Access. Feel free to remove
  access when this step is finished." (~75751) and "After you have given access, you can choose to restart Arc now, or
  continue and restart later.", and buttons for back, restart, continue, "Continue without restarting" and cancel. The
  other button labels are deduplicated short strings, so Kite's ("Continue", "Cancel", "Restart Kite", "Open System
  Settings") are inferred. Arc's Safari screen has a drag-the-app drop target (`AuthFlowDropTarget*`,
  `SystemPreferencesVentura` assets); Kite opens the Full Disk Access pane instead. Arc also has a profile step ("Which
  Arc Profile should we import to?") and "Replace existing cookies…"; Kite has no profiles or cookie import, so
  neither is built.
- Per-browser lines (~75170): Firefox "history, autocomplete data, and bookmarks", Safari "history, passwords, and
  bookmarks", Chromium browsers "history, cookies, passwords, autocomplete payment info, and bookmarks". Kite's line
  names only what it imports: "Kite can import your history and bookmarks from X."
- Browsers (ARC_ImportFeature.bundle Assets.car names): Brave, Chrome, Edge, Firefox, Opera, Opera GX, Safari,
  Vivaldi. Kite reads all but Firefox, and lists only those with a profile on the Mac. Arc's order is unverified.
- Toasts (bytes read from the Arc binary): "Now importing… Sit tight!", "Success! We imported all of your stuff",
  "Only some of your data imported. Please try again!", "We weren’t able to import… please try again!".
- Mechanism: Arc runs Chromium's importer through ADK (`ADK/Browser+Import.swift`, categories `history`,
  `bookmarksAndFavicons`, `autofillFormData`, `notRecentHistory`; "Safari [a-z]+ database is unreadable for the
  importer"). It probes Full Disk Access with paths such as `/Library/Safari/Bookmarks.plist` (~75165). Kite reads the
  files itself and treats EPERM/EACCES on Safari's files as "needs Full Disk Access".
- Where bookmarks land: **inferred.** Arc's onboarding state holds `spaceTitle`, `selectedFavorites`,
  `importedFavorites` and `bookmarks` together (~166895), and its bookmark screen ("Bookmarks get an upgrade.",
  `BookmarksSelection`) picks folders from a tree. Kite puts them in a space named after the browser as pinned tabs,
  folders kept (collapsed); importing again replaces that space after asking.
- File formats (key names and counts only, read from this Mac; fixtures are made up): Chromium `Bookmarks` and
  `AccountBookmarks` JSON (`roots.bookmark_bar/other/synced`, nodes `type` url/folder, `name`, `url`, `children`);
  history is the `urls` table of `History`. Safari `Bookmarks.plist`: top-level lists `BookmarksBar`, `BookmarksMenu`,
  `com.apple.ReadingList` (left out) and a `History` proxy; leaves have `URLString` and `URIDictionary.title`.
  `History.db`: `history_items` (`url`, `visit_count`) and `history_visits` (`history_item`, `visit_time` in seconds
  since 2001, `title`), in WAL mode.
## Tidy Tab Titles → `TidyTabTitles` (KiteCore), `TidyTabTitlesController` (Arc 1.171 strings and defaults, 1 Nov 2026)

- What and when: Max pane copy (`~/rea-arc/arc-strings.txt` 80509) says tabs are "automatically renamed with tidier,
  shorter titles when you Pin them". Settings key `renamePinnedTabsEnabled` (64166; toggle
  `onToggleRenamePinnedTabsEnabled` 69092), feature flag `rename-pinned-tabs-using-ai` (73906), analytics
  `auto_renamed_pinned_tab` (70870). Gabe's Arc: `renamePinnedTabsEnabled = 1`, `arcMaxAutoOptInEnabled = 1`, so
  Kite's `tidyTabTitlesEnabled` defaults on; Kite menu › Tidy Tab Titles turns it off (until a Settings window).
  The search keyword for the setting is "tidy tab titles" (200328).
- Mechanism: `WindowState+AIRenameTabs.swift`, `AIRenameTabsFeatureState`, `AIRenameTabsAction`, `TabRenameAIError`
  (44027, 61275). The model is told it is bookmarking a tab and gets the title; rules (61279–61292): drop the site's
  name unless it's all there is, drop SEO cruft, stay specific, keep proper nouns with context, drop words naming the
  kind of page, keep subject/verb/object; reply JSON `filtered` (no limit) and `rewritten` (1–3 words), in the user's
  language. Kite words its own prompt with the same rules and uses `rewritten` (inferred: which field Arc shows was
  not traced in the disassembly; the 1–3 word one matches "shorter titles").
- The result is the tab's custom title: Arc's rename path is `updateCustomTitle(for:title:options:)` (82917ff), and
  "User renamed the tab before the automatic tab name could be generated." (82736) means a manual rename wins.
  Undoing it is the ordinary Rename (an empty name shows the page's title again). Kite also drops the name if the tab
  was unpinned before the reply.
- Not copied: `isAnimatingAiRename` (an animation on the title; not measured), `TidyTitleConfiguration` /
  `BundledTidyTitles` (per-site title rules from content.arc.net; data not inspected), the feedback report
  (`submitTidyTabTitleFeedback`, 82961). Model: Arc's provider isn't known; Kite uses Claude haiku, no tools.

## Instant Links → `InstantLinks` (KiteCore), `InstantLinksController` (Arc 1.171 strings and disassembly, 1 Nov 2026)

- **Key: ⇧⏎.** Arc's Max preferences description is stored XOR-obfuscated with the key "ObfuscatorString"
  (decoder at `0x1007f6b0c`, called from `MaxPreferenceViewController` at `0x102024720`/`0x102024758`; data
  `0x1045d9270` len 0x49 and `0x1045d92e8` len 0x25). Decoded, it tells you to press Shift + Enter on any web
  search to open the top result, and adds that you can search multiple queries. Arc's command bar text field
  has a `shiftReturn` command (strings 156140–156200: return, escape, backTab, optionReturn, commandReturn,
  shiftReturn, commandShiftReturn).
- **Setting:** `instantLinksEnabled` (strings 64169, 171070 `isInstantLinksEnabled`), one of the Arc Max
  toggles; Gabe's Arc has it on (`defaults read company.thebrowser.Browser`), so Kite defaults it on
  (`instantLinksEnabled` in Kite's defaults; no settings UI yet).
- **Mechanism (V1):** an obfuscated prompt (decoded at `0x1045e83d0`, call `0x102280578`) asks a model to turn
  the input into JSON `{title, queries[], format}` with format `tab` | `folder` | `split` (folder or split only
  when asked; one query unless the input asks for several things; `site:` added when a site is named). Kite
  uses the same schema with its own wording, run on Kite's Claude (`claude -p --model haiku`, no tools).
- **Top result:** `WebSearch/GoogleSearchEngine.swift` loads Google in hidden WebKit web content
  (`googleHiddenWebContentWebKit`, `document.documentElement.outerHTML`), reads results with `#search a`
  (also `#tvcap a`, `#topstuff a`, `#botstuff a`), unwraps `https://www.google.com/url?q=`, and detects captchas
  (`form[id='captcha-form']`, `iframe[title='reCAPTCHA']`, `div[id='recaptcha']`) (strings 200340–200375,
  83515–83535). Kite uses a hidden `WKWebView` the same way (`#search a` links that hold an `h3`), and follows
  Google's opaque `/goto?url=` redirect to the first page off Google.
- **Also in the binary, not built:** `InstantLinksResponseV2` with typed actions (web with a count, image, map,
  directions, flights, news, siteSearch on 15 named sites, history; URL templates at strings 81470–81495) behind
  remote flag `instant-links-v2-enabled`; an intent prompt (navigate vs search) behind
  `instant-links-intent-prototype-enabled` / `instant-links-suggestion-enabled` with a `SuggestionInstantLinksView`
  row; and a sidebar cell `InstantLinksCellView` (`links`, `favicons`, `linkCount`, `isExpanded`) plus an
  `instantLinks` item container. Which flags Arc's server turns on is unknown.
- **Inferred:** ⇧⏎ only for a search (a typed URL opens as usual) and not in Site Search; results open in
  query order with the first selected; what Arc shows while it works (probably the sidebar cell) is unverified.

## Zap → `Boost.zaps`, `ZapLibrary.css`, `ZapScript`, `ZapPickerScript` (KiteCore), `BoostsModel`, `LiveZaps`, `ZapPicker` (Arc 1.171 binary, strings and assets, 1 Nov 2026)

Sources: `~/rea-arc/arc-strings.txt`, `~/rea-arc/decomp/arc.s`, `ARC_BoostsEditor.bundle` (Assets.car, SelectorPicker.js;
read only for its function names, nothing copied).

- **Where it lives.** Zap is a tool inside Arc's Boost editor (`BoostsEditor` module: `SelectorPicker`,
  `SelectorPickerMode`, `HoveredElementTracker`, `PostClickOverlay`, `SelectorPreview`, `SelectorSpotlight`,
  `SelectorVisualizer`, `HighlightRect`, `PinToRectView`, `BoostsEditorShelfView`, `IndividualZapCell`; strings
  37721–37814). Editor actions include `showSelectorPicker`, `hideSelectorPicker`, `appendZap`, `removeZap`,
  `setZapToPreview` (163640–163700). The editor opens from the site control center's New Boost button and the page
  context menu's "Customize Page" › "Create a new boost" (73700–73727, 84896). No menu bar item or command bar
  action for Zap (menudump: only Window › View Boosts…, disabled).
- **Picker mechanism.** Native overlay over the web contents; page JS only answers geometry:
  `getHoveredElement({x: …})`, `getSelectorCandidates({x: …})`, `rectsForSelector(…)` (JS.swift strings, 73424–73428;
  the bundle's SelectorPicker.js defines these three window functions). Candidates are capped at 100 matches.
- **Text.** Shelf: "Click elements on the page to " + bold "Zap" + " them" (arc.s 0x1012eef9c: literal, then inline
  small strings `Zap` with `Text.bold()`, then ` them`). Post-click buttons: "Zap this" (inline small string at
  0x1012d8d04), "Zap all related elements", "Cancel" (0x1012d8d6c); in copy mode "Copy selector for this" /
  "Copy selector for related". Error: "Failed to run Zap JS". Editor button: "Hide Selector Picker".
- **Sizes and colours.** Post-click overlay `.frame(width: 250)` (0x1012d8960, 250.0). `ZapPreviewBackground`
  sRGB 0.851 grey (#D9D9D9) for zap cells; Boosts palette `BoostsRed` sRGB (1, 0.055, 0.055).
- **Storage and CSS.** Zaps are part of a Boost's data (`BoostData`, stored locally and in Firestore); applied as
  `<selector> { display: none !important; }` (BoostsClient string at 71515).
- **Kite.** Zaps are part of each Boost (`Boost.zaps` in `boosts.json`), as in Arc's `BoostData`. The Boost editor
  has a Zap button (tooltip "Zap", then Arc's "Hide Selector Picker" while it's open) that opens the picker over the
  page in the window the editor came from. A pick goes to the edited Boost, else the site's newest Boost, else a new
  Boost for the site (as New Boost makes one). The shelf lists and removes that Boost's zaps. The Boost script adds
  the site's zaps (Boosts that are on) as one `style[data-kite-zap]` at document start, top frame, page world; a
  zap, an undo or a Boost turned on/off or deleted replaces that style live in open pages (`LiveZaps`). Like
  Boosts, zaps never run in incognito windows, and the picker won't open there. The first Zap release kept zaps
  in `zaps.json`; Kite moves them into each site's Boost on the first launch and renames the file
  `zaps.json.migrated` (kept). Inferred: the Zap button's icon (SF `bolt`; no Zap asset in
  ARC_BoostsEditor.bundle) and its "Zap" tooltip (Arc's show string isn't in its strings).
- **Unverified / not measured:** the highlight's colour, fill and stroke (Kite uses BoostsRed at 15% fill with a
  2pt stroke), the cursor during picking, the shelf's position and look, the candidate slider in
  `SelectorPreview` (Kite offers one "related" candidate), what `zapToPreview` shows on hover (Kite shows the zapped
  element again while its cell is hovered), and Arc's selector heuristics (Kite has its own).

## Media page → `MediaPageView`, `MediaLibraryModel`, `KiteCore/MediaLibrary` (Arc 1.171 menu bar, strings and disassembly, 1 Nov 2026)

Nothing in Arc was pressed or watched. Line numbers are `~/rea-arc/arc-strings.txt`; addresses are Arc-arm64.
Short titles (≤15 bytes) are Swift immediates, decoded from the `mov`/`movk` pairs before each
`NSLocalizedString` call.

- What it is: a gallery, not a list of tabs playing media. `HomeButton/Pages/Media/MediaReducer.swift`
  (82570), `MediaPage`, `MediaPageReducer`, `ScreenshotCell`, `HomeScreenshotPageDelegateAction`,
  `MediaPagePreviewPresenter`, `AirDropContent`, `PermissionID`, `MediaObservationID` (43796–43810). Its
  `HomePageID` case is `screenshotsAndCaptures` (174994 area). Library tooltip: "Opens your Library, which is
  like your Camera Roll within Arc. Screenshots, Captures, Downloads, and more can appear here." (80704).
- Menu: Window › View Media…, no shortcut, after View Easels… (`menudump Window`); title when shown is
  "Hide Media" ("Menu item title to hide all Screenshots & Captures", 62223; decoded).
- Sources: file flags `isScreenshot`, `isScreenRecording`, `isDownload`; `sourceFolders` downloads, desktop,
  documents, screenshotsAndScreenRecordings, custom (166112 area); `ignoredFilePaths` in IgnoredPaths.json.
  "Show media from:" (82453) toggles, decoded at 0x1025d7620: Documents, Desktop, Screenshots, Arc Captures,
  Downloads (enum order 0–4 via 0x1025d7588).
- Captures: `CaptureClient` (`storeCapture`, `deleteCapture`, `getImageCachePath`, StorableCaptures.json;
  76364–76370), so Arc keeps its Captures and lists them here.
- Welcome (before any folder is read; `isOnboardedToMediaPage`): symbol `photo.on.rectangle.angled`, "Your Media in
  the Library", "Quickly grab screenshots, images, and videos from your computer by showing them in the Arc
  Library!", "Media never leaves your computer and is not viewable by anyone but you." (82560–82566).
  Empty-state action titles "Allow Access" / "Learn more"; denied copy "Allow Arc to show your Documents,
  Desktop, and Download Folders to see them here alongside your Captures."; empty copy "Save media to your
  Documents, Desktop, and Download Folders to see them here, alongside your Captures in Arc." (82551–82553).
- Sections "Today", "Yesterday", "Earlier This Week" (shared Home strings); item kinds Image, Video, generic.
- Item menu (decoded): Copy (inferred; its title wasn't decoded), Show in Finder, Open in Preview, Hide from Arc
  (a screenshot/file), Delete (a Capture), Open Source URL / Copy Source URL (a Capture), AirDrop, Send via
  iMessage. Preview: `BaseHomeComponents.MediaPreviewWindow` with `Backdrop`.
- Kite: Arc → Kite in the copy ("Kite Captures", "Hide from Kite"). Inferred, not seen: that "Allow Access"
  is the welcome card's button, which folders a non-screenshot lands under, that only a folder's own files
  (not subfolders) are read, when Arc stores a Capture (Kite: every area and full-page capture), the grid,
  tile and preview sizes, the filter icon, and that the preview is drawn in the page (Arc uses a window).
  Not built yet: AirDrop, Send via iMessage, Learn more, the denied-permission state, custom folders, the
  Hide Media title (View Media… opens the Library's Media page; it doesn't toggle).
## Tab audio button → `TabAudioButton` (KiteCore), `TabAudioButtonView` in `SidebarView` (Arc 1.171 binary, 1 Nov 2026)

Sources: `~/rea-arc/arc-strings.txt`, `otool` disassembly (`decomp/arc.s`) and Ghidra decompilation of
Arc-arm64 (1.171). Nothing was run in Arc.

- **View:** `TabCellView.audibilityButton` (ivar names from Swift metadata). TabCellState carries `isAudible` and
  `isMuted` (strings ~149993). The button's accessibility identifier is `sidebarTabCellMuteButton` (~156512).
- **Size:** width and height constraints both 24 (constant at 0x10380c7a8; the close button uses the same one).
- **Placement:** added to the cell's horizontal `bodyStack` (spacing 6, centred) with sort key 1; the title stack
  has key 2 and the close button 7, and Arc sorts the stack's views by key (0x100a0ca44). So the button sits between
  the favicon and the title, never over the favicon. Custom spacing after it: 2 (0x100363904), so the title moves
  right by 26. It is not a hover reveal.
- **Show/hide:** the button lives in a clipping wrapper whose width constraint collapses to 0; shown and hidden in
  an `NSAnimationContext` with `allowsImplicitAnimation` and duration 0.18 (0x1003692dc). It's driven by one Bool
  of the cell state; that this Bool is `isAudible || isMuted` is inferred from the state's two fields.
- **Tooltip:** "Mute this tab" / "Unmute this tab" (small-string immediates at 0x1002b484c and 0x1002b4900, comments
  "Tooltip; mutes the tab." / "Tooltip; unmutes the tab.").
- **Context menu:** "Mute" / "Unmute" (immediates at 0x102ec1948 and 0x102eb8518, comments "Context menu action to
  mute the selected tab" / "... to unmute a tab", `SidebarMenu+PlatformGeneration.swift`). Their position in the menu
  and when they appear weren't traced.
- **Icon:** a `TranslucentButton` with ARCUI's animated `SidebarCellSpeakerIconWrapperView`: SF `speaker` at
  `.system(size: 14, weight: .medium)`, three custom sound waves (`FirstSoundWave`…`ThirdSoundWave`, 8pt-wide frames,
  staggered springs, response 0.3, damping 0.6) and a `SlashShape` (springs 0.25/0.7 out, 0.3/0.65 in). The speaker
  shifts 4pt left while the waves show. No speaker asset in any Assets.car.
- **Menu bar:** no Mute item in Arc's File/Edit/View/Tabs/Archive/Window menus (menudump). The command bar has
  "Mute All Tabs" / "Unmute All Tabs" (see the next section).

Kite: same size, place, gap, tooltips, menu titles and 0.18s show/hide (SwiftUI ease-in-out with an opacity
transition rather than Arc's width collapse). The icon is SF `speaker.wave.3` / `speaker.slash` at 14pt medium,
swapped without Arc's wave and slash animation; its 0.6 opacity copies Kite's close button (Arc's tint unmeasured).
"Audible" is Kite's media script (playing and not muted by the page), not Chromium's audio-output signal.

## Mute / Unmute All Tabs → `MuteAllTabs` (KiteCore), `muteAllTabs(_:)` in `BrowserWindowController+Media` (Arc 1.171 binary, 1 Nov 2026)

Sources: `~/rea-arc/arc-strings.txt`, `strings` and `otool` disassembly (`decomp/arc.s`) of Arc-arm64 (1.171),
`menudump` of Arc's menu bar. Nothing was pressed or run in Arc.

- **Command-bar actions:** `muteAllTabs` / `unmuteAllTabs` sit in Arc's command-bar action list next to
  `toggleSidebar`, `resetCurrentTab`, `addLeftSplit`… (strings ~69893, ~161128, ~169671; coding keys
  `MuteAllTabsCodingKeys` / `UnmuteAllTabsCodingKeys` ~41029). Descriptions "Action to mute all tabs" / "Action to
  unmute all tabs" (~79415).
- **Titles:** "Mute All Tabs" / "Unmute All Tabs", built as small-string immediates ("Mute All" + " Tabs", at
  0x101d874f8 and 0x101d895f4, next to the "Action to mute all tabs" literal). No extra trigger phrases were found
  next to them (Add Bottom Split, two entries on, has "New Bottom Split"); the title is also matched lowercased.
- **Not elsewhere:** no Mute item in Arc's File/Edit/View/Tabs/Archive/Window/Help menus (menudump). The sidebar
  context menu (`SidebarMenu+PlatformGeneration.swift`) has only the per-tab "Mute" / "Unmute"; no space, Today or
  all-tabs mute string exists.
- **Scope:** not traced. Kite mutes every live page in the window, in all its spaces (Arc's command bar acts on
  its window); whether Arc's reaches other windows, or tabs that load later, is unverified. Whether Arc offers
  both actions at all times or only when they'd change something is unverified; Kite always offers both.

Kite: hidden Tabs-menu items (`commandBarOnly`, ids `muteAllTabs` / `unmuteAllTabs`, so a shortcut can be set in
keybindings.json), found by the command bar. Each live page's engine mute is set and its sidebar speaker updates.
Hibernated tabs aren't touched (they have no page and make no sound).
## Task Manager → `TaskManager` (KiteCore), `TaskManagerWindow` (Arc 1.171 menu bar, strings and ArcCore, 1 Nov 2026)

- Menu (`menudump Help`): Help › Troubleshooting holds Record Trace, Open Task Manager, a separator, Reveal Arc
  Data, Copy Arc Info. No shortcuts. Open Task Manager was disabled with Arc in the background (not read further).
- Selectors: `openTaskManager` / `recordTrace` / `cancelTrace` (arc-strings 176564–176566), menu outlets
  `openTaskManagerMenuItem`, `recordTraceMenuItem`, `cancelTraceMenuItem` (149687–149689), and
  `$__lazy_storage_$_supportsTaskManager`; ArcCore exports `showTaskManager`.
- It is Chromium's task manager, not an Arc window: ArcCore (CEF/Chromium 156.0.8078.74) contains
  `TaskManagerView`, `task_manager_view.h`, `task_manager_search_bar_view.cc`, prefs `task_manager.column_visibility`,
  `task_manager.category`, `task_manager.end_process_enabled`, and every `IDS_TASK_MANAGER_*_COLUMN`. No
  `TaskManagerMac` (the old Cocoa one is gone).
- Its English strings (ArcCore en.lproj/locale.pak): columns "Task", "Memory Footprint", "CPU", "Network",
  "Process ID" (plus optional ones: Profile, Swapped Memory, Start Time, CPU Time, GPU Memory, JavaScript Memory,
  Idle Wake Ups, …); buttons "End Process" and "End Task"; refreshed-UI strings "Search", "Search for any process
  from the list.", "Ends the highlighted task.", "Task(s) ended.", categories "Tabs & extensions", "Browser",
  "System", "All tasks"; row titles "Tab: $1", "Incognito Tab: $1", "Utility: $1", "GPU Process", "Subframe: $1";
  "N/A".
- Kite: CEF only runs Chrome commands (IDC_TASK_MANAGER) for Chrome-style browsers, and Kite's are Alloy style
  (hosted in its own views), so Kite draws the table itself: Chromium's five default columns, its row titles, the
  browser then GPU/utility processes then tabs, a process's numbers on its first row only, 1 s refresh, End Task.
  Memory is the process's physical footprint (proc_pid_rusage, "145,268K"); CPU is % of one core.
- Process ids: Chromium tabs' renderers report their pid to the browser (KiteHelper's render process handler,
  `kite.rendererPID`, on each main-frame script context); WebKit tabs use WKWebView's private
  `_webProcessIdentifier` (guarded). Chromium's GPU and utility processes are Kite's children, named from
  `--type` / `--utility-sub-type`.
- Inferred, not observed (Arc's task manager wasn't opened): the button wording ("End Task", the refreshed UI's,
  over the older "End Process"), the window size, the row order, the utility names, and double-click to show a
  tab.

### Search, categories, sorting, columns, Network (g58)

Arc's task manager wasn't opened (the rules allow no presses in Arc), so this follows Chromium's source for the
refreshed task manager that ArcCore 156 ships (`task_manager_search_bar_view.cc` and the category strings are in
it), read from chromium.googlesource.com (main, Nov 2026) and reimplemented:

- Header (`TaskManagerView::CreateHeaderContent`): category tabs with icons on the left, then a spacer and the
  search field in flex 7:3, over a separator. On the Mac there are three tabs (`GetTabDefinitions`): "Tabs &
  extensions", "Browser" (the `kSystem` category; "System" is ChromeOS's title), "All tasks"; the default is Tabs &
  extensions (`kDefaultCategory`), restored from `task_manager.category`. Tabs and extensions (renderers without a
  subtype, extensions, guests) go under the first; the browser, GPU and utility processes under Browser
  (`ShouldKeepTaskForTabsAndExtensions` / `ShouldKeepTaskForSystem`). Changing tab clears the selection.
- Search (locale.pak 930–932, chromium_strings.grd): placeholder "Search", accessible name "Search for any process
  from the list.", clear button "Clear search" (shown only with text). It filters 50 ms after typing
  (`kInputChangeCallbackDelay`), case- and accent-insensitively on the Task column's text, and keeps every task of
  a process that has a match in the shown category (`UpdateMatchedProcessSet`, `ShouldKeepTask`).
- Sorting (`views::TableView::ToggleSortOrder`): a new column sorts its initial way (ascending for Task and
  Process ID, descending for the rest, `initial_sort_is_ascending` in task_manager_columns.h); the next click
  reverses it; the third clears it. With nothing saved it opens sorted by CPU, highest first
  (`RetrieveSavedColumnsSettingsAndUpdateTable`). A process's rows stay together and processes sort by their
  first row (`GroupSortHelper`).
- Columns: right-click the header (or the rows) for a checklist of columns; the last visible one can't be hidden
  (`IsCommandIdEnabled`). Kite lists the columns it can fill: Chromium's five defaults plus Idle Wake Ups
  (interrupt wakeups per second, `ri_interrupt_wkups`) and File Descriptors (`PROC_PIDLISTFDS`), both off by
  default as in Chromium. Saved, with the sort and category, in `TaskManager.json` in Kite's support folder
  (Chromium: local state). Left out: Profile, the WebCore caches, GPU, SQLite, JavaScript and CppGC memory,
  Process Priority, Keepalive Count (they need numbers from inside the engine).
- Chromium turns alternating row colours off on every platform (`SetAlternatingRowColorsEnabled(false)`); End Task
  is enabled only when every selected task can end (`IsEndProcessButtonEnabled`); opening it selects the active
  tab's row (`SelectTaskOfActiveTab`).
- Network: bytes received + sent per second over the last refresh, summed per process and shown on its first row
  (`Task::Refresh`, `TaskGroup`), written by `ui::FormatSpeed` ("$1 B/s", "$1 KB/s", "$1 MB/s" at 3 KiB / 2 MiB /
  1 GiB, one decimal under 100, locale.pak 50449–50454), "0" for none. Chromium counts each request's bytes in its
  network service; Kite's Chromium engine counts them in CEF's `OnResourceLoadComplete` (body bytes received plus
  in-memory upload bytes), so a request counts when it finishes, not as it streams, and disk-cache hits count
  too. GPU and utility rows read "0" (Chromium credits the network service's bytes to the tasks that asked).
  The Browser row reads N/A (Kite's own requests aren't counted), and on WebKit every row reads N/A: WebKit
  loads in its shared networking process and has no public API for a page's bytes.
- Inferred: the tab strip's look (accent title and a 2 px underline for the selected tab, SF Symbols for Chromium's
  tab and list icons, Kite's app icon for Browser), the paddings and the search field's minimum width.

## mailto: handling → `MailHandler`, `MailHandlerSettings` (KiteCore), `MailHandlers` (Arc 1.171 strings, Info.plist and settings key names, 1 Nov 2026)

- Arc has no setting or list of web mail services. Its only mailto: prompt is Chromium's protocol-handler
  permission: arc-strings 79956–79957 "Make %@ your default mail app?" ("Format string asking for
  `mailto:`-handling permission where the argument is the site's title or a fallback string"), in
  `PermissionRequests.PermissionRequestDialogView` / `PermissionRequestPopoverView` (79944–79946, 41481–41484),
  with "Button to deny permission" / "Button to allow permission" (79942–79943) and "Click the lock to change this
  any time" (79945). Permission types include `registerProtocolHandler` (152243) and "protocol handler request
  type" (63706–63707); `WebContentPermissionProtocolHandlerType` (31351) has the cases `unknown` and `mailto`
  (152269–152270), so only mailto gets its own wording.
- The Gmail and Outlook compose URLs in the binary (`https://mail.google.com/mail/u/`, 61213;
  `https://outlook.live.com/mail/0/deeplink/compose`, 61233) belong to the hover-preview cards' compose button
  ("Tooltip for button within a preview that links to a page to compose an email", 61214), not to mailto: links.
- Arc's Info.plist `CFBundleURLTypes` registers "Email Address URL" (`mailto`) beside https, so Arc can be the
  system's default mail app.
- Settings keys (`defaults read company.thebrowser.Browser`): nothing named for mail. `arcAlwaysAllowedLinkToSchemesPerSite`
  maps sites to schemes (Gabe's has two sites → `mailto`); by its name, the sites allowed to open those schemes in other apps without asking:
  Arc's "open in another app" permission, which Kite doesn't have.
- Kite: the page's `navigator.registerProtocolHandler` is replaced (both engines) with HTML's checks (2 arguments,
  `%s` → SyntaxError, other origin → SecurityError); a valid mailto handler from a secure page asks once in a
  popover over the page; Allow makes it the one default, Deny is remembered (Chromium keeps ignored handlers).
  A mailto: link (in the page, target=_blank, or from another app) then loads the handler URL with the whole
  link in place of the first `%s`, escaped as Chromium's `EscapeQueryParamValue(…, use_plus=true)`
  (`ProtocolHandler::TranslateUrl`). No handler: the system's mail app, unless that's Kite.
- Inferred or unobserved: the popover's layout, anchor and button titles ("Deny"/"Allow" from the string
  comments); the site name (Kite shows the handler's host); that a page's mailto: link replaces that page
  (Chromium's handler throttle rewrites the navigation in place); turning it off from Site Controls (Arc's
  "Click the lock" suggests its site control center; Kite shows a Default Mail App row only on the handler's
  site). Schemes other than mailto aren't registered.

## Page context menu → `PageContextMenu` (KiteCore), `PageContextMenuItems`, WebKit/CEF hooks (Arc 1.171 ArcCore, 1 Nov 2026)

Sources: ArcCore.framework (arm64 slice): UTF-16 literals and a disassembly of the code that references them;
ArcCore's `en.lproj/locale.pak` for Chromium's stock titles; `~/rea-arc/arc-strings.txt` (main binary).

- **Where it's built.** Arc's web page menu is Chromium's `RenderViewContextMenu`, built inside ArcCore and handed
  to Swift as an `ArcMenuModel` with an `ArcContextMenuElementInfo` (`linkURL`, `srcURL`, `selectionText`,
  `mediaType`… selectors near ArcCore strings 1218229). The main binary's `ContextMenus` module only builds the
  sidebar menus; its "Copy link as Markdown" (strings 84947) is a sidebar item, not a page item.
- **Arc's own items.** Three hard-coded UTF-16 titles in ArcCore `__ustring` (vm 0xd75a3aa / 0xd75a3da /
  0xd75a40a): "Open Link in Split View" (command 53250), "Open Link in Little Arc" (53249), "Capture Image..."
  (53248). Referenced from ArcCore 0x4282600–0x42828d8.
- **Link order** (ArcCore 0x4282754–0x4282b50, AddItem calls with Chromium command and string ids): Open Link in New
  Tab (50100, IDS 8931) · Open Link in New Window (50101, 8932) · Open Link in Split View (53250, behind a check at
  0x42827ec) · Open Link in Little Arc (53249, behind an embedder check, kind 18, at 0x4282874) · Open Link in
  Incognito Window (50102, 8933) · separator · Save Link As… (50103, 8948) · Copy Link Address (Chromium; Copy
  Email Address for mailto:) · Copy Link Text (50107, 8951, only with link text in some cases) · separator.
- **Image order** (0x42824d4–0x42826a0): Open Image in New Tab (50123, 8961) · Save Image As… (50120, 8958) ·
  Capture Image... (53248, embedder check kind 19) · Copy Image (50122, 8960) · Copy Image Address (50121, 8959).
- **Kite.** The link section above, with "Little Kite" for "Little Arc", on both engines; Open Link in New Tab opens
  in the background (Chromium's disposition). Split View adds a pane after the focused one with the link (Kite's
  Add Split View pane). WebKit: the image section too (WebKit's Copy Image does the copying). Chromium (Alloy): link
  items replace Alloy's page items (Back, Forward, Print, View Source) when the click is on a link.
- **Left out:** "Capture Image..." (its action isn't in the evidence); "Customize Page" › Boosts (Boosts aren't in
  Kite); Copy Link Text.
- **Inferred / unverified:** what the checks before Split View and Little Arc test (Kite: Split View hidden in Little
  Kite and disabled when the split already has 4 panes; Little Kite hidden in Little Kite and incognito windows);
  Open Link in Incognito Window disabled in incognito (Chromium's `IsOpenLinkOTREnabled`); which side of the
  focused pane Arc's split opens on. Selection and page-level sections are still WebKit's own (Look Up, Search
  With Google, Back/Reload…), not Chromium's.
## ⌥⌘-click opens a link in Split View → `LinkClick` (KiteCore) (Arc 1.169 decomp, 1.171 strings, 1 Nov 2026)

- The routing is in `decidePolicyForWebContentFrameNavigation(windowID:windowContentID:action:disposition:modifierFlags:response:)`
  (arc-strings ~83229, `WindowsData+WebContentFrame.swift`). The helper is FUN_102add204 (`~/rea-arc/decomp/out5/g37-policy.txt`) and
  its caller is FUN_102ad9450 (`out5/g37-caller.txt`).
- The disposition is a single-payload Swift enum: `littleWindow(…)`, then the empty cases `ignoreAction, currentTab, newBackgroundTab,
  newForegroundTab, newWindow, popup, splitView, incognito, newPictureInPicture`. These come from the `__swift5_fieldmd` record.
  Their tags are 2…10 **[inferred]**: that numbering puts the "opening a new window should be handled separately" log on tag 6 (newWindow), and the
  caller's `0x5bc` mask leaves out exactly newWindow and incognito.
- Modifiers are Arc's own option set, mapped from NSEvent at 0x1009a223c: shift 1, control 2, option 4, command 8. The constants are at
  0x103698b10…b48.
- `newBackgroundTab` (Chromium's ⌘-click or middle-click) at 0x102add4a8:
  - If `optionCommandClickLittleArcEntryPointEnabled` (settings key index 0x3f) is on and ⌥⌘ are held, the link opens in Little Arc
    ("Open Little Arc when clicking on links with ⌥⌘ held").
  - Otherwise, if ⌥ is held, the disposition becomes `splitView` (tag 8).
  - Otherwise it opens a background tab, or the current tab.
  - `newForegroundTab` (⇧⌘) passes through unchanged.
  - ⇧ alone is Peek (the caller tests shift, `disableShiftClickToOpenLinksInModal`).
- That Little Arc key isn't in Gabe's defaults or among the `registerDefaults` keys found, so it is probably off by default **[inferred]**. Kite has
  no ⌥⌘ Little Arc entry point, so in Kite ⌥⌘-click always splits.
- What the split looks like (which pane, focus, what a full split does) isn't traced. Kite follows Add Split View: a new pane after the
  clicked tab, focused. On a full split Kite does nothing, which matches Gabe's choice for Add Split View; Arc shows "Cannot Add New Pane".
- No settings text mentions this click. The only Links-pane modifier settings are Peek (⇧) and Little Arc (⌥⌘).

## One page per tab across windows → `SharedPages` (PagePool), `PagePlaceholderView` (Arc 1.171 strings and decomp, 1 Nov 2026)

- Arc has a content placeholder system: `ContentPlaceholderClient` (`registerPlaceholder`, `unregisterPlaceholder`,
  `currentPlaceholders`, `placeholderSnapshots`; arc-strings 82622–82627, 176059–176062) with `ContentPlaceholderData`,
  `ContentPlaceholderSourceData` (43898–43900), fields `contentSnapshotClient`, `sources`, `placeholders` and a `sidebarItemID`
  (176063–176068). So placeholders are keyed by tab and drawn from content snapshots.
- The window side is `WindowContentPlaceholderViewController` (30684, 61654) with `ViewModel`, `Snapshot`, `BlurredSnapshotView`,
  `ViewState` (30685–30688), an `NSHostingController` (`init(rootView:)`). Decomp around FUN_1001ad81c
  (`~/rea-arc/decomp/out3/g65wcp.txt`): the SwiftUI view is `Image(nsImage:).resizable()` with `.stretch`, a flexible frame
  centred, ignoring all safe areas; snapshots sit in a top-aligned `ForEach`, and a new one comes in with
  `withAnimation(.easeInOut(duration: 0.2))`, the old one going 0.2 s later. `WebContentPlaceholderView` (30633, 61512) is a
  layer-backed view whose `updateLayer` only sets a background colour (decomp @1001693a0–1001694c8, `out3/g65placeholder.txt`).
- No user-visible string mentions a tab open in another window, and no "Bring here"/"Move here" action exists in the strings
  (searched "another window", "other window", "open here", "move here", "this tab is"). So the placeholder has no text or
  button; Kite adds none.
- **[inferred]** Which window holds the live page: the one that put the tab on screen last (selected it), and a window coming
  forward (becoming key) takes its pages back. The decomp doesn't show the trigger; Arc wasn't driven to watch it.
- **[unmeasured]** The blur radius (Kite: Gaussian sigma 20 px on the 2× snapshot) and the placeholder's background colour
  (Kite: the card's `windowBackgroundColor`).
## Downloads in progress → `AppDelegate.applicationShouldTerminate`, `QuitDialog.runDownloadsInProgress` (Arc 1.171 strings, 1.169 disassembly, 1 Nov 2026)

- Strings (`~/rea-arc/arc-strings.txt` 61957–61966, inside `applicationShouldTerminate(_:)` / `handleTerminateReply(_:allowTerminateLater:)`):
  title "Downloads in progress" ("Alert title; Confirmation dialog when closing application while downloads are in progress."),
  text "There are downloads in progress. Closing the application will cancel them." ("Alert informative text"). No count
  or per-download wording exists: the text is the same for one download or many.
- Buttons, decoded from inline Swift small strings in `~/rea-arc/decomp/arc.s` at 0x100232558 and 0x100232604 (fn 0x100232404):
  **"Close " + app name** (so "Close Arc"; the name comes from fn 0x1005a4a94 and is appended) and **"Keep browsing"**
  (comment "Alert button; Cancel closing app action."), in that order.
- Mechanism: `applicationShouldTerminate(_:)` (0x10023e2b8…) asks ArcCore for a terminate decision (three cases;
  "Unknown ArcCore terminate decision" asserts on others) and replies later; the dialog is built from the decision's
  publisher (0x10023225c → closure 0x10023fa64 → 0x100232404). The same path cancels a pending auto-update relaunch
  ("Auto update was cancelled because in progress download was detected.").
- It's Arc's own SwiftUI dialog, like "Quit Arc?": presented through 0x100fc1948, a sibling of the quit dialog's
  0x100fc2a50 (title, message, two button/action pairs). Its look isn't measured; Kite uses the "Quit Kite?" layout with a
  message line.
- With the warn-before-quitting dialog: that one is shown by the ⌘Q action before `terminate`; this one comes from
  `applicationShouldTerminate`, so ⌘Q shows "Quit Arc?" first, then this **[inferred from where each lives; not traced
  end to end]**. Quits that skip ⌘Q (Dock, logout, scripts) get only this one.
- Which button Return/Escape pick isn't known; Kite makes Close Kite the default and Keep browsing the cancel button
  **[Kite's choice]**.

## Still unknown

- The default intensity of a new theme, and the system material Arc puts under it, which sets the blur radius.
- The ⌘T panel's exact shadow parameters (only its effect was measured).
- Arc's default sidebar width, light-theme fill opacities, and the space-switch animation timing.
- The space swipe's physics and settle, and what Arc's space strip shows (see *Spaces*).

## Show full URL in the toolbar → `ToolbarURL`, `PageToolbar` (Arc 1.171 strings and binary, 1 Nov 2026)

- Setting text "Show full URL when Toolbar is enabled" (`~/rea-arc/arc-strings.txt` 80422), in the preferences list
  next to window dragging and Shared Quotes. Key `toolbarShowFullURLsEnabledPreference` (64221, 148552, 171077;
  `onToggleToolbarShowFullURLsEnabledPreference` 171281, `toolbarShowFullURLsEnabledPreferenceDidChange` 176743).
- Gabe's value: the key is absent from `defaults read company.thebrowser.Browser` (his `topBarURLEnabled` is 0,
  toolbar off). Arc reads settings through `UserDefaultsClient.boolForSetting` (arc.s 100d80e34); the key's only
  two references in arc.s are its raw-value switch (1005a1c50) and the key table (1005a3054), with no registered
  default found, so a missing key reads as false. Kite defaults to off. Inferred from that, not seen in Arc's UI.
- What it switches: the toolbar's view state holds `displayTitleShort` and `displayTitleLong` next to
  `shouldToolbarShowFullURLs` and an `urlDomainWidth` frame (150859–150955). The exact text of each title was not
  found in the binary (no symbols; the function that builds them wasn't located). Kite's short form stays the host
  it already showed; the long form is the whole address (scheme, host, port, path, query, fragment), truncated at
  the tail before the buttons. Whether Arc's long form drops the scheme or "www.", and what `urlDomainWidth` is
  used for (keeping the domain visible or styling it), is unverified.
- Arc also toggles it from the toolbar's right-click menu: `toggleToolbarFullURLs` in
  `commandBarToolbarContextMenuActions` (172024), titled "Hide Full URL" (immediate string at arc.s 1003a7a08,
  comment "Title for the 'Hide Full URL' context menu action." 62840) and "Show Full URL" (62841). Kite has no
  toolbar context menu yet; until the settings window exists the toggle is Kite menu → Show Full URL in Toolbar
  (command id `toggleToolbarFullURLs`, Arc's action name), not an Arc menu item.

## Profiles (read from Arc's files and binary, 2026-11-01)

- Storage (observed in Arc's data, structure only): each profile is a Chromium profile folder under
  `User Data` ("Default", "Profile 1", …). `StorableSidebar.json` gives each space `profile`:
  `{"default": true}` or `{"custom": {"_0": {"directoryBasename": "Profile 1", "machineID": …}}}`, and
  `topAppsContainerIDs` pairs each profile with its own favorites container (favorites are per profile).
- Text and buttons (binary: localized keys next to their comments, small-string keys decoded from the
  instructions before each call): menu bar "New Profile" (`newProfile:`) and "Change Profile"
  (`changeProfileForCurrentSpace:`), space menu "Set Profile", "New Profile…"; create sheet "Create a new
  Profile", "What do you want to call this Profile?" (placeholder "Personal"), Next / Back / Create Profile,
  "Which Spaces should use this Profile?"; change sheet "Change Profile" / "Cancel" with a "New Profile"
  option; move confirmation "Switch it up"; errors "A Profile with that name already exists.", "Invalid
  Profile name."; Settings "Your Profiles", "Not used", "%d Spaces", "Only Profiles not assigned to any Spaces
  can be deleted.", "The Default Profile cannot be deleted.", "Delete this Profile", "To continue, please type
  the name of this Profile:".
- Not yet measured: the sheets' layout and chrome (Kite uses macOS sheets), the one-space count string, and
  which characters Arc rejects as invalid.

## Split View: Add Left / Right / Top / Bottom Split → `SplitSides.swift` (KiteCore), `BrowserWindowController+SplitSides` (Arc 1.171 menu bar, strings and disassembly, 1 Nov 2026)

Arc wasn't driven; nothing here is from a recording. Titles shorter than 16 bytes are Swift small strings, so they're not in
arc-strings.txt; they were read from the `mov`/`movk` immediates in `~/rea-arc/decomp/arc.s` (the 1.169 arm64 slice).

- **Menu bar** [menudump View, Arc 1.171]: only Add Split View (⌘L, Gabe's), Close this Split Pane (⌃⇧-), Separate Page from
  Split View, Expand Current Split. No side items in the menu bar.
- **Command bar actions** [str + dis]: coding keys `AddLeftSplitCodingKeys`, `AddRightSplitCodingKeys`, `AddTopSplitCodingKeys`,
  `AddBottomSplitCodingKeys` (arc-strings.txt 41024–41027) sit with the other command bar actions (`NewVerticalSplitViewPane`,
  `ConvertTo…SplitView`, `JoinNextMeeting`). Raw IDs `addLeftSplit`, `addRightSplit`, `addTopSplit`, `addBottomSplit`
  (@101d8dce0 area). Titles "Add Left Split" (@101d87574), "Add Right Split" (@101d86a78), "Add Top Split" (@101d86760),
  "Add Bottom Split" (cstring, 79400), with comments "Action to add new left/right/top/bottom split". Trigger phrases
  "New Left/Right/Top/Bottom Split" (@101d897cc, @101d882fc, @101d87a04, cstring 79450).
- **Split View Controls Menu** [dis, `ContextMenus/SplitScreenButtonMenu.swift`, @102ed2acc–102ed4df0]: the pane's split button
  menu. Move Left / Move Right / Move Up / Move Down; Add Left Split / Add Right Split (one function) and Add Top Split /
  Add Bottom Split (another), icons `icon-split-add-{left,right,top,bottom}`; Separate Tab from Split; Share Split View…;
  Convert to Vertical / Horizontal Split View. Which pair shows when wasn't traced (the split into two functions matches one
  axis per split, inferred).
- **Sidebar plus menu** [dis, `ARC_SidebarPlusButton`, @1027c8f00–1027cae34]: New Tab, Note, Easel, Folder, Boost, Space, and
  "New Right Split" / "New Bottom Split" (icons `split-add-right` / `split-add-bottom`; comments "add a right/bottom split view
  pane"). A second layout titles both "New Split".
- **Sidebar tab context menu** [dis, `ContextMenus/SidebarMenu+PlatformGeneration.swift`, @102eba2e0]: "Add Split View" ("Add a
  new split view") and "Open in Split View" ("Open item in split view"); no side items. A split row's own menu ("Split View
  Context Menu", @102ec23fc) has Share Split View…, Separate All Tabs, add a tab, Convert to Vertical/Horizontal Split View,
  and per-tab "Separate from Split View".
- **Kite:** the four command bar actions, hidden in View like Arc's other command-bar-only split actions, with the "New … Split"
  phrases as keywords. A single page takes all four sides (left/right → side by side, top/bottom → top/bottom); a split takes the
  two sides along its axis; four panes take none (validation greys the rest out). The empty pane goes right next to the focused
  one on that side, takes half its share, and gets the command bar, as Add Split View; Esc takes it away again.
  **Inferred:** next to the focused pane (not at the split's far end), half its share, and off-axis sides disabled rather than
  converting the split. **Not built:** the Split View Controls Menu (needs Arc's pane split button; its Move items are pane
  rearranging), the sidebar plus menu (Kite's + makes a space directly), and the tab context menu's Add Split View / Open in Split
  View (no side items there in Arc).

## Installed web apps (PWAs) → `WebApps`, `WebAppInstallability` (KiteCore), `WebAppsController`, `WebAppInstallDialog` (Kite addition; Chrome as the reference, 1 Nov 2026)

Arc 1.171 has no installed apps. Its File and Window menus (read-only `menudump`) have no install or app
items, and the only hit in its binary strings is Chromium's permission-request name `web app installation`
(arc-strings.txt line 63652). Gabe asked for PWAs anyway, copying Chrome's UI and UX. Every Chrome detail
below comes from one of three sources. Nothing was copied: Kite reimplements it.

- **Strings: CEF's en-US `locale.pak`** (ThirdParty/cef, `Chromium Embedded Framework.framework/Resources/en.lproj`,
  read with a small pak v5 parser). Install icon tooltip "Install $1" (9438). Dialog title "Install app" (9449),
  subtitle "Access this site in a dedicated window on your computer" (9450). "Installing app…" (9454),
  "Successfully installed" (9452), "Open tab in app" (9453), "Learn More" (9767), "Next" (2690),
  "Show in Finder" (9232). Menu item "&Install page as app…" (9494).
- **Flow and layout: Chromium source** (chromium.googlesource.com, main, read on 1 Nov 2026).
  - `chrome/browser/ui/views/web_apps/web_app_install_flow_dialog_delegate.cc`
    - The steps: intro (Learn More, Cancel, Next) → the Mac installer options (OK says Install) →
      progress (the buttons and Learn More hidden) → success (Open tab in app, Show in Finder on Mac).
    - The subtitle and banner are cleared after the intro.
    - Simple and DIY intros get a banner illustration; the detailed intro doesn't.
    - The dialog is tab-modal (`ShowWebModalDialogViews`).
    - Learn More goes to `https://support.google.com/chrome?p=pwa_install` (`chrome/common/url_constants.h`).
  - `web_app_install_intro_view.cc`: the detailed card has a 16pt inset and an 8pt corner radius, with the
    icon, name and origin, then the description (secondary), then a full-width carousel.
  - `web_app_install_options_view.cc` (Mac): the app icon with its host under it, a 64×94 arrow, and the
    destination folder with its label.
  - `image_carousel_view.cc`: images 180pt tall (a 50pt throbber plus 65pt above and below), 8pt apart.
    The 32pt pill scroll buttons sit 8pt in from each edge. Each click scrolls by the images that fit, over 0.5s.
  - `web_app_icon_name_and_origin_view.cc`: the 32pt icon (`kIconSize`), then the name over the origin.
  - `chrome/browser/ui/web_applications/pwa_install_page_action.cc`: the icon is shown when the page is
    promotable, with tooltip "Install <name>".
  - Installability: `components/webapps/browser/installable/installable_evaluator.cc`. It needs a name or
    short_name, a window display mode, and an "any" icon of at least 144px.
  - Screenshots: `installable_data_fetcher.cc`. Desktop shows "wide" screenshots only. It also needs:
    - at most 8 screenshots;
    - each between 320 and 3840px;
    - the same aspect ratio as the first;
    - a ratio of at most 2.3.
  - `components/webapps/common/constants.cc`: the description is cut at 300 characters.
- **Gabe's screenshot of Chrome on reddit.com** (relayed in the brief):
  - The icon sits at the right end of the URL field.
  - The detailed dialog has screenshots and a › arrow.
  - Next is filled blue.

Kite's own choices, not measured against Chrome on screen:
- Dialog width 448, 20pt padding, 12pt corners, title 15 semibold.
- Pill buttons 32pt tall. Next uses Chrome's primary blue (#0B57D0 light, #A8C7FA dark).
- The simple dialog's banner is Kite's own drawing, because Chrome's illustration is an asset.
- "Open tab in app" opens the app at the tab's page and closes the tab. Chrome moves the live tab instead.
- The app window's toolbar is 38pt: back, forward, reload, the title, Open in Kite. It is tinted with theme_color.
