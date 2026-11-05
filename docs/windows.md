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
  src/shell/    Kite.exe (with Chromium, Kite.dll under CEF's bootstrap): main.cpp (the command
                line, the session), BrowserWindowController
                (the window and what's in it: views, Chromium, shortcuts), composition, input
  src/cli/      kitecore: the model, headless
  tests/        unit tests (no test framework dependency); fixtures/ holds hand-made inputs
                (an Arc for Windows folder, Chromium Web Data databases)
  tools/perf/   kiteperf: the measurement harness, its session fixture and pages (never shipped)
  helix/        checkpoints.md and states/ (sessions for the UI gate)
  resources/    Kite.manifest (DPI, UTF-8 code page, long paths, Common Controls 6), Kite.ico (the
                Mac's AppIcon.icns, from make-icon.py), Kite.rc, which embeds them, and Version.rc
  tools/build/  StampBootstrap.cpp: makes Kite.exe from CEF's bootstrap.exe (W6b)
  scripts/      fetch-cef.ps1, gen-unicode-tables.py, make-icon.py, make-web-data.py (the Web Data
                fixtures)
  cmake/        mingw-w64.cmake (cross-compile check off Windows), CopyCef.cmake
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
  A capture's sidebar is a few levels off the Mac's capture (about 4 darker in
  dark, 5 to 6 lighter in light), and that's the material under the tint, not
  the tint (W9b5). Both draw the theme with the same shader and alpha and lay it
  over the material with the same "over" on sRGB values: solving each pixel of
  a Mac capture for what's under the tint, `(capture − theme) / (1 − tint)`,
  gives one flat colour over the whole sidebar, and the PC's captures are the
  shader over #202020 to within half a level. That flat colour is what the
  Mac's in-process capture draws for its `.sidebar` material, the unblurred
  fallback of `cacheDisplay` (UICapture's `composedRender`): #272727 dark on the
  CI Mac (w9c-mac, w9d-mac), (43, 43, 39) on Gabe's Mac (w9b-mac), and #E6E6E6
  light. It changes from Mac to Mac, and on screen the material blurs what's
  behind the window, so there's no Mac colour to port: the capture's fallback
  stays Mica's base. With Personal's tint of 0.44, #272727 against #202020
  is 0.56 × 7 ≈ 4 levels in every row; with Work's 0.55, #E6E6E6 against
  #F3F3F3 is 0.45 × 12.5 ≈ 5.6.
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
A covered Kite (and a locked, display-off or other-desktop one) hides its
shown page the same way (P2, "A window no one can see draws nothing" below):
Chromium's own occlusion tracking covers only its top-level windows.
`windows/helix/pages/popup-opener.html` logs the page's `visibilityState`,
resizes and opener messages in its title to check all this (on Gabe's PC,
not in CI). CEF runs its own UI
thread (`multi_threaded_message_loop`), so Kite's message loop and
DirectComposition are untouched; CEF's callbacks reach Kite's thread through
`PostMessage`, and Kite moves its page windows on CEF's thread. Some calls
stay synchronous between the threads, because a child window on another
thread shares its parent's input (focus and DPI changes, destroying the
window), until W10 removes the child windows. A second
launch hands over to the running Kite (Chromium allows one per profile). Kite.exe's command
line is Kite's, but Chromium reads the raw line too: CEF's startup parses it before
`command_line_args_disabled` stops the browser process's later reads, and each helper's
`CefExecuteProcess` reads it whole. Chromium trims every argument of Unicode whitespace and takes
`--`, `-` and `/` as switch prefixes, case-insensitively, and acts on `chromehtml:` itself. So
Kite takes only its own flags and their values (`core/CommandLine.h`): any other argument, a
value Chromium could read as a switch, or `chromehtml:` anywhere, is an error before anything
starts. A value that is exactly an integer, like `--swipe -120`'s, is the one exception:
Chromium reads `-120` as a switch named `120`, and none of its switches is a number.
`--type` launches are Chromium's own helpers: one spelled any other way than Chromium's
`--type=X`, or for a helper Kite doesn't run (a crashpad handler), exits at once.
`--wait-for-debugger` is still honoured before Kite's parser runs (CEF's own startup); it only
waits. W30's protocol and file handlers must register as `"Kite.exe" --single-argument %1`, as
Chrome does, with `Arguments()` reading the raw line the same way (everything after
`--single-argument` is one argument, never a switch), and must pass the URL it checked itself: a
second launch's arguments don't reach `OnAlreadyRunningAppRelaunch` with arguments disabled, so
the relaunch message has to carry and validate it. Profiles sit where the Mac keeps them: `<support>\Chromium`
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
when it's next shown. When memory runs low (W11, the Mac's
`watchMemoryPressure`) every page but the shown one goes the same way:
Windows' low-memory resource notification, waited on by the thread pool with
no thread or timer of Kite's, reports it once per spell of low memory
(`shell/MemoryPressure.h`). It comes late, by default at about 32 MB free per
4 GB of memory (64 MB at most), where the Mac's warning level comes well
before, and Windows has no earlier signal to wait on. The window checks it again
as it handles the report, so a dip that's already over closes nothing. Ctrl-click and
middle-click open a link in a background tab, Ctrl+Shift-click in a
foreground one (a `target=_blank` link opens as a popup tab either way, as on
the Mac). The first page is made once the window is on
screen and not minimized. `--smoke-test` loads
`windows/helix/pages/smoke.html` in CI and fails unless one `WM_CLOSE`
closes every browser in time. Not yet: the card's 6pt corners (a child window can't be clipped
smoothly; W10), and the page in `--capture` (W10).

**Chromium's sandbox (W6b).** Every helper (renderer, GPU, utility) runs in
Chromium's sandbox, as on the Mac, whose helpers enter it in KiteHelper/main.mm
before the framework loads. CEF 156 does it on Windows only through its bootstrap
(it no longer ships `cef_sandbox.lib` to link into a client), so `Kite.exe` is
CEF's prebuilt `bootstrap.exe` and Kite's code is `Kite.dll` beside it. The
bootstrap starts every process, puts a helper in the sandbox before any of Kite's
code loads there, and calls `RunWinMain` in Kite.dll (`shell/main.cpp`), which
checks the bootstrap's CEF version and hands its sandbox info to
`CefExecuteProcess` and `CefInitialize`.

- **Kite.exe** is made at build time by `windows/tools/build/StampBootstrap.cpp`
  (the `KiteExe` target, run again only when one of its inputs changes). It's the
  bootstrap with Kite's manifest (`resources/Kite.manifest`: per-monitor DPI v2,
  the UTF-8 code page, long paths, and the common controls v6 the bootstrap's own
  manifest asks for), Kite's version resource (`resources/Version.rc`, so Task
  Manager says Kite rather than "CEF Bootstrap Application"), Kite's icon
  (`resources/Kite.ico`, as its first icon group, in place of CEF's), and
  chrome.exe's 8 MiB main-thread stack (the bootstrap reserves 1 MiB; Kite.exe
  had 8). `stamp-bootstrap --check` verifies all of it in ctest's `kite-binaries`.
- **The wrapper** is built for `CEF_API_VERSION_LAST` (`fetch-cef.ps1`'s
  `USE_SANDBOX`), as Kite.dll is, and with Control Flow Guard (`/guard:cf`, which
  CMake's defaults leave out), into `build-sandbox-cfg-release` and
  `build-sandbox-cfg-debug`. The names change with how it's built, so a checkout
  from before that shares the CEF folder keeps its own wrapper folders.
- **Kite.dll** loads with only kernel32 and libcef.dll and delay-loads the rest:
  every helper maps it, renderers under win32k lockdown, where user32 can't load.
  A renderer now loads 21 DLLs where it loaded 28, none of user32, gdi32,
  shell32, ole32 and imm32. Kite.dll and Kite.exe both have Control Flow Guard and
  are CET compatible, as Chromium's binaries are, and every object of the
  wrapper linked into Kite.dll is compiled with `/guard:cf`. `kite-binaries`
  checks all of it.
- **What runs where.** As in Chrome on Windows (Chrome 155 on the same PC shows
  the same), renderers run at untrusted integrity with a restricted token and no
  win32k, the GPU process at low integrity, the storage service untrusted, and
  the network service unsandboxed at medium. Each renderer's main frame reports
  its process (`kite.rendererPID`, sent in every run as the Mac's helper does for
  its Task Manager). `--smoke-test` fails unless that renderer is below medium
  integrity, restricted or in an AppContainer, and without win32k, and unless no
  helper but the network service runs at medium (`shell/Sandbox.h`). It prints
  each one's sandbox.
- **The LPAC grant.** The build grants ALL RESTRICTED APPLICATION PACKAGES read
  and execute on its output folder, as CEF's `SET_LPAC_ACLS` does, for a helper
  Chromium runs as a less privileged AppContainer. Nothing at today's defaults
  needs it: with the grant removed from the folder and its files, `--smoke-test`
  passed and every helper ran as above (2026-11-04). Installing covers it anyway
  (see Installing), for when one does.
- **Absolute paths.** The bootstrap makes Kite.exe's folder the browser
  process's working directory (so no helper inherits a handle to wherever Kite
  was started). So every path Kite is given (`--capture`, `--frame-log`,
  `KITE_SUPPORT_PATH`) must be absolute (`PathOption` in `shell/main.cpp`), and a
  relative one is refused.

CEF logs `Timeout of new browser info response for frame … (has_rfh=0)` at
ERROR, sandboxed or not, every time Chromium's error page reloads itself (its
NetErrorAutoReloader tries again after 1 s, 5 s, 30 s, 1 min, 5 min, 10 min and
then every 30 min while the page is visible). Each try makes a speculative main
frame in a renderer, which asks the browser process for its browser over a
synchronous IPC; the try fails again, Chromium discards the frame, and CEF's
browser side, which only answers frames it has attached, never answers or cancels
the request, so it times out after 2 s and logs (CEF's `browser_info_manager.cc`).
The renderer whose frame is gone waits those 2 s; nothing on screen does. The Mac
runs the same CEF with the same settings, so it logs the same. Hiding it would
take a log level above ERROR or turning off the error page's auto-reload, which
the Mac has, so Kite leaves it to a fix in CEF (cancel the request when the frame
is deleted). Popups were said to log it too; one that opens from a click wasn't
reproduced here, since that needs a real click.

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
not (255, 129, 129). That mix is `core/ColorSpaces.h`'s `BlendCalibrated` (alpha
too), with sRGB's transfer function, shared with the OKLab maths and the backdrop.
A grey or missing favicon has no colour: the pane is just white, the globe in its
middle (Segoe's globe fills its em square, so it's set at
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
  the Mac's format (`Tests/Fixtures/one-shot-flags.plist`, which both test suites
  read). The box's lines are as DirectWrite wraps them (the Mac's two at 240pt).
  The close button's X is Kite's own two strokes (`favorites_empty::CloseShape`),
  6.2pt across with 1pt strokes for the Mac's 8pt bold xmark, centred in its 18pt
  box at 0.5: an estimate, since a Mac reference can't hover
  (`--empty-favorites-hover` shows it on Windows).
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
  while a drag is on with no favorites), the preview cards over a
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
Ctrl+F4, F3, Shift+F3, F5, Ctrl+F5, Shift+F5, F12, Ctrl+Shift+I, Ctrl+U, Alt+Left and
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

## Find in page

Ctrl+F opens the Mac's find bar (W21, `shell/FindBarView`, ported from `FindBar.swift` with Ask
on Page off, which is Arc's `FindInPageView`): 300 × 32pt, 10pt in from the content card's
top-right corner and narrower in a narrow card, with the magnifier, the query field ("Find in
page…"), the n/N counter ("Not Found" in red), the previous and next arrows, a divider and close,
in Arc's popover colours and shadow, light or dark as the app's appearance (the session's
`pageAppearance`, else Windows' apps' mode). It appears and goes without animation. Every
keystroke searches at once (no debounce, as on the Mac): `CefBrowserHost::Find`, and a new search
steps once more so its first match is active, as the Mac's `ChromiumEngine.find`; each
`OnFindResult` fills the counter. Return and Shift+Return, the arrows, Ctrl+G and Ctrl+Shift+G
(and Windows' F3 and Shift+F3) step through the matches, or open the bar when it's closed or
empty; Esc or close ends the search (`StopFinding`, the active match left selected) and gives the
page the keyboard. Like every Edit › Find item on the Mac these are Prefer Websites, so a page that
uses Ctrl+F keeps it. The bar closes when the shown tab changes (another tab, a closed tab, a
space switch) and stays through a navigation, as the Mac's. With no page, Ctrl+F beeps; a page
still being made (Ctrl+F straight after a new tab) opens the bar, and its search runs once the
page exists.

The bar is a small surface in the overlay target, in a page layer under the command bar's
(`Compositor::PageOverlay`), so it draws over the page's child window and typing redraws only the
bar. The page keeps taking input everywhere else: its window gets a region with a hole the bar's
shape, its 5pt corners rounded (`Chromium::SetOverlayHole`, `SetWindowRgn` on CEF's thread, in the
same task as the page's placement and without its own repaint when a move follows), so the bar's
clicks fall through to Kite's window. `--smoke-test` checks with `ChildWindowFromPointEx` that a
click on the bar misses the page, one beside it or on its corner doesn't, and that the hole goes
with the bar. Whatever moves the content card has to put the bar back in its corner and the hole
under it (`FindBarView::SetCard`, then `UpdateFindHole`): the window's resize and the sidebar's
toggle (`MovePage`) do, and split view will have to.

One of Kite's fields has the keyboard at a time (`KeyboardOwner`, `GiveKeyboard`), as one field
editor does on the Mac and as Windows has one system caret a thread: the command bar while it's
open, else a space's rename, else the find field. Opening the command bar takes it from both, a
rename takes it from the find field, and Ctrl+F or a press in the find field ends a rename
(keeping what was typed). The field is the first responder from Ctrl+F or a press in it until
another field or the page takes the keyboard; a press on the arrows or close leaves it where it
was, as a borderless NSButton never becomes first responder. Losing it collapses the selection
and drops the undo history, as the Mac's field editor leaves a field. While the find field has
the keyboard, a navigation doesn't move it to the page, and activating Kite doesn't either; nor
does Ctrl+F over the open command bar as it closes (Kite sets that it keeps the keyboard before the
bar closes, CEF's thread asks again before focusing the page, and Chromium's own focus as the page
windows are enabled again is declined). A press in the field that already has the keyboard only
moves the caret (Shift extends the selection). Not yet: closing the command bar gives the keyboard
to the page even when the find field had it before, where the Mac's first responder would return
to the field; it waits for knowing what the Mac does after a row is committed.

The field is `shell/TextField`, the one-line field the command bar's field and the rename field
are to share (W21b): `shell/TextEditing` and `shell/TextLine` (from W9d), undo and redo as the
Mac's field editor groups them (`core/TextUndo`: a run of typing is one undo; Ctrl+Z, Ctrl+Y and
Ctrl+Shift+Z), the caret and drag selection, the hidden system caret, Windows' IME composition
window at the caret, and the caret's blink on a visual of its own (view timer 0x4B47), which runs
only while the field has the keyboard and stops after Windows' caret timeout. `--smoke-test` finds
in `windows/helix/pages/smoke.html` after it loads (1/1, then Not Found). `--capture … --find TEXT
[--find-result ACTIVE/TOTAL]` captures the bar; a capture runs without Chromium, so the page's
report is given. `kitecore find` prints the query's search, counter, Ask on Page's mode
(`--ask`, kept from the Mac's tests though Windows has no ask card yet) and frame, and `kitecore
undo` replays a field's edits through `core/TextUndo`. Not yet: the
buttons' tooltips and accessibility names, Use Selection to Find (Ctrl+E) and Jump to Selection,
Ask on Page's card, and an inline IME composition (Windows' composition window draws it, as in
the command bar).

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
against both fonts' character maps, except ten drawn as shapes (below). A
symbol fills its glyph's outline, centred on its ink, at the size that makes
Segoe's briefcase glyph ink the Mac's briefcase width, 14.65pt at 12.5 (one
factor for every symbol; edge to edge, as a glyph's outline is measured, from
the Mac's dark 2x bar captures), in the theme's accent when lit and in the label
colour at 45% when greyed. A picture is the Mac's rounded square, round(size × 1.2) on a
side with 22% corners, its PNG from the profile's SpaceIcons folder scaled to the
square's pixels, greyed as an emoji is; a missing file shows "photo". Pictures
are read and decoded on a worker thread (none over 1 MB or 2048px), which posts
to the window when they're ready, and the cells and headers showing one draw
again; a file that can't be read keeps its placeholder and is looked for again
at a draw 2 s on (`core/PictureLoads.h`). One painter, the sidebar's, serves
the bar and the headers. Known differences:
Fluent has one weight where the Mac's symbols are semibold (the placeholder's
"photo" is regular on the Mac); several stand-ins are outlines of filled
symbols, cloud and cloud.fill share a glyph, and nine have no such object in
either font (bookmark, paw, bed, cutlery, dumbbell, bandage, baseball, takeaway
bag, theatre masks), which W9b4 draws as Kite's own shapes (see below); glyphs
are centred on their ink where the Mac centres the symbol's image (checked only
for the briefcase's glyph, within 0.25pt, before W9b5 drew the briefcase); no
Mac capture shows a symbol Segoe draws, so the calibration's 14.65pt is checked
only on the briefcase;
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
and the emoji is set so it draws the Mac's 14.5pt, centred on its ink; the header's at the same factor, 17.4pt of ink at 15 as the Mac's systemFont(ofSize: 15) draws (W9e: 36px at 2x, where Segoe's own 15pt inked 30). Cells sit
on whole pixels at every scale (core snaps them), so they draw where they take
clicks. Known differences: in the 2pt where two cells overlap only the later
cell's backing shows (the Mac shows both).

The nine (W9b4) are Kite's own simple shapes (`core/SymbolShape.h`), not
Apple's outlines: each is filled figures in the bar's 12.5pt about the icon's
centre, in layers joined or cut in order (so the front theatre mask cuts a gap
round itself in the one behind), drawn by the same painter through one Direct2D
geometry per symbol, scaled by 1.2 for the header's 15pt. Each inks the box the
Mac's symbol inks in its cell (keeping its offset from the centre), measured
from the Mac's 2x renders to a quarter point, and comes within an eighth of its
inked area, so it sits and weighs as the Mac's (`SymbolShapeTests`). Only those
numbers come from the Mac: the drawings themselves are Kite's own, not fitted to
Apple's. In the header the Mac redraws the symbol at 15pt and places it by
metrics it rounds to the half point (`place(.center)` in SidebarKit.swift), which
Kite's shapes don't have, so each carries where the Mac's 15pt ink sits in its
slot, measured from the Mac's header renders, as the Mac's own `SymbolOrigins`
are (`PlaceDrawnSymbol`; W9b5). The PC's captures give every one the Mac's ink
box in the bar, centred within 0.15pt. Known differences: details differ (the
bed's headboard, the bandage's pad marked by two cuts and four holes, the
baseball's seams and stitches, the masks' faces); the header's shapes are the
bar's scaled, where the Mac's symbol is redrawn at 15pt, so four (paw, dumbbell,
baseball, masks) ink a header box half a point wider or taller than the Mac's;
and the masks reach past the header's 26pt slot as the Mac's do (only their
width was measured from the bar, the slot's capture clips them, so their header
place across is the bar's scaled). If a shape's
geometry can't be made, Kite logs it and draws nothing for that symbol, except
the briefcase, which falls back to its glyph.

The briefcase (W9b5, the test sessions' Work icon) is drawn the same way, held to
the same numbers: Segoe's glyph is a plain case, where the Mac's has more to it.
It's Kite's own case, one 1.35pt stroke throughout (the Mac's weight): a handle
over a rounded body, a straight band across the middle and a tab on the band,
with the Mac's ink box in the bar (14.5 × 12.5pt, centred at (-0.25, +0.25)), its
inked area within an eighth, and the Mac's place in the header's slot. Its glyph
still sizes the other glyphs (the calibration above). Known difference: the band
and the tab are Kite's, so the inside differs from the Mac's.

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
the gesture is decided (its began, and its movement until the first that has some),
each event asks where the pointer is then, as the Mac's `isOverSidebar`; a vertical
gesture decided over the list scrolls it to its end, momentum included, wherever the
pointer goes after: the gesture stays with the list it was decided under. One decided
vertical elsewhere on the sidebar (the top row, the header, the space bar) has nothing
of Kite's to scroll, so its contact is released at once. A swipe can catch the pages
mid-settle and carries on from where they are. Windows' wheel messages carry no
gesture phases, so the touchpad's contact is taken on
`DM_POINTERHITTEST` by a DirectManipulation viewport on manual updates
(`shell/TouchpadInput.h`, Chromium's way). The frame clock steps it once a frame
while the gesture or its momentum runs, at the display's highest rate, and while the
fingers rest before moving, unboosted and for 10 s at most; each frame draws the
backdrop only when the swipe moved. The pages' settle after a release runs on the
compositor with the compositor clock boosted, as a keyboard switch's slide
(`FrameClock::BoostWithoutFrames`), so a settle with no crossfade (two spaces in the
same theme) is at the display's highest rate too, as the Mac's settle on its clock
is. A gesture whose pointer is off the sidebar before it's decided (over the page,
or the command bar opened), and a contact that rests past 10 s, are released
(`ReleaseContact`), so the rest is the system's wheel messages for whatever is under
the pointer. Core's `TouchpadPhases` turns the viewport's statuses and content
reports into the Mac's phases and sends the viewport back over its content's middle
after a gesture that moved it, the next gesture counting from there however late
DirectManipulation applies it (its tests replay the sequences:
momentum, fingers down mid-momentum, the system taking the viewport, the reset's own
pass). `--capture FILE --swipe DX` holds a swipe DX points in, and the smoke test
feeds the same handler a vertical gesture, one whose pointer has moved over the page
before it's decided, a vertical one that carries on over the page (still the list's,
its momentum too, and its contact kept), one decided vertical over the top row
(released), a swipe that lands, one caught mid-settle, a short one that stays and a
flick back; then, with a third space added for it, a keyboard switch overtaking a
landing, a space selected under the swipe, a release in a hidden window (it lands at
once), the rubber band before the first space and a crossfade's boost ending while the
touchpad's frames go on; and with the other spaces set aside, both ways on one
space. `--frame-log` also records every status, content report, release and poll,
for a run on a real touchpad. Known differences:
- What moves the pages is DirectManipulation's content travel, which follows
  Windows' scrolling direction setting (the Mac's pages follow the fingers whichever
  way its natural scrolling is set).
- A mouse's sideways wheel or Shift and the wheel never pages spaces (the Mac's
  doesn't either), it scrolls the bar's strip.
- Fingers that rest on the touchpad over the sidebar for 10 s without moving lose
  their contact (`TouchpadInput`'s `kLongestRest`), so the frame clock doesn't poll
  DirectManipulation for as long as a hand lies there; moving after that, they're
  the system's wheel messages, which scroll the list (or, sideways over the space
  bar, its strip) but never page. The Mac has no
  such cap: fingers can rest as long as they like and still swipe.
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
the header's name field (`shell/RenameField`, the Mac's SpaceRenameField and Done): the
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
checkpoints: What's This Space For?… and Edit Theme
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

Change Space Icon… (W9e) is the Mac's SpaceIconPicker (`core/SpaceIconPicker.h`,
`shell/SpaceIconPickerView`): from the space's menu (its space selected, then 0.15 s on, as
openPicker(after: 0.15)) or a click on the header's icon (at once), a popover 272pt wide hangs
under the header's icon with its arrow on the icon's middle, centred on it and kept 4pt inside
the screen. Its tabs are Emoji, Icon and Image, with the bin (Remove Icon) beside them once the
space has an icon; it opens on the tab the icon came from. Emoji: Search, then the Mac's
EmojiCatalog (1101 emoji in eight categories, 7 to a row 33.5 apart, 33pt rows, 5 rows showing)
and the category bar, whose buttons clear Search and scroll their first emoji's row to the top.
The catalog is generated from the Swift file (`windows/scripts/gen-emoji-catalog.py`), split into
characters as Swift's chars() does, with each code point's Unicode name, so Search matches what
the Mac's ICU Any-Name transform gives ("\n{grinning face}"; a flag is its two letters, so
"united" finds none). Icon: the 56 symbols, 8 to a row 31 apart, at 16pt in labelColor, drawn
by the sidebar's painter as the bar and the header draw them (Segoe glyphs and Kite's nine
shapes). A pick sets the icon at once (the bar's cell and the header draw it, and it's saved)
and leaves the popover open; replacing a picture deletes its file once no space shows it
(SpaceIconImages.discard). While the picker is open an icon-less header keeps the icon's slot,
a dashed 24pt square, to hang it from, from the request on (a menu's 0.15 s included). A
right-click on the header's icon opens the space's menu, as one on the rest of the header does
(`HeaderMenuSpace`); a press on the header's icon, or its placeholder, is the icon button's,
which opens the picker again. It closes on Escape, a press anywhere else in the window, the page
or another app taking the keyboard, the command bar, another space shown, the sidebar hidden
(Change Space Icon… shows a hidden sidebar first), the list scrolled (the header it hangs from
moves), and the window moving, resizing or minimizing.

It's a window of its own (owned, never activated, so the browser window keeps the keyboard and
passes Search its keys; in W21's model the keyboard is `KeyboardField::IconPicker`'s from the request,
the menu's 0.15 s included, until it closes, so the window taking the focus never hands it to the page), drawn by DirectComposition in its own target: the frame and controls in
one surface (the Icon tab's grid too), the emoji grid in a virtual surface as tall as its rows,
in a clip, scrolled by moving it. Only the rows in view draw, as they come into view, and rows
more than 10 from view are trimmed away; a held cell draws only itself; moving over the grid
draws nothing; nothing runs while it's idle but Search's caret blink, which Windows' caret
timeout ends; each emoji's text layout is made once, by the emoji, so a search reuses them. Its
redraws' failures report a lost GPU, which rebuilds everything as the caption buttons' do. It
lays out at its own monitor's scale (WM_DPICHANGED, and its window's DPI checked as it opens) and stays on the anchor's monitor.
Replacing a picture deletes its file on the UI thread, as the Mac does: one DeleteFile of a name
core checked, an exception to the no-file-I/O rule (docs/windows-architecture.md) that only a
Mac profile's picture icon can reach. Emoji are Segoe UI Emoji's colour glyphs at 22pt scaled as the bar's (Apple's
14.5pt ink at 12.5) and centred on their ink. `kitecore space icon-picker ID [--tab] [--category
N] [--query TEXT] [--scroll PT] [--pick N]` prints the grid model and picks a cell headless;
`--hit X,Y` and `--place` print what a point hits (the later of two overlapping cells) and where
the popover goes. `--capture FILE --icon-picker N,emoji|icon[,CATEGORY]` holds space N's picker
open on that tab, with a category's button clicked (kept inside the window, so the capture has
all of it), and `--pick-icon N,TAB,CELL` clicks a cell and closes
it with Escape.

Known differences: the Image tab (a picture of your own: choose a file, drop one, paste) is
there, disabled, and a picture icon opens on Emoji: Windows has the pieces (the file dialog,
WIC, the clipboard, OLE drops) but writing the picture belongs on a worker and a drop target on
the window meets Chromium's, which want their own checkpoint. AppKit's segmented control, the
rounded-border field, the popover's fill, edge, corners and arrow are drawn to estimates (no
shadow, a straight-sided arrow) until the UI gate measures the Mac's; a held button dims to
50% (SwiftUI's plain style dims; not measured); the categories' and the bin's tooltips aren't
shown; there's no scroller (macOS shows an overlay one while scrolling); a press outside goes
on to what it's over; the popover closes when the window moves, where NSPopover moves with it;
the category bar's rosette is Segoe's certificate medal (neither font has a rosette); the
header's icon has no "Change Space Icon" tooltip yet. Segoe UI Emoji has no country flags, so
52 of the Flags category's 59 cells (and a flag icon from a Mac profile, in the bar and the
header) draw as the two letters of their regional indicators, each clipped to its 33.5pt cell
(the pairs fit: `--icon-picker 1,emoji,7`); and Windows 10's Segoe UI Emoji lacks Unicode 13
and 14's emoji (🫠, 🥲, 🫶, 🪴 and others), which draw as its fallback boxes there.

## Saving the session

As on the Mac (`BrowserStore.scheduleSave`, `SessionSaveDelay`), the session is
saved as it changes (W11): a second after the last sidebar change or
navigation, ten seconds after a page's title or favicon (which never push a
waiting save back), and at once when the window closes or Windows ends the
session. Each change arms one one-shot timer; when it fires, Kite's UI thread
copies the session (`kitecore save-bench`: a 58–93 μs median for 200 tabs) and
hands the copy to `core/SessionWriter`, whose thread encodes it, skips the
write if the bytes are what it last wrote, and writes it atomically
(`core/StoreFile`: a sibling `.tmp` flushed to the disk, then renamed over the
file; each write has a temp of its own, so two writers never share one). Kite
waits for the last write once the window is gone, before Chromium shuts down
(so a launch meanwhile hands over to it rather than read a file about to be
replaced; with the window gone, that launch is dropped, and the user launches
again), 10 s at most; logoff and shutdown wait in the window, 3 s at most.
Giving up is safe, since the file is then the old one or the new one; a write
still stuck then ends the process (`TerminateProcess`, exit 4) rather than let
the C++ library tear down under the writer's thread. The writer also keeps
the Mac's rolling backups in `Backups\` (`core/SessionBackups`, the same names
and budgets): the session as found at each launch (not a second launch that
hands over to the running Kite), and at most one an hour while Kite runs,
offered after every save as on the Mac, and on each 15-minute auto-archive
pass, which on the Mac always saves. An unreadable `session.json` is moved aside
and the newest backup that reads takes its place; the Mac says so in a toast,
Windows (no toasts yet) only to the debugger and a quiet run's stderr.
`kitecore backups` lists them; `kitecore save-schedule` replays changes
through the timer's rules; `kitecore save-bench` measures a save, in a temp
folder of its own. `Kite.exe --save-log` is the live check: a quiet window that
logs each save and its UI-thread cost. Not yet: the Mac's `syncPinnedURLs` in
its page-event path (a pinned tab that had no page adopting the first address
it reports), which comes with pinning.

## Downloads

Chromium's downloads (W20a) follow the Mac's engine (`KCBrowser.mm`'s download
handler, `DownloadsModel`, `DownloadLocation`): each page's client is CEF's
`CefDownloadHandler`. A download saves into its profile's folder (Settings ›
Profiles › Download location, kept in `session.json`'s `profileSettings` by the
profile's dataStoreID, as on the Mac; a chosen folder that has gone falls back),
under the name Chromium suggests made safe for Windows (`core/Downloads.h`'s
`SafeDownloadName`: its last part, no drive or stream, no device names, no
trailing dots or spaces, 255 UTF-16 units at most), numbered "name 2.ext" when
the folder has one or another download holds it (names compared as NTFS
compares them, `CompareStringOrdinal` ignoring case; 1000 tries at most), and
shortened, as Chrome does, so the whole path stays within `MAX_PATH` (Alloy
writes the target itself, with no `.crdownload` beside it: checked on the PC); a profile set to Ask gets Chromium's Save As dialog
there. The folder and the free name are found on CEF's file thread (a chosen
folder can be a slow network share), where `core/Downloads.h`'s
`DownloadReservations` finds and holds a name in one step, so a burst of
same-name downloads gets a path each (ten at once, checked on the PC with
`KITE_TEST_AUTOMATIC_DOWNLOADS=http://127.0.0.1:PORT`, since without a click
Chromium allows a page one); no lock is held while the disk is asked. A Chrome Web Store package
(its MIME type or a .crx name, from Google's extension hosts over https; the
Mac takes the MIME type from any host) is cancelled and never listed: nothing on
Windows installs extensions yet (W27a), where the Mac hands it to Chromium's
installer. Chromium marks each finished file as from the internet itself (its
quarantine writes the `Zone.Identifier` stream, `ZoneId=3` with `HostUrl`), and
`--save-log` reads each finished file's mark back. Once a page's browser is
gone Chromium may stop reporting its downloads (it hands them to another page
of the profile only if one is there as it goes: a page that starts a download
and closes itself, run on the PC, went both ways). So a page with a download
running isn't closed until it's done: the page cap and memory pressure skip it,
and a page Kite closes (its tab closed, unloaded, or another profile now) or
that closes itself (its window kept past `DoClose`) is parked: hidden, muted,
moved to about:blank (its camera, microphone, sound and scripts go with the
page; the download, the profile's, goes on: checked on the PC with
`KITE_TEST_CLOSE_TAB_MS`, which gives a `--save-log` run's page a click's user
activation and then closes its tab), opening no popups or tabs, and showing no
dialogs (its Leave Page is answered Leave, as the Mac's closed pages answer it;
checked with a page that asks). Its tab goes as before. It closes once its
downloads are done, or have made no progress for 10 minutes (then they're
cancelled), checked once a minute by a window timer that runs only while a page
is parked; closing the window closes them all. The `KITE_TEST_*` switches act
only in a `--save-log` run on a test profile. Chromium's reports reach
Kite's thread folded together, one per download per wake however often Chromium
reports (about twice a second), and go through `core/DownloadsModel.h`'s rules:
a finished download is final, an ended incognito session takes no more, and
downloads.json is written 0.2 s after a download starts or finishes and 5 s
after a progress tick, which never pushes back a save already waiting.
downloads.json is the Mac's file (`Tests/Fixtures/downloads-v1.json`, which both
suites read), read at launch and written by `core/DownloadsWriter.h`'s worker as
the session's writer does (atomically, skipping unchanged bytes), so the UI
thread touches no file; a download that starts before the read is in waits for
it, and the list read joins under it. An unreadable file is moved aside, and
one with items Kite can't read is copied aside first, as on the Mac. Quitting
waits for the session's, history's and downloads.json's last writes within one
10 s deadline (downloads.json's handed over first, so it runs alongside the
other two on its own worker), and logoff within one of 3 s. A progress report
costs Kite's UI thread about 8 μs (the model and the timer; nothing is drawn:
the Library comes with W20b), measured by `--save-log`, which logs Chromium's
reports, those that reached Kite, their cost and downloads.json's writes.
Closing the window with downloads running asks first, the Mac's "Downloads in
progress" (`shell/QuitDialog.h`, a task dialog where the Mac draws its own
alert); Close Kite cancels them. It's asked as the window closes, before its
pages do, where
the Mac asks at terminate: closing the window is quitting here. A quiet run logs
`KITE_TEST_MODAL: dialog: Downloads in progress | [Close Kite, Keep browsing]`
and closes, as the Mac's test-safe run answers, and a profile set to Ask has its
download cancelled with `KITE_TEST_MODAL: save panel: <name>`. Downloads go to
`KITE_TEST_DOWNLOADS_PATH` (absolute; Kite refuses a relative one) on a test
profile (any but `%LOCALAPPDATA%\Kite`), as the Mac honours it with
`KITE_SUPPORT_PATH`, and a quiet run without it uses `<support>\Downloads`,
never the user's. A finished download flashes the taskbar button while Kite is
behind, the Mac's Dock bounce. `kitecore downloads` lists the file, `downloads
apply` replays the engine's reports through the same rules, and `downloads
location` shows and sets each profile's folder and Ask; kitecore never writes
over a downloads.json item it can't read. Known differences: parking (the Mac
removes a closed page's view and keeps no page for its downloads); a name that would make the path longer than
`MAX_PATH` is shortened even where Windows' long paths are on; logging off or
shutting down doesn't ask (Windows ends Kite there; its downloads read as
interrupted next launch, as a download cut off by quitting does on the Mac; a
follow-up: answer `WM_QUERYENDSESSION` with `ShutdownBlockReasonCreate`'s
"Downloads in progress" and ask). Not yet: the Library's Downloads page and its actions (W20b;
its Remove must cancel a running download first, as the Mac's does), the
progress badge and the download's flight (W20c), Tidy Downloads, incognito
windows (W29b), and the Settings pane that changes the location (W31a).

## History

Browsing history (W25a) is the Mac's: one entry per page (`url`, `title`,
`lastVisit`, `visitCount`), web pages only, at most 20,000 (the oldest tenth
goes past the cap), in `history.json` for the default profile and
`Chromium\<dir>\Kite History.json` for another, in the Mac's format
(`core/History`, `Tests/Fixtures/history-v1.json`, which both suites read). A
page's main-frame address (CEF's `OnAddressChange`, as the Mac's
`addressDidChange`: the URL a navigation commits, after its redirects, and a
same-document change to a new URL, such as pushState or a fragment) is a visit
when it isn't the address that tab's page last recorded, so a reload isn't one
and a page closed for the live-page limit records again when it loads; the
page's title goes to the address last recorded, and a repeat changes nothing.
A URL is kept as the Mac's NSURL keeps it (`History::Normalized`): a path,
query or fragment that holds what it may not, which Chromium sometimes leaves
as typed (`|`, `^`, `` ` ``, `{`, `}`, `[`, `]`, `\`, a stray `%`), is taken as
unescaped and percent-encoded whole, its `%` signs too; a valid part is left
as it is.

History saves 3 s after the last change and at least every 30 s while changes
keep coming (`CappedDebounce`), at once for an import, and when the window
closes; logoff and shutdown wait for it within the same 3 s as the session,
and quitting within the same 10 s. `core/HistoryStore` reads each profile's
file and writes it on a worker of its own (`core/WorkerThread`, the
session writer's thread too), from a snapshot that costs the UI thread a few
μs: the entries are kept in 256 shards that copies share and copy on write, a
shard at a time. The files are read only once the launch is Kite's (after
Chromium starts, or for a capture), so a second launch never opens the running
Kite's history. Until a file has been read, its store keeps this run's visits
and replays them over it. A file over 64 MB isn't read (and isn't written
over); one over the cap is trimmed as it's read, on the worker. The command
bar shows up to three pages from the current space's profile's history after
the tabs, never one already shown as a tab, the page you're on or the Open
row's URL; each entry keeps its title, URL and host lowercased and decomposed,
so a keystroke's search is a byte search with Swift's Character rules checked
only where it hits. `kitecore history` lists, searches, adds, merges, removes
and clears; the `history-bench` executable measures it.

Known differences from the Mac:

- A file that's there but couldn't be read or moved aside (or is over 64 MB) is
  never written over; the Mac's `try?` reads it as no file and overwrites it.
- Only URLs Foundation reads back are recorded (`url::HasValidAuthority`), so
  one entry can't make the Mac drop the whole file.
- A page history doesn't keep (about:blank) saves nothing; the Mac's store
  marks itself changed and saves anyway.
- Ties in the ranking and the prune go to the later visit, then the lower URL;
  the Mac leaves them in no set order.
- A visit that takes the history past the cap while the writer holds a
  snapshot doesn't prune; the next visit after the writer has let go does (the
  Mac prunes at once, on a copy-on-write dictionary that copies everything).
- Before a profile's file has been read, a search sees only this run's
  visits; the Mac reads the file on its main thread, so it never waits.
- One shell timer serves every profile's saves, armed for the store due first;
  each store keeps its own debounce, so the timing is the Mac's.
- The bar's history rows show the no-favicon globe, as its tab rows do; the
  Mac fetches `host/favicon.ico`.
- The tab rows above the history rows are still W7a's; the Mac's Arc order is
  W7c.
- An unreadable file moved aside when `<name>.corrupt-<unix time>.json` is
  already there gets a `-N` suffix (up to 99); the Mac's `try? moveItem` fails
  then, and its next save writes over the unreadable file.
- `HistoryStore::Merge` before the profile's file has been read counts the new
  pages against this run's history only (the import is replayed over the file
  once it's in, so nothing is lost or doubled); the Mac's read is done first.
- A file over 20,000 pages is trimmed to 20,000 as it's read; the Mac keeps it
  as it is until the next new page, then cuts it to 18,000 (Windows' next new
  page past the cap cuts to 18,000 too).
- Kite for Mac's CEF bridge (`ToNSURL`, KCBrowser.mm:110) encodes a URL that
  has both an escape and a raw invalid character in the same part twice over
  (`?a=%2C&b=x|y` becomes `?a=%252C&b=x%7Cy`). Windows does the same, so both
  apps key the page alike; it's a Mac bug, to be fixed on the Mac side (and
  then here).
- A raw Unicode host would be kept as typed, where NSURL IDNA-encodes it
  (`xn--…`). Chromium reports hosts in punycode, so a visit never has one; a
  hand-written or imported file could.

URL keys (`History::Normalized`) follow NSURL's RFC 3986 parsing, which is
macOS 14's and later (Kite for Mac's minimum). Both suites read the same
raw-to-key pairs (`Tests/Fixtures/history-url-keys.json`); the Mac's checks
them against NSURL itself, last on macOS 15.7.4 (24G517), Gabe's runner. macOS
14 itself hasn't been checked.

Not yet: the history page (`kite://history`, with the Mac's days and
headings), Delete browsing data, Import from Arc (W33a), and the bar's
favicons.

Import from Arc brings Arc's history into it (W33a, below).

## Import from Arc

Arc stops working on 2026-12-22, so Kite for Windows imports Arc for Windows'
data the way the Mac imports Mac Arc's (W15; `core/ArcImport*`, ported from
KiteCore's `ArcImport*.swift` and KiteMac's `ArcImportController.swift`). Arc
for Windows keeps it in its package,
`%LOCALAPPDATA%\Packages\TheBrowserCompany.Arc_*\LocalCache\Local\Arc`:
`StorableSidebar.json` (with dated backups, tried newest first when the current
file doesn't read), `StorableArchiveItems.json`, `StorableKeyBindings.json` and
`StorableLinkRouting.json` when there are any, Site Search in
`User Data\Default\Web Data` (read with Kite's own SQLite reader) and profile
names in `User Data\Local State`. Its settings aren't macOS defaults but an
XML plist beside that folder, `LocalCache\Local\company.thebrowser.arc.plist`.
Its sidebar is Mac Arc's shape with two differences Kite reads too: a space's
containers may come as `newContainerIDs` (enum-keyed), and its icon as
`customInfo.iconType.icon`, a name from Arc's own icon set (one of Kite's
symbols when it matches, else a stand-in).

Spaces, pinned tabs, folders, splits, favorites, profiles, the archive, Site
Search and Arc's settings go into `session.json`, in the Mac's format;
shortcut changes into `keybindings.json` (read at launch) and Air Traffic
Control routes into `LinkRouting.json`, as the Mac's stores keep them.
The session is saved first, then the other two files, both on the session
writer's thread (`SessionWriter::SaveThen`). Arc's unnamed spaces stay
out, as the Mac's dialog starts, unless Arc has no named space at all (Arc for
Windows often has one unnamed space holding everything): then they come over, a
deliberate difference from the Mac. A sidebar item listed twice or in a loop
is placed once, and nothing nests past 64 levels (the Mac's #362). Site Search
is left out while Arc is writing Web Data (a hot journal beside it).
`kitecore --profile P import-arc [PATH|--auto] [--include-unnamed|--leave-out-unnamed]`
runs it headless and prints the counts per kind and what was skipped and why;
`kitecore profile list|add|rename|delete` manages the profiles it makes. In the
app it's the `importFromArc` command, also in the window's system menu
(Alt+Space): the system folder picker stands in for the Mac's open panel, and
a message box with the Mac's text for its dialog. Not yet: sign-ins (cookies)
and extensions, and the Little Kite setting (no Little Kite).

Arc's browsing history comes too (W33a; `core/ArcHistoryImport`, ported from
KiteMac's `ArcHistoryImport.swift` and `BrowserHistoryImport.chromium`): each
profile's `User Data\<profile>\History`, Chromium's database, read as the
Mac's query reads its `urls` table (`hidden = 0 AND last_visit_time > 0`, the
newest 20,000 by last visit, then the web pages among them, each URL as the
Mac's `URL(string:)` writes it, `History::Normalized`; "" for no title, a count
of at least 1), and merged with `History.merge` into the history of the Kite
profile that Arc profile's spaces went to, once the session that names that
profile is saved; Kite's 20,000-page cap applies after the merge, and importing
again doubles nothing. Kite for Windows reads the file in place with its own
reader, a page at a time (`sqlite::FilePages`, `ScanTable`), keeping the newest
rows in a heap as they stream past: a synthetic 201 MB History (360,000 pages,
`scripts/make-history.py --synthetic`) imports in about 0.45 s with a 35–45 MB
peak working set (warm cache). Since it isn't a copy, a profile's history (and
Web Data) is left out, with the reason in the confirmation and the summary,
while Arc may be changing it (`DatabaseBusy`): a live writer of the database,
its journal, its log or `User Data\lockfile` (a probe that opens each for
reading while denying writers, before and after the read: *Arc is writing it*),
a hot journal or a `History-wal` that isn't empty with no writer (*Arc didn't
finish its last write*), or the file changing during the read. A lockfile
nobody holds is nothing; failing to open a file for any reason but its not
being there counts as a writer. Merging runs on the UI thread after the
session is saved, one profile a message: about 45 ms for 20,000 pages, 65–135 ms
into a full history (merging on the history worker from a snapshot is the
follow-up). A window that closes with the writer's result in merges the rest at
once; one that closes before it (the session still being written) keeps the
spaces and side files, and Arc's history isn't merged. `kitecore import-arc` prints the history
counts: rows found, pages imported and new, and what was left out by reason.

Known differences from the Mac's history import:

- The Mac copies History (with its `-journal` and `-wal`) and opens the copy
  with SQLite, which rolls a hot journal back and reads a WAL's frames; Kite for
  Windows refuses both (*open and quit Arc once*). After Arc shuts down for good
  (2026-12-22) that can't be cleared, so the follow-up is reading through them:
  an in-memory rollback of the journal's pages, or the WAL's committed frames.
- While Arc is writing (running), the Mac reads its copy; Kite for Windows
  refuses.
- A row over 4 MiB, or a URL over Chromium's 2 MB, is left out.
- Rows tied on last visit at the 20,000th place go by row order (SQLite leaves
  it unspecified).
- A history store whose file isn't read yet queues an import and merges it
  once it is, so its new pages aren't counted in the summary.
- Two rows that are one URL once normalized are one page: the newer row's visit
  and title (the older title when the newer has none) and the higher count.

## Pinning, renaming and folders

Pin Tab (Ctrl+D, the Mac's ⌘D, Arc's Use Both priority) moves the selected tab to the end of its
space's pinned items, or a pinned tab (from any folder) to the top of its space's Today; a split
moves as one, its panes in order. A pinned tab or favorite remembers the page it was pinned at
(`pinnedURL`, `BrowserState::SyncPinnedURLs`, run after every change and as a session loads, as
the Mac's store and decoder do: never Kite's own pages or about:blank, and unpinned tabs lose
theirs). One that has left that page (`Tab::HasLeftPinnedURL`: a fragment, a trailing slash,
"www." and http/https don't count) shows Back to Pinned URL (arrow.uturn.backward, Segoe's Undo
glyph) on hover, left of the close button, which sends it home and loads its page if it has
one. These commands have the Mac's ids and no default shortcut, so keybindings.json can bind
them: New Folder… (`newFolder`, "New Folder" at the end of the selected space's pinned items;
as on the Mac it doesn't open the folder's rename), Duplicate Tab (`duplicate`, a copy below
the tab in Today, or at Today's top for a pinned tab or favorite, selected), Rename Current
Tab… (`renameCurrentTab`), Reset all tabs in this Space (`resetSpace`), Reset Tab to Original
URL (`resetTab`), Replace Pin with Current Page (`replacePinnedTab`) and Add to Favorites
(`toggleFavorite`). Each is enabled as the Mac's validateMenuItem has it (a tab selected, or
one off its pinned page), and a disabled one's key passes on.

A double-click on a tab's row (on the second press, as the Mac's mouseDown) or Rename Current
Tab… opens the row's name field (`shell/RenameField`, W9d's header field generalized): the
title all selected in the row's 14pt, "Keep it short and sweet!" when empty, over the field
editor's background, with no Done; Return renames (a blank name goes back to the page's title),
Escape doesn't, and leaving it keeps what was typed, as does its row going (another space shown,
the tab moved into a closed folder: `SidebarShowsRow`, one walk to the row). A press elsewhere in the
renamed row does nothing and the field keeps editing (the Mac's row hides its close and Back to
Pinned URL while it renames, and its tap ignores a renaming row). A row that only moves
(Pin Tab mid-rename) keeps its field, still editing, as the Mac's list moves a row by its id
(SidebarList.apply's moveRow), keeping its cell and field. A double-click on a split pane's row does
nothing (the Mac's split is one SplitRowCell, with no doubleTapped). A folder's field is the same in its 14pt semibold with no
placeholder, and a blank name keeps the old one. The fields are visuals in their page, clipped to
the list, so a keystroke draws only the field (the smoke test checks the page doesn't draw). A
favorite or a split's pane has no row to rename in: the Mac's Rename Tab… dialog for those, and
for a hidden sidebar, comes with ArcDialog (W19), a beep until then. A folder's rename comes in by
its menu's Rename… (W17), as on the Mac.

`kitecore tab pin|favorite|rename|duplicate|reset|reset-all|separate|reveal|pinned-url|replace-pin`
and `kitecore folder new|rename|delete|move` (a folder by id or name) do the same headless;
`kitecore sidebar` gives each tab row's `canReset` and `renamed`, `kitecore shown KIND ID` whether
the page lists a row, and `click … --double` is a double-click's second press.
`--capture FILE --rename-row N` opens row N's field (from 1, as `sidebar` lists the selected
space's rows), `--hover-row N` rests the pointer on row N, and `--run-command ID` runs a command
first (`pinTab` on a pinned tab is the "after unpin" state). The rows' menus (W17, below) rename,
delete and fill folders from the window; a folder is filled by kitecore until W18a's drag. Not yet:
Undo (W16: `EditState` is where it records), the command bar's command rows (the commands are there
to bind, not to search), Back to Pinned URL's tooltip, and the "Pin Tab"/"Unpin Tab" retitling of
the shortcut (the tab's menu has it).

## The sidebar's row menus

A right-click on a tab's row, a folder's row or a favorite's pane opens its menu (W17), ported
from the Mac's TabRowCell, FolderRowCell and FavoritePaneView menus (SidebarListCells.swift,
SidebarFavorites.swift) with their items, order, words, separators and enabled states
(`core/SidebarContextMenu.h`, which also has SidebarContextMenu.swift's edits: Archive Other Tabs /
Below / Above, a folder's Duplicate, New Nested Folder…, Turn “Name” into Space, and LinkFormat's
Markdown links). As on the Mac, a Ctrl+click is a right-click there (and on a space's cell or its
header, the space's menu), opening the menu when it's let go over the row it pressed; the empty
sidebar, the divider and the address field have none, and the gaps between pills take nothing. New
Tab has no menu: a right-click there opens nothing and a Ctrl+click is spent (the Mac's mouseDown
hands it to rightMouseDown, which finds no menu), never opening the command bar. A right-click on
one of a row's own buttons (a tab's close or Back to Pinned URL, the header's chevron and, with W9e,
its icon) passes the menu up to the row, as AppKit's buttons pass rightMouseDown on; a Ctrl+click
presses the button instead, as the Mac's SymbolButtons (controlClickShowsMenu false) and the
header's icon button do. Rows and panes don't take a Ctrl+click that brings the window forward (they
don't accept first mouse); the space bar's cells do. Known trade-off: Ctrl+click as the Mac's
Control-click spends the gesture a ⌘-click's Windows counterpart would use for selecting several
rows, which Kite doesn't have; if multi-select comes, it needs another gesture (Shift+click, say).

- **A tab's:** Add to Favorites, Pin Tab or Unpin Tab, Back to Pinned URL and Separate From
  Pinned Tab (a pinned tab off its page), Edit Pinned Page ▸ (Edit…, Replace Pinned URL with
  Current; a pinned tab with a pinned URL), Copy Link and Copy link as Markdown (greyed out with
  no page), Rename… (the row's field), then Add Split View on the tab on screen or Open in Split
  View on another, Duplicate, Move to ▸ (the spaces), then Close Tab (Unload Tab when pinned) and,
  for a Today tab, Archive Other Tabs, Archive Tabs Below and Archive Tabs Above, each greyed out
  with nothing on its side.
- **A folder's:** Duplicate (not for Claude's folders), Delete, New Nested Folder… (made open at
  the folder's end, its rename opened), Turn “Name” into Space (a plain folder with tabs, never one
  named Claude), Copy All Links and Copy All Links as Markdown (greyed out with no links), Rename….
  Delete asks first in Arc's words ("Delete your “Name” folder?", "Deleting this folder will
  archive the tabs inside it.", Delete Folder and Cancel; a task dialog, always light, as Delete
  Space's), then archives the tabs inside, their pages closing (the selection, if it was there,
  goes to the space's first tab). A live folder's menu is Refresh (disabled: live folders don't
  refresh on Windows yet; its status line, filters and Repositories ▸ aren't built) and Delete Live
  Folder, which works as the Mac's does without its refresher: it asks Arc's question ("Delete your
  GitHub Live Folder?", "You can restore this folder at any time by right-clicking the sidebar.",
  Delete and Cancel), then removes the folder and its tabs unarchived and records the source in the
  session's `liveFoldersTurnedOff`, so a live folder the Mac made isn't stuck on Windows.
- **A favorite's:** Remove from Favorites, Edit Pinned Page ▸ (with a pinned URL), Copy Link (always
  enabled, as the Mac's), Unload Tab.

The menu is Windows' own, through `shell/ContextMenu` (W9d's machinery, moved out of SpaceMenu for
both): TrackPopupMenuEx on the right button's release (a Ctrl+click's on the left button's), dark
in a dark space through uxtheme's ordinals 135 and 136 as the space's menu is. It's built as it
opens, from the session as it is then, and nothing is kept while it's closed; a rename open ends
first, keeping what was typed. Disabled until their checkpoints: Edit Pinned Page › Edit… (Arc's
dialog, W19), Add Split View and Open in Split View (W36), Move to ▸ and its spaces (moving between
spaces and profiles, with Arc's cross-profile warning: W18b), and a live folder's Refresh. Never shown, as on a Mac
where nothing plays and Claude drives no tab: Stop Claude, Mute Tab / Unmute Tab (Windows doesn't
follow pages' sound yet) and the Peek badge. Not yet: the split row's menu (Windows shows no split
rows), Tidy Tabs' Remove header, the "Archived N tabs" and "Folder deleted" toasts (W16), Undo
(W16), and a keyboard way in (the Mac has none: its sidebar never takes the keyboard, so the Menu
key and Shift+F10 open nothing there until the sidebar's accessibility, W35c).

`kitecore menu tab|favorite TAB_ID|folder FOLDER` prints a menu as `space menu` prints the space's,
with its `line` in the Mac's KITE_TEST_CONTEXT_MENU format; `--pick TITLE` (or "Submenu ▸ Item")
runs an item as the window does. `kitecore click X Y --button right` says which menu a right-click
there opens. `--capture FILE --row-menu N` (a row from 1, as `sidebar` lists them) and
`--favorite-menu N` (a pane from 1) open one as a right-click on its middle does, read back from
Windows' menu like `--space-menu`'s, and print its line to stderr.

## Middle-click to close (a Windows addition)

A middle click on a tab's row in the sidebar closes that tab, as Chrome, Edge and Arc for Windows
do: Today's tabs, pinned tabs and tabs in folders. It does what the row's close button does (and
Ctrl+W for the selected tab): Today's tab is archived and its page closes; a pinned tab, in a
folder or not, unloads, keeping its row while its page closes (the button's tooltip on the Mac
says "Unload"); one that closes for good (a split's pane, or one with no page) goes. A tab in one
of Claude's folders has no close button unless it closes for good, and without one it takes no
middle click. It acts on release inside the row it went down on, so a press moved off the row, or
one the mouse capture was taken from, closes nothing. The press itself draws nothing. While
something is renamed, a middle press goes as a left press does: in the field, or elsewhere in the
renamed tab's or folder's row, it does nothing and the field keeps editing (the row's close button
is hidden then); anywhere else it ends the rename, keeping what was typed. A middle click on
a favorite, a folder, the header, New Tab, the space bar, the top row or empty sidebar does
nothing: a favorite is a tile, not a tab row, and has no close button to stand in for. A page's
own middle clicks (a link opening in a background tab, autoscroll) are Chromium's, in the page's
window, and unchanged. Known difference: the Mac has none (no sidebar middle click, and its
`ui input` refuses middle clicks). `core/Sidebar`'s `SidebarMiddlePressAt` and
`SidebarMiddleRelease` decide it, and `kitecore click X Y --button middle` does it headless,
printing the close's `outcome` (`removed` or `unloaded`, as a close button's click now does too).

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
  instead, with no frames of Kite's, the compositor clock boosted while it runs
  (`FrameClock::BoostWithoutFrames`, one per animation: the pages' slide, the
  sidebar's hide and show), as the Mac's clock asks for the screen's top rate
  while it runs the settle. With the display off, the compositor clock's wait
  fails at once (`STATUS_GRAPHICS_PRESENT_OCCLUDED`) and the thread falls back on
  `DwmFlush`, which paces it at DWM's displayless 500 Hz with stalls of a few
  hundred ms. So the smoke test checks the thread first (3 frames within 5 s
  while the touchpad polls, and once it's done the next frame stops the clock),
  then steps the clock's frames itself at 60 Hz (`FrameClock::SetManual`): its
  frame-clock checks are of when Kite starts, boosts and stops the clock and what
  each frame does, never of whether the display is ticking.
- **Swap chains** are flip-model (`DXGI_SWAP_EFFECT_FLIP_DISCARD`) composition
  swap chains with a frame-latency waitable object, so frames present on the
  next vblank of a high-refresh or variable-refresh (G-Sync/FreeSync) display
  without tearing. Present with sync interval 1; never block a 500Hz display on
  a 60Hz timer.
- **DirectComposition animations** run at the compositor's rate.
- The windowed CEF fallback (child HWND) renders at the monitor's rate on its own.
- **Chromium's Energy Saver** caps pages at 30fps on battery below 20%. As on
  the Mac (`KCRuntime.mm`, on by default since 9e19088c, as in Chrome), Kite
  sets `performance_tuning.battery_saver_mode.state` to 1 unless the user turns
  it off (`Chromium::SetEnergySaverEnabled`); every launch sets it, so Local
  State's value from an earlier run doesn't stick. Nothing turns it off on
  Windows yet: the Mac's toggle (Settings › Advanced › Kite, and the Kite menu)
  and its stored choice (`chromiumEnergySaver` in UserDefaults) come with
  Settings (W31). `--smoke-test` reads it back and fails unless it's 1. That's
  Chromium's own default too, so CI's smoke writes a Local State with it off (0)
  first, and a 1 then shows that Kite set it.
- **A window no one can see draws nothing** (`shell/Occlusion.h`, P2), as the
  Mac's AppKit occlusion stops a covered window's page and its `ThemeView`
  crossfade. Kite counts as hidden while the session is locked
  (`WTSRegisterSessionNotification`), the display is off
  (`GUID_SESSION_DISPLAY_STATUS`; dimmed still shows), its window is cloaked on
  another virtual desktop (`DWMWA_CLOAKED`), or opaque windows cover it (fewer
  than 64 of its pixels left, `core/Occlusion.h`). Then the shown page's widget
  is hidden as when minimized, so Chromium stops drawing it, and a theme
  crossfade lands at once with the frame clock stopped (`Seen()` in the browser
  window). Covered is worked out as Chromium's `NativeWindowOcclusionTrackerWin`
  does: out-of-context WinEvent hooks and an `EnumWindows` pass that subtracts
  the windows above Kite's from its rect.
  - **What covers.** A window covers only when nothing about it says it may be
    see-through. These never cover: layered windows with alpha or a colour
    key, click-through, acrylic, cloaked, minimized and tool windows, owned
    popups, and windows with a shaped or empty region. Nor do windows drawn by
    DirectComposition without a class known to be opaque (Chromium's and
    Electron's `Chrome_WidgetWin_1`, and `ApplicationFrameWindow` for UWP
    frames). That rules out the full-monitor `Windows.UI.Core.CoreWindow` the
    emoji panel and touch keyboard use. WezTerm and Windows Terminal never
    cover, since their opacity settings leave no trace in their styles.
  - **The class list's caveats.** A transparent Electron window (a
    `Chrome_WidgetWin_1` drawn with alpha, not layered) counts as opaque, and so
    does a UWP app whose `ApplicationFrameWindow` hosts an in-app acrylic (host
    backdrop) brush. Zen (acrylic), WezTerm and Windows Terminal never cover,
    even at full opacity, so a Kite under them earns no savings.
  - **What counts as seen.** It errs towards visible: Kite in front (a window
    of Kite's process is the foreground window when a verdict arrives, asked of
    Windows then; `WM_ACTIVATEAPP` clears covered at once), a window being dragged over or near a
    visible Kite or off a covered one (until the pass after the drop), or a
    taskbar thumbnail, Alt+Tab or Task View up. So does a screen recorder that
    runs only to record (OBS, XSplit, Bandicam, Camtasia's recorder,
    ScreenToGif, Zoom's sharing host), but not ones that stay resident (Windows
    11's Snipping Tool, ShareX, Snagit, Loom), which would switch covered
    detection off for good. Chromium makes no recorder exception at all.
  - **Hooks.** They run on their own thread, so other apps' windows never wake
    Kite's UI thread. Each one is on only while it can change the verdict:
    none while locked, display-off, minimized or on another desktop; while
    Kite is in front, only foreground changes and drags (a drag that starts in
    front comes too soon after the foreground change for a hook made then).
    System-wide hooks are kept only for events a person causes at a person's
    rate: an app coming forward, a drag, a minimize, a desktop switch. Per
    thread, the shell's shows on its preview threads (the taskbars' and the
    hosts of Alt+Tab and Task View) while Kite is covered, and their hides
    while one of those is up: never Explorer's whole process, where renaming
    a file or typing in Win+R raises a caret's show per key (File Explorer's
    windows each run on a thread of their own). Moves, z-order, state changes, shows, hides and destroys aren't
    hooked otherwise, not even for the windows over Kite. Measured: a caret
    raises a show, a hide and a move on every key (in the app being typed in,
    usually the one over Kite), a tooltip a show and a hide, every Win32 menu
    a create and a destroy (it's a window made each time it opens: 23.5
    context switches a second covered, for menus twice a second), and a moving
    window tens of moves a second, at 5 to 8 context switches each, past the
    watcher's 20 a second. And a maximize or restore raises only
    `LOCATIONCHANGE`, never a `STATECHANGE`. So a window newly over a visible
    Kite without coming forward is found at the next pass (it costs rendering,
    never a blank), and a closed occluder by the heartbeat. Kite's own move or
    resize pokes the thread once, when it ends (`WM_EXITSIZEMOVE`).
  - **Heartbeat.** What uncovers a covered Kite without an event (a
    restore-down, Win+Arrow, a FancyZones snap, leaving full screen, a monitor
    change, a window closed, hidden or turning translucent) is found by a
    heartbeat that runs only while Kite is covered. Twice a second it re-reads
    the windows that covered it with user32 alone (`IsWindow`, visible,
    minimized, maximized, its owner, `GetWindowRect`, the style, the extended
    style and layered alpha), and runs a pass on any change. Every 4 s it runs
    a whole pass, asking DWM afresh too, for z-order changes, new windows and
    a cloak or backdrop change. It's the watcher's MsgWait timeout, not a
    timer, and stops when Kite is uncovered. The first `WM_SETCURSOR` or
    `WM_MOUSEMOVE` to reach a covered Kite asks for a pass too. A drop, and a
    monitor, work-area or scale change, get a second pass 0.3 s later, once
    snaps and refits have settled. What it costs, measured per thread in
    kiteperf's covered phase: the browser process makes 5 to 8 more context
    switches a second than a build without P2, all of them on the occlusion
    watcher (the unnamed thread that starts in Kite.dll,
    `Occlusion::ThreadMain`; Chromium's threads are unchanged), which makes 7
    to 9. About 6.5 of those are the twice-a-second wake itself and about 2.5
    the whole pass's DWM questions every 4 s, more while another window
    animates (measured: 15 to 21 with a window moving 60 times a second, 7 to
    11 without the whole pass's DWM questions).
  - **DWM's answers** (a window's frame, backdrop and cloak, each a round trip
    to dwm.exe) are cached per window by its rect, and asked again for every
    window when they could be stale: the end of a lock or display-off, the
    pointer on a covered Kite, Kite's activation, any cloak event, and the
    heartbeat's whole passes.
  - **Off for test runs.** `--smoke-test` and `--frame-log` run without
    occlusion, so their checks of the slide and the crossfade can't pass
    unseen, and so does `--perf-control` until kiteperf asks for it in its
    covered phase: kiteperf opens Kite behind other windows, so its other
    phases would measure whatever the desktop happened to cover.
    `--occlusion-log FILE` (test profiles) writes each verdict and the
    thread's counters.
  - **Known gaps.** A covered Kite uncovered without an event shows its card
    until the heartbeat sees it, or the pointer reaches it. That's up to half
    a second for what the half-second check reads (an occluder moved, resized,
    minimized, restored, hidden, closed, or made translucent or
    click-through), and up to 4 s, the next whole pass, for what it doesn't:
    an occluder sent behind Kite without a foreground change, a window region
    set on it (`SetWindowRgn`), or its backdrop switched to acrylic. A Kite
    captured as a window by an app not on the recorder list (a meeting app
    sharing it while covered) shows its card. While a recorder runs, a covered
    Kite draws (the verdict is visible, so there's no heartbeat); the watcher
    waits on the recorder's process, and its exit runs a pass.

## Measuring performance

Kite.exe has three hooks for measuring it. They need `KITE_SUPPORT_PATH` to be a test profile,
one holding a `kite-test-profile` file (kiteperf writes it into each profile it makes), and
they're refused when it is the default profile (`%LOCALAPPDATA%\Kite`, from the environment or
the known folder, compared by volume and file id, so any spelling of it counts) or can't be
resolved. The checked directory stays open, undeletable, for the whole run, and the run uses its
resolved path. The marker guards against mistakes (a script pointed at the real profile), not
against another program running as the same user. Off, each costs
one predictable bool check (`perf::On()`) and allocates nothing. A run with any of them opens
behind other windows, without asking for the focus, and never shows a dialog, as
`--smoke-test` does.

- `--perf-log FILE`: JSON lines (`shell/PerfLog.h` lists them) with raw QueryPerformanceCounter
  values; the header has `qpcFrequency` and the Chromium switches. A writer thread writes them
  within 50 ms, so the UI thread never waits on the file. Marks: `started`, `window-created`,
  `first-commit`, `cef-init-begin` and `cef-init-end`, `shown`, `browser-created`, `load-begin`
  and `load-end` per tab (from CEF's thread), `command-begin` and `command-end` with the
  command's id, `loop-end`, `exit`, and any the control asks for. Each mark carries the counters
  so far: presents (the backdrop's and the command bar's), the real pointer's moves over and
  out of the window (not the control's; Kite's chrome only, since a page is CEF's own child
  window and its moves never reach Kite), commits (every
  `IDCompositionDevice::Commit`, which all go through `Compositor::Commit`) and surface draws per
  view. A dispatched message that takes over 8 ms is logged with how long it took. A control
  input (a pointer move or a command) is logged with its first commit within 250 ms, or with
  none, and the first composition frame the compositor made after that commit (a lower bound:
  it can take a commit up later), from `DCompositionGetFrameId` and `DCompositionGetStatistics`
  (Windows 11): the vblank the compositor made it for, and when it was presented on the monitor
  Kite's window is on, where the statistics can say. The frame clock's frames are logged with
  `--frame-log`'s content, the compositor's rate and the same frame times.
- `--perf-control`: requests by `WM_COPYDATA` (`dwData` 'KPRF', a UTF-8 JSON object):
  `{"command":ID}` runs a shortcut's command by its id (`kitecore shortcuts`), `{"mark":NAME}`
  logs a mark, `{"open":URL}` opens an http or https page in a tab, `{"input":"move","x":X,
  "y":Y,"qpc":Q}` posts a pointer move at client pixels, `{"input":"leave"}` takes it away, and
  `{"occlusion":"on"}` or `"off"` starts or stops watching whether the window can be seen
  (off under `--perf-control` until asked).
  A request is checked and queued, and the answer is 1, or 0 for one Kite can't run; it then
  runs from the message loop, so the sender isn't held and its dispatch is timed like any
  other. While a posted pointer is over the window the system's `WM_MOUSELEAVE` is ignored,
  since the real pointer is somewhere else.
- `--chromium-switches "--a --b=c"`: switches for Chromium's browser process
  (`OnBeforeCommandLineProcessing`), from an allow-list (`shell/PerfProtocol.h`): the GPU
  backend and rasterization (always in the sandboxed GPU process), throttling and backgrounding,
  the renderer limit, and four features that can be turned off by name, to measure Kite with one
  and without. Nothing that weakens the sandbox, site isolation or web security, opens a
  debugging port, or changes a path or a launched process. Chromium reads nothing else of
  Kite.exe's command line.

`kiteperf` (`windows/tools/perf`, built with the app by MSVC only, never shipped) drives them.
Each run launches Kite.exe on a fresh `%TEMP%` profile (marked `kite-test-profile`) holding
`sessions/perf-10tabs-2spaces.json` (ten static tabs, eight and two, in two spaces with
different themes), suspended into a job object; pages come from its own Winsock server on
127.0.0.1 to 127.0.0.12, port 18765, each address its own site. Kite inherits only its output
file. Once a second, and at each phase's start and end, it samples every process of Kite's (the
job's list, and a parent walk over the system's process list), typed by `--type` (`unknown`
when the command line can't be read): CPU, private working set and commit (never the shared
working set), writes, context switches (ended threads included), handles, threads, and PDH's
GPU memory and GPU engine time. A process that starts or ends mid-phase counts from its start
and to its end, and the job's own CPU total is kept beside the per-process sum as a check. Any
figure an API couldn't read is null, never 0. Each sample also says how
much of Kite's window no other window covers, whether the real pointer is over it and whether
it's in front, with dwm.exe and the rest of the machine for context. A phase is `noisy` when
the rest of the machine kept the CPUs over 25% busy; other work shares this PC, so results are
medians of runs.

For a PR (docs/windows-architecture.md, Performance), build main and the branch, then, back to
back:

```powershell
windows\build\tools\Release\kiteperf.exe --kite <main>\Kite.exe --phases idle,hover --runs 3 --label main --out main.json
windows\build\tools\Release\kiteperf.exe --kite <branch>\Kite.exe --phases idle,hover --runs 3 --label branch --out branch.json
windows\build\tools\Release\kiteperf.exe --compare main.json branch.json   # the markdown table for the PR
```

`--compare` warns when the two differ in scenario, phases, run count, frame statistics, GPU
counters, assets or the primary display's rate. `--chromium-switches` is checked against
Kite's allow-list before anything starts. The standard scenario's phases: open (every tab, a load each, counting processes
started and ended); settle 30 s; idle 60 s; switchSpaces (every 0.5 s for 20 s: the crossfade's
frame intervals from one clock, p50/p99 and missed, and switch-to-present); switchTabs and
reload (every 0.5 s for 10 s); hover (pointer moves posted at 120 Hz for 10 s over the rows:
moves sent, committed and move-to-present); titleTick (a page that retitles itself every
second, 20 s); anim (a CSS and requestAnimationFrame page selected, 10 s), hiddenAnim (the
same in a background tab, 20 s), covered (under kiteperf's own black window, with Kite's
occlusion turned on for the phase and off after it, 20 s; a Kite without the request, like a
build from before P2, refuses it and is measured as it is) and
minimized (20 s); then one `WM_CLOSE` and the time until every process is gone. `--phases`
runs some of them (open and settle always first); `--scenario idle` stops after idle,
`startup` after the first page, and `smoke` (CI) is a few seconds each of open, idle,
switchSpaces and hover. A request Kite refuses (when it comes in, or when it comes to run it), a
page that doesn't load within 3 s, or (in
smoke) a phase that logged no frames or moves fails the run (exit 3), and failed runs stay
out of the medians. The idle check fails when Kite presented or committed anything; it says
how often the real pointer moved over Kite meanwhile (Kite's own count), and exits 4 only when
it never did (Kite drew by itself).

Nothing in kiteperf takes the focus or sends real input: Kite opens behind other windows, the
moves are posted to it, the cover never activates and sits just over Kite in the z-order (not
topmost), and Kite is minimized with `SW_SHOWMINNOACTIVE`. Since Kite opens behind other
windows, its window is usually covered on a desktop in use, and each phase reports how
visible it was (`window.kiteVisiblePct`): anim is "selected", not necessarily on screen. Kite
itself can still come to the front: Chromium activates a top-level `Chrome_WidgetWin_1` of
Kite's as the first page's browser is made, so when nobody has used the machine for longer
than Windows' foreground lock timeout, Kite takes the foreground. A result says so
(`tookFocus`, and `kiteInFront` per phase).

## Plan

The checkpoint list in windows/helix/checkpoints.md is the detailed plan. In short:

1. Win32 shell that CI builds with MSVC, tests and launches (in review, #260:
   `windows/`, `.github/workflows/ci-windows-native.yml`).
2. The model core and session file with their tests and a shared fixture (in
   review, #260).
3. CEF: `windows/scripts/fetch-cef.ps1`, one browser per tab, windowed first
   so pages load (W6), then the sandbox (W6b, done) and the off-screen spike: D3D11
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
`KITE_SUPPORT_PATH` that isn't an existing directory, or isn't an absolute path,
is refused. With Chromium the build makes `Kite.dll` and `Kite.exe` (CEF's
bootstrap, see "Chromium's sandbox") in `windows/build/<config>`, the folder
that ships, with kitecore.exe and Chromium's runtime; the import libraries go to
`lib/<config>`, the tests to `tests/<config>` and the build tools to
`tools/<config>`. The runtime is copied when Kite.exe is made again (Kite.dll,
the manifest, the icon or the bootstrap changed); a runtime file deleted from
the folder by hand comes back only with that, or a clean build. CMake stops until `fetch-cef.ps1` has built the sandboxed
wrapper (`build-sandbox-*`).

## Installing

What ships is `windows/build/Release` without `*.lib`, `*.pdb` and `*.exp`
(CI's `kite-windows-x64` artifact). Two things a copy of it
needs that a plain copy doesn't give:

- **The LPAC grant**, once, on the install folder, inheritable so that files
  copied in later get it too (robocopy and a zip don't carry the build folder's):

  ```
  icacls "%LOCALAPPDATA%\Programs\Kite" /grant "*S-1-15-2-2:(OI)(CI)(RX)"
  ```

  Today's helpers run without it (see "Chromium's sandbox"); a helper Chromium
  puts in an LPAC AppContainer can't load Kite.dll or libcef.dll without it.
- **Signing covers Kite.exe, Kite.dll and libcef.dll with the same
  certificate**, and chrome_elf.dll with them. Once Kite.exe is signed, the
  bootstrap requires the DLL it loads and chrome_elf.dll to carry valid
  signatures with the same primary certificate, or it stops (CEF's
  `bootstrap_win.cc`, `CheckDllCodeSigning`). libcef.dll is signed with them so
  the whole set is one publisher's. An unsigned build passes because all of them
  are unsigned.

Every run, quiet or not, makes its pages without activating them. CEF shows a
page's Chromium widget (`Chrome_WidgetWin_1`, the child of its `CefBrowserWindow`
host) with views' `Widget::Show`, whose `HWNDMessageHandler::Activate` calls
`SetForegroundWindow` on it, so a page made while Kite was behind another app (a
quiet run's first page, a popup a background page opened) brought Kite in front
whenever Windows let it (a process launched on an idle PC may). Kite makes the
host window with `WS_EX_NOACTIVATE`, which CEF copies onto the widget for that
show and takes off again (`CefBrowserPlatformDelegateNativeWin::CreateHostWindow`
in CEF's `libcef/browser/native/browser_platform_delegate_native_win.cc`), and
takes it off the host once the browser exists (`SetAsPage` and `OnAfterCreated`
in `shell/Chromium.cpp`), so clicks activate a page as before.

Quiet runs (decided in `main.cpp`, its `quiet`; `Options::quiet` everywhere
else) never come to the front, as the Mac's `KITE_DIAGNOSTICS=1` runs (KiteCore's
`WindowPresentation`). The window opens behind the others without activating,
keeps `WS_EX_NOACTIVATE` (Windows doesn't hand it the foreground when the window
in front closes) and answers `WM_MOUSEACTIVATE` with `MA_NOACTIVATE`; a relaunch
doesn't bring it forward. Its pages never take the focus, and show no dialogs:
file choosers are cancelled, JavaScript dialogs suppressed, Leave Page answered
Leave, and `window.print()` and Developer Tools skipped, each with the Mac's
`KITE_TEST_MODAL: <what>` line on stderr. Only a smoke test has pages for these
to matter: a capture starts no Chromium. Both watch `EVENT_SYSTEM_FOREGROUND`
for Kite's process (`shell/QuietRun.h`): `--smoke-test` fails if any of its
windows became the foreground window, and a capture says so on stderr. Clicking
a quiet run's taskbar button brings it forward, which fails a local smoke test.

Off Windows, the model and its tests build natively, and MinGW cross-compiles the app:

```bash
cmake -S windows -B /tmp/kite-core && cmake --build /tmp/kite-core -j && ctest --test-dir /tmp/kite-core
# The same tests under ASan and UBSan, as CI runs them (KITE_WERROR=OFF: the build above gates warnings):
cmake -S windows -B /tmp/kite-asan -DCMAKE_BUILD_TYPE=Debug -DKITE_WERROR=OFF -DCMAKE_CXX_FLAGS="-O1 -fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=undefined" -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=address,undefined" && cmake --build /tmp/kite-asan --target KiteCoreTests -j && ctest --test-dir /tmp/kite-asan -R KiteCoreTests
cmake -S windows -B /tmp/kite-mingw -DCMAKE_TOOLCHAIN_FILE="$PWD/windows/cmake/mingw-w64.cmake" && cmake --build /tmp/kite-mingw -j
```
