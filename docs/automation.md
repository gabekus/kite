# Claude in the browser: MCP server and `kite` CLI

Claude Code (or any MCP client) can drive real Kite tabs on the user's own Claude plan, the way Claude in Chrome
drives Chrome.

**Connect:** Kite menu → **Connect Claude Code…** turns control on and asks once. It then:
- links `kite` into `~/.local/bin`;
- runs `claude mcp add -s user kite -- …/Kite.app/Contents/Helpers/kite mcp`.

The same sheet can copy a `claude_desktop_config.json` snippet for Claude Desktop. By hand:

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
| `javascript_tool` | `javascript` | `kite js CODE` | Asks every time unless "Allow Claude to Run JavaScript Without Asking" is on. |
| `read_console_messages` | `read_console_messages` | `kite console [--errors]` | Regex `pattern`, `only_errors`, `clear`. |
| `read_network_requests` | `read_network_requests` | `kite network` | Regex `url_pattern`, `clear`. |
| `upload_image` / `file_upload` | `upload_file` | | Paths on this Mac. The sheet lists them first. |
| (none) | `click`, `type`, `screenshot` | `kite click/type/screenshot` | Kept from the first version. |
| (none) | `wait_for` | | load, navigation, selector, text, network_idle. Event-driven. |
| (none) | `handle_dialog` | | alert / confirm / prompt / beforeunload. |
| (none) | `list_downloads` | | Downloads since control was turned on. |
| (none) | `list_spaces`, `switch_space`, `create_space`, `pin_tab`, `create_folder`, `move_to_folder` | `kite spaces` | Kite's own organization. |
| `gif_creator`, `shortcuts_*`, `switch_browser` | not yet | | |

| (none) | `batch` | `kite call batch` | Several tool calls in one round trip. See below. |

`kite call TOOL '{json}'` reaches any tool. `kite tools` lists them all. The old names `list_tabs`,
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

  It also stops before any step that would need the user's OK, without asking. That step has to be called on its
  own, so the user sees it on its own and a batch can never chain past a confirmation. Every step goes through the
  same policy as a single call.
- **Change-only reads.** Kite keeps each tab's last `read_page` as a baseline. After a click, type, `form_input`,
  key press, dialog answer or navigation, the result adds what changed since that read: outline and text lines,
  marked + and −. It's capped at 60 lines; past that, or on a new page, it says to call `read_page`.
  `read_page` with `changes_only` returns only the diff. A tab that was never read costs nothing extra.
- **Cheaper screenshots.**
  - JPEG (quality 70) is the default; `format: "png"` gives lossless. On a Wikipedia article that was 65 KB instead
    of 165 KB.
  - Screenshots are at most 1280 pixels wide, because Claude's image cost grows with pixels. Coordinates Claude
    reads off a scaled screenshot are mapped back to the page for every `computer` action.
  - `zoom` still returns full resolution.

## Safety

- **Off by default.** The setting is stored per profile in `<profile>/automation.json` (`allowClaudeControl`,
  `allowJavaScript`, `useClaudeSpace`). While it's off there's no socket, and no DevTools events are collected.
- **Local only.** A Unix socket at `<profile>/Automation/kite.sock`. Its folder is 0700 and the socket 0600, and the
  peer uid is checked.
- **Confirmation sheet.** Kite selects the tab and asks. Deny is the default button; after 2 minutes the answer is
  Deny. A denial comes back to Claude as a tool error. Kite asks before:
  - submitting a form;
  - clicking a control whose text, id or name says send / post / pay / buy / order / checkout / delete / confirm and
    similar. This includes `computer` clicks at a coordinate: the point is hit-tested and the control there is
    classified the same way. Clicks into another site's iframe always ask.
  - Return (or Space) on such a button;
  - Return in a text field, except search boxes. ⌘/Ctrl-Return counts too.
  - typing or `form_input` into password, card, one-time-code and similar fields;
  - running JavaScript, unless the user allowed it in the menu;
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

## Not done yet

- Cross-site (out-of-process) iframes can't be read; clicks into them ask first.
- `find` matches words, not meaning.
- No GIF recording, shortcuts, or browser switching.
- Downloads are listed but can't be started, cancelled or redirected.
- No split view or Peek tools: those features don't exist in Kite yet.
- WebKit tabs can only be read and captured.
