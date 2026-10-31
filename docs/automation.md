# Claude in the browser: MCP server and `kite` CLI

Claude Code (or any MCP client) can drive real Kite tabs on the user's own Claude plan, the way Claude in Chrome
drives Chrome.

**Connect:** Kite menu → **Connect Claude…** turns control on and asks once. It then:
- links `kite` into `~/.local/bin`;
- runs `claude mcp add -s user kite -- …/Kite.app/Contents/Helpers/kite mcp`;
- if the Claude desktop app is installed, adds the same server to
  `~/Library/Application Support/Claude/claude_desktop_config.json` (everything else in the file is kept, and the
  old file is saved as `claude_desktop_config.json.kite-backup`), then quits and reopens Claude so it loads it.

The same sheet can still copy the snippet instead. By hand:

```bash
claude mcp add -s user kite -- /path/to/Kite.app/Contents/Helpers/kite mcp
```

**Transport.** MCP over stdio (`kite mcp`), then the app's Unix socket, then in-process DevTools calls
(`ExecuteDevToolsMethod`). Kite never opens a remote-debugging port for this.

## Tools, and their Claude in Chrome equivalents

| Claude in Chrome | Kite tool | CLI | Notes |
|---|---|---|---|
| `tabs_context_mcp` | `tabs_context` | `kite tabs` | Every tab in every space, with ids, URLs, space, front. |
| `tabs_create_mcp` | `tabs_create` | `kite open URL` | Background by default. `space: "claude"` opens it in a Claude space. |
| `tabs_close_mcp` | `tabs_close` | `kite call tabs_close` | Asks first if Claude didn't open the tab. |
| (switch tab) | `switch_tab` | | |
| `navigate` | `navigate` | `kite open URL --here` | Also `"back"` / `"forward"`. Waits for the load. |
| `resize_window` | `resize_window` | | Points. |
| `read_page` | `read_page` | `kite read [--interactive]` | Outline with refs, same-site iframes included, then page text. |
| `find` | `find` | `kite find QUERY` | Word and role matching, not a model. Returns refs. |
| `get_page_text` | `get_page_text` | `kite text` | `<article>` or `<main>` when present. |
| `computer` | `computer` | `kite key KEYS` | See below. |
| `form_input` | `form_input` | | Text, checkbox/radio (true/false), `<select>` by option text or value. |
| `javascript_tool` | `javascript` | `kite js CODE` | Runs without asking, like Claude in Chrome. |
| `read_console_messages` | `read_console_messages` | `kite console [--errors]` | Regex `pattern`, `only_errors`, `clear`. |
| `read_network_requests` | `read_network_requests` | | Regex `url_pattern`, `clear`. |
| (none) | `network_log`, `network_request`, `export_har` | `kite network [--follow]`, `kite request ID`, `kite har` | HAR-style log across tabs with a cursor. See below. |
| `upload_image` / `file_upload` | `upload_file` | | Paths on this Mac. The sheet lists them first. |
| (none) | `click`, `type`, `screenshot` | `kite click/type/screenshot` | Kept from the first version. |
| (none) | `wait_for` | | load, navigation, selector, text, network_idle. Event-driven. |
| (none) | `handle_dialog` | | alert / confirm / prompt / beforeunload. |
| (none) | `list_downloads` | | Downloads since control was turned on. |
| (none) | `list_spaces`, `switch_space`, `create_space`, `pin_tab`, `create_folder`, `move_to_folder` | `kite spaces` | Kite's own organization. |
| `gif_creator`, `shortcuts_*`, `switch_browser` | not yet | | |

| (none) | `batch` | `kite call batch` | Several tool calls in one round trip. See below. |

`kite call TOOL '{json}'` reaches any tool. Options can go before or after the command
(`kite --socket PATH mcp`). `kite tools` lists them all. The old names `list_tabs`,
`tabs_*_mcp` and `javascript_tool` still work.

### `computer`

Actions:
- `screenshot`;
- `left_click`, `right_click`, `middle_click`, `double_click`, `triple_click` (at `coordinate` or a `ref`, with `modifiers`);
- `hover`;
- `scroll` (`scroll_direction`, `scroll_amount`);
- `left_click_drag`;
- `key` (`"Enter"`, `"cmd+a Backspace"`, `repeat`);
- `type`;
- `wait` (up to 30 s);
- `zoom` (`region` `[x0, y0, x1, y1]`, returned at full resolution).

Screenshots have one pixel per CSS pixel of the viewport, so a pixel in the screenshot is the coordinate to click.

How the actions run:
- **Pointer and keys:** mouse and key events go through `Input.dispatchMouseEvent` / `dispatchKeyEvent`. ⌘
  shortcuts carry their macOS editing command (`selectAll`, `copy` and so on), which Chromium needs to act on them.
- **Scrolling:** done in the page (the scrollable element under the point), because a background tab never
  acknowledges wheel events.
- **Background tabs:** everything works on background tabs without switching to them. Only a confirmation sheet
  brings a tab forward.

## Fewer round trips, fewer tokens

Most of an agent's time goes to model round trips and context, not to the browser. Three things cut both.

- **`batch`.** Up to 25 tool calls run in one round trip, in order. For example: `form_input`, `type` with submit,
  `wait_for` text, then `read_page` with `changes_only`. A batch-wide `tab` applies to every step that doesn't name
  one. It stops at the first error.

  It also pauses (not an error) before any step that would need the user's OK, without asking. That step has to be called on its
  own, so the user sees it on its own and a batch can never chain past a confirmation. Every step goes through the
  same policy as a single call.
- **Change-only reads.** Kite keeps each tab's last `read_page` as a baseline. After a click, type, `form_input`,
  key press, dialog answer or navigation, the result adds what changed since that read: outline and text lines,
  marked + and −. It's capped at 60 lines; past that, or on a new page, it says to call `read_page`.
  `read_page` with `changes_only` returns only the diff; the first one on a tab only records the baseline and says so,
  so it stays small. `type` warns when the field it typed into isn't visible (a hidden copy of a search box, say). A tab that was never read costs nothing extra.
- **Cheaper screenshots.**
  - JPEG (quality 70) is the default; `format: "png"` gives lossless. On a Wikipedia article that was 65 KB instead
    of 165 KB.
  - Screenshots are at most 1280 pixels wide, because Claude's image cost grows with pixels. Coordinates Claude
    reads off a scaled screenshot are mapped back to the page for every `computer` action.
  - `zoom` still returns full resolution.

## Kite's own interface: the `ui` tool

The tools above read web pages. `ui` reads Kite itself (window, sidebar, card, command bar, menus) from inside the
app, so checking Kite's behaviour never needs a screen recording, an app switch or the user's pointer. It's off
unless Kite menu → **Diagnostics for Claude** is on (it needs Claude's control on too), or a test build runs with
`KITE_DIAGNOSTICS=1` on a `KITE_SUPPORT_PATH` profile, which also turns control on for that profile.

Points are window points from the window's top-left corner (the content runs under the titlebar). A point
names the device pixel whose top-left it is, so a point on a rect's top or left edge is inside it.

| Action | What it returns |
|---|---|
| `windows` | Each window's number, kind (browser, incognito), size, scale, key/main, full screen, covered, refresh rate. |
| `tree` | Views with frames, `NSVisualEffectView` material and blending, layer fill, corner radius and curve, border, shadow, text colour and font, hidden and alpha; SwiftUI's accessibility elements (role, id, label, frame, selected) inside hosting views; with `layers`, Core Animation sublayers. `root` starts at a node path, `match` lists matching nodes flat, `depth` and `max_nodes` bound it. |
| `capture` | The window's pixels through ScreenCaptureKit, as on screen, even when covered or in the background, in sRGB. `region` crops at full resolution, `pixels` reads colours as hex, `save` writes a PNG. Without Screen Recording permission it falls back to a view render and says what that misses. |
| `pointer` | Synthetic mouse moves (`points`, or `from`/`to`/`steps`) sent to the window only. At each point: the view hit, cursor rects, tracking areas (flagged when inactive because Kite is in the background), and the cursor Kite sets. Identical points fold into runs. |
| `input` | One synthetic event for the window: `keys`, `text`, `click` (with `button`, `count`, `modifiers`), a drag (`from`/`to`) or `scroll` (`dx`, `dy`). With Kite in front keys take AppKit's exact path; in the background they take the same steps by hand (view key equivalents, menu bar, first responder). Says where each key went. |
| `menu` | Every menu item: path, shortcut, action and target, id, enabled, hidden. Flags shortcuts with no ⌘/⌃/⌥/fn ("FIRES WHILE TYPING", the emoji-on-e bug) and two enabled items on one shortcut. |
| `key_log` | The last keys pressed in Kite: window, first responder chain, input source, and any menu item each one fired. Plain typing shows only its kind (letter, digit), unless it fired a menu item. |
| `trace` | Records for `seconds` (default 1.5), after pressing optional `keys`: each Core Animation animation (key path, duration, curve control points or spring, from/to), every layer whose on-screen frame or opacity changed with progress samples, SwiftUI elements matching `match`, and frame intervals with late frames. |

CLI: `kite ui ACTION '{json}' [-o FILE]`. `capture -o` saves at full resolution.

What works with Kite in the background (checked on a test build behind other windows):

- Nothing activates Kite or takes focus, including clicks and keys. A `KITE_DIAGNOSTICS=1` run opens its
  window behind the user's windows; capture, tree, pointer and trace all work on a covered window.
- `tree` gets SwiftUI's elements by asking Kite's own accessibility tree once (SwiftUI builds it only for an
  accessibility client). That needs Accessibility permission for Kite; a test build launched from a terminal or
  Claude inherits the launching app's. Without it the tree says SwiftUI's elements are missing.
- `capture` needs Screen Recording permission, inherited the same way for a test build.
- `pointer` hover: a synthetic move drives tracking areas and SwiftUI's `.onHover` in the background. The
  window server only sends entered and exited for the real pointer, so the probe sends them itself as its point
  crosses an area; hover stays where the last point left it (so a capture can see it), and a point outside the
  window, like `[-1,-1]`, ends it. Areas limited to the key window or the active app are listed as INACTIVE NOW
  and get nothing, as with a real pointer over a background window. Over a web page the cursor is WebKit's,
  set later from the web process, so it isn't named.
- `input` clicks and drags follow AppKit's first-mouse rule: with the window not key, a view that doesn't
  accept first mouse (the sidebar resize handle, for one) never gets the click, and a synthetic click can't
  activate Kite the way a real first click would. `input` says when that happened. SwiftUI buttons and rows
  accept first mouse, so they work.
- Keys: a web view claims ⌘ shortcuts as key equivalents and hands them back to the menu bar a moment later;
  `input` and `key_log` follow the key through and name the menu item it fired.
- `trace`: animation `from`/`to` values are the layer's own (position in its superlayer, bottom-left), while
  the sampled frames are window points. SwiftUI's accessibility frames follow the model, not the animation, so
  `match` shows only start and end; the layers show the curve.
- `menu`: AppKit ignores fn when matching a key against the menu bar, so a system item on fn E (Emoji &
  Symbols) or fn F (Enter Full Screen) fires on a plain "e" or "f" that reaches the menu bar, and is flagged.

`kite probe APP` does the same reading for another app (Arc), from outside it: `kite probe Arc tree` (accessibility
roles and frames in window points; text hidden unless `--text`) and `kite probe Arc capture -o arc.png` (one window
in the background, sRGB). It needs Accessibility and Screen Recording permission for whatever runs `kite`. Another
app's cursors can't be read from outside it.

Pieces: `UIInspection` and `UIReport` in KiteCore (arguments and formatting, unit tested), `Sources/KiteMac/Diagnostics/`
(the Mac side; `CursorRectRecorder` swaps in a recording copy of `NSView.addCursorRect(_:cursor:)` the first time a
pointer probe runs, since AppKit can't list cursor rects otherwise), and `Sources/KiteCLI/Probe.swift`.

## Network log

`read_network_requests` only sees a tab after Claude first touches it, and keeps method, URL and status. The network
log is for debugging with Claude: the user reproduces a bug in their own tabs, then Claude reads what happened.

- **Record Network for Claude** (Kite menu, off by default, needs control on) logs every tab in the main window, not
  just the tabs Claude drives. Incognito windows are never logged. Without it, the log still covers Claude's tabs, in
  memory only.
- **What's kept.** For each finished request: method, URL, status, resource type, MIME type, protocol, server
  address, initiator, size on the wire, duration, timing phases (blocked, dns, connect, ssl, send, wait, receive), and
  request and response headers (the ones that actually went out, from the `ExtraInfo` events). The newest 5,000 are
  kept in memory.
- **Redaction, before anything is kept.** Cookie and Set-Cookie keep only cookie names and attributes. Authorization,
  API key, CSRF, session and token headers are masked. Secret-looking query and fragment parameters are masked
  (`token`, `code`, `state`, `sig`, `key`, `password`, `X-Amz-Signature` and similar), and so are passwords in URLs.
  Bodies get the same treatment for JSON fields and form fields when they're fetched.
- **Bodies are never stored.** Chromium holds them (up to 20 MB per tab, 5 MB per response) and `network_request`
  fetches them on request. Request bodies aren't copied into events (`maxPostDataSize: 0`).
- **On disk.** While recording, finished requests are appended to `<profile>/NetworkLog/YYYY-MM-DD.ndjson`, one
  JSON object per line (folder 0700, files 0600), so `jq` and `tail -f` work on them too. Days older than 7 are
  deleted, and a day stops at 100 MB. HAR exports go to the same folder and are deleted on the same schedule.

Tools:
- `network_log`: one short line per request, like `#41 POST 422 fetch 87ms 1.2kB api.example/v1/orders`, then
  `cursor: 41`. `since` returns only newer requests, so polling it is a tail. Filters: `tab` (default every tab),
  `status` (`2xx`…`5xx`, `errors`), `host` (with subdomains), `type` (`fetch,xhr`, or `all`), `url_pattern`,
  `limit` (default 50). Successful images, fonts, stylesheets and media are hidden unless `type` is `all`; failures
  always show.
- `network_request`: one request in full: timing, redacted headers, and both bodies while Chromium still has them,
  cut to `max_body_length` (default 4,000 characters).
- `export_har`: a HAR 1.2 file of the matching requests (every type), with text bodies when `bodies` is true.
  Returns the path.

Built for cost. Everything is answered from memory over the local socket, with no page work, so a call costs well
under a millisecond. The per-request line is about 20 tokens. A tail returns only what's new, headers and bodies
come only when asked for, and the tools work inside `batch`: a click, `wait_for` network_idle and
`network_log` with `since` make one round trip.

`kite network --follow` prints new requests as they finish, polling the cursor once a second.

## Safety

- **Off by default.** The setting is stored per profile in `<profile>/automation.json` (`allowClaudeControl`,
  `useClaudeSpace`, `recordNetwork`). While it's off there's no socket, and no DevTools events are collected.
- **Local only.** A Unix socket at `<profile>/Automation/kite.sock`. Its folder is 0700 and the socket 0600, and the
  peer uid is checked. A profile too deep for a socket path (over 103 bytes, e.g. a test profile in a nested temp
  folder) uses `/tmp/kite-<uid>/<hash of the profile path>.sock` instead. The app refuses that folder unless it can
  make it 0700, and the CLI only connects to a socket the user owns.
- **Confirmation sheet.** Kite selects the tab and asks. Deny is the default button; after 2 minutes the answer is
  Deny. A denial comes back to Claude as a tool error. Kite asks before:
  - submitting a form;
  - clicking a control whose text, id or name says send / post / pay / buy / order / checkout / delete / confirm and
    similar. This includes `computer` clicks at a coordinate: the point is hit-tested and the control there is
    classified the same way. Clicks into another site's iframe always ask.
  - Return (or Space) on such a button;
  - Return in a text field, except search boxes. ⌘/Ctrl-Return counts too.
  - typing or `form_input` into password, card, one-time-code and similar fields;
  - uploading files;
  - answering OK to a `confirm`, `prompt` or leave-page dialog;
  - closing a tab Claude didn't open;
  - opening `file:` URLs.

  Other non-web schemes are refused.
- **Untrusted content.** Everything a page controls comes back inside `<untrusted-page-content>` blocks that pages
  can't close early:
  - titles, URLs and page text;
  - the outline and `find` results;
  - console and network logs;
  - JavaScript results;
  - dialog messages;
  - form values.
- **Indicator.** A "Claude is controlling this tab" pill floats over the page, with Show and **Stop**. Stop revokes
  the tab: it ends its event collection and fails pending confirmations and waits.

## Events, waits and dialogs

When Claude first touches a tab, Kite enables the Page, Runtime, Log and Network domains for that tab. `TabActivity`
(in KiteCore) keeps up to 1,000 console messages and 1,000 requests per tab, plus any open dialog and the in-flight
count. All of it is dropped when the tab closes, the user presses Stop, or control is turned off.

How `wait_for` waits, without polling:
- **load and navigation:** `Page.loadEventFired` and `Page.frameNavigated` events;
- **network_idle:** nothing in flight for 0.5 s;
- **selector and text:** a `MutationObserver` inside the page.

How dialogs work:
- A page with a JavaScript dialog open is frozen. Tools other than `handle_dialog`, `screenshot` and the logs report
  the dialog instead of hanging.
- An action that opens a dialog returns as soon as it opens.
- CEF also shows its own native dialog. If the user answers that one, the tab unfreezes for Claude too.

## Pieces

- `Sources/KiteCore/Automation/` (Foundation only, unit tested):
  - `AutomationCommand` and `AutomationTools`: the tools, their arguments and schemas.
  - `KeyChord`: key names to DevTools key events.
  - `AutomationPolicy`: what needs confirmation.
  - `ElementFinder`: `find`.
  - `TabActivity`: console, network, dialogs and idleness.
  - `NetworkLog`, `Redaction` and `NetworkLogStore`: the network log, its redaction, and its files on disk.
  - `AccessibilityOutline`, `UntrustedContent`, `MCPServer`, `AutomationWire`, `AutomationReport`.
- `Sources/KiteCore/BrowserState+Automation.swift` holds the additions behind the Kite tools: background spaces, the
  Claude space, folders and moving tabs into them. Nothing in it changes existing mutations.
- `Sources/KiteCLI/main.swift`: the `kite` CLI and `kite mcp`. It's built as `kite-cli` and installed as
  `Kite.app/Contents/Helpers/kite`.
- `Sources/KiteMac/Automation/`:
  - `AutomationController` (+`Tools`): runs the tools, confirmations, Stop, events and waits.
  - `ChromiumAutomation`: the DevTools calls.
  - `WebKitAutomation`: read and screenshot only.
  - `AutomationServer`: the socket.
  - `ClaudeControlBanner`: the pill.
  - `ClaudeConnect`: the Connect sheet.
- `KCBrowser`:
  - `callDevToolsMethod:params:completion:` returns DevTools errors;
  - `devToolsEventHandler` delivers DevTools events;
  - `KCDownloadDidUpdateNotification` reports downloads.

## Claude Tasks: Kite's own Claude

Kite menu → **Claude Tasks…** (or **Ask Claude About This Tab…**) gives Claude a goal without leaving Kite.
Kite runs Claude Code headless on the user's own Claude login (no API key):

```
claude -p --output-format stream-json --verbose --include-partial-messages \
  --mcp-config '{"mcpServers":{"kite":{"command":".../Helpers/kite","args":["mcp"],"env":{"KITE_AGENT_TASK":"<task id>"}}}}' \
  --strict-mcp-config --tools "" --allowedTools mcp__kite --permission-mode dontAsk --append-system-prompt …
```

- **Only Kite's tools.** `--strict-mcp-config` skips the user's other MCP servers and `--tools ""` removes Claude Code's
  shell, file and web tools. Every Kite safety rule still applies: the confirmation sheets, untrusted-content blocks
  and the Stop button. Starting a task turns on Allow Claude to Control the Browser.
- **Background.** `kite mcp` sends `KITE_AGENT_TASK` with each call. Tabs that task opens go into a folder named after
  the task in the Claude space, never in front of the user. Tabs it closes are removed from the folder for good.
  **Close Tabs** removes the folder.
- **Keeps going.** While a task runs, Kite holds an idle-sleep assertion, and closing the main window only hides it
  (the Dock icon brings it back). A closed lid still sleeps the Mac.
- **Finishing.** The task posts a notification (clicking it opens the task) and badges the Dock icon until it's read.
  **Follow up** runs another turn in the same Claude Code session (`--resume`).
- **What's kept.** `<profile>/Claude/tasks.json` (0600, last 50 tasks) holds the goal, Claude's replies, one line per
  tool call and errors. Tool results (page content) are never stored. Claude Code runs in `<profile>/Claude/Work`, so
  no project's CLAUDE.md applies.
- **Pieces.** `ClaudeTask`, `ClaudeStream` (stream-json parser) and `ClaudeInvocation` live in `KiteCore/Claude`.
  `ClaudeTasksController` (processes, tabs, notifications) and `ClaudeTasksWindow` live in `KiteMac/Claude`.

## Not done yet

- Cross-site (out-of-process) iframes can't be read; clicks into them ask first.
- `find` matches words, not meaning.
- No GIF recording, shortcuts, or browser switching.
- Downloads are listed but can't be started, cancelled or redirected.
- No split view or Peek tools: those features don't exist in Kite yet.
- WebKit tabs can only be read and captured.

## One Claude with the Claude desktop app

The goal: Kite's Claude and the Claude desktop app should be the same Claude, so it knows what the user did in
Desktop. What Desktop knows (chat history, chat search, memory, projects) lives in the claude.ai account and is
only reachable from inside a Desktop or claude.ai chat. Nothing hands it to `claude -p`, and Desktop's local data
isn't an API. So Kite joins Desktop instead of running a second Claude next to it:

- **Desktop has Kite's tools.** Setup (the sidebar's Claude button) and Connect Claude… add Kite to
  `claude_desktop_config.json`. Desktop loads servers from that file into its Chat tab, Cowork and its local
  Code sessions, so whatever Claude does in Kite from Desktop is in that chat, with Desktop's memory.
- **⌘J asks in Desktop.** With **Kite menu → Ask Claude in the Claude App** on (the default when Desktop is
  installed), Return in the ⌘J bar opens `claude://claude.ai/new?q=…` with the request (and the attached tab's
  title, URL and Kite tab id) in a new Desktop chat. Desktop shows it in the composer and the user sends it. The
  bar's ↗ button switches between Desktop and running here.
- **Kite tasks continue in Desktop.** A task that ran here (`claude -p`) has a Claude Code session id; the bar's
  "Continue in the Claude App" button runs `claude --desktop --resume <id>`, which opens that session in
  Desktop's Code tab (Claude Code 2.1.285+, Claude subscription sign-in).

Limits: Desktop doesn't send a `q` prompt by itself (by design), and a headless task that's opened in Desktop
shouldn't get more Kite follow-ups, or the two would write to one transcript.

