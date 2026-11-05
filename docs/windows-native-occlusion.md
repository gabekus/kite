# Chromium's native occlusion tracker in Kite for Windows (P12a, P12b)

**Off by default since P12b.** Kite for Windows turns off Chromium's own window occlusion
tracker: its browser process gets `--disable-features=CalculateNativeWinOcclusion`. Gabe made
the call (perf plan row P12) on P12a's measurement below, and P2 (#379), Kite's own occlusion,
does the one thing the tracker did for Kite. "P12b: off, with P2" below is the check that it
does.

- **Where.** `core/ChromiumSwitches.h` works out the switches and
  `KiteApp::OnBeforeCommandLineProcessing` (`shell/Chromium.cpp`) applies them. The feature goes
  after whatever `disable-features` CEF already has, never replacing it. CEF 156 turns off five
  features of its own, and Kite's helpers get all six:
  `--disable-features=AutofillActorMode,CalculateNativeWinOcclusion,EnableHangWatcher,GlicActorUi,KillOnInvalidNavigationHeaders,LensOverlay`.
  `kitecore chromium-switches` prints what Kite gives Chromium.
- **Checked.** `--smoke-test` reads Chromium's command line back and fails unless
  `CalculateNativeWinOcclusion`, named in the check itself (so emptying the default list fails
  it), is off and not also on (or on and not off, when a run turned it on), and unless every
  feature CEF had in its own lists is still there (`chromium_switches::FeatureProblem`). CI runs
  it both ways.
- **The measurement tool** is `windows/tools/perf/native-occlusion/occlusion-ab.cpp`. Its "on"
  arm turns the tracker back on and its "off" arm is Kite's default.

## Turning it back on

On a test profile (a `KITE_SUPPORT_PATH` holding a `kite-test-profile` file, as for every
measurement hook in docs/windows.md, Measuring performance):

```powershell
Kite.exe --perf-log run.jsonl --chromium-switches "--enable-features=CalculateNativeWinOcclusion"
kiteperf.exe --kite Kite.exe --chromium-switches "--enable-features=CalculateNativeWinOcclusion" ...
```

- `--enable-features=CalculateNativeWinOcclusion` is on `--chromium-switches`' allow-list
  (`shell/PerfProtocol.h`). It's the only feature that can be turned on there.
- It also takes the feature out of `disable-features`, so Chromium never gets it both on and
  off. Chromium would read that as off.
- A request that turns it on in one switch and off in another is refused.
- It's for the A/B tool, and for a check after a CEF update (below: Chromium's main branch may
  let the tracker see Kite's window). The default profile can't turn it on, so users can't
  either. Shipping it on again means changing `DefaultDisabledFeatures()` in
  `core/ChromiumSwitches.cpp`.

## P12b: off, with P2

Does P2 cover what the tracker did, with the tracker off? Kite at P12b, Release, CEF 156.0.7,
on Gabe's PC (Windows 11 26200, 2560×1440), 2026-11-05, with `occlusion-ab` (Re-running it,
below):

- 3 runs per arm, alternating, and the tables give medians. "on" is the tracker turned back
  on (`--enable-features`), "off" is Kite's default. Both arms have P2: off for idle, on from
  then on (kiteperf's way of turning it on).
- **The display was on for every phase of every run.** The tool checks it per phase and kept
  it from idling off.
- **The desktop was in use.** A quiet run opens at the bottom of the z-order, and Gabe's
  maximized windows covered it. So once P2 was on, its verdict was covered from its first
  pass in every run (each run's `--occlusion-log`).
- No run took the foreground (`kiteForeground` false in all 12).

Animating page (a CSS spin and a `requestAnimationFrame` canvas):

| phase | Kite CPU ms/s on | off | tracker cs/s on | off | page hidden % on | off | rAF fps on | off |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| idle (P2 off) | 463.2 | 462.8 | 0.3 | 0 | 0 | 0 | 349.3 | 349.6 |
| nearMover | 24.3 | 4.8 | 1,843 | 0 | 100 | 100 | 0 | 0 |
| covered | 10.0 | 10.6 | 3.5 | 0 | 100 | 100 | 0 | 0 |
| overMover | 27.0 | 8.4 | 1,852 | 0 | 100 | 100 | 0 | 0 |
| lockNotice | 4.7 | 2.6 | 0.9 | 0 | 100 | 100 | 0 | 0 |

Static page (30 s idle):

| phase | Kite CPU ms/s on | off | browser cs/s on | off | tracker cs/s on | off | page hidden % on | off |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| idle (P2 off) | 5.5 | 5.4 | 76 | 78 | 0.2 | 0 | 0 | 0 |
| nearMover | 22.7 | 3.7 | 2,053 | 49 | 1,835 | 0 | 100 | 100 |
| covered | 7.9 | 7.4 | 44 | 43 | 3.5 | 0 | 100 | 100 |
| overMover | 24.2 | 3.5 | 2,088 | 69 | 1,839 | 0 | 100 | 100 |
| lockNotice | 2.4 | 2.3 | 25 | 26 | 0 | 0 | 100 | 100 |

Reading them:

- **The tracker's cost is gone.** Under an app window moving 60 times a second, beside Kite or
  over it, the tracker took 1,835–1,852 cs/s and about 18 ms/s with it on, and nothing with it
  off. Kite's CPU there went from 22.7–27.0 to 3.5–8.4 ms/s.
- **Covered: P2 hides the page.** Once P2 was on, the page was `hidden` for the rest of the
  run and `requestAnimationFrame` stopped, in both arms. Kite's CPU for the animating page went
  from 463 ms/s (idle, P2 off) to 10 ms/s covered. The tracker made no difference there, since
  it can't see Kite. A kiteperf run agrees (one run, Kite's default): anim 666.1 ms/s,
  covered 6.2.
- **Lock: what could be measured.** lockNotice posts `WM_WTSSESSION_CHANGE` with
  `WTS_SESSION_LOCK` to Kite's window, and the unlock at the end. Nothing is locked, and
  Chromium's tracker, which listens on a window of its own, never hears it.
  - P2's verdict went to locked and back to covered in every run, at the phase's start and
    end (`covered@0.05 locked@66.3 covered@86.3`), and the page stayed `hidden` with no frames.
  - But the page was hidden already (covered). So this shows the lock path keeps a page hidden
    and comes back cleanly. It doesn't show that a lock hides a page Kite was showing.
  - That needs a Kite nothing covers before the lock. Gabe's desktop had no such place, and
    these runs never raise Kite over his windows.
  - The session was never actually locked.
- **Display off: not measured.** The display stayed on, and nothing here turns it off. What
  covers it:
  - P2 listens for `GUID_SESSION_DISPLAY_STATUS` (`shell/Occlusion.cpp`), and its tests take
    the verdict to DisplayOff and Locked and back (`OcclusionTests.cpp`:
    `lockDisplayAndCloakHideAndComeBack`, `lockedOrDisplayOffHooksNothingAndIgnoresEvents`).
  - Any hidden verdict hides the page the same way, through `SetOccluded`. That's the path
    the covered phase measured.
  - P12a measured what's at stake: 5 ms/s with the tracker on, 431 with it off, before P2.
- **The gap P12b found, closed by #410: a page made while Kite can't be seen.** A Kite that
  opened covered, with P2 on from its start, didn't hide its page.
  - Kite hid the page's windows as the browser attached, but Chromium showed the page about
    0.4 s after its load, and with the verdict unchanged nothing hid it again.
  - Chromium's tracker had hidden such a page on lock and display off (P12a's display-off
    runs were such runs, and their "on" arm stayed `hidden`). With the tracker off, it would
    have run through a lock or display off.
  - #410 has the page report whether it reads as visible. Kite re-hides one it has hidden by
    showing and hiding its windows (docs/windows.md, P2, "A page Kite hides stays hidden").
  - Measured with `--p2-from-launch` (P2 on from Kite's start, Kite covered by the desktop
    from about 0.16 s), 3 runs per arm, medians. CPU is Kite's total, "off" arm (Kite's
    default), before #410 → with it:

    | phase | Kite CPU ms/s | page hidden % | rAF fps |
    |---|---:|---:|---:|
    | idle | 488 → 10.1 | 0 → 100 | 351 → 0 |
    | nearMover | 471 → 2.1 | 0 → 100 | 349 → 0 |
    | covered | 484 → 3.1 | 0 → 100 | 350 → 0 |
    | overMover | 474 → 3.1 | 0 → 100 | 350 → 0 |
    | lockNotice | 482 → 2.3 | 0 → 100 | 351 → 0 |

    The "on" arm (tracker back on) went the same way: covered 481 → 4.3, lockNotice 477 → 2.7.
    Its movers stayed at 21.9 and 23.6 ms/s, the tracker's ~1,845 cs/s.

## Short answer (P12a)

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
  lock and display off itself, and also when Kite is covered or on another desktop. P12b did,
  after P2 landed.

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

## Numbers (P12a, before P2)

Kite for Windows at perf/P0b-kiteperf (1618b7f5), Release, CEF 156.0.7 / Chromium
156.0.8078.17, on Gabe's PC (Windows 11 26200, 2560×1440). "on" was Chromium's default then;
"off" was `--chromium-switches "--disable-features=CalculateNativeWinOcclusion"`. Neither arm
had P2. The P12a tool's phases were idle, nearMover, covered and overMover, with Kite's own
occlusion not yet there; today's tool adds lockNotice and turns P2 on after idle.

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

## Display state (P12a)

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
  open overnight. (P12b found one case P2 missed, a page made while Kite can't be seen;
  #410 closed it. See "P12b: off, with P2".)
- **Nothing else in Kite reads it.** No Kite code reads page visibility, Chromium's occlusion
  state or `WasHidden`. Background tabs and a minimized Kite are hidden by hiding their widget
  windows (docs/windows.md, Rendering), which doesn't involve the tracker.
- **DevTools.** Developer Tools opens as a Chrome-style top-level window, which the tracker
  does see. With it off, a covered DevTools window keeps drawing. That's minor.
- **Video capture and screen sharing.** No change. Chromium already counts a captured page as
  visible whatever the tracker says (`WindowTreeHost`'s video-capture count).
- **A CEF upgrade** may make the tracker work for child windows (above). The switch would then
  turn off something that works. P2 would still cover the same cases.

## Recommendation (P12a)

Turn the tracker off on Windows, in the same change as P2 (#379) or after it lands, never
before. (P12b did, after P2 landed.)

- **With P2,** turning it off loses nothing. P2 covers lock and display off itself, and covered
  and cloaked too, which Chromium's tracker can't do for Kite. It saves about 18 ms of CPU and
  1,800 wakeups a second whenever any app's window animates, and the tracker's idle wakeups
  otherwise (6 to 130 cs/s, depending on the desktop). P2 measured 6–10 cs/s for its own
  hooks with another process's window sliding beside Kite (#379).
- **Without P2,** turning it off is a regression. With the display off or the session locked,
  pages keep running: 431 ms/s of CPU for one animating page, where the tracker kept it at 5.
- **The switch itself:** add `--disable-features=CalculateNativeWinOcclusion` in
  `OnBeforeCommandLineProcessing`, beside P2. If Kite ever sets other `disable-features`,
  merge the lists into one switch: a second `--disable-features` replaces the first. (P12b
  merges it with CEF's own list, `core/ChromiumSwitches.h`.)
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
.\occlusion-ab.exe --kite ..\..\..\build\Release\Kite.exe --runs 3 --idle 30 --out static.jsonl
.\occlusion-ab.exe --kite ..\..\..\build\Release\Kite.exe --runs 3 --page anim --idle 20 --out anim.jsonl
```

- It needs a Kite from P12b on: its "on" arm passes
  `--chromium-switches "--enable-features=CalculateNativeWinOcclusion"`, which an older Kite
  refuses. Its "off" arm passes nothing.
- It runs Kite with `--perf-control`, so Kite's own occlusion is off for idle (the page draws
  wherever Kite is) and turned on after it, from a page that has been shown (see the gap
  under "P12b"). With `--occlusion-log`, each run's line has Kite's verdicts.
  `--p2-from-launch` runs it without `--perf-control`, as a user's Kite runs: its occlusion
  is on from the start, idle included, so a Kite that opened covered makes its page while it
  can't be seen.
- Per phase it also gives the share of the phase the page was `hidden` and its rAF rate, from
  the page's own log in its title.

- It waits for the display to be on and never wakes it. It keeps the display on while a run
  goes, and leaves out of the medians any run whose display went off. Pass `--any-display` to
  measure regardless, as was done here.
- It prints the medians as a markdown table, and writes one JSON line per run to `--out`. Each
  line has per-process-type and per-thread numbers, and the page's visibility history.
- Nothing in it takes the focus or sends input. Kite is a quiet `--perf-log` run, and the tool's
  own windows are `WS_EX_NOACTIVATE`, moved with `SWP_NOACTIVATE`.
- #366 (quiet runs never activate) has landed, so Kite itself can't take the foreground in
  these runs. P12a's runs used a build with its page style patched in.
- kiteperf's `idle` and `covered` phases give the whole-process view, with
  `--chromium-switches "--enable-features=CalculateNativeWinOcclusion"` for the old default.
  Its cover is a tool window, which the tracker ignores by design, so kiteperf alone can't show
  the tracker's cost under a moving window.
