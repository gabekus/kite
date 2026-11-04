# Kite for Windows: architecture rules

The rules Helix's reviewers enforce (docs/helix.md). Change them on purpose, in
their own PR, never as a side effect of a checkpoint.

## Layers

- `windows/src/core`: the model. C++20 and the standard library only (a CRT
  call behind `#ifdef _WIN32` is fine, `<windows.h>` isn't), and nothing from
  the shell. It builds and its tests run on any OS. Everything here is
  unit-tested and reachable from `kitecore`.
- `windows/src/shell`: the app (`main.cpp`'s `wWinMain`), Win32,
  DirectComposition, Direct2D/DirectWrite, D3D11, input, and the CEF host. It
  may use `core`; `core` never uses it.
- `windows/src/cli`: `kitecore`, a thin command layer over `core`. It may use
  Win32 for process plumbing (UTF-16 arguments, the console's UTF-8 output) and
  nothing else.
- `windows/resources`: the process manifest both executables embed.
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
  The one exception is an animation that must draw again each frame because no
  compositor property can do it (the theme's crossfade, an OKLab mix in a
  shader, as the Mac's ThemeView): it runs on the frame clock
  (`shell/FrameClock.h`), at the display's rate, only while it changes, and
  the clock stops when it ends. An offset, a scale or an opacity is always an
  `IDCompositionAnimation`.
- Render at the display's refresh rate with no 60fps caps (docs/windows.md,
  Refresh rate).
- No work on the UI thread that can block: file I/O over a few KB, network,
  or anything that waits on Chromium goes elsewhere. Two exceptions, until
  saving moves to a background writer with the first checkpoint that changes
  state at runtime: loading the session before the first window exists, and
  the final save as the window closes or Windows ends the session.
- Never save over a session that couldn't be read (`SessionStore::MaySave`).
- Measure before claiming a speedup, and put the numbers in the PR.

## Code

- C++20, MSVC `/W4 /WX /permissive-`, static CRT. It must also build with
  MinGW-w64 GCC (`-Wall -Wextra -Werror`, `windows/cmake/mingw-w64.cmake`),
  which is how a non-Windows machine checks it.
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
