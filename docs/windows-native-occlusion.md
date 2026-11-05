# Chromium's native occlusion tracker in Kite for Windows (P12a)

A measurement for a decision: should Kite for Windows turn off Chromium's own window occlusion
tracker (`--disable-features=CalculateNativeWinOcclusion`)? It's a Chromium switch, so it's
Gabe's call (perf plan row P12). Nothing here changes Kite's switches.

This stacks on #363 (kiteperf), which stacks on #359 (`--chromium-switches` for test profiles).
The measurement tool is `windows/tools/perf/native-occlusion/occlusion-ab.cpp`.

## Short answer

- **The busy thread is Chromium's tracker.** The thread is
  `ThreadPoolSingleThreadCOMSTASharedForegroundBlocking`. With the feature on, it takes
  1,820–1,850 context switches and about 18 ms of CPU a second whenever any app's window
  animates anywhere on the desktop, over Kite or not. With the feature off, it does nothing:
  0.0 context switches a second in every phase of every run.
- **It can't see a covered Kite.** It tracks each page's child window, and its walk only
  visits top-level windows.
- **It does one thing for Kite.** While the session is locked or the display is off, it
  marks every page occluded, so pages report `hidden` and stop animating. With it off and the
  display off, an animating page ran `requestAnimationFrame` at about 357 fps, and Kite went
  from 5 to 431 ms of CPU a second.
- **Recommendation: turn it off together with P2 (#379), not before.** P2 hides the page on
  lock and display off itself, and also when Kite is covered or on another desktop.

## What the tracker is

`ui/aura/native_window_occlusion_tracker_win.cc` (read at Chromium 156.0.8078.17, CEF 156's).
In Kite's browser process it's the thread named
`ThreadPoolSingleThreadCOMSTASharedForegroundBlocking`: a COM STA task runner
(`MayBlock`, `USER_VISIBLE`) that base names that way. The P2 work saw that thread at
119–138 context switches a second on origin/main.

- Every aura root window Chromium makes is registered with it. For a windowed CEF browser
  that's the page's own `Chrome_WidgetWin_0`, a child of Kite's `CefBrowserWindow` host,
  which is a child of Kite's window.
- While it tracks any window, it keeps out-of-context WinEvent hooks on that thread:
  system-wide for foreground, move/size start and end, minimize start and end, show/hide,
  state change, cloak/uncloak and capture end, plus `EVENT_OBJECT_LOCATIONCHANGE` for every
  process that has a visible, opaque top-level window. Every event delivered wakes the thread
  (a context switch), even the ones it then ignores.
- An event it acts on starts a 16 ms timer. When the timer fires, it walks every top-level
  window with `EnumWindows`, subtracting each opaque window's rect from the screen, until it
  reaches the tracked windows. That decides VISIBLE or OCCLUDED for each one.
- On lock (`WTS_SESSION_LOCK`) and display off (`GUID_SESSION_DISPLAY_STATUS`) it marks every
  tracked window OCCLUDED, whatever the walk says (`MarkNonIconicWindowsOccluded`,
  `UpdateOcclusionState`).

## Why it can't see a covered Kite

In Chromium 156 the tracked HWND is the page's widget, a child window. `EnumWindows` only
lists top-level windows, so the walk never reaches it.

- Its state stays UNKNOWN, which Chromium treats as visible.
- A covered Kite never makes its pages OCCLUDED. This is the gap docs/windows.md already
  notes ("Chromium's occlusion tracking covers only its own top-level windows"), and P2 (#379)
  fills it with Kite's own hooks.
- With a tracked window always UNKNOWN, the walk never ends early, so every pass visits every
  top-level window on the desktop.

Chromium's main branch now maps an embedded widget to its `GA_ROOT` window (Kite's own
window) before tracking it. A CEF upgrade that brings that in would let the tracker see a
covered Kite, overlapping P2. Re-check this note on the next CEF bump.

## What it does do for Kite: lock and display off

The forced OCCLUDED on lock and display off doesn't depend on the walk, so it does reach Kite's
pages. Chromium hides an occluded page: `document.visibilityState` becomes `hidden`,
`requestAnimationFrame` stops and timers are throttled.

Measured with the display off (below), on a page that writes its `visibilityState` history
into its title, read back from the session Kite saves on closing:

| arm | static page, 3 runs | animating page, 3 runs |
|---|---|---|
| tracker on | `hidden` from the first second to the end (one run saw 25 s `visible` mid-idle) | `hidden` throughout, 0 rAF frames |
| tracker off | `visible` until Kite closed | `visible` until Kite closed, 39,931–40,202 rAF frames in about 112 s |

That's the one thing Kite gets from the tracker today, and turning it off loses it.

## Numbers

Kite for Windows at perf/P0b-kiteperf (1618b7f5), Release, CEF 156.0.7 / Chromium
156.0.8078.17, on Gabe's PC (Windows 11 26200, 2560×1440). "on" is Chromium's default; "off"
is `--chromium-switches "--disable-features=CalculateNativeWinOcclusion"`.

- The arms alternated, on then off, 3 runs each, and the tables give medians. Each run is a
  fresh test profile with one local page, 60 s idle (30 s for the animating page), then 20 s for
  each other phase.
- CPU is ms per second from CPU cycles (`QueryThreadCycleTime`, process cycle times, TSC at
  4.70 GHz), summed over every Kite process. The 100 ns thread times move only at the 15.6 ms
  clock tick, which is too coarse for a thread that wakes for microseconds.
- cs/s is context switches per second, from `NtQuerySystemInformation`.
- "Tracker" is the browser process's threads named
  `ThreadPoolSingleThreadCOMSTASharedForegroundBlocking`. There are two in both arms; with
  the feature off both are idle.
- The display was off for every run.
- The mover is the tool's own captioned window, moved 60 times a second with
  `SWP_NOACTIVATE`. In nearMover it slides right of Kite and never touches it; in overMover
  it slides over Kite's page.
- The tables come from the scratch prototype of the committed tool (same phases, page and
  counters). The committed `occlusion-ab.cpp` was checked with one short run of each arm,
  which agreed (tracker 1,917 and 1,841 cs/s under the movers, 0 with it off).
- The build carried #366's `WS_EX_NOACTIVATE` page style as a local, uncommitted patch in both
  arms, so no run took the foreground (none did).

Static page:

| phase | Kite CPU ms/s on | off | Kite cs/s on | off | tracker ms/s on | off | tracker cs/s on | off |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| idle | 3.7 | 5.6 | 136 | 108 | 0.1 | 0.0 | 6 | 0 |
| nearMover | 20.4 | 3.1 | 2,011 | 31 | 17.6 | 0.0 | 1,823 | 0 |
| covered | 0.6 | 6.0 | 15 | 26 | 0.0 | 0.0 | 4 | 0 |
| overMover | 20.5 | 2.5 | 2,032 | 24 | 18.1 | 0.0 | 1,846 | 0 |

Animating page (a CSS spin and a `requestAnimationFrame` canvas):

| phase | Kite CPU ms/s on | off | GPU process ms/s on | off | renderer ms/s on | off | tracker cs/s on | off |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| idle | 5.0 | 431.5 | 1.6 | 261.5 | 0.2 | 165.2 | 0 | 0 |
| nearMover | 21.4 | 447.0 | 0.1 | 273.6 | 0.3 | 169.0 | 1,822 | 0 |
| covered | 1.6 | 440.9 | 0.0 | 264.5 | 0.0 | 168.2 | 7 | 0 |
| overMover | 20.3 | 422.0 | 0.0 | 258.5 | 0.0 | 159.6 | 1,835 | 0 |

Reading them:

- **The tracker's cost follows other windows, not Kite.** Any captioned app window moving
  anywhere costs the browser process about 18 ms/s of CPU and 1,800+ wakeups a second. That's
  about 30 wakeups per move, plus a full `EnumWindows` walk every 16 ms. A window over Kite costs
  the same as one beside it.
- **Idle depends on the desktop.** With nobody at the PC, the idle phase was 0.2–27 cs/s
  (median 6). P2's 119–138 cs/s was on a desktop in use. P2's 372 cs/s "while another window
  moves" was a `WS_POPUP` mover: the tracker wakes for a popup's moves but then skips them,
  so it pays the wakeups without the walks.
- **Drags are cheaper.** A user dragging a window sends move/size start and end, and the
  tracker skips the moves in between. An app that moves its own window (an animation, a
  sliding notification, a video player's overlay) is the expensive case measured here.
- **The page costs dwarf the tracker's only while the display is off.** The static page's
  idle and covered CPU is higher with the tracker off (5.6 vs 3.7, 6.0 vs 0.6 ms/s) for the
  same reason as the animating page's 431 ms/s: the page stays `visible`.

kiteperf's whole-process view: `--phases idle,covered --runs 3`, one arm after the other, with the
display off. Its standard session is ten tabs; covered comes after it opens the animating
page.

| phase | Kite CPU ms/s on | off | private MB on | off | GPU MB on | off |
|---|---:|---:|---:|---:|---:|---:|
| idle | 1.6 | 4.2 | 182.2 | 191.8 | 133.2 | 148.9 |
| covered | 2.3 | 551.7 | 182.4 | 219.6 | 138.4 | 161.4 |

- **It agrees.** With the display off, the "off" arm's pages stay `visible`, and the animating
  page runs flat out under kiteperf's cover.
- **It can't show the tracker's own cost.** kiteperf's cover is a tool window, which the tracker
  ignores, and it has no moving window. Both arms passed the idle check (no presents, no
  commits).

## Display state

The display was off for every run. This PC's monitor was off from idle the whole session,
except about a minute at 20:50, which ended before a run could start. That doesn't make the
tracker dormant, so the A/B is still a valid measure of its cost:

- **What stays on.** Display off doesn't unregister its hooks or stop its walks: with the
  display off it still took 1,820+ cs/s under a moving window. The power notification only
  changes what it reports (everything OCCLUDED), not whether it runs.
- **What changes.** The idle numbers are a floor: other apps make fewer window events with
  nobody at the PC. The "off" arm's page costs are display-off only: with the display on, both
  arms' pages are `visible` (the tracker can't see a covered Kite), so the page costs match and
  the only difference left is the tracker thread.
- **To confirm with the display on,** run the tool without `--any-display` (Re-running it,
  below). It waits for the display, keeps it on while a run goes, and leaves out any run
  whose display went off.

## Risks of turning it off

- **Lock and display off.** Pages would keep running while the session is locked or the display
  is off. P2 (#379) covers both itself: it hides the shown page's widget on
  `WTS_SESSION_LOCK` and on `GUID_SESSION_DISPLAY_STATUS` off, as well as when Kite is cloaked
  or covered. Without P2, turning the tracker off is a regression for an animating page left
  open overnight.
- **Nothing else in Kite reads it.** No Kite code reads page visibility, Chromium's occlusion
  state or `WasHidden`. Background tabs and a minimized Kite are hidden by hiding their widget
  windows (docs/windows.md, Rendering), which doesn't involve the tracker.
- **DevTools.** Developer Tools opens as a Chrome-style top-level window, which the tracker
  does see. With it off, a covered DevTools window keeps drawing. That's minor.
- **Video capture and screen sharing.** No change. Chromium already counts a captured page as
  visible whatever the tracker says (`WindowTreeHost`'s video-capture count).
- **A CEF upgrade** may make the tracker work for child windows (above). The switch would then
  turn off something that works. P2 would still cover the same cases.

## Recommendation

Turn the tracker off on Windows, in the same change as P2 (#379) or after it lands, never
before.

- **With P2,** turning it off loses nothing. P2 covers lock and display off itself, and covered
  and cloaked too, which Chromium's tracker can't do for Kite. It saves about 18 ms of CPU and
  1,800 wakeups a second whenever any app's window animates, and the tracker's idle wakeups
  otherwise (6 to 130 cs/s, depending on the desktop). P2 measured 6–10 cs/s for its own
  hooks with another process's window sliding beside Kite (#379).
- **Without P2,** turning it off is a regression. With the display off or the session locked,
  pages keep running: 431 ms/s of CPU for one animating page, where the tracker kept it at 5.
- **The switch itself:** add `--disable-features=CalculateNativeWinOcclusion` in
  `OnBeforeCommandLineProcessing`, beside P2. If Kite ever sets other `disable-features`,
  merge the lists into one switch: a second `--disable-features` replaces the first.
- **This is Windows only.** The tracker and the switch don't exist on the Mac, which uses
  AppKit's occlusion (perf plan P12 says "both platforms" for the audit as a whole).
- **Re-check after a CEF upgrade.** If Chromium's `GA_ROOT` mapping arrives, the tracker would
  see Kite's window and could do P2's covered case itself. Measure again then, since it would
  also hide pages when Kite's window is covered, which P2 already does.

## Re-running it

From a Visual Studio developer prompt, with Kite built (Release):

```powershell
cd windows\tools\perf\native-occlusion
cl /nologo /O2 /EHsc /std:c++20 /W4 /DUNICODE /D_UNICODE /DNOMINMAX occlusion-ab.cpp
.\occlusion-ab.exe --kite ..\..\..\build\Release\Kite.exe --runs 3 --out static.jsonl
.\occlusion-ab.exe --kite ..\..\..\build\Release\Kite.exe --runs 3 --page anim --idle 30 --out anim.jsonl
```

- It waits for the display to be on and never wakes it. It keeps the display on while a run
  goes, and leaves out of the medians any run whose display went off. Pass `--any-display` to
  measure regardless, as was done here.
- It prints the medians as a markdown table, and writes one JSON line per run to `--out`. Each
  line has per-process-type and per-thread numbers, and the page's visibility history.
- Nothing in it takes the focus or sends input. Kite is a quiet `--perf-log` run, and the tool's
  own windows are `WS_EX_NOACTIVATE`, moved with `SWP_NOACTIVATE`.
- Until #366 lands, Kite itself can still take the foreground when the PC has been idle
  longer than Windows' foreground lock timeout (docs/windows.md, Measuring performance). The
  runs here used a build with #366's page style patched in for that reason.
- kiteperf's `idle` and `covered` phases give the whole-process view with
  `--chromium-switches "--disable-features=CalculateNativeWinOcclusion"`. Its cover is a tool
  window, which the tracker ignores by design, so kiteperf alone can't show the tracker's cost
  under a moving window.
