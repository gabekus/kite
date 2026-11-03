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
  src/shell/    Kite.exe: wWinMain, the Win32 window, composition, input
  src/cli/      kitecore: the model, headless
  tests/        unit tests (no test framework dependency)
  helix/        checkpoints.md and states/ (sessions for the UI gate)
  resources/    Kite.manifest (DPI, UTF-8 code page, long paths) and its MinGW .rc
  scripts/      fetch-cef.ps1, gen-unicode-tables.py
  cmake/        mingw-w64.cmake (cross-compile check off Windows)
```

## Rendering

The hard part is **airspace**. A Chromium child HWND draws on top of the
window's own composition tree, so the glow and Peek couldn't overlap the page.
Until W10, the command bar gets around it with a second DirectComposition
target on the window with topmost TRUE, which shows over child windows. While
the bar is open the page windows are disabled, so clicks reach Kite's window.
That target can't blur the page under it, though. The way out:

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
  backdrop swap chain, with the command bar's buffer (`--command-bar`) put
  over it on the CPU, as DirectComposition puts it. The caret is left out:
  it's its own visual. Once the sidebar and page are more visuals (W4, W10),
  the capture should read the composed window instead
  (Windows.Graphics.Capture).
- **Material:** the Mac's `.sidebar` material, blended behind the window, is
  Windows 11's acrylic system backdrop (`DWMSBT_TRANSIENTWINDOW`) under a
  window with no redirection bitmap. Where there's none (Windows 10, Windows
  11 before 22H2, Server) the backdrop is drawn over a solid colour, Mica's
  base (#202020 dark, #F3F3F3 light); whether acrylic's own fallback differs
  isn't checked yet. As on the Mac, the material's light or dark appearance
  follows the space's theme.
- **Input:** the off-screen path forwards mouse, keyboard and IME events to
  CEF (`SendMouseClickEvent`, `SendKeyEvent`, ...). This is the most work and
  the main risk, so prototype it first.

Fallback if the off-screen path is too costly: windowed CEF (child HWND), with
any overlays in separate layered top-level windows. That's simpler but less
flexible.

**Today (W6): windowed CEF**, so pages load while the off-screen path is
built (W10). `shell/Chromium` creates one Alloy-style browser per tab (as
the Mac's) as a child window over the content card (right of the sidebar's
240pt, inset 10pt). Other tabs' windows, and the shown one while Kite is
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
opener; its tab stays in the session until W5 closes tabs, but this run never
shows it again. Ctrl-click and middle-click open a link in a background tab,
Ctrl+Shift-click in a foreground one (a `target=_blank` link opens as a popup
tab either way, as on the Mac). The first page is made once the window is on
screen and not minimized. `--smoke-test` loads
`windows/helix/pages/smoke.html` in CI and fails unless one `WM_CLOSE`
closes every browser in time. Not yet: the card's 6pt corners (a child window can't be clipped
smoothly; W10), the sandbox (W6b), and the page in `--capture` (W4).

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
- **Our vsync clock** comes from DirectComposition: `DCompositionWaitForCompositorClock`
  (Windows 11) or `IDXGIOutput::WaitForVBlank` on the output the window is on,
  on a dedicated thread. It must follow the window to another monitor
  (`WM_DISPLAYCHANGE`, `WM_DPICHANGED`, `MonitorFromWindow`), the same way the
  macOS `FrameClock` follows `NSScreen`.
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
