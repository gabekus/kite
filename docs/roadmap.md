# Roadmap

Roughly in priority order. Arc's last day is 2026-12-22, so anything that
depends on Arc's data has to land before then.

## Before daily use

- **Signing and notarization**, with Sparkle for updates.
- **Back/forward history across hibernation on Chromium.** WebKit restores
  `interactionState`; CEF currently reloads the URL only.

## Import from Arc (temporary, remove after 2026-12-22)

- ~~Spaces, pinned tabs, folders, favorites and themes from
  `~/Library/Application Support/Arc/StorableSidebar.json`.~~ Done (File > Import from Arc…).
- History and bookmarks from Arc's Chromium profile.
- Installed Arc apps (PWAs).
- Passwords via the user's password manager or Arc's own export, not by
  decrypting Arc's keychain-protected store.
- Put it behind a single `ArcImport` module so removing it later is one delete.

## Claude in the browser (modeled on Yet Another Browser)

1. **Local MCP server plus a `kite` command.** Claude Code or Claude Desktop
   drives your real tabs (list, read, click, type, navigate, screenshot) on your
   own Claude plan. Chromium already gives us `Runtime.evaluate` and the rest of
   CDP through `KCBrowser.executeDevToolsMethod`.
2. **Side panel** using the user's Anthropic API key and the same tools.
3. **Guardrails:** confirm before submitting forms, sending messages or paying.
   Treat page text as untrusted data, never as instructions (prompt injection).
   Use a visible "Claude is controlling this tab" state.

## Arc features to keep

The full list of Arc's features and shortcuts, with Kite's status and the plan
for each, is in [arc-parity.md](arc-parity.md).

- **Peek:** ⇧-click opens a link in an overlay on top of the current page.
- **Mini player:** when a background tab plays media, show controls (play/pause,
  next, picture-in-picture) at the bottom of the sidebar. Drive it through CDP
  (`Runtime.evaluate` on media elements). Check whether Alloy-style CEF allows
  `requestPictureInPicture()`.
- **Drag tabs** between spaces, and into or out of pinned folders.
- **Split view.**
- **Little Arc:** a small quick-look window for links opened from other apps.
- **Boosts** (per-site CSS/JS) can share the dark-pages plumbing.

## Apps (PWAs)

CEF's Alloy style has no built-in "Install app". Plan: read the site's web app
manifest and generate a small `.app` launcher in `~/Applications/Kite Apps/`
that opens the site in a chrome-less Kite window with its own icon and Dock tile.

## Extensions

Alloy-style CEF (what we use to embed Chromium in our own view) has no
extension API. Chrome Web Store extensions need CEF's Chrome style, which on
macOS requires a CEF Views-hosted window. Spike: host the page in a Chrome-style
`CefBrowserView` inside a CEF window, and check whether our AppKit sidebar and
Metal views can live in the same `NSWindow`.

## Sync and sharing

Spaces, pinned tabs and settings across devices, plus shareable spaces and
folders like Arc's. It has to work on Windows too, so CloudKit alone won't do.
Plan: end-to-end encrypted sync (keys never leave devices) to a small backend,
with sharing through per-space keys. The data model in `KiteCore` is already
plain `Codable` values, which suits that.

## Windows

See [windows.md](windows.md).
