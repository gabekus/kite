# Kite for Windows

Goal: the same browser on Windows, as fast as we can make it, with as few layers
between Kite and Windows as possible.

## Decision (Gabe, 2026-11-03)

**Native C++20 on Win32.** No cross-platform UI framework and no language bridge.
The model is Shopify's [back to native](https://shopify.engineering/back-to-native):
each platform is written natively, and the two share specs, tests and a data format
instead of an implementation.

- **Language: C++.** It's Windows' first-party systems language and CEF's own
  API, so Kite calls Chromium directly with no bridge. Swift on Windows (to reuse
  KiteCore) was the first idea, but it adds a toolchain and runtime Microsoft
  doesn't ship and a C++ interop layer in front of CEF. C# adds the .NET runtime.
  Rust isn't first-party on Windows either and would need its own CEF bindings.
- **UI: Win32 + DirectComposition + Direct2D/DirectWrite**, drawn by Kite itself.
  These are the APIs WinUI, Edge and Chrome sit on. Leaving WinUI out avoids the
  Windows App SDK runtime, XAML startup cost and XAML airspace problems, and
  Kite's chrome is custom-drawn on the Mac anyway.
- **Engine: CEF 156**, the same Chromium as macOS, through CEF's C++ API.
- **Shaders: HLSL** ports of `Kite.metal`.
- **Build: CMake + MSVC** (Visual Studio 2022 or later), static CRT, so `Kite.exe` needs
  no redistributable. The only third-party piece is CEF.
- **Reference: Kite for Mac.** Windows matches the Mac app's behaviour, layout
  and motion, measured from the Mac build with `kite ui`. Arc for Windows is
  never the reference.

### Sharing with the Mac without sharing code

- **KiteCore's tests are the spec.** Each piece of KiteCore that Windows needs
  (BrowserState, URL input, command-bar search, the hibernation policy, theme
  math, Arc import) is ported to C++ under `windows/src/core` with its Swift tests
  ported alongside, case for case.
- **The session file is the contract.** `session.json` keeps the Mac's schema,
  checked by shared JSON fixtures that both test suites load.
- **Headless first.** `windows/src/core` has no UI and its tests run in
  milliseconds, so most of the port can be checked without launching the app.

How the port is run, gate by gate: [helix.md](helix.md). The rules reviewers
enforce: [windows-architecture.md](windows-architecture.md). The plan:
[windows/helix/checkpoints.md](../windows/helix/checkpoints.md).

## Layout

```
windows/
  CMakeLists.txt
  src/core/     the model (KiteCore's counterpart): JSON, BrowserState, session, URL input
  src/shell/    Kite.exe: main.cpp (the command line, the session), BrowserWindowController
                (the window and what's in it: views, Chromium, shortcuts), composition, input
  src/cli/      kitecore: the model, headless
  tests/        unit tests (no test framework dependency)
  helix/        checkpoints.md and states/ (sessions for the UI gate)
  resources/    Kite.manifest (DPI, UTF-8 code page, long paths, Common Controls 6) and its MinGW .rc
  scripts/      fetch-cef.ps1, gen-unicode-tables.py
  cmake/        mingw-w64.cmake (cross-compile check off Windows)
```

## Rendering

The hard part is **airspace**. A Chromium child HWND draws on top of the
window's own composition tree, so the glow and Peek couldn't overlap the page.
The window's composition tree is one DirectComposition device with two
targets: the backdrop with the chrome over it (the sidebar and the caption
buttons, surfaces drawn with one Direct2D device context), behind the page; and the overlay, topmost TRUE, over the page.
Until W10, the command bar lives in the overlay, which shows over child windows,
though it can't blur the page under it. While the bar is open the page windows are
disabled, so clicks reach Kite's window. Ctrl+T pressed in a page reaches Kite
on CEF's UI thread (`OnPreKeyEvent`), which calls `SetFocus` on Kite's window
so the keys typed next come to the bar. That call waits for Kite's thread:
usually less than a frame, and at most one frame-latency wait (1 s) when Kite
is mid-draw. Keys that arrive before the bar opens open it
(`Chromium::KeysComeToKite`). The way out of the airspace problem:

- **Render Chromium off-screen with shared textures.** CEF's
  `shared_texture_enabled` hands us each frame as a D3D11 texture with no CPU
  copy (supported on Windows). We composite it ourselves, so the page is just
  another layer.
- **Compose everything with DirectComposition:**
  theme backdrop, sidebar, page texture, glow, command bar. It's the same
  layering as the macOS window, all on the GPU.
- **Port the shaders to HLSL** (`Kite.metal` is about 150 lines of pure math:
  OKLab blend, grain, rounded-rect SDF glow). `windows/src/shell/shaders/`
  holds the ports; fxc compiles them when Kite builds, so nothing compiles
  at startup. `core/ThemeBackdrop` is a CPU reference of the Metal shader,
  and `Kite.exe --backdrop-test` checks the GPU's float output against it in
  CI (`kitecore theme` prints the same reference's corner pixels, which CI
  compares with Kite.exe's capture). The reference is pinned to a golden
  file, `Tests/Fixtures/theme-backdrop.json`, that the Mac suite renders
  with Kite.metal and compares (`ThemeShaderGoldenTests`), so the Windows
  port is checked against the Mac's own shader, not a second reading of it.
- **Lost GPU:** a driver update, TDR or hybrid-GPU switch removes the D3D11
  device. Kite listens for it (`RegisterDeviceRemovedEvent`) and also checks
  every `Present`/`ResizeBuffers`, then rebuilds the renderer and composition
  tree on whatever adapter is there and redraws.
- **Captures** (`--capture`, the Helix UI gate) read back the frame the
  window presents, laid out at `--capture-scale`× on any monitor. That's the
  backdrop swap chain, with the sidebar's and caption buttons' surfaces and the
  command bar's buffer (`--command-bar`) drawn again into textures and put over it on the CPU, as
  DirectComposition puts them. The caret is left out: it's its own visual.
  The page isn't in it: a child window isn't part of the tree until W10 makes
  pages textures.
- **Material:** the Mac's `.sidebar` material, blended behind the window, is
  Windows 11's acrylic system backdrop (`DWMSBT_TRANSIENTWINDOW`) under a
  window with no redirection bitmap. Where there's none (Windows 10, Windows
  11 before 22H2, Server) the backdrop is drawn over a solid colour, Mica's
  base (#202020 dark, #F3F3F3 light); whether acrylic's own fallback differs
  isn't checked yet. As on the Mac, the material's light or dark appearance
  follows the space's theme.
- **Title bar (W3b):** the window keeps `WS_OVERLAPPEDWINDOW` (so Snap,
  Aero Shake, the system menu and the taskbar behave as Windows expects) but
  `WM_NCCALCSIZE` takes the caption off: the client area, and the backdrop
  with it, runs up to the window's top edge, as the Mac's
  `.fullSizeContentView`. Windows keeps its left, right and bottom resize
  borders; the top one is hit-tested inside the client area. Kite draws
  Windows 11's minimize, maximize and close buttons itself at the top-right
  (`shell/CaptionButtonsView`, 46 × 32, Segoe Fluent Icons' Chrome glyphs,
  WinUI's caption colours) and reports them as `HTMINBUTTON`, `HTMAXBUTTON`
  and `HTCLOSE`, so Snap Layouts appear over maximize (checked on Gabe's PC with a
  real pointer). The band above the
  content card and the sidebar's top row (down to the address field) drag
  the window (`core/TitleBar`), but for the top row's buttons, which take
  their presses (W12). With the sidebar hidden the whole band drags. The card starts under the buttons, 32pt
  down, since a Chromium child window over the buttons would take their
  clicks. A maximized window keeps its client area on the screen and leaves
  a pixel for an auto-hiding taskbar (asked of Explorer once per monitor, and
  again after a settings change, not on every resize).
- **Input:** the off-screen path forwards mouse, keyboard and IME events to
  CEF (`SendMouseClickEvent`, `SendKeyEvent`, ...). This is the most work and
  the main risk, so prototype it first.

Fallback if the off-screen path is too costly: windowed CEF (child HWND), with
any overlays in separate layered top-level windows. That's simpler but less
flexible.

**Today (W6): windowed CEF**, so pages load while the off-screen path is
built (W10). `shell/Chromium` creates one Alloy-style browser per tab (as
the Mac's) as a child window over the content card (right of the sidebar's
240pt, inset 10pt, and 32pt from the top under the caption buttons). Other tabs' windows, and the shown one while Kite is
minimized, are hidden along with their Chromium widget window (the host's
`Chrome_WidgetWin_N` child), which is what Chromium reads as the page's
visibility: they report `hidden` and stop drawing, and `visible` when
they're back. They keep their size, as on the Mac, so a tab switch doesn't
resize and reflow them. That leans on Chromium's window layout, so `--smoke-test` fails
if the widget isn't found; W10's off-screen pages replace it with `WasHidden`.
A Kite window that's covered rather than minimized still draws its page
(Chromium's occlusion tracking covers only its own top-level windows).
`windows/helix/pages/popup-opener.html` logs the page's `visibilityState`,
resizes and opener messages in its title to check all this (on Gabe's PC,
not in CI). CEF runs its own UI
thread (`multi_threaded_message_loop`), so Kite's message loop and
DirectComposition are untouched; CEF's callbacks reach Kite's thread through
`PostMessage`, and Kite moves its page windows on CEF's thread. Some calls
stay synchronous between the threads, because a child window on another
thread shares its parent's input (focus and DPI changes, destroying the
window), until W10 removes the child windows. A second
launch hands over to the running Kite (Chromium allows one per profile). Profiles sit where the Mac keeps them: `<support>\Chromium`
is `root_cache_path`, the default profile is `Chromium\Default`, and a
space's other profile gets its own request context in `Chromium\<directory>`.
Popups and `target=_blank` links open as tabs that keep `window.opener`, as
on the Mac, and a popup that closes itself hands the screen back to its
opener and its tab leaves the session, as closing it would (W5). A tab Kite
closes (its close button, Ctrl+W, the auto-archive) or unloads (a pinned tab)
takes its browser with it: Kite hides the page and force-closes it on CEF's
thread, and remembers its own closes, so `DoClose` doesn't report them as a
page closing itself. A page whose browser isn't made yet closes as it arrives.
As on the Mac, at most six pages stay alive (W5b): past that, showing a tab
closes the least recently shown page, unless it's tied to a popup, using the
camera or microphone, or playing sound (asked of the page with the Mac's
script through DevTools' `Runtime.evaluate`). Its tab stays and loads again
when it's next shown. Ctrl-click and middle-click open a link in a background tab,
Ctrl+Shift-click in a foreground one (a `target=_blank` link opens as a popup
tab either way, as on the Mac). The first page is made once the window is on
screen and not minimized. `--smoke-test` loads
`windows/helix/pages/smoke.html` in CI and fails unless one `WM_CLOSE`
closes every browser in time. Not yet: the card's 6pt corners (a child window can't be clipped
smoothly; W10), the sandbox (W6b), and the page in `--capture` (W10).

## The sidebar's top row

W12 ports the top of the Mac's `SidebarHeaderView` (`core/SidebarTopRow.h`,
`shell/SidebarTopRowView`): the sidebar toggle, then back, forward and reload
at the far end, 32pt buttons 2pt apart ending 6pt short of the sidebar's edge,
on the row at y 7.5 (ArcMetrics.Sidebar). As SymbolButtons they're SF Symbols at
15pt in labelColor at 0.6, and back, forward and reload at 0.125 while disabled
(back and forward from the page's history, reload with a tab); reload is the X
while the page loads, keeping its "Reload" tooltip. Like the Mac's they show no
hover or press of their own, take the click that brings the window forward, and
are cut out of the window's drag. Their tooltips are Windows' own: a comctl32
tooltip made on the first hover over a button (so comctl32 doesn't load at
launch), the window's mouse messages relayed to it (`TTM_RELAYEVENT`, no
subclass of the window), with the system's delay and light look. What a page
reports comes from CEF's `OnLoadingStateChange` (the Mac's navigation state)
and goes with the page.

- **Where the row starts.** The Mac's toggle sits at x 71, just right of the
  traffic lights (their cluster runs from 12 to 72, centred on y 24 against the
  row's 23.5). Windows has nothing on the left (its caption buttons stay top-right,
  W3b, 138pt wide at the window's right edge, well clear of the sidebar's 234),
  so the toggle starts 6pt in, the same inset the navigation buttons keep from the
  sidebar's other edge: its ink starts at x 13.5, about where the Mac's first
  traffic light does. The row's height and everything right of the toggle are the
  Mac's. `top_row_metrics::kToggleX` is the one number to change for another
  choice (the Mac's 71 is `kMacToggleX`).
- **Symbols.** sidebar.left, reload's arrow.clockwise and the X are Kite's own
  geometry (core's `TopRowShape`), measured from the Mac's 15pt renders
  (review/w9d-mac and review/w12-mac): Segoe's Refresh opens at one o'clock with
  a corner arrowhead, where SF's opens at the top, its arc running into a chevron
  there. The X is two crossed strokes of reload's weight, 11pt across, an
  estimate until a Mac capture holds the loading state. Back and forward are
  Segoe Fluent Icons' (Segoe MDL2 Assets' on Windows 10) Back and Forward, scaled
  to cover the Mac's measured ink and centred on it.
- **Each button is a `FadedLayer`** (shell/FadedLayer.h, shared with the space
  bar's icons): turning one on or off is an effect group's opacity, committed on
  the sidebar's next pass with nothing drawn; the X draws only reload's surface,
  and a hover draws nothing (the smoke test counts the surfaces drawn and the
  commit).
- **Not yet:** the compact layout under 212pt (no toggle, a More menu,
  HeaderLayout), which comes with resizing the sidebar (it's 240 until then);
  View › Show Toolbar and Developer Mode's reload options; and the hover reveal
  of a hidden sidebar (SidebarPeek), a checkpoint of its own.

**Hiding the sidebar** (View › Hide Sidebar, Ctrl+S as the Mac's ⌘S, or the
toggle; the `toggleSidebar` command) is the Mac's `updateSidebar`: the sidebar
slides off the window's left edge, and back, over 0.08 s on (0.25, 0.46, 0.45,
0.94), a DirectComposition animation of its root visual's offset (a toggle caught
mid-slide turns back from where it is), with the compositor clock boosted while
it runs (`FrameClock::BoostWithoutFrames`; no frames of Kite's). The card's
leading edge goes from the sidebar's 240 to the 10pt inset. As on the Mac the
state isn't saved (a launch shows the sidebar), a hidden sidebar takes no pointer
or touchpad swipe and draws nothing at rest (what changes meanwhile draws as it
shows again), a space switch doesn't slide its pages, and Rename Space shows it
first. The page is a child window, which no compositor property moves, so until
W10's off-screen pages it moves once: as a show begins and as a hide ends (the
card keeps the sidebar's edge while it slides off, so a tab switch or a resize
meanwhile doesn't put the page over it). Chromium moves it on CEF's thread, a
little after that. The Mac's page slides with the card, kept at the wider width
meanwhile. A rename open in the header ends as the sidebar hides, keeping what
was typed.

- **A pointer's way back.** Windows has no menu bar yet and no hover reveal, and
  the toggle leaves with the sidebar, so Show Sidebar / Hide Sidebar is also in
  the window's system menu (Alt+Space, or a right-click on the band above the
  card), retitled for what it will do, as Import from Arc is there (W15). Until
  SidebarPeek lands that, and Ctrl+S, are the only ways to bring a hidden sidebar
  back.

`kitecore sidebar [--page back,forward,loading] [--hidden]` prints the row and the
card's edge; `kitecore click X Y --page …` says what a click on a button runs.
Captures: `--page-status` and `--toggle-sidebar N` (main.cpp); a hover draws
nothing, which the smoke test checks.

## The favorites grid

W13 ports the Mac's favorites tray (`FavoritesTrayView`, `FavoriteTileView`,
`FavoritePaneView` and `FavoritesEmptyStateView` in SidebarFavorites.swift,
`FavoritesTrayLayout`; core's `core/Favorites.h`, `shell/FavoritesView`): the
current space's profile's favorites (`favoritesByProfile`), between the address
field and the space's page, which starts under them. Tiles are 47pt high and 8pt
apart, at most four a row, as many as square tiles fit and then the rows balanced
(5 are 3 + 2, 9 are 3 × 3), with 8pt above and below; a favorite split is one
tile, its panes 2pt apart. The grid stays put while the pages slide, under the
space bar and the pages (the Mac's subview order), which also get the pointer
first. An unselected pane is the address field's white wash (0.10, 0.20 hovered;
3.5 times on a light theme); the selected one is white at 0.45 (0.8 light) with
its favicon's colour over it at 0.2 (0.3 hovered; none, 0.1 hovered on a light
theme) and a 2pt ring of that colour. The colour is NSImage.dominantColor's (the
fullest of twelve hue bins in the icon drawn 16px a side) half way to white as
`NSColor.blended(withFraction:of:)` mixes it: in calibrated RGB (Apple's Generic
RGB, gamma 1.8), not sRGB, which is what makes YouTube's ring (255, 149, 150) and
not (255, 129, 129). A grey or missing favicon has no colour: the pane is just
white, the globe in its middle (Segoe's globe fills its em square, so it's set at
the favicon's 18pt, the Mac's 36px at 2×; the rows' globes with it). A click
selects the favorite (released inside the pane, not after a 4pt drag, not the
click that brings the window forward), the window's whole band is the tray's (no
window drag, no row), and a pane's tooltip is the tab's title (comctl32's, as the
top row's: `shell/RelayedTooltips`, their tools placed from where the sidebar
rests). Ctrl+1–9 count the favorites first, a split once (`SidebarStops`,
unchanged from W8).

- **The empty state.** With no favorites, Arc's dashed box ("Drag to add
  Favorites" over "Favorites keep your most used sites and apps close", 59pt in
  a 240pt sidebar, so the space's header sits near y 157), until its close button
  (shown while the pointer is over the box) dismisses it. That's a one-shot flag
  (`core/OneShotFlags.h`): the Mac keeps it in UserDefaults on a real profile and
  in the profile's `One-Shot Flags.plist` on a test one; Windows has no
  UserDefaults, so every profile keeps it in that file, a binary property list in
  the Mac's format. The box's lines are as DirectWrite wraps them (the Mac's two
  at 240pt).
- **Each pane is up to four `FadedLayer`s** (the wash, the tint, the ring and the
  favicon; the tint and ring only once there's a colour) in a visual of its own,
  each drawn once at full strength and faded by its effect group, so a hover or a
  selection is opacities the sidebar's next pass commits, with nothing drawn (the
  smoke test counts the layers drawn and the commit). A favicon arriving draws
  only its pane's icon layer, and, once its 16px icon gives the colour, its tint
  and ring; a pane whose favicon changes draws its icon and tint again
  (`FavoriteRedrawFor`). The empty state's box is one layer and its close button
  another, whose opacity the hover sets.
- **Captures.** `--favicons` fetches the favicons as the window does (a capture
  otherwise has none, so no network), waits for them, and names any favorite's
  that didn't load (the globe shows, as on the Mac); `--favorite-hover N` and
  `--favorite-click N` hold a pane hovered or clicked. `kitecore sidebar` gives
  `favorites` (columns, height, `listTop`, each tile and pane with its frame, the
  empty state and its close button), and `kitecore click` on a pane selects it,
  on the close button dismisses the empty state.
- **Not yet:** dragging tiles and the drop gap (W18b, which also shows the tray
  while a drag is on with no favorites), the tile's menu and its Ctrl+click
  (W17), Add to / Remove from Favorites (W14, W17), the preview cards over a
  hovered favorite (FavoritePreviewCard, W38), accessibility for the panes (W35c),
  and hiding the tray while Create a Space shows (the Mac's `creating`, W9f).
  Corners are circular rather than continuous, as in the rest of the sidebar.

## Shortcuts

Kite's shortcuts (W8) are the Mac's menu commands, by the same ids, with Ctrl in
place of ⌘ (`windows/src/core/KeyBindings.h`, ported from `KeyBindings.swift`
and `ShortcutPriorityGate.swift`, with their tests). `keybindings.json` in the
support folder has the Mac's layout, and `Tests/Fixtures/keybindings-v1.json`
is read by both test suites. In it "control" is Ctrl, "option" Alt and "shift"
Shift, and "command" (⌘) is read as Ctrl too, as the defaults map it, so a
Mac file's ⌘⇧W is Ctrl+Shift+W. A shortcut Windows can't press (⌃⌘) or one that
would take typing keys is ignored and the command keeps its default, as the
Mac ignores an unsafe one. An override with no shortcut removes the command's
shortcut (a priority-only change keeps it in the file, as the Mac writes it). A
few commands also take the keys Windows users expect, without showing them:
Ctrl+F4, F5, Ctrl+F5, Shift+F5, F12, Ctrl+Shift+I, Ctrl+U, Alt+Left and
Alt+Right; like the Mac's hidden alternates (⌘← for Back), they stay when the
command is rebound or its shortcut removed, unless another command's shortcut
takes them.
`kitecore shortcuts` prints the table for a profile.

In Kite's own window a shortcut runs from the window's key messages. In a page
it goes by the command's priority, as on the Mac: Prefer Kite runs it in
`OnPreKeyEvent` before the page sees the key; Prefer Websites lets the page
have it, and runs it in `OnKeyEvent` only when the page didn't use it; Use Both
does the same, and a second press within 4.6 s runs Kite's before the page.
Both paths look keys up the same way (`shell/Keys.cpp`): a key without Ctrl or
Alt (other than F1–F24) is never looked up, and a Ctrl+Alt key that types a
character on the current layout (AltGr's, which Windows also gives Left
Ctrl+Left Alt) is typing, not a shortcut. A held key repeats its command, as the
Mac's menus do. While the command bar is open its shortcuts still run, as the
Mac's menus come before its field editor, but for the keys the field edits with
(Alt+Left, Ctrl+Backspace), as the Mac doesn't take ⌘← from a focused field.
Ctrl+1 to Ctrl+8 select the space's nth tab and Ctrl+9 its last, in the Mac's
order: favorites, pinned and then today's tabs, top to bottom, including tabs in
closed folders (the Windows sidebar doesn't draw favorites yet), with a split
counted once. Next and Previous Space are the Mac's Ctrl+Shift+S, Ctrl+Alt+Right
and Ctrl+Alt+Left; Space 1 to 9, the Mac's ⌃1 to ⌃9, are Alt+1 to Alt+9 here,
since Ctrl+1 to Ctrl+9 are Tab 1 to 9. Developer Tools opens in a window of its own (Chrome style: CEF
makes no Alloy-style DevTools), counted with the pages so Chromium's shutdown
waits for it. Not yet: Settings → Shortcuts (the
file is read at launch; the table will be swapped atomically), the "Press
Ctrl+D again" prompt for Use Both, the toast after Copy URL, Ctrl+W closing a
focused Developer Tools window, and Print (Ctrl+P): with CEF 156 on Windows 11,
once the print dialog is cancelled CEF never prints again and Chromium's
shutdown hangs, so Print waits until that's fixed.

## Spaces

Switching spaces (W9a) is the Mac's `sync()`: the title bar's dark mode, the
material and the caption buttons take the new space's appearance at once, and
the backdrop crossfades to its theme over 0.3 s with Arc's spring (response
0.15, damping 0.95; `core/SpaceSwipe.h`'s `ThemeCrossfade`, with the Mac's
rule for a switch interrupted before halfway), redrawn on each of the frame
clock's frames. The sidebar's pages are composition visuals, one per built
space (the selected one and its neighbours, `SpaceSwipe::BuiltPages`), a
sidebar's width apart in a strip that a clip keeps inside the sidebar, under
the address field. A switch slides only the strip, from a page's width to rest
on a critically damped spring (response 0.1 s). The slide is a DirectComposition
animation (`SettleSegments`, cubic pieces within 0.05 pt of the spring), so the
compositor runs it and no frame of it runs Kite's code or redraws the sidebar;
a timer at its end builds the new space's neighbours and drops the page left
behind. A page no longer built loses its place in its list, as the Mac's list
goes with its scroll view.

The space bar (W9b) sits along the sidebar's bottom, 50pt tall: Arc's Library
button and + button at its ends (drawn; what they open comes later), and a cell
per space centred between them on a 34pt pitch, or from the room's leading edge
when they don't fit, scrolled with a sideways wheel or Shift and the wheel
(`core/SpaceBar.h`). A cell shows its emoji in colour for the space you're in and
greyed (saturation 0, at 45%) for the others, or a dot for an icon-less space.
SF Symbol and picture icons (W9b2) draw in the bar and the page header
(`core/SpaceIcon.h`, `shell/SpaceIconPainter.h`). Apple's SF Symbols only draw on
Apple's systems, so the Icon tab's 56 symbols, "briefcase" and "photo" each
have a stand-in glyph in Segoe Fluent Icons, or Segoe MDL2 Assets where Fluent
isn't installed, picked by eye from every glyph each font has and checked
against both fonts' character maps, except nine drawn as shapes (below). A
symbol fills its glyph's outline, centred on its ink, at the size that makes the briefcase ink the Mac's 15pt at 12.5 (one
factor for every symbol), in the theme's accent when lit and in the label colour
at 45% when greyed. A picture is the Mac's rounded square, round(size × 1.2) on a
side with 22% corners, its PNG from the profile's SpaceIcons folder scaled to the
square's pixels, greyed as an emoji is; a missing file shows "photo". Pictures
are read and decoded on a worker thread (none over 1 MB or 2048px), which posts
to the window when they're ready, and the cells and headers showing one draw
again; a file that can't be read keeps its placeholder and is looked for again
at a draw 2 s on (`core/PictureLoads.h`). One painter, the sidebar's, serves
the bar and the headers. Known differences:
Fluent has one weight where the Mac's symbols are semibold (the placeholder's
"photo" is regular on the Mac), and its briefcase is 1.5pt taller for the same
width; several stand-ins are outlines of filled symbols, cloud and cloud.fill
share a glyph, and nine have no such object in either font (bookmark, paw, bed,
cutlery, dumbbell, bandage, baseball, takeaway bag, theatre masks), which W9b4
draws as Kite's own shapes (see below); glyphs are centred on their ink where the
Mac centres the symbol's image (checked only for the briefcase, within 0.25pt);
an SF Symbol name outside the 58 (which the Mac draws, from automation or a
hand-edited session) shows the dot in the bar and a blank icon slot in the
header; a picture shows nothing until its decode arrives (the Mac reads it in its
layout), at launch, after a DPI change (new sizes) and in a jump's slide to a page
not built yet; a file over 1 MB or 2048px or in a format WIC can't read (PDF, SVG;
HEIC without its extension) shows the placeholder where the Mac draws it, and an
embedded colour profile or JPEG orientation isn't applied (only a file put there
by hand can be any of these); if the worker thread can't start, pictures are
decoded on the UI thread as a last resort; a file that turns up after a miss shows
at the icon's next redraw (a switch, or a hover over the page's rows; the bar's
hover only moves its backing), as the Mac's next reload reads it;
a picture's corners are circular where the Mac's are continuous; the MDL2 fallback (Windows without
Segoe Fluent Icons) is checked against the font's map but not yet seen drawn.
A switch's slide relights
the cells with the pages: each cell's two layers have DirectComposition opacity
animations on the strip's spring (its light is linear in the strip's offset,
`HighlightAlongSettle`), so the slide still draws nothing. A click selects the
space; the pointer over another space's cell shows its rounded backing, a small
visual of its own that moves with the pointer and the scroll, so hovering and
scrolling draw nothing. The Library and + symbols are drawn from the Mac's
measured archivebox and plus (Segoe Fluent's glyphs differ in size and shape),
and the emoji is set so it draws the Mac's 14.5pt, centred on its ink. Cells sit
on whole pixels at every scale (core snaps them), so they draw where they take
clicks. Known differences: in the 2pt where two cells overlap only the later
cell's backing shows (the Mac shows both).

The nine (W9b4) are Kite's own simple shapes (`core/SymbolShape.h`), not
Apple's outlines: each is filled figures in the bar's 12.5pt about the icon's
centre, in layers joined or cut in order (so the front theatre mask cuts a gap
round itself in the one behind), drawn by the same painter through one Direct2D
geometry per symbol and scaled for the header's 15pt. Each inks the box the
Mac's symbol inks in its cell (keeping its offset from the centre), measured
from the Mac's 2x renders to a quarter point, and comes within an eighth of its
inked area, so it sits and weighs as the Mac's (`SymbolShapeTests`); the PC's
captures give every one the Mac's ink box in the bar, centred within 0.15pt,
and within half a point of it in the header. Known differences: the drawings are Kite's own,
so details differ (the bed's headboard, the bandage's pad marked by two cuts and
four holes, the baseball's seams and stitches, the masks' faces); the header's
are the bar's scaled by 1.2, where the Mac's symbol is redrawn at 15pt (the
captures' header boxes agree to half a point); and the masks reach past the
header's 26pt slot as the Mac's do (only their width was measured from the bar,
the slot's capture clips them).

The tip over a hovered cell (W9b3) is the Mac's SpaceTip in SpaceTipWindow's place:
0.4 s after the pointer comes onto a cell, a capsule 28pt tall centred over it, its
bottom 2pt above the cell's top, with the space's name, its profile's name in a white
chip, and the keys that select it (the first nine), on the accent darkened to 45% of
its OKLab lightness with a 1pt white 15% border; it fades in over 0.15 s on Core
Animation's default curve (the Mac's measured alpha fits it ten times better than the
named curves) and goes at once when the pointer leaves the cell, a drag starts, or the
window moves, resizes or is minimized. It's a window of its own (owned by the browser
window, never activated, transparent to the pointer, drawn by DirectComposition), so a
wide tip over the first cell can reach past the window's left edge as the Mac's panel
does. `kitecore sidebar` gives each cell's `tip`, and `--capture FILE --space-tip N`
draws space N's at rest over the frame. Known differences: the Mac's ⌃n is Alt+n here,
so the first keycap says "Alt" and is wider than the Mac's 18pt square (4pt either
side of its label); the chip's face is drawn as the Mac's 2x capture inks SF's
face.smiling (a disc with the eyes and smile cut out; Segoe has no filled face); the
text is Segoe UI Variable's, the name and the chip bold where the Mac's are semibold (SF's semibold
inks as heavy) with each text's capitals centred, so the tip's width differs from the
Mac's by the fonts' advances; the tip hides when the window moves or resizes, where the
Mac's child panel moves with it; the keycaps' corners are circular where the Mac's are
continuous; and its x is on whole pixels where the Mac's is on whole points (up to
0.5pt at 2x). A window restored under a still pointer shows its cell's tip 0.4 s
later, as the Mac's tracking area enters again.

Two fingers sideways on a precision touchpad over the sidebar (W9c) page between
spaces, as the Mac's SpaceSwipeController: the pages follow the fingers,
rubber-banding past the first and last space, the bar's light follows them
(`SpaceSwipe::Highlight`), and the backdrop crossfades towards the neighbour by
how far they've gone (`ThemeCrossfade::SetInteractive`). Let go past half a page,
or flicked faster than 300pt/s towards a neighbour, the pages settle there on the
switch's spring and the theme settles from where the fingers left it
(`FinishInteractive`); the space is selected only once the pages are at rest, its
page where the neighbour's was, so the slide's first frames don't wait for the
selection's redraw and the page swap. A gesture is the swipe's when its first
movement is more sideways than vertical; one that starts vertically scrolls the
list for its whole length, momentum included, and a swipe's own momentum is
swallowed (`core/SpaceSwipeGesture.h`, `kitecore space swipe DX [SECONDS]`). Until
the swipe begins, each event asks where the pointer is then, as the Mac's
`isOverSidebar`: a vertical gesture scrolls the list under it. A swipe can catch the
pages mid-settle and carries on from where they are. Windows'
wheel messages carry no gesture phases, so the touchpad's contact is taken on
`DM_POINTERHITTEST` by a DirectManipulation viewport on manual updates
(`shell/TouchpadInput.h`, Chromium's way). The frame clock steps it once a frame
while the gesture or its momentum runs, at the display's highest rate, and while the
fingers rest before moving, unboosted and for 10 s at most; each frame draws the
backdrop only when the swipe moved. A gesture whose pointer is off the sidebar
before it's the swipe's (over the page, or the command bar opened), and a contact
that rests past 10 s, are released (`ReleaseContact`), so the rest is the system's
wheel messages for whatever is under the pointer. Core's `TouchpadPhases` turns the viewport's
statuses and content reports into the Mac's phases and sends the viewport back over
its content's middle after a gesture that moved it, the next gesture counting from
there however late DirectManipulation applies it (its tests replay the sequences:
momentum, fingers down mid-momentum, the system taking the viewport, the reset's own
pass). `--capture FILE --swipe DX` holds a swipe DX points in, and the smoke test
feeds the same handler a vertical gesture, one whose pointer has moved over the page,
a swipe that lands, one caught mid-settle, a short one that stays and a flick back;
then, with a third space added for it, a keyboard switch overtaking a landing, a
space selected under the swipe, a release in a hidden window (it lands at once), the
rubber band before the first space and a crossfade's boost ending while the
touchpad's frames go on; and with the other spaces set aside, both ways on one
space. `--frame-log` also records every status, content report, release and poll,
for a run on a real touchpad. Known differences:
- What moves the pages is DirectManipulation's content travel, which follows
  Windows' scrolling direction setting (the Mac's pages follow the fingers whichever
  way its natural scrolling is set).
- A mouse's sideways wheel or Shift and the wheel never pages spaces (the Mac's
  doesn't either), it scrolls the bar's strip.
- Only a contact that comes down over the sidebar can page: one that comes down over
  the page is Chromium's (the hit test goes to its window), and its wheel messages
  have no phases to page with, so a pointer that moves onto the sidebar before the
  fingers do still scrolls the page. The Mac asks where its first movement is.
- A space selected under the swipe (from the keyboard) leaves its theme between
  three: the release goes on to the selected space's from whichever of the two was
  showing more (`ThemeCrossfade::FinishInteractive`), where the Mac's
  finishInteractiveTheme has no such branch and settles back on the theme the swipe
  started from. For the same case the neighbour is looked up guarded (a release with
  no space left that side stays), where the Mac's show and finish index the spaces
  unguarded and would trap.
Unverified on a real touchpad (synthetic touchpad input doesn't exist):
DirectManipulation's actual status sequences and their timing, the scrolling
direction, the hit test's point, whether the pointer moves while a contact is held,
and whether a released contact's rest comes back as wheel messages.

Known differences from the Mac: during the 0.2 s slide only the selected page
takes clicks and shows hover (the Mac's outgoing page is a live list too), and
Space n for a missing space is passed on from Kite's own window but still kept
from a page (Chromium's key thread doesn't know the spaces). `Kite.exe --frame-log FILE`
writes each frame the clock delivered in a test run.

Editing spaces (W9d) is the Mac's SidebarSpaceBar cellDragged and menu(for:) with
KiteCore's space edits (`core/SpaceEditing.h`, `BrowserState::RenameSpace`, `InsertSpace`,
`SetSpaceIcon`, `DeleteSpace`, `MoveSpace`, `CreateFolder`). A press on a cell that moves 4pt
picks its icon up: the cell it left shows nothing, a ghost (a visual sharing that cell's
surfaces and the hover backing's) follows the pointer, and the other cells slide aside to open
the slot it aims at, each an `IDCompositionAnimation` of its offset over 0.2 s on Core
Animation's ease-in-ease-out (`core/SpaceBar.h`'s `SpaceDrag`). A drag draws nothing: a move
within the open slot moves only the ghost's visual, a new slot starts the cells' slides, and
the sidebar's redraw message coalesces a burst of moves into one commit. A drop over the strip
lands in that slot, anywhere else (or the mouse taken away) back where it came from, the ghost
settling there over the same 0.2 s; then, a frame later, the space moves, keeping the
selection where it was. A drop still landing refuses a new drag, as the Mac's, and the spaces
changing under a drag end it. A swipe keeps the spaces it began between by id
(`SpaceSwipe::Neighbours`, the Mac's): once a reorder or a delete under it leaves the pages on
screen the wrong ones, it's dropped, the pages and the theme settle back, and the rest of its
gesture shows nothing (`SpaceSwipeGesture::Abandon`).

A right-click on a cell or the space's header opens the space's menu with the Mac's items,
order and words (`SpaceMenu`): Change Space Icon…, Rename Space…, What's This Space For?…,
Edit Theme Color…, Set Profile ▸, then New Folder and Live Folders ▸, then Delete Space
(disabled for the last space). Rename Space…, or a click on the current space's name, opens
the header's name field (`shell/SpaceRenameField`, the Mac's SpaceRenameField and Done): the
name all selected in the header's 13pt semibold, 2pt into the field as in AppKit's field
editor, over the editor's textBackgroundColor (#1E1E1E dark, white light, square, from 3pt
before the field to 1pt past its end and 22pt tall, as the Mac's capture draws it), "Space Name" when
empty, Done at the right (its width rounded up to a point, as SidebarLabel's naturalWidth);
Return or Done renames (a blank name keeps the old one), Escape doesn't, and leaving it (a
press elsewhere in the window, the page or the command bar taking the keyboard, the menu
opening, another space shown) keeps what was typed; another app taking the keyboard doesn't
end it. The field is a visual of its own in its space's page, so it slides and swipes with
the page and a keystroke draws only the field; its editing, layout, scrolling, selection,
caret and blink are the command bar's, moved out for both (`shell/TextEditing`,
`shell/TextLine`). Delete Space deletes a space with no tabs at once and asks first about one
with tabs, in the Mac's words ("Delete “Name”?", "Its pinned and unpinned tabs are closed.",
Delete and Cancel), its pages closing with it. `kitecore space menu`, `rename`, `icon`,
`folder`, `delete`, `new`, `move` and `drag` do the same headless. Kite.exe delay-loads
comctl32 (the question) and gdi32 (the menu's read-back), so Chromium's processes don't load
them.

Known differences: the menu is Windows' own (TrackPopupMenuEx), as the Mac's is AppKit's: it
looks like Windows' and opens on the right button's release, as Windows' context menus do,
where the Mac's opens on the press. It's dark in a dark space through uxtheme's unnamed
SetPreferredAppMode and FlushMenuThemes (ordinals 135 and 136, as Explorer and Notepad use
them), on Windows 10 1903 and later only, set as the menu opens and put back to the default as
it closes (the mode is the whole process's; docs/windows-architecture.md); without them it's
light. The question before Delete Space is a task dialog (Common Controls 6, which the
manifest now asks for), always light, where the Mac has a sheet. Disabled until their
checkpoints: Change Space Icon… (the icon picker, W9e), What's This Space For?… and Edit Theme
Color… (their dialogs, and the theme editor), Set Profile and Live Folders (Windows can't move
a space's pages to another profile or keep live folders yet). Not yet: the + button's menu and
Arc's Create a Space page, which New Space opens (W9f; `kitecore space new` makes the space
they'd leave), Undo, and the rename's caret in `--capture` (its own visual, as the command
bar's). `--capture FILE --space-drag N,X` holds space N's cell dragged to X points along the
bar, `--space-drop N,X` lets it go there and settle, `--space-menu N` reads back space N's menu
(PrintWindow of this machine's own Windows menu, so it differs by Windows version, theme and
monitor scale, without DWM's rounded corners and shadow, resampled from its monitor's scale
to the capture's) and puts its bottom-left on the cell's centre, and `--rename-space N` opens
space N's name field drawn as with the keyboard (a quiet capture's window never has it).



## Refresh rate

Kite renders at whatever the display supports (60Hz, 120/144Hz laptops, 240 to
500Hz gaming panels), with no 60fps caps, and draws nothing while idle. On
Windows that means:

- **Chromium off-screen is capped by default.** CEF's `windowless_frame_rate`
  defaults to 30fps. Rather than raising it to a fixed number, set
  `external_begin_frame_enabled` and call
  `CefBrowserHost::SendExternalBeginFrame` from our own vsync clock instead, so
  the page renders at the panel's rate and stops when nothing changes (only send
  begin frames while the page has damage or animations).
- **Our vsync clock** (`shell/FrameClock.h`, W9a) comes from DirectComposition:
  a thread waits on `DCompositionWaitForCompositorClock` (Windows 11), or
  `DwmFlush` before it, and posts the window one message a frame, only while
  something has to redraw each frame (the theme's crossfade, a shader mix that
  a compositor property can't do), or a touchpad gesture's DirectManipulation
  updates need stepping (W9c). While something moves (a crossfade, fingers or
  their momentum) it calls `DCompositionBoostCompositorClock`, so a display with
  a dynamic refresh rate runs at its highest, as the Mac asks for the screen's
  maximum rate; the window decides that each frame (`FrameClock::SetBoost`), so
  fingers resting after a fade leave the rate alone. The
  compositor's clock is the system's: with several displays it follows the
  fastest, not necessarily the window's. Each frame is drawn for
  DirectComposition's estimate of when it reaches the screen
  (`GetFrameStatistics`), as the Mac's `FrameClock.targetTimestamp`. What a
  compositor property can do (the pages' slide) is an `IDCompositionAnimation`
  instead, with no frames of Kite's.
- **Swap chains** are flip-model (`DXGI_SWAP_EFFECT_FLIP_DISCARD`) composition
  swap chains with a frame-latency waitable object, so frames present on the
  next vblank of a high-refresh or variable-refresh (G-Sync/FreeSync) display
  without tearing. Present with sync interval 1; never block a 500Hz display on
  a 60Hz timer.
- **DirectComposition animations** run at the compositor's rate.
- The windowed CEF fallback (child HWND) renders at the monitor's rate on its own.

## Plan

The checkpoint list in windows/helix/checkpoints.md is the detailed plan. In short:

1. Win32 shell that CI builds with MSVC, tests and launches (in review, #260:
   `windows/`, `.github/workflows/ci-windows-native.yml`).
2. The model core and session file with their tests and a shared fixture (in
   review, #260).
3. CEF: `windows/scripts/fetch-cef.ps1`, one browser per tab, windowed first
   so pages load (W6), then the sandbox (W6b) and the off-screen spike: D3D11
   shared texture, frame time, input latency (W10).
4. DirectComposition tree and the chrome (sidebar, command bar, spaces), matched
   to measurements of Kite for Mac. HLSL shaders with a golden-image test.
5. Packaging: signing, installer, updates.

## Building

With Visual Studio 2022 or later (Desktop development with C++):

```powershell
cmake -S windows -B windows/build -A x64   # newest Visual Studio installed
cmake --build windows/build --config Release
ctest --test-dir windows/build -C Release
$env:KITE_SUPPORT_PATH = (New-Item -ItemType Directory "$env:TEMP\k-$(Get-Random)").FullName
windows\build\Release\Kite.exe
```

Without `KITE_SUPPORT_PATH` the profile is `%LOCALAPPDATA%\Kite`. A
`KITE_SUPPORT_PATH` that isn't an existing directory is refused.

Off Windows, the model and its tests build natively, and MinGW cross-compiles the app:

```bash
cmake -S windows -B /tmp/kite-core && cmake --build /tmp/kite-core -j && ctest --test-dir /tmp/kite-core
cmake -S windows -B /tmp/kite-mingw -DCMAKE_TOOLCHAIN_FILE="$PWD/windows/cmake/mingw-w64.cmake" && cmake --build /tmp/kite-mingw -j
```
