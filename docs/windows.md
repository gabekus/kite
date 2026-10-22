# Kite for Windows

Goal: the same browser on Windows, as fast as we can make it, sharing as much as
possible with macOS.

## What carries over unchanged

- **KiteCore** (Swift, Foundation only): spaces, tabs, command-bar search, URL
  parsing, the hibernation policy, theme math, the session file. CI builds and
  tests it on Windows, so it stays portable.
- **The engine:** CEF's Chromium on Windows is the same version and API as on
  macOS. The Objective-C++ bridge becomes a plain C++ bridge with the same shape
  (one `KCBrowser` per tab, the same delegate events, DevTools/CDP calls), and
  Swift on Windows calls it through Swift's C++ interop.

## Shell

Swift 6 on Windows plus [swift-winrt](https://github.com/thebrowsercompany/swift-winrt)
for the WinUI 3 and Win32 APIs. That's The Browser Company's own toolchain from
Arc for Windows.

The hard part is **airspace**. A Chromium child HWND always draws on top of
XAML, so nothing (glow, Peek, command bar) could overlap the page. To avoid it:

- **Render Chromium off-screen with shared textures.** CEF's
  `shared_texture_enabled` hands us each frame as a D3D11 texture with no CPU
  copy (supported on Windows). We composite it ourselves, so the page is just
  another layer.
- **Compose everything with DirectComposition / Windows.UI.Composition:**
  theme backdrop, sidebar, page texture, glow, command bar. It's the same
  layering as the macOS window, all on the GPU.
- **Port the shaders to HLSL** (`Kite.metal` is about 150 lines of pure math:
  OKLab blend, grain, rounded-rect SDF glow). Keep them in sync with a
  golden-image test that renders both versions at fixed inputs.
- **Input:** the off-screen path forwards mouse, keyboard and IME events to
  CEF (`SendMouseClickEvent`, `SendKeyEvent`, ...). This is the most work and
  the main risk, so prototype it first.

Fallback if the off-screen path is too costly: windowed CEF (child HWND), with
any overlays in separate layered top-level windows. That's simpler but less
flexible.

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
- **Windows.UI.Composition animations** already run at the compositor's rate.
- The windowed CEF fallback (child HWND) renders at the monitor's rate on its own.



1. CI: KiteCore builds and tests on `windows-latest` (done; see `.github/workflows/ci.yml`).
2. Spike: Swift + CEF off-screen + D3D11 shared texture in a bare window,
   measuring frame time and input latency.
3. Port the bridge to C++ and the shaders to HLSL.
4. WinUI shell: sidebar, command bar, spaces.
