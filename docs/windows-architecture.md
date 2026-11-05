# Kite for Windows: architecture rules

The rules Helix's reviewers enforce (docs/helix.md). Change them on purpose, in
their own PR, never as a side effect of a checkpoint.

## Layers

- `windows/src/core`: the model. C++20 and the standard library only (a CRT
  call behind `#ifdef _WIN32` is fine, `<windows.h>` isn't), and nothing from
  the shell. It builds and its tests run on any OS. Everything here is
  unit-tested and reachable from `kitecore`.
- `windows/src/shell`: the app, Win32, DirectComposition, Direct2D/DirectWrite,
  D3D11, input, and the CEF host. Its entry point is `main.cpp`'s `RunWinMain`,
  exported from `Kite.dll`: with Chromium, Kite.exe is CEF's bootstrap, which
  calls it in every process (the browser, and each helper already in Chromium's
  sandbox). Without CEF (MinGW, or none fetched) it's `wWinMain` in Kite.exe. Helpers load
  Kite.dll under win32k lockdown, where user32 can't load, so Kite.dll
  delay-loads everything but kernel32 and libcef.dll. It may use `core`; `core`
  never uses it.
- `windows/src/cli`: `kitecore`, a thin command layer over `core`. It may use
  Win32 for process plumbing (UTF-16 arguments, the console's UTF-8 output) and
  nothing else.
- `windows/tools/build`: build-time programs whose output ships, such as
  `StampBootstrap`, which makes Kite.exe from CEF's `bootstrap.exe` with the
  manifest below and `windows/resources/Version.rc`'s version. They run on the
  build machine and are MSVC only. They never ship themselves, and nothing links
  them into Kite. They use Win32 and the standard library only, and nothing from
  `core` or `shell`. They build into their own output folder, apart from the
  shipped files. Other programs under `windows/tools` (test or measurement tools,
  say) aren't in this layer.
- `windows/resources`: the process manifest both executables embed.
- `windows/tools/perf` (and every other folder of `windows/tools` but
  `windows/tools/build`): test and measurement executables only, such as
  `kiteperf`. They are never linked into Kite.exe and never shipped. They may
  use `core`, the header-only protocol they share with Kite.exe
  (`shell/PerfProtocol.h`, `shell/Text.h`), Win32, and these first-party
  measurement APIs: PDH, psapi, job objects, `NtQuerySystemInformation` and
  `NtQueryInformationProcess` (looked up with `GetProcAddress`, never linked),
  and Winsock (`ws2_32`, for a loopback page server). A new API is added here
  first. They're Windows-only and MSVC-only, so they're exempt from the
  MinGW-w64 build (Code, below). `core` and the shell never use them.
- No third-party code except CEF. No WinUI or Windows App SDK, no .NET, no
  Swift runtime, no Boost, no JSON or test libraries. First-party Windows APIs
  (WIC, DirectWrite, UI Automation, WinHTTP) are fine.
- Undocumented Windows exports are not, with one exception: uxtheme's dark-mode
  exports for popup menus (SetPreferredAppMode and FlushMenuThemes, ordinals 135 and
  136), so a dark space's Win32 menu is dark, as the Mac's NSMenu follows the
  window. They're looked up at run time (never imported), called only on Windows 10
  1903 (build 18362, from RtlGetVersion) and later, only while a menu is open (the
  mode is process-wide, so it goes back to the default as the menu closes), and a
  missing export leaves the menu light. Nothing else may use them.

## Parity with the Mac

- Kite for Mac is the reference. Port its behaviour from its code and tests,
  and say in the PR which Mac files a change follows.
- `session.json` and every other file both apps read keep the Mac's format.
  Members Windows doesn't model yet stay in `extra` and are written back.
  Shared formats get a fixture in `Tests/Fixtures` that both suites load.
- Names follow the Mac's where a concept is the same (`BrowserState`,
  `OpenTab`, `SidebarTabs`), in C++ style (types and functions in PascalCase,
  members in camelCase).

## Performance

- Draw nothing while idle: no timers or animation ticks without visible
  change. Animations run on the compositor (DirectComposition), not on a CPU loop.
  One exception is an animation that must draw again each frame because no
  compositor property can do it (the theme's crossfade, an OKLab mix in a
  shader, as the Mac's ThemeView): it runs on the frame clock
  (`shell/FrameClock.h`), at the display's rate, only while it changes, and
  the clock stops when it ends. The other is a touchpad contact taken over the
  sidebar, whose DirectManipulation manual updates the same clock steps
  (`shell/TouchpadInput.h`): while its gesture or momentum runs, drawing only
  the frames it moved, and, unboosted and drawing nothing, while the fingers
  rest before moving, for at most 10 s, after which the contact goes back to
  the system. An offset, a scale or an opacity is always an
  `IDCompositionAnimation`.
- Idle means drawing nothing, and waking only for one narrow exception: Kite may
  watch the system for a signal that lets it stop drawing or working (whether
  its window can be seen, covered, locked, the display's power), never for one
  that starts work. Showing again what it stopped is allowed. Otherwise
  polling and timers are still never allowed for it. A one-shot wait after an
  event (a debounce) is not a timer. Such a watcher:
  - runs off the UI thread, which hears only when the outcome changes;
  - drops each event at the first check unless it can matter, and debounces
    the work the rest asks for;
  - hooks system-wide only events that can't be tied to a process in advance,
    and only in the states where they can change the outcome; everything else
    per process, in the same way. Events a person causes at a person's rate
    (an app coming forward, a drag, a minimize, a desktop switch) count as
    those when no process can be named for them, and the PR measures them;
  - enumerates nothing (EnumWindows, process lists) while nothing changed,
    with one exception: a verification heartbeat is allowed only while Kite
    has stopped drawing because it's covered, at most twice a second,
    re-reading only the windows that covered it (and a whole pass every few
    seconds). A covered Kite stops ~650 ms/s of rendering, and the events that
    would uncover it (a restore-down, a keyboard snap, leaving full screen, a
    window turning translucent) don't exist. It stops when Kite is no longer
    covered;
  - stays within 20 context switches a second on its thread in the worst case,
    with 0 more on the UI thread;
  - and has its PR measure each Kite thread's context switches per second
    against origin/main in every state that keeps hooks, under the worst input
    for each hook (another app's window moving, the mouse over a hooked app,
    typing into it, its tooltips and menus), with real focused input where it
    can be had and repeated runs, reporting the spread and the noise floor.
- Render at the display's refresh rate with no 60fps caps (docs/windows.md,
  Refresh rate).
- No work on the UI thread that can block: file I/O over a few KB, network,
  or anything that waits on Chromium goes elsewhere. The session is saved on
  a background writer (`core/SessionWriter`): the UI thread only copies it.
  Two exceptions: loading the session before the first window exists, and
  waiting at quit for the writer's last write (once the window is gone, or
  in the window when Windows ends the session), always for a bounded time:
  the atomic write makes giving up safe.
- Never save over a session that couldn't be read (`SessionStore::MaySave`).
- Measure before claiming a speedup, and put the numbers in the PR.
- "Draw nothing while idle" is checked, not just reviewed: kiteperf's idle
  phase (60 s on a settled ten-tab session) fails unless Kite presented
  nothing and committed nothing (`Kite.exe --perf-log`'s counters).
- Every checkpoint PR that could change performance attaches a
  `kiteperf --compare main.json branch.json` table. Build main and the branch
  (Release), then run, back to back on the same machine,
  `kiteperf --kite <exe> --phases idle,<phase> --runs 3 --out <name>.json`
  for each, where `<phase>` is the phase that exercises the change (several
  are comma-separated; open and settle always run first). The table is
  medians of those 3 runs. Main is re-run for every comparison, never read
  from a saved file: the machine and main both move.
- Kite.exe's measurement hooks (`--perf-log`, `--perf-control`,
  `--chromium-switches`) run only with `KITE_SUPPORT_PATH` set to a test
  profile: one that holds a `kite-test-profile` marker file (kiteperf and CI
  make it), never the default one (`%LOCALAPPDATA%\Kite`), and one that
  resolves. The marker guards against mistakes, such as a script pointed at
  the real profile, not against another program running as the same user.
  Off, they cost at most one predictable bool check on a hot path and
  allocate nothing. `--chromium-switches` takes only the switches on its
  allow-list (`shell/PerfProtocol.h`): nothing that weakens the sandbox, site
  isolation or web security, opens a debugging port, or changes a path or a
  launched process. Chromium reads nothing else of Kite.exe's command line
  (`command_line_args_disabled`).

## Code

- C++20, MSVC `/W4 /WX /permissive-`, static CRT. It must also build with
  MinGW-w64 GCC (`-Wall -Wextra -Werror`, `windows/cmake/mingw-w64.cmake`),
  which is how a non-Windows machine checks it. The measurement tools
  (`windows/tools/perf`, and every other folder of `windows/tools` but
  `windows/tools/build`) are exempt: they're MSVC only.
- Text from people (URL input, names) is classified by Unicode character
  (`core/Unicode.h`), not by byte or ASCII, the way Swift's `Character` does.
- JSON read and written is valid UTF-8 (Foundation rejects anything else).
- Ids are UUIDs, normalized to uppercase when read, as Foundation writes them.
- Strings are UTF-8 `std::string` in `core`; convert to UTF-16 only at Win32
  calls. Paths are `std::filesystem::path`; use `u8string()` for text, never
  `string()` (it throws outside the ANSI code page).
- Errors are values (`std::variant`, `std::optional`, an error string), not
  exceptions. User-facing failures never crash and never show a dialog under
  `--smoke-test` or `--capture`.
- Comments say why, not what. Each file starts with what it's for and, when it
  ports Mac code, which.
- Never commit Arc's code or assets. The Arc rules in AGENTS.md still apply.
