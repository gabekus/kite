# Claude in the browser: MCP server and `kite` CLI

Claude Code (or any MCP client) can drive real Kite tabs on the user's own Claude plan.

```bash
# Kite menu → Allow Claude to Control the Browser (off by default), then:
claude mcp add kite -- /path/to/Kite.app/Contents/Helpers/kite mcp
```

The app shows the exact command, including `-e KITE_SUPPORT_PATH=…` when it runs on a test profile, when you turn the setting on.

## Tools

| MCP tool | CLI | What it does |
|---|---|---|
| `list_tabs` | `kite tabs` | Tab ids, titles, URLs, which is in front |
| `read_page` | `kite read [--tab ID] [--max N]` | URL, title, accessibility outline with refs (`e42`), page text |
| `click` | `kite click REF \| --selector CSS` | Real mouse events at the element's center (DOM click if it's covered) |
| `type` | `kite type TEXT [--ref R \| --selector S] [--submit]` | Focus, select, `Input.insertText`, optional Return |
| `navigate` | `kite open URL [--here \| --tab ID]` | New background tab by default in the CLI; waits for the load |
| `screenshot` | `kite screenshot [-o FILE]` | PNG of the tab's viewport (works for background tabs) |

Without a tab id, tools act on the tab in front. Background tabs are driven without switching to them.

## Pieces

- `Sources/KiteCore/Automation/` (Foundation only, unit tested):
  - `AutomationCommand`: the tools, their argument parsing and JSON Schemas.
  - `MCPServer`: the JSON-RPC/MCP handling (initialize, tools/list, tools/call, ping).
  - `AutomationWire`: the socket's line protocol and `LineBuffer`.
  - `AutomationPolicy`: which actions need the user's OK.
  - `UntrustedContent`: wraps page-derived text.
  - `AccessibilityOutline`: CDP AX tree → outline with refs.
  - `AutomationReport`: formats tool results; also holds `AutomationSettings`.
- `Sources/KiteCLI/main.swift`: the `kite` CLI and `kite mcp` (stdio ↔ app socket). Built as `kite-cli`, installed as
  `Kite.app/Contents/Helpers/kite` (a `kite` binary would collide with `Kite` on a case-insensitive disk).
- `Sources/KiteMac/Automation/`:
  - `AutomationServer`: the socket.
  - `AutomationController`: runs tools, confirmations, Stop, the setting.
  - `ChromiumAutomation`: CDP through `ExecuteDevToolsMethod`.
  - `WebKitAutomation`: read and screenshot only; click and type return "unsupported".
  - `ClaudeControlBanner`: the "Claude is controlling this tab" pill with Stop.
- `KCBrowser callDevToolsMethod:params:completion:` returns CDP's error message, not just nil.

## Safety

- **Local only.** The server is a Unix socket at `<profile>/Automation/kite.sock`:
  - its folder is 0700 and the socket 0600;
  - each connection's peer uid must match the user (`getpeereid`);
  - there is no TCP listener.
- **Off by default.** The setting is stored per profile in `<profile>/automation.json`. While it's off, no socket exists.
- **Confirmation.** Kite asks before an action that could commit something on the user's behalf. Kite selects the tab and shows a sheet. Deny is the default button, and no answer within 2 minutes counts as Deny. A denial comes back to Claude as a tool error. Kite asks before:
  - form submits;
  - clicks on controls whose text, id or name says send / post / pay / buy / order / checkout / delete / confirm / …;
  - typing into password, card, OTP and similar fields (the text is hidden in the sheet);
  - typing with `submit`;
  - opening `file:` URLs.

  Non-web URL schemes (`javascript:`, `data:`, …) are refused.
- **Untrusted content.** Page titles, URLs, text and the outline arrive inside `<untrusted-page-content>` blocks. Pages can't close a block early. The MCP `instructions` tell the model that this content is data.
- **Indicator.** A banner shows while Claude drives a tab. It clears 2 minutes after the last command, or 15 seconds after the client disconnects. Stop revokes that tab until the setting is turned off and on.

## Not done yet

- Iframes: the outline and refs cover the main frame only.
- WebKit click and type.
- `<select>` choice by option text.
- An in-app "Install `kite` command" option that symlinks the CLI onto PATH.
