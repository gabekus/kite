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

### Sharing a build

`scripts/package-share.sh` builds a release Kite.app (in its own worktree, never
touching /Applications) and packs `dist/Kite/` plus a zip of it: Kite.app,
`install.sh`, a README and [SETUP.md](Resources/SETUP.md). The person unzips it and
runs `bash install.sh`, which installs Kite and starts `kite setup`: Claude Code with
the setup guide, which walks them through connecting Claude Code and the Claude app.
The build is signed but not notarized yet, so install.sh clears macOS's quarantine flag.

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

## For agents: spaces and the Claude folder

Claude drives Kite through its MCP server (`kite mcp`) or the `kite` CLI. Every tab Claude opens follows these rules,
which are also in the MCP server's instructions and the tool descriptions, so any Claude session gets them:

- **Pick the space from what the tab is about.** `list_spaces` shows what each space is for (its `for:` line, set
  with `describe_space`). Pass that space to `tabs_create` (or `navigate` with `space`). Don't ask which space, and
  don't just use the one in front. The user writes it in Create a Space ("What's it for?") or the space's
  right-click menu ("What's This Space For?…").
- **Claude's tabs go in that space's Claude folder by default.** `tabs_create` puts a tab in the space's Claude folder,
  a pinned folder Kite makes when needed. Pass `claude_folder: false`, or `active: true`, only for a link the user
  asked to open for themselves. That opens a plain tab in the space.
- **One folder per Claude session.** Pass `session`, a short name Claude makes up for the work at hand ("Cloudflare
  DNS move"), and the tab goes in Claude › that name. Kite remembers it for the session's later tabs, and reuses a
  folder with the same name. So a space's sidebar reads Claude › Session 1, Claude › Session 2.
- **Never a Claude space.** Kite has no Claude space and `create_space` refuses that name.
- **Filing a tab you're already driving:** `move_to_folder` with `folder: "claude"` moves it into its own space's
  Claude folder.

CLI equivalents: `kite spaces`, `kite describe-space NAME TEXT`, `kite open URL --space NAME [--session NAME]` (Claude folder) or
`--plain` (a plain tab), `kite call move_to_folder '{"folder":"claude","tab":"ID"}'`. More in `docs/automation.md`.

## For agents: handing steps to the user

When Claude stops because the user has to do something themselves (its safety check or the user's rules won't let it,
the choice is theirs, it needs a secret only they hold, or a command has to run on their Mac), it calls `handoff`
instead of listing steps in the chat. The user then sees what to do in Kite itself, not back in the chat:

- **On the page:** the control to click gets a ring in Claude's orange with the step beside it ("Claude needs you ·
  1. Approve Apple"). Clicking it finishes the step. Only a real click counts; the page can't fake one.
- **In the sidebar:** each tab with a step waiting gets an orange dot (its tooltip says the step), as does a folded
  folder holding one.
- **Over the page:** a card says why Claude stopped, what to do here, and step *n* of *m*, with **Done**, **Skip** and
  **Next** (which goes to the next tab that needs you). A terminal step shows its command with **Copy**. Folded,
  the card is a pill: "Claude needs you · 3 steps".

```json
{"reason": "My safety check won't let me change nameservers or invite an admin.",
 "steps": [
   {"tab": "TAB-1", "instruction": "Approve Apple", "text": "Approve"},
   {"tab": "TAB-1", "instruction": "Save", "text": "Save"},
   {"tab": "TAB-2", "instruction": "Tick Super Administrator", "ref": "e42"},
   {"instruction": "Run the secrets script (it reads 1Password)", "command": "bash ~/dev/cf-split/set-outside-secrets.sh"}
 ]}
```

`handoff` returns at once with an id (`h1`). `handoff_status` (`id`, `wait` up to 600 seconds, `cancel`) says which
steps the user did, skipped or hasn't reached, with each tab's URL now, so Claude carries on when they're done.
CLI: `kite call handoff '{…}'`, `kite call handoff_status '{"id":"h1","wait":600}'`. More in `docs/automation.md`.

## For agents: VPN reconnects without a tab

When a VPN client with web sign-in (OpenVPN Connect, Tunnelblick: SSO, SAML) reconnects, it opens its sign-in page
in the default browser. For a host Kite watches, Kite loads that page on a hidden page with the user's cookies (the
profile of the space the link would go to), and closes it once the sign-in goes back to the VPN's site. Only a page
that needs the user (a password, a code, an MFA push or button that sits there for 10 s, or 45 s without finishing)
becomes a tab, behind the one in front, with one Dock bounce and no change of focus.

The `vpn` tool: `status` (watched hosts, the last sign-in, and the hosts of links other apps opened lately, so you can
spot the VPN's), `watch` / `unwatch` with `host` (only one the user confirms is their VPN's; nothing is watched by
default), `reconnect` (has Tunnelblick, or OpenVPN Connect with `profile`, connect again, then waits for the sign-in)
and `wait`. It never changes the VPN client's profiles. CLI:

```bash
kite vpn status
kite vpn watch vpn.example.com
kite vpn reconnect [--profile NAME] [--timeout 60]
```

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
