# Kite: project handoff (full context)

Paste this into the Claude project's instructions or knowledge. It describes the state as of
**2026-10-22**. Before relying on any detail, check it against the code in `~/dev/kite`
(the repo wins).

---

## 1. What this is

**Kite** (working name; the user may rename it) is Gabe's open-source rebuild of the **Arc browser**.
The Browser Company is shutting Arc down:

- **Oct 22, 2026:** no new Arc accounts. The latest Arc adds data export.
- **Nov 23, 2026:** Arc Search (mobile) loses sign-in, sync and AI features.
- **Dec 22, 2026:** Arc for Mac and Windows stops working; accounts are deactivated and data is deleted within 30 days.

Anything that depends on reading Arc's data (the importer) must ship before **Dec 22, 2026**.

Repo: `~/dev/kite` (a local git repo on branch `main` with **no commits yet**; don't commit unless asked).
License: MIT (Gabe Kuslansky). Bundle ID: `dev.gabek.Kite` (Gabe owns gabek.dev).

## 2. How Gabe wants it built (standing direction)

1. **Copy Arc's UI/UX one-for-one first**, then iterate: layout, spacing, interactions, shortcuts.
   Recreate the look, but **draw our own icons, sounds and animations**. Arc's bundle
   assets (metallibs, Lottie files, sounds, Assets.car) are proprietary and must not be copied.
2. **Performance: take every win available.** Prefer the fast path even when it's more work.
3. **Engine is Chromium on Mac** (decided after discussion). He wants **real Chrome DevTools** and the
   CDP debugging port. He asked twice whether WebKit could give Chrome DevTools for its battery
   life. It can't (WebKit speaks a different inspector protocol, and the CDP↔WebKit adapters are
   abandoned), so: Chromium, with WebKit kept as a dev/fallback engine.
4. **Windows version too**, "super performant" and tweakable. See §9.
5. Subagents and parallel sessions are fine when pieces don't touch the same files.
6. Gabe types fast with typos. Interpret generously, but **ask when a request is truly ambiguous**.
   Example: "⌘L should be split view by default" meant Add Split View on ⌘L (his Arc binding).

### Features Gabe has asked for (all tracked in `docs/roadmap.md`)
- Arc import: spaces, pinned tabs, folders, favorites, themes. Remove the importer after Arc dies. *(core done; UI in progress)*
- **Claude in the browser**, modeled on Yet Another Browser (yetanotherbrowser.com): your own Claude/ChatGPT plan
  works in your tabs, clicks/types/reads as you, asks before sending or paying, and Claude Code can drive
  it over MCP or a CLI.
- **Dark pages** built in (no extension), first-class and minimal. *(core and engine done; minimal UI in progress)*
- **Install PWAs** like Arc, and bring over the PWAs installed from Arc.
- **Mini player** for media in background tabs (play/pause, PiP).
- **Peek** (⇧-click opens the link in an overlay).
- **Account sync + sharing** (spaces/folders), cross-platform.
- **Resizable sidebar.** *(in progress)*
- **Split view**, with ⌘L as Add Split View (confirmed 2026-10-25).
- Chrome Web Store extensions (blocked by CEF Alloy; see §6).

## 3. Current status

Working and verified in the running app (screenshots taken):
- Kite.app runs **Chromium 156.0.8078.17 via CEF 156.0.7**, inside Kite's own window and shell.
- Metal theme gradient backdrop; SwiftUI sidebar (address pill, nav buttons, pinned/unpinned list, space switcher); rounded content card with an explicit-path shadow.
- Command bar: ⌘T new tab, ⌘L edit the current URL; suggestions combine URL/search detection with open-tab search.
- **Chrome DevTools** opens from View → Developer Tools (⌥⌘I) as a separate window.
- **CDP port** via `KITE_REMOTE_DEBUGGING_PORT` (verified with `/json/version` → `Chrome/156.0.8078.17`).
- **Dark pages** via Chromium's auto dark mode (`Emulation.setAutoDarkModeOverride` through `ExecuteDevToolsMethod`), per tab. Verified on Hacker News.
- Clean quit: every browser closes, no helper processes remain, and tabs persist.
- Session persistence (atomic JSON; a corrupt file is moved aside, never overwritten).
- **Arc importer** (core) tested on Gabe's real `StorableSidebar.json`: 3 spaces, 7 favorites, 46 tabs, 3 folders, 2 split views, 2 Arc profiles.
- `swift test`: **30 tests passing** (Swift Testing).

Also done and checked in the running app with a scratch profile:
- Favorites grid at the top of the sidebar, and nested pinned folders that remember whether they're expanded.
- **File → Import from Arc…**, with a confirmation sheet listing counts and notes. Re-importing replaces spaces imported earlier.
- Draggable sidebar edge (width persisted).
- Moon toggle in the address pill for per-site dark pages, plus Off / Match System / Always in the View menu. Dark pages re-apply when macOS switches light/dark (`BrowserStore.systemIsDark`).
- `WebEngine.supportsDarkPages`.

Known gaps and risks:
- The Chromium sandbox is on: each helper enters it with `CefScopedSandboxContext` in `KiteHelper/main.mm`,
  which loads `libcef_sandbox.dylib` from the framework's `Libraries/` (the minimal distribution ships it;
  CEF 156 has no `libcef_sandbox.a`). `chrome://sandbox` doesn't exist in CEF; check helpers with
  `sandbox_check(pid, NULL, 0)` instead.
- No Chrome extensions (Alloy style).
- CEF tab hibernation loses back/forward history (WebKit restores `interactionState`).
- Media "busy" detection on Chromium uses a JS check of `<video>/<audio>` plus `OnMediaAccessChange` (camera/mic); CEF has no "audible" API.
- App is 334 MB (mostly the CEF framework). Not signed or notarized; ad-hoc signed only.
- The Metal toolchain isn't installed (`xcodebuild -downloadComponent MetalToolchain`), so shaders compile at runtime. The bundle script precompiles them when it is installed.
- Windows CI job written but never run (nothing pushed).

## 4. Build, run, test

Requirements: macOS 14+ (dev machine: macOS 15.7, Apple Silicon), Xcode 26.3 / Swift 6.2, `brew install cmake ninja`.

```bash
cd ~/dev/kite
scripts/build-cef.sh            # once, optional: CEF from source with H.264/AAC (~5-8 h, ~90 GB peak) → ThirdParty/codecs/
scripts/fetch-cef.sh            # CEF minimal macosarm64 (the codecs build if present, else download ~135 MB, SHA-1 pinned); builds libcef_dll_wrapper.a
scripts/bundle-app.sh debug     # → build/Kite.app (framework + 5 helper apps, ad-hoc signed)
open build/Kite.app
swift run Kite                  # WebKit engine, fast UI iteration (no CEF needed)
swift test                      # core tests
KITE_ARC_SIDEBAR=/path/to/copy/of/StorableSidebar.json swift test   # also runs the importer on real data (prints counts only)
```

Environment variables:
- `KITE_ENGINE=webkit`: force WebKit even inside Kite.app.
- `KITE_REMOTE_DEBUGGING_PORT=9222`: expose CDP. Any local process can then drive the browser, so it's off by default.
- `KITE_SUPPORT_PATH=/tmp/x`: throwaway profile and session. **Always use this when testing** so Gabe's real session isn't touched.

Verifying the UI from Claude Code:
- Launch `build/Kite.app/Contents/MacOS/Kite` in the background with `KITE_SUPPORT_PATH`.
- Find the main window with a small Swift script using `CGWindowListCopyWindowInfo`, picking the **largest** window owned by "Kite", since a DevTools window is also owned by Kite.
- Capture it with `screencapture -x -o -l<id>`.
- Drive menus and keys with `osascript` / System Events: `click menu item … of menu "View" of menu bar 1`, `keystroke`.
- Bring Kite to the front first. Keystrokes go to the key window, which might be DevTools.
- Quit via the Kite menu's "Quit Kite", not `pkill`, when testing shutdown.

## 5. Architecture

```
Package.swift            swift-tools 6.0. KiteCore + tests always; on macOS KiteMac (Swift 5 language mode);
                         CEFBridge + KiteHelper only when ThirdParty/cef/build/libcef_dll_wrapper/libcef_dll_wrapper.a exists.
Sources/KiteCore/        Foundation-only, portable to Windows (CI runs it on windows-latest).
  Models.swift           BrowserTab, TabFolder, PinnedItem (indirect enum tree), Space (pinnedItems + tabs,
                         custom Codable that migrates the old flat `pinned`), ClosedTab, TabSection, TabLocation, CloseOutcome.
  BrowserState.swift     The whole persisted state + all mutations (open/select/close/reopen/pin/favorite/move/
                         archive/spaces/dark pages). Custom Decodable with decodeIfPresent for forward compatibility.
  ArcImport.swift        Arc StorableSidebar.json → spaces/favorites (+ BrowserState.merge). Self-contained so it can be deleted.
  URLInput.swift         Typed text → URL or search (SearchEngine: google/duckDuckGo/kagi/bing).
  TabSearch.swift        Command-bar ranking of open tabs.
  LiveTabPolicy.swift    Which tabs keep a live engine page (LRU, protected set).
  Theme.swift            ThemeColor (sRGB), Theme (1–4 colors + grain), OKLab conversions, presets, glow colors.
  SessionStore.swift     Versioned, atomic session.json; quarantines corrupt files.
Sources/KiteMac/
  main.swift             Creates KCApplication (CEF's NSApplication subclass), picks the engine, runs CefRunMessageLoop or NSApp.run.
  AppDelegate.swift      Store/window setup, 12h auto-archive timer, supportDirectory (KITE_SUPPORT_PATH).
  BrowserStore.swift     @Observable wrapper around BrowserState: page status, command bar, sidebar, debounced saves,
                         onChange/onPageChange callbacks to the window controller.
  BrowserWindowController.swift  NSWindow (full-size content, transparent titlebar). Back to front: ThemeView,
                         sidebar NSHostingView, ShadowView/contentClip (web content), GlowView, command bar host.
                         Menu actions (@objc), dark-pages application, theme cutout.
  MainMenu.swift         Programmatic menus and shortcuts (Arc-like).
  Engine/WebPage.swift   WebPage / WebEngine protocols + PageEvent enum (engine-neutral).
  Engine/PagePool.swift  Page lifecycle: lazy creation, visibility (WasHidden), LRU hibernation (max 6 live),
                         memory-pressure source, routes PageEvents into the store, popups become tabs.
  Engine/ChromiumEngine.swift  ChromiumPage wraps KCBrowser (#if canImport(CEFBridge)).
  Engine/WebKitEngine.swift    WebKitPage wraps WKWebView: KVO, navigation/UI delegates, downloads, alerts, file picker.
  Metal/ShaderLibrary.swift    Loads Kite.metallib from the bundle or compiles Shaders/Kite.metal at runtime; caches pipelines.
  Metal/ThemeView.swift  On-demand MTKView backdrop; 0.4s OKLab crossfade on space switch; cutout under content.
  Metal/GlowView.swift   Loading glow overlay; runs only while loading, then pauses and hides; hitTest → nil.
  Shaders/Kite.metal     Full-screen triangle from vertex_id; theme fragment (OKLab gaussian blend, grain, dither,
                         rounded-rect cutout discard); glow fragment (rounded-rect SDF rim + bloom + sweep).
  Views/SidebarView.swift, CommandBarView.swift, FaviconView.swift (NSCache favicon loader).
Sources/CEFBridge/       Objective-C++ over CEF's C++ API; Swift sees only include/CEFBridge.h.
  KCRuntime.mm           KCApplication (CefAppProtocol, sendEvent wrapper, terminate → close all browsers then quit),
                         KCRuntime (load framework, CefInitialize settings, run loop, shutdown), live-browser registry.
  KCBrowser.mm           KCBrowser (one per tab) + KCClient (life span, display, load, request, download handlers,
                         DevTools message observer). JS evaluation and any CDP method go through ExecuteDevToolsMethod.
Sources/KiteHelper/main.mm   Helper process entry (CefScopedLibraryLoader::LoadInHelper + CefExecuteProcess).
Resources/Info.plist, Helper-Info.plist   NSPrincipalClass KCApplication, automatic graphics switching, camera/mic strings.
scripts/fetch-cef.sh, bundle-app.sh
docs/roadmap.md, windows.md, HANDOFF.md (this file)
ThirdParty/ (gitignored)   CEF distribution + wrapper build.
```

Data flow: UI actions call `store.mutate { $0.someMutation() }`. That calls `onChange`, and the window controller's `sync()`
swaps the shown page, theme, command bar and sidebar. Page events flow from the engine to `PageEvent`, then `PagePool.handle`, then the store.

## 6. Hard-won technical facts (don't relearn these)

**CEF on macOS**
- `CefWindowInfo.SetAsChild(parentView, …)` forces **Alloy style** ("Alloy style will always be used if parent_view is provided").

**Extensions (measured Oct 2026, CEF 156 / Chromium 156.0.8078.17; spike branch `extensions-self-install`)**
- Kite's **Alloy-style tabs run Chrome extensions**: MV3 service workers, content scripts and `chrome-extension://` pages
  (a popup page opened as a tab has `chrome.runtime`/`chrome.tabs`). `--load-extension=<dir>` works at launch, with or
  without `--enable-extensions`.
- **Installing from the Chrome Web Store works**: the store page has `chrome.webstorePrivate`/`chrome.management`, and
  Add to Chrome brings up Chrome's own native "Add "X"?" dialog (a Views window). The install lands in
  `<profile>/Chromium/Default/Extensions/<id>/<version>`.
- **`chrome://extensions` is blocked** in Alloy-style browsers (`ERR_ABORTED`; chromium.log: "Navigation to chrome://extensions/
  is blocked in Alloy-style browser"). Kite needs its own extensions UI.
- **`chrome.tabs.create` fails with "No current window"**: Kite's tabs aren't Chrome windows. `chrome.windows.create` and
  extension welcome pages *do* create a Chrome-style browser window (tab strip, omnibox, extension toolbar); those browsers get
  `CefBrowserProcessHandler::GetDefaultClient()`'s client, and their windows are `BrowserNativeWidgetWindow`.
  Kite routes them into background tabs (`KCDefaultClient.mm`) and never orders those windows in (`KCExtensionWindows.mm`).
  A hidden Chrome-style "anchor" browser would make `tabs.create` work, but its window couldn't be hidden reliably.
- **Chrome's install dialog can't be hidden or replaced** without patching CEF: its NSWindow title is empty (the "Add …?" text is
  only its accessibility title), Chrome fades it in itself (alpha steps 0.29 → 1, bypassing `-setAlphaValue:`), and
  "Add extension" stays disabled while the dialog isn't really visible (its anti-clickjacking delay). So Kite attaches Chrome's
  own dialog to the Kite window as a sheet instead; a native Kite card needs a CEF change (an install-prompt callback).
- `--apps-gallery-install-auto-confirm-for-tests=accept` is **not** honoured.
- The store's "Switch to Chrome?" popup/banner isn't driven by `navigator.userAgentData` brands: adding a "Google Chrome" brand
  changed nothing, and Arc 155 (Chromium-only brands, same `webstorePrivate` methods) gets "Add to Arc" and no promos. Kite
  rewrites the store page instead (`WebStoreScript`).
- A store install downloads the `.crx` through the tab's `CefDownloadHandler`; route it to a temp folder, not ~/Downloads.
- **`Extensions.loadUnpacked` (CDP) only works on a browser-target session**, i.e. over the TCP debugging port. From a page
  session (what `ExecuteDevToolsMethod` reaches) it's "Method not available"; `Target.attachToBrowserTarget` is "Not allowed"
  in-process and over TCP; `--remote-debugging-pipe` (fds 3/4) never answered. So a Kite-managed install (download the CRX from
  `clients2.google.com/service/update2/crx`, verify, unpack with the manifest `key` so the id stays the store's) can only load
  it at launch via `--load-extension`, i.e. after a restart, and Chromium then reports it as installType `development`.
- **`DoClose` must return `true`** for tab browsers. Returning false sends `performClose:` to the *whole window*.
  We remove the browser's NSView ourselves (`dispatch_async` → `removeFromSuperview`) to complete the close.
- When quitting, `closeAllBrowsersAndQuit` closes every browser. `browserDidClose` must **not** report `browserDidRequestClose`
  while quitting (checked with `KCRuntimeIsQuitting()`), or the tabs get removed from the saved session.
- The app must run as `KCApplication` (it implements `CefAppProtocol` with a `CefScopedSendingEvent` in `sendEvent:`).
  `terminate:` calls `willTerminate` (save the session), then closes browsers. `CefRunMessageLoop()` returns, then main calls `CefShutdown` and `exit(0)`.
- The framework is loaded dynamically (`CefScopedLibraryLoader`), so `swift build` works without CEF present; the engine is chosen at runtime.
- Helper bundles must be named `Kite Helper.app`, `Kite Helper (GPU).app`, `(Renderer)`, `(Plugin)`, `(Alerts)`, each
  executable named the same as its bundle. Sign them inside-out (helpers, then framework, then app).
- Compile flags must match the wrapper: `-std=c++20 -fno-rtti -fno-exceptions -fno-threadsafe-statics -fno-strict-aliasing`.
- Popups: `OnBeforePopup` builds a new `KCBrowser` container, calls `SetAsChild` into it, gives it a new `KCClient`, and returns false,
  so `window.opener` survives (OAuth). ⌘/middle-clicks arrive through `OnOpenURLFromTab` with background/foreground dispositions.
- `ExecuteDevToolsMethod` works **without DevTools open**. Results come back through `CefDevToolsMessageObserver::OnDevToolsMethodResult`.
  This is the hook for page reading/clicking for the Claude/MCP features and the mini player.
- Zoom: Chromium levels are logarithmic. `level = log(factor) / log(1.2)`.
- `WasHidden(true)` on background tabs is the main battery lever. Chromium throttles hidden tabs.
- CEF's Mac UI thread is the main thread. The bridge header uses `NS_SWIFT_UI_ACTOR` on `KCBrowser`/`KCBrowserDelegate`.
- The menu's Close Tab (⌘W) must close the key window when it isn't the browser window (e.g. DevTools). That was already a bug once.
- `remote_debugging_port = 0` disables CDP.

**Swift / AppKit gotchas hit so far**
- SwiftUI's `Tab` (macOS 15 SDK) collides with a model type called `Tab`, hence `BrowserTab`.
- JSON `.iso8601` dates drop fractional seconds and broke round-trip tests, so the default `Double` date strategy is used.
- SwiftPM's generated `Bundle.module` **traps** if the bundle is missing, so check `Bundle.main` first. Inside a `.app` the module bundle isn't present.
- Metal uniform structs are laid out by hand to match MSL: `ThemeUniforms` is 176 bytes, `GlowUniforms` stride 80 (asserted at init).
  `half` is a reserved type name in MSL.
- MTKView on-demand drawing: `enableSetNeedsDisplay = true` with `isPaused = true`. For animation use `enableSetNeedsDisplay = false`
  with `isPaused = false`, then switch back afterwards.
- `NSHostingView.sizingOptions = []` stops SwiftUI's size constraints from fighting Auto Layout.
- WebKit delegate completion handlers are `@MainActor` (`WK_SWIFT_UI_ACTOR`), so signatures must include it.

**Arc internals (from inspecting Arc 1.169.0 on this Mac)**
- Arc = Swift/AppKit/SwiftUI shell (about 50 SPM feature modules named `ARC_*`: CommandBar, LittleBrowser, Boosts, SpaceStyleEditor,
  PictureInPicture, MediaControlsFeature, SiteControlCenter, …) + `ArcCore.framework` (585 MB, a **Chromium 155 fork**)
  + Aperitif helpers (`libaperitif.dylib`, not investigated) + Firebase/Firestore + CloudKit + Sparkle + Lottie + LaunchDarkly + Datadog/Sentry.
- Arc has only **two Metal libraries**:
  - `ARC_WindowThemeUI.bundle/default.metallib`:
    - `gradientVertex/gradientFragment`: N gradient layers with an underlay color; pow/dot math, so perceptual blending.
    - `overlayVertex/overlayFragment`: crossfade between two overlay textures, using `fromOverlayAlpha`, `toOverlayAlpha` and `progress`.
    - `renderVertex/renderFragment`: combines the gradient texture with a grain texture tiled `overlayRepetitions` times, and `discard`s inside `cutoutCoordinates`, skipping pixels under the web content.
  - `ARC_GlowProgressLoadingIndicator.bundle/default.metallib`:
    - `progressLoadingIndicatorFragment`: a rounded-rect SDF glow with progress, intensity, inset, cycleProgress and primary/secondary colors.
  - Both are compiled with fast-math, target macOS 13, and draw full-screen quads from constant positions with no vertex buffers.
  - Kite's `Kite.metal` is an **original** reimplementation of these ideas.
- `rea` (github.com/morluto/rea), the repo Gabe first linked, is not Arc's code. It's a reverse-engineering MCP tool
  ("Reverse Engineer Anything"). It could be used against Arc.app for deeper feature investigation.
- **StorableSidebar.json** at `~/Library/Application Support/Arc/StorableSidebar.json` (about 288 KB for Gabe):
  - `sidebar.containers[]` holds a `global` container, containers with `spaces` / `items` / `topAppsContainerIDs`, and a `littleBrowser` container.
  - Collections are **flat alternating arrays**, `[id, object, id, object, …]`.
  - Space: `id`, `title`, `customInfo.iconType.{emoji_v2 (string), emoji (int codepoint)}`, `customInfo.windowTheme.background…` (variants such as `blendedSingleColor`
    and `blendedGradient.baseColors[]`; colors are `{red, green, blue, alpha, colorSpace: "extendedSRGB"}`, with grain at `modifiers.noiseFactor`),
    `profile` (`{default: true}` or `{custom: {_0: {directoryBasename: "Profile 1"}}}`), and `containerIDs: ["pinned", id, "unpinned", id]`.
  - Item: `id`, `parentID`, `childrenIds[]`, `title` (a custom name), and `data` with one of:
    - `tab: {savedURL, savedTitle, timeLastActiveAt}`
    - `list: {}` (a folder)
    - `splitView: {…}`
    - `itemContainer.containerType.{spaceItems._0 | topApps._0 (profile)}`
  - Timestamps are seconds since 2001 (Apple reference date). The importer sets `lastActiveAt = now` so Kite's 12-hour auto-archive doesn't sweep imported tabs.
  - Favorites (`topApps`) are per Arc profile; Kite merges them into one shared grid, deduped by URL.
- Arc also keeps a standard Chromium profile (history, bookmarks, cookies). Passwords sit behind the Keychain item "Arc Safe Storage".
  Plan: move passwords via Gabe's password manager or Arc's export, **not** by decrypting the keychain.
- Arc's `Helpers/app_mode_loader` is Chrome's PWA app shim. Arc's installed apps are Chrome-style app shims; their locations haven't been checked yet.
- **Never print Gabe's actual URLs or titles** while inspecting his Arc data. Show structure and counts only, and work on a copy.

## 7. Performance techniques in place (keep and extend)

- Only the selected tab loads at launch; other pages are created when first shown.
- At most 6 live pages (LRU). Hibernation is skipped for tabs playing media or using the camera or mic. Every background page hibernates on a memory-pressure warning.
- Hidden tabs get `WasHidden(true)` on Chromium; WebKit throttles views that aren't in a window by itself.
- Theme shader: draws only when the theme, size or cutout changes. Colors are converted to OKLab once on the CPU. It uses no vertex buffers or textures, skips pixels under the page, and dithers to avoid 8-bit banding.
- Glow: renders at 60fps only while a page loads, fades out, then pauses and hides.
- Explicit `shadowPath`, so Core Animation skips an offscreen shadow pass.
- `NSSupportsAutomaticGraphicsSwitching` keeps dual-GPU Macs on the integrated GPU.
- Session saves are debounced by 1s and written atomically; favicons are cached in an NSCache with in-flight request merging.
- Ideas not done yet:
  - A precompiled metallib (needs the Metal toolchain).
  - Persisting CEF navigation history across hibernation.
  - Chromium energy-saver features.
  - Measuring with Instruments (Energy Log, Time Profiler) against Arc and Chrome on the same sites.

## 8. Roadmap (priority order; see docs/roadmap.md)

1. **First commit** (pending Gabe's OK). The Arc import UI, favorites, folders, resizable sidebar and dark-pages toggle are done.
2. ~~**Chromium sandbox**~~ done: `CefScopedSandboxContext` in the helper.
3. Re-import support up to Dec 22 (already idempotent by Arc UUIDs). The remaining Arc data: history and bookmarks from Arc's Chromium profile, and Arc's installed PWAs.
4. **Claude in the browser**:
   - A local MCP server plus a `kite` CLI, so Claude Code or Desktop drives real tabs on Gabe's own plan. Tools: list tabs, read page (`Runtime.evaluate` / DOM / accessibility tree via CDP), click, type, navigate, screenshot.
   - Then a side panel using the Anthropic API key (default model `claude-opus-5-5`; also `claude-sonnet-5-5`, `claude-haiku-5-5`).
   - Guardrails: confirm before submitting forms, sending or paying; treat page content as untrusted (prompt injection); show "Claude is controlling this tab".
5. Arc parity:
   - Peek.
   - Split view (⌘L = Add Split View).
   - Mini player.
   - Little Arc.
   - Boosts.
   - Folders: drag between them, drag tabs between spaces.
   - Swipe between spaces.
   - Archive UI.
6. PWAs: read the site's manifest and generate a launcher `.app` in `~/Applications/Kite Apps/` that opens a chrome-less single-site window.
7. Extensions: a CEF Chrome-style spike (see §6).
8. Sync + sharing: end-to-end encrypted, cross-platform (CloudKit alone won't reach Windows); per-space keys for sharing.
9. Signing, notarization, Sparkle updates. Rename the product if Gabe picks a name.
10. **Windows** (§9).

## 9. Windows plan (docs/windows.md)

- Reuse KiteCore (Swift on Windows; the CI job is written).
- Same CEF engine: port the ObjC++ bridge to plain C++ and call it from Swift with C++ interop.
- Shell: Swift + `thebrowsercompany/swift-winrt` (WinUI 3 / Win32), the same toolchain Arc for Windows used.
- The hard part is **airspace**: a CEF child HWND always draws over XAML, so nothing could overlap the page. The plan:
  - Render CEF off-screen with **D3D11 shared textures** (`shared_texture_enabled`) and compose everything with DirectComposition.
  - Port `Kite.metal` to HLSL and keep both in sync with a golden-image test.
  - Forward input (mouse, keys, IME) to CEF. This is the riskiest part, so prototype it first.
- Fallback: windowed CEF plus separate layered windows for overlays.
- Arc for Windows uses the same `StorableSidebar.json` format, so the importer should work there. Its path on Windows is unverified.

## 10. Conventions

- Match the existing code style: concise doc comments that explain *why*, no noisy comments; `@MainActor` UI types.
- Value-type core: all behavior in `BrowserState` mutations, unit-tested; shells only render and call mutations.
- New persisted fields must be `decodeIfPresent` with defaults (see `BrowserState.init(from:)`, `Space.init(from:)`).
- Keep KiteCore free of Apple-only frameworks (no AppKit, Combine or SwiftUI); Foundation only.
- Verify in the real app (bundle, launch with `KITE_SUPPORT_PATH`, screenshot) before calling UI work done; report what wasn't verified.
- Don't commit, push, or download large binaries without Gabe's OK. CEF downloads come from `cef-builds.spotifycdn.com` with the SHA-1 pinned in `fetch-cef.sh`.
- Commit attribution line: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
