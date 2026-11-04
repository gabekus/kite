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
  tests/        unit tests (no test framework dependency)
  helix/        checkpoints.md and states/ (sessions for the UI gate)
  resources/    Kite.manifest (DPI, UTF-8 code page, long paths), its MinGW .rc, Version.rc
  tools/build/  StampBootstrap.cpp: makes Kite.exe from CEF's bootstrap.exe (W6b)
  scripts/      fetch-cef.ps1, gen-unicode-tables.py
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
  the window (`core/TitleBar`). The card starts under the buttons, 32pt
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
cell's backing shows (the Mac shows both), and a touchpad's sideways scroll over
the bar scrolls the strip until W9c sends it to the swipe.

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

Known differences from the Mac: during the 0.2 s slide only the selected page
takes clicks and shows hover (the Mac's outgoing page is a live list too), and
Space n for a missing space is passed on from Kite's own window but still kept
from a page (Chromium's key thread doesn't know the spaces). Not yet: the space
bar (W9b), a touchpad's swipe (W9c), reordering spaces and the space menu
(W9d). `Kite.exe --frame-log FILE` writes each frame the clock delivered in a
test run.

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
  a compositor property can't do). While it runs it calls
  `DCompositionBoostCompositorClock`, so a display with a dynamic refresh rate
  runs at its highest, as the Mac asks for the screen's maximum rate. The
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

Off Windows, the model and its tests build natively, and MinGW cross-compiles the app:

```bash
cmake -S windows -B /tmp/kite-core && cmake --build /tmp/kite-core -j && ctest --test-dir /tmp/kite-core
cmake -S windows -B /tmp/kite-mingw -DCMAKE_TOOLCHAIN_FILE="$PWD/windows/cmake/mingw-w64.cmake" && cmake --build /tmp/kite-mingw -j
```
