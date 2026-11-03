# Kite for Windows: architecture rules

The rules Helix's reviewers enforce (docs/helix.md). Change them on purpose, in
their own PR, never as a side effect of a checkpoint.

## Layers

- `windows/src/core`: the model. C++20 and the standard library only. No
  `<windows.h>` except in `SupportDirectory.cpp`, and nothing from the shell.
  Everything here is unit-tested and reachable from `kitecore`.
- `windows/src/shell`: Win32, DirectComposition, Direct2D/DirectWrite, D3D11,
  input, and the CEF host. It may use `core`; `core` never uses it.
- `windows/src/cli`: `kitecore`, a thin command layer over `core`.
- No third-party code except CEF. No WinUI or Windows App SDK, no .NET, no
  Swift runtime, no Boost, no JSON or test libraries. First-party Windows APIs
  (WIC, DirectWrite, UI Automation, WinHTTP) are fine.

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
- Render at the display's refresh rate with no 60fps caps (docs/windows.md,
  Refresh rate).
- No work on the UI thread that can block: file I/O over a few KB, network,
  or anything that waits on Chromium goes elsewhere.
- Measure before claiming a speedup, and put the numbers in the PR.

## Code

- C++20, MSVC `/W4 /WX /permissive-`, static CRT. It must also build with
  MinGW-w64 GCC (`-Wall -Wextra -Werror`), which is how a non-Windows machine
  checks it.
- Strings are UTF-8 `std::string` in `core`; convert to UTF-16 only at Win32
  calls. Paths are `std::filesystem::path`; use `u8string()` for text, never
  `string()` (it throws outside the ANSI code page).
- Errors are values (`std::variant`, `std::optional`, an error string), not
  exceptions. User-facing failures never crash and never show a dialog under
  `--smoke-test` or `--capture`.
- Comments say why, not what. Each file starts with what it's for and, when it
  ports Mac code, which.
- Never commit Arc's code or assets. The Arc rules in AGENTS.md still apply.
