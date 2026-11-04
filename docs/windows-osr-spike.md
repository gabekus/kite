# Kite for Windows: the off-screen CEF spike (W10)

The measured spike behind DECISION 1 in the parity plan: should production Kite move its pages
from windowed CEF (one child HWND per browser) to off-screen rendering (OSR, shared D3D11
textures), for the card's 6pt corners, Peek and split-view overlays? This is evidence, not a
production feature. Everything here runs only with `--osr` on a test profile
(`KITE_SUPPORT_PATH`); without it Kite is unchanged.

Measured on Gabe's PC, 2026-11-04: Ryzen 7 9800X3D, Radeon RX 9070 XT driving one 2560×1440
display at **500 Hz**, 100% scale, plus the CPU's Radeon iGPU (no display). Windows 11 25H2
(26200), CEF 156.0.7 (Chromium 156.0.8078.17). Other agents' builds and Kites ran at the same
time, so every row records the system's CPU load and the numbers are medians of 3 runs.

## Recommendation

**Go, with conditions.** Off-screen pages work: in a day's spike every input path that matters
for browsing (mouse, double click, wheel, keys, committed IME text, cursors, `<select>`
popups) works through Kite's window, hidden and minimized pages stop drawing, a static page
presents nothing, and the card gets the Mac's anti-aliased 6pt corners. That's what Peek,
split view and the glow need, and no windowed design gets the corners (a child window can't be
clipped smoothly, and the backdrop under the corners is DWM's acrylic, which Kite can't redraw
over it).

It costs, measured against windowed on the same pages:

- **Input latency: +4 ms while a page is drawing, +14 ms from idle** (posted mousemove to the
  first composed frame showing it: 9.7 vs 5.4 ms p50 animating, 11.3 vs 7.5 scrolling, 19.5
  vs 5.2 static), at 500 Hz. That's 2 and 7 vblanks here; at 60 Hz the same pipeline depth is
  one to two frames.
- **CPU: +0.4–0.5 ms per frame**, almost all on CEF's UI thread in Kite.exe (228 ms/s at 475
  frames/s, against 2 ms/s windowed): 1.24 vs 0.76 ms of Kite's processes per frame
  animating, 1.42 vs 0.99 scrolling. Idle and minimized it's as cheap or cheaper (7.8 vs 14.1
  and 1.6 vs 6.2 ms/s).
- **GPU memory: +22 to +30 MB in Kite.exe and +16 to +41 MB in the GPU process** for one
  1030×778 page (Kite's swap chain and device, Chromium's capture pool), growing with the card.
- **Frames: 464–484/s against 490–496/s** at 500 Hz; the p99 interval is 2 vblanks off-screen,
  1–2 windowed.
- **Missing: accessibility (the page is invisible to UIA), drag and drop, IME composition
  glue, touch/pen and precision-touchpad gestures.** Windowed Chromium has all of them free.

The conditions, as the W35 checkpoints below: windowed pages stay a switchable fallback
(`--windowed-pages`) until W35c lands; W35a has to bring the from-idle latency down (the 14
ms is the biggest number here and the first thing to chase) and carry kiteperf gates for
idle, latency and CPU per frame; and off-screen doesn't become the default until W35c's
accessibility bridge passes a Narrator check. If W35a can't get from-idle input within a
frame or so of windowed, the fallback is the hybrid below (Hybrid), not the windowed status
quo.

## What the spike is

- `shell/OffscreenPage.{h,cpp}`: the presenter. A D3D11 device of its own on Kite's
  renderer's adapter (multithread-protected), a composition swap chain shown by a
  DirectComposition visual in a new page layer of Kite's tree (`Compositor::PageLayer`, over
  the chrome, under the overlay). `OnAcceleratedPaint` runs on CEF's UI thread; there the pool
  texture is opened (`OpenSharedResource1`, every frame, as CEF requires), drawn into the swap
  chain's back buffer in one pass that cuts the card's 6pt corners out with an anti-aliased
  rounded-rect SDF (`shaders/OffscreenPage.hlsl`, compiled by fxc at build time), and presented
  (`Present(1, 0)`) before the callback returns. Kite's thread never touches that device; the
  visual picks up each present without a commit. Kite's own device and its single-threaded
  Direct2D factory are untouched, so the W10 row's ID2D1Multithread concern doesn't arise.
- `shell/Chromium.cpp`, with `--osr`: `windowless_rendering_enabled`,
  `SetAsWindowless` + `shared_texture_enabled`, `windowless_frame_rate` = the monitor's
  refresh rate (500; `KITE_OSR_FPS` overrides), and the presenter on Kite's renderer's
  adapter (which Chromium's GPU process picks too; see Adapter). A `CefRenderHandler`
  (`GetViewRect`, `GetScreenInfo` with the window's scale, `GetScreenPoint`, `OnPopupShow`/`OnPopupSize`, `OnAcceleratedPaint`,
  `OnImeCompositionRangeChanged`), `OnCursorChange`, and `LayoutOffscreen`: the shown page gets
  `WasHidden(false)` + `WasResized` + `Invalidate`, every other page (and all of them while
  minimized) `WasHidden(true)`. No page windows, so none of the windowed path's widget-window
  hiding, `EnableWindow`, or cross-thread focus waits.
- `Chromium::ForwardInput`, called from the window's message filter after the sidebar's:
  `WM_MOUSEMOVE`/buttons/double-click counting/capture → `SendMouseMoveEvent` and
  `SendMouseClickEvent`; `WM_MOUSEWHEEL`/`WM_MOUSEHWHEEL` → `SendMouseWheelEvent`; keys and
  characters → `SendKeyEvent` (cefclient's modifier mapping) while the page has the keyboard
  (a click in the card gives it; a click elsewhere, the command bar, or the window losing focus
  takes it); `WM_MOUSELEAVE` → mouse-leave; `WM_SETCURSOR` → the page's cursor. Points are
  client px minus the card's origin, divided by the window's scale (DIPs).
- `--capture` with `--osr` starts Chromium, waits for the page's first frame and composes the
  presented frame (read back on CEF's thread) at the card. A windowed capture still leaves the
  page out.
- `KITE_OSR_SELFTEST=FILE` drives `windows/helix/pages/osr-selftest.html` by posting Win32
  messages to Kite's own window (the path a real mouse and keyboard take) and logs what the page
  saw. No real input, no focus taken.
- `windows/tools/osrperf` (standalone, not in Kite's build; P0b's kiteperf didn't exist yet):
  launches Kite on a test profile without activating it, behind every other window, and measures
  one page. Details under Method.

## What works, and what doesn't

Checked with the self-test (all through Kite's window messages unless noted):

| | result |
|---|---|
| Page in the composition tree, 6pt corners | works; anti-aliased, as the Mac's (captures below) |
| Mouse move, click, focus | works; the field takes focus, I-beam cursor |
| Double click | works (Kite counts clicks: Chromium doesn't off-screen); selects a word |
| Wheel | works; 3 notches scroll 300 px with Chromium's smooth scrolling |
| Keys, characters | works (`WM_CHAR` "ab" typed) |
| Cursors (`OnCursorChange`) | works: I-beam over the field, hand over the link (`CT_HAND`) |
| `<select>` popup (`OnPopupShow`/`OnPopupSize`, `PET_POPUP` paints) | works: opens, Down + Enter picks "two"; Kite composes the popup's texture over the view's |
| IME, committed text | works without glue: `WM_IME_CHAR` → DefWindowProc → `WM_CHAR` → the page (漢) |
| IME, composition | CEF's side works (`ImeSetComposition` → compositionstart/update, `ImeCommitText` → compositionend, `OnImeCompositionRangeChanged` fires). Kite's side (IMM32: `WM_IME_COMPOSITION` → `ImeSetComposition`, `GCS_RESULTSTR` → `ImeCommitText`, `WM_IME_ENDCOMPOSITION`, the candidate window at the caret) isn't written: without it the IME shows its own floating composition window. Not tried with a real IME: that needs real input and switching the input method (global on Windows by default). cefclient's `osr_ime_handler_win.cc` is the reference, about 400 lines |
| WasHidden for hidden tabs | works: a popup tab in front makes its opener report `hidden` and its frames stop (`hides`, no ignored paints); minimized → no presents (Measurements) |
| WasResized | works on every card change; resizing is live (the texture follows the swap chain; frames of the old size are clipped to the card) |
| Adapter | Chromium's GPU process and the presenter are on the same GPU without being told; `--use-adapter-luid` breaks Chromium here (Measurements) |
| Drag and drop | not done. Needs `StartDragging` (DoDragDrop with an IDataObject from `CefDragData`) and an `IDropTarget` on Kite's window feeding `DragTargetDragEnter/Over/Leave/Drop`, plus `DragSourceEndedAt`/`DragSourceSystemDragEnded` (cefclient's `osr_dragdrop_win.cc`, about 700 lines). Windowed pages get it from Chromium for free |
| Accessibility | not done. An off-screen page has no HWND, so Narrator and other UIA clients see nothing of the page. Needs a `CefAccessibilityHandler` bridge into a UIA provider tree on Kite's window (cefclient's partial `osr_accessibility_*`, about 1,000 lines, does names and roles only). This is the biggest gap |
| Context menu | not tried (CEF's default menu would show a modal menu on screen during the test) |
| Touch, pen, precision touchpad | not done. Needs `WM_POINTER` → `SendTouchEvent`. Windowed Chromium uses DirectManipulation for touchpad scrolling and pinch; off-screen, a touchpad arrives as `WM_MOUSEWHEEL` deltas, so scrolling loses its precise feel and overscroll |
| Tooltips (`title=`), `<input type=color>`/date pickers, autofill, permission bubbles | not tried; all go through `OnPopupShow` or Kite-drawn UI off-screen |

## Measurements

Medians of 3 runs (sys CPU is the whole machine's load during the run). "All Kite" is
Kite.exe and every Chromium helper; dwm.exe is listed apart. Each run's JSON is in
`docs/windows-osr-spike/runs` (`m-*` the matrix, `min-*`, `clip-*`, `fps60-*` the
variations); `py windows/tools/osrperf/summarize.py docs/windows-osr-spike/runs m` makes these
tables.

| page | mode | sys CPU % | frames/s (WGC) | interval p50 / p99 ms | Kite.exe CPU ms/s | GPU proc CPU ms/s | renderer CPU ms/s | all Kite CPU ms/s | all Kite CPU ms/frame |
|---|---|---|---|---|---|---|---|---|---|
| anim | windowed | 21 | 496 | 2.00 / 2.00 | 1.6 | 282.8 | 75.0 | 375.0 | 0.76 |
| anim | --osr | 17 | 464 | 2.00 / 4.00 | 228.0 | 299.9 | 64.0 | 578.0 | 1.24 |
| scroll | windowed | 45 | 490 | 2.00 / 4.00 | 14.1 | 301.6 | 170.3 | 487.2 | 0.99 |
| scroll | --osr | 50 | 484 | 2.00 / 4.00 | 232.6 | 323.0 | 167.0 | 694.5 | 1.42 |
| static | windowed | 20 | **0** | - | 7.8 | 1.6 | 4.7 | 14.1 | - |
| static | --osr | 27 | **0** | - | 3.1 | 3.1 | 0.0 | 7.8 | - |

| page | mode | GPU engine ms/s: Kite.exe / GPU proc / dwm | GPU dedicated MB: Kite.exe / GPU proc | input to frame p50 / p90 ms | --osr presents/s, copy+present ms |
|---|---|---|---|---|---|
| anim | windowed | 0.0 / 7.9 / 27.5 | 34 / 29 | **5.4** / 6.0 | - |
| anim | --osr | 9.5 / 11.6 / 2.2 | 64 / 54 | **9.7** / 11.4 | 475, 0.89 |
| scroll | windowed | 0.0 / 9.5 / 24.3 | 34 / 56 | **7.5** / 8.2 | - |
| scroll | --osr | 10.2 / 13.2 / 2.3 | 64 / 97 | **11.3** / 14.2 | 499, 1.81 |
| static | windowed | 0.0 / 0.0 / 12.9 | 34 / 32 | **5.2** / 6.6 | - |
| static | --osr | 0.0 / 0.0 / 16.7 | 56 / 48 | **19.5** / 21.7 | 0, - |

No latency sample was missed (40 per run). "copy+present" is the wall time on CEF's UI thread
from `OnAcceleratedPaint` to `Present` returning, open and draw included.

Variations, 2 runs each on the anim page (static where marked):

| | result |
|---|---|
| Minimized (`--minimize`, 5 s) | windowed 6.2 ms/s of Kite CPU; `--osr` 1.6 ms/s and 0 presents (WasHidden) |
| `KITE_OSR_CLIP=dcomp` (DirectComposition's aliased clip, a plain `CopyResource`, opaque swap chain) | Kite.exe GPU engine 7.8 ms/s against the mask pass's 9.5 (about 3.5 µs a frame); CPU and frames the same within noise. The mask costs nothing that matters |
| `KITE_OSR_FPS=60` (windowless_frame_rate 60 on the 500 Hz display) | 60 frames/s, 98 ms/s of Kite CPU (1.65 ms/frame), input to frame 36.2 / 51.4 ms (about 2 frames at 60). Static from idle: 10.4 / 20.3 ms. There's no windowed 60 Hz baseline: Kite can't change the display's rate |
| Adapter | Without a switch Chromium's GPU process and Kite's renderer are both on the RX 9070 XT (LUID 0x90006E64, by PDH, the adapter holding each process's dedicated memory), so the shared texture never crosses GPUs. `--use-adapter-luid` is read only as `0xHIGH,0xLOW`; decimal (what the spike first passed) or one part is ignored. Honoured, in CEF 156 on this PC, it fails ANGLE's EGL display on **either** adapter: the GPU process crashes three times and Chromium ends the browser process ("GPU process isn't usable. Goodbye."), Kite with it. So the spike passes nothing by default (`KITE_OSR_LUID` for the experiment) |
| IDCompositionTexture | `osrperf dcomp4`: IDCompositionDevice4 and composition textures are supported on all three adapters here. Kite's tree is on the v1 API (`DCompositionCreateDevice`, `IDCompositionDevice`), and textures need `DCompositionCreateDevice3`'s device, so using them means moving Kite's tree to that API, and each frame becomes a `SetContent` + `Commit` on Kite's device from CEF's thread, where a swap chain's present needs neither. It would save the swap chain's two buffers (6 MB at this size) and maybe a queue stage of latency; not tried |

Kite.exe's CPU with `--osr` is CEF's UI thread: its off-screen plumbing (the frame sink
capturer's frames arriving over Mojo, the `CefAcceleratedPaintInfo`) and the presenter
(`OpenSharedResource1` every frame, as CEF requires, a draw and a present). The split wasn't
profiled; W35a should, with ETW. The GPU-engine numbers say the GPU cost is small either way:
Kite's pass is about 20 µs a frame. dwm.exe's GPU time is the whole desktop's and noisy, but
its medians were lower with `--osr` on both animated pages (2 against 24–28 ms/s), probably
because DWM composes one simple swap chain instead of Chromium's own DirectComposition tree.

The windowed static page had one run of the three at 115 WGC frames/s while Chromium's
processes were idle (GPU process 1.6 ms/s): DWM recomposing the window for something outside
the page. The median is 0, and every `--osr` static run was 0 frames and 0 presents.

## Captures

`Kite.exe --capture --capture-scale 2` with `windows/helix/pages/smoke.html`, in
`docs/windows-osr-spike/`: `capture-windowed.png` and `capture-osr.png`. Windowed leaves the
page out, as before; `--osr` includes it, with the 6pt corners (12 px at 2×) anti-aliased.
`dwm-windowed.png` and `dwm-osr.png` are the real windows as DWM composed them (the anim page),
and `corners-tl.png` the card's top-left corner at 10×: windowed (square), DirectComposition's
clip (aliased) and the shader (anti-aliased). `osrperf --shot` reads back what DWM composes
(Windows.Graphics.Capture), which shows the same for the real window, and shows that
DirectComposition's own rounded clip (`IDCompositionRectangleClip`, kept behind
`KITE_OSR_CLIP=dcomp`) is **aliased** even with `DCOMPOSITION_BORDER_MODE_SOFT`, opaque or
premultiplied: hence the shader.

## Method

`windows/tools/osrperf/osrperf.cpp`, per run: launch `Kite.exe --window-size 1280,820
[--osr]` with `SW_SHOWNOACTIVATE`, put it behind every other window, wait for the page's first
frame and 4 s more, then:

- **cpu**: 10 s, nothing watching. `GetProcessTimes` of Kite.exe and each Chromium helper (by
  `--type`), PDH `\GPU Engine(pid_*)\Running Time` (all engines) and `\GPU Process
  Memory(pid_*)\Dedicated Usage` per process, `GetSystemTimes` for the machine's load, and
  `--osr`'s own counters (`Local\KiteOsrSpike-<pid>`). dwm.exe's GPU time is listed too; it
  composes the whole desktop, so it's noisy.
- **cadence**: 10 s of Windows.Graphics.Capture on Kite's window (`MinUpdateInterval` 1 ms;
  the default caps it at 60): each frame DWM composes with a change in the window, with its
  QPC time. The same instrument for both modes: a windowed page's presents are Chromium's GPU
  process's, which Kite can't count, and DCompositionGetStatistics reports per-display frames,
  not per-window.
- **latency**: 40 times, a `WM_MOUSEMOVE` posted (to the page's deepest Chromium window when
  windowed; to Kite's window with `--osr`, which forwards it) alternating 12 px, then the first
  captured frame in which the page's grey block changed colour; the time from the post to that
  frame's `SystemRelativeTime`. Between posts 60–76 ms, off the vblank's phase. No real input.
- `windows/tools/osrperf/summarize.py` makes the tables (medians of the runs).

Pages: `windows/helix/pages/osr-anim.html` (three transform animations on Chromium's
compositor thread), `osr-scroll.html` (a long page scrolled by `requestAnimationFrame` on the
main thread), `osr-static.html` (nothing moves).

## Risks

- **Latency from idle.** 19.5 ms p50 against 5.2 windowed at 500 Hz, and 36 ms while
  animating at a 60 fps windowless rate. The off-screen pipeline has more stages: Chromium
  renders, viz's frame sink video capturer copies the frame into a pool texture, it crosses to
  the browser process, CEF calls `OnAcceleratedPaint` on its UI thread, Kite draws it into a
  second swap chain and presents, then DWM composes. From idle the begin-frame source and the
  capturer have to start too. Things to try in W35a: `external_begin_frame_enabled` driven by
  Kite's frame clock (`SendExternalBeginFrame` at the vblank, started on input), `Invalidate`
  on input, IDCompositionTexture instead of the swap chain, and `Present` timing.
- **CEF's UI thread.** It's also where every browser-side callback and Kite's page commands
  run. At 500 frames/s the frames take a quarter of a core there; a slow present or a busy
  frame delays everything else on it. The texture can't be handed to another thread (it goes
  back to the pool when the callback returns), so the work there has to stay small.
- **Accessibility.** No HWND, so screen readers see nothing of the page until Kite bridges
  `CefAccessibilityHandler` to UIA. That's a large piece of work (W35c) and a regression for
  anyone who relies on it, so it gates the default.
- **Everything Chromium does with its own window, Kite redoes:** drag and drop, IME
  composition and the candidate window, touch and pen, DirectManipulation's touchpad
  scrolling and pinch, tooltips' and pickers' popups, context menus, pointer lock,
  `NotifyScreenInfoChanged` on monitor and DPI changes. CEF's off-screen mode is also less
  used upstream than windowed, so more of its bugs will be Kite's to find.
- **Fractional scales.** `CefMouseEvent` takes whole DIPs, so at 125% or 150% a pointer
  position rounds by up to a pixel and a bit; and the view's size rounds to whole DIPs too.
  Not visible at this PC's 100%; check at 150% in W35b.
- **Video.** Off-screen frames are 8-bit BGRA: no HDR, no hardware overlays (MPO) for video,
  and protected (hardware DRM) video may not copy into the shared texture. Not tested.
- **GPU process failure.** A crashed or unusable GPU process ends Kite (seen with
  `--use-adapter-luid`); the windowed path is no different there, but off-screen also depends
  on the shared texture opening on the presenter's device. W35a needs the presenter to follow
  whatever adapter the texture comes from, and to rebuild on device loss of either device.
- **Tab switches** show the previous page's last frame until the new page paints (a frame or
  two, after `WasHidden(false)` + `Invalidate`). W35a should hide the visual until then.
- **Memory** grows with the card: the capture pool and the swap chain are the card's size, so a
  4K card costs roughly nine times this page's 50 MB.

### Hybrid (if W35a can't fix latency)

Keep the shown page windowed and use off-screen browsers only where an overlay must sit over a
page: Peek's page, drawn in the overlay target (topmost, so it shows over a child window, as the
command bar does today) and the glow. The card keeps square corners, split view gets square
panes, and the command bar still can't blur the page. CEF fixes a browser's mode when it's
made, so a page can't move between the two; a Peek "open" would reload it windowed.

## The checkpoints it implies

For the parity plan (C:\Users\Gabe\Documents\Claude\kite-windows-parity-plan.md):

- **W35a, off-screen pages in production.** The presenter per window as here (own D3D11
  device, the corner shader, `Present(1, 0)` on CEF's thread), plus: the adapter taken from the
  texture (open the handle on the adapter it opens on; never `--use-adapter-luid`), device loss
  of Kite's device, the presenter's and the GPU process, occlusion → `WasHidden` with P2's
  hooks (covered, locked, display off), no stale frame on a tab switch, `NotifyScreenInfoChanged`
  on monitor and DPI changes, `--capture` with the page (in this spike), the from-idle latency
  work in Risks, an ETW profile of CEF's UI thread, and kiteperf gates: idle presents 0, CPU per
  frame, input-to-frame against the windowed baseline. `--windowed-pages` stays.
- **W35b, off-screen input.** Done here: mouse, double click, capture, the vertical wheel,
  keys and characters, committed IME text, cursors, `<select>` popups (the horizontal and
  Shift wheel are written, not tested).
  Left: IMM32 composition glue and the candidate window (cefclient's `osr_ime_handler_win`),
  drag and drop both ways (`osr_dragdrop_win`), `WM_POINTER` touch and pen →
  `SendTouchEvent`, precision touchpad (DirectManipulation or `WM_POINTER` touchpad
  contacts), context menus (CEF's or Kite-drawn: ties to DECISION 2), tooltips, color and date
  pickers, autofill, pointer lock, fractional-DPI rounding, and Kite's shortcuts through
  `OnPreKeyEvent` with Use Both's second press (the window's filter runs Kite's shortcuts
  before forwarding, which already matches Prefer Kite; Prefer Websites needs the key sent
  first).
- **W35c, accessibility.** `CefAccessibilityHandler` → a UIA fragment tree on Kite's window
  (names, roles, bounds, focus, text and value patterns), checked with Narrator and
  Accessibility Insights. Off-screen becomes the default only after this.
