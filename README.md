# Kite

An open-source, Arc-style browser for macOS (Windows next), built in Swift on Chromium.

Arc shuts down on December 22, 2026. Kite keeps the parts that made it good,
including spaces, pinned tabs, the ⌘T command bar, themed windows and auto-archiving,
and drops the account wall.

> Kite is a working name and early. Expect breaking changes.

## Status

| | |
|---|---|
| Engine | Chromium 156 via [CEF](https://github.com/chromiumembedded/cef), with WebKit as a lightweight fallback |
| Chrome DevTools | ⌥⌘I, or the CDP port (`KITE_REMOTE_DEBUGGING_PORT`) |
| Spaces, pinned and unpinned tabs, auto-archive after 12h | ✅ |
| Command bar (⌘T new tab, click the URL to edit it, switch to open tabs) | ✅ |
| Split view (⌘L, up to 4 panes) | ✅ |
| Metal theme gradients and loading glow | ✅ |
| Tab hibernation and memory-pressure handling | ✅ |
| Favorites grid, pinned folders, resizable sidebar | ✅ |
| Import spaces, pinned tabs, folders, favorites and themes from Arc (File menu) | ✅ |
| Dark pages: moon in the address bar per site, plus Off / Match System / Always | ✅ (Chromium) |
| Chromium sandbox (renderer, GPU and utility processes) | ✅ |
| Everything else | see [docs/roadmap.md](docs/roadmap.md) |

## Build

Requires macOS 14+, Xcode 26, CMake and Ninja (`brew install cmake ninja`).

```bash
scripts/fetch-cef.sh          # downloads CEF (~135 MB, SHA-1 checked) and builds its C++ wrapper
scripts/bundle-app.sh debug   # builds build/Kite.app
open build/Kite.app
```

`scripts/install-app.sh` builds a release Kite.app and installs it to /Applications,
so it opens from the Dock, Launchpad and Spotlight with its icon. `scripts/update-app.sh`
does the same from the latest `origin/main` (or `scripts/update-app.sh <branch>` to test a
branch), in a separate `../kite-release` worktree. /Applications/Kite.app is the one Kite
that gets used and tested. If it's open, the new build is staged and goes in when you quit
Kite; pass `--restart` to quit it now (tabs are saved) and reopen it.

For quick UI work without Chromium, `swift run Kite` runs on WebKit.
`swift test` runs the core tests.

Useful environment variables:

- `KITE_ENGINE=webkit` forces WebKit even inside Kite.app.
- `KITE_REMOTE_DEBUGGING_PORT=9222` exposes the Chrome DevTools Protocol for Playwright, Puppeteer or agents. Anything on your machine can then drive the browser, so leave it off otherwise.
- `KITE_SUPPORT_PATH=/tmp/kite` uses a throwaway profile and session. It also turns on
  Chromium's mock keychain, so test runs never ask for keychain access.
- `KITE_MOCK_KEYCHAIN=1` or `0` forces the mock keychain on or off.
- `KITE_SIGN_IDENTITY="Apple Development: …"` picks the code-signing identity for `bundle-app.sh`.

### Keychain prompt

Chromium keeps its cookie and password encryption key in the login keychain. An ad-hoc
signed build gets a new code identity on every rebuild, so macOS asks for your password
each launch. `bundle-app.sh` signs with your Apple Development cert when you have a
valid one, so the identity stays the same and "Always Allow" sticks across rebuilds.
Without one, run `scripts/make-signing-cert.sh` once to create a self-signed
"Kite Local Signing" identity instead.

## Layout

```
Sources/KiteCore     Platform-neutral model: spaces, tabs, URL parsing, tab search,
                     hibernation policy, OKLab theme math, session file. Foundation only.
Sources/KiteMac      macOS shell: AppKit window, SwiftUI sidebar and command bar,
                     Metal views, engine adapters (Engine/).
Sources/CEFBridge    Objective-C++ wrapper over CEF's C++ API, exposed to Swift.
Sources/KiteHelper   Chromium helper process (renderer, GPU, ...).
Sources/KiteMac/Shaders/Kite.metal   Theme backdrop and loading glow.
```

## Performance notes

- **Startup:** only the selected tab loads. Other tabs come alive when you open them.
- **Background tabs:** Chromium is told when a tab is hidden, so it throttles rendering and timers. Beyond six live tabs the least recent are hibernated, unless they're playing media or using the camera or mic. Everything hibernates under memory pressure.
- **Shaders:** they draw only when something changes. The theme shader skips pixels under the page, gets its colors already converted to OKLab by the CPU, and uses no vertex buffers or textures. The glow runs only while a page loads.
- **Shadow:** the content card's shadow uses an explicit path, so there's no offscreen pass.
- **Graphics switching:** `NSSupportsAutomaticGraphicsSwitching` keeps dual-GPU Macs on the integrated GPU.

## License

MIT. Chromium and CEF are BSD-licensed; see `ThirdParty/cef/LICENSE.txt` after fetching.
