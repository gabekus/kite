# Action trace

Kite records every automation tool call, and every event around it, on one timeline with one pair of clocks, so the
time an agent and the user spend in the browser can be measured and optimized, and handed to an eval pipeline.
It covers Gabe's own browsing too (with `actor: "user"`), and resource samples (memory, CPU, wakeups, energy, the
Mac's power and heat).

- **Where:** `<support>/Traces/YYYY-MM-DD.jsonl` (`~/Library/Application Support/Kite/Traces/`, or
  `$KITE_SUPPORT_PATH/Traces/`), one JSON object per line, a file per local day, owner-only (0700 folder, 0600
  files). Days older than 90 are deleted; a day stops growing at 200 MB.
- **Never uploaded.** Nothing in Kite reads the trace but `kite trace` and the `trace` tool.
- **Off switch:** Settings › Advanced › Kite › Record Action Trace (on by default; UserDefaults `actionTraceDisabled`).
- **Cost:** emitting fills in a record and appends it to a buffer under a lock; encoding and writing happen on a
  background queue every 0.5 s (or at 256 records), so a tool call or the main thread never waits on the disk.
  `ActionTraceTests` holds an event under 1 ms on the main thread (it's a few microseconds), a 300-tab sidebar diff
  under 1 ms, and a resource sample under 5 ms off the main thread.

## Reading it

```bash
kite trace                                  # the last hour: timeline, then the summary
kite trace --since 15m --session "Cloudflare DNS move"
kite trace --tab 3F2A --actor agent         # a tab (id or its first characters); user, agent or kite
kite trace --json                           # the matching records as JSONL
kite trace export --session NAME > run.jsonl   # a session's records (everything kept), for evals
kite trace resources --since 2h             # top tabs by memory and energy, Kite's totals, the Mac
```

`kite trace` reads the files itself, so it works whether or not Kite is running (the last half second may not be
written yet). The timeline has one line per call and event: local time, the gap since the line before, the
duration, who, and what (tool or event, tab, host and path, `→` where a call ended up, details, and phases in braces).
Batch steps are indented under their batch. Samples are left out of the timeline; `resources` reads them.

The summary gives, per tool, the count, errors, p50, p95 (nearest rank), max and total; the five slowest calls; the
agent's time working, waiting on the user (`handoff_status`, `sign_in`, confirmation sheets) and between calls (the
agent thinking); a finished handoff step to the agent's next call; the slowest page loads by host; command bar
opened to page loaded; and energy by host and by Claude session.

Agents read their own timings with the MCP tool `trace` (read-only): by default its own connection's calls over
the last 15 minutes, or `session`, `tab`, `actor`, `all`; `summary_only` drops the timeline.

## Privacy

A trace must be safe to hand to an eval pipeline. It never holds typed text, a form value, page text, a script, a
find query, a note, a dialog's message, a file path or a screenshot. Concretely (`TraceRedaction`, `TraceCall`,
`TracePageInput`, tested in `ActionTraceTests`, including that a typed sentinel never reaches a record or the file):

- **URLs** are a host and a path. Query values are stripped (`/search?q=&page=`: the names stay), the fragment and
  any user or password go, and path segments that look like ids, tokens or emails become `:n`, `:id`, `:email`.
  Non-web URLs keep only their scheme (`file:`).
- **`type` and `form_input`** record the field's role (`name`, `address`, `card`, `password`, `code`, `email`,
  `phone`, `search`, `username`, `id_number`, `date`, `number`, `text`, …) and the length, never the text.
- **Errors** lose page content blocks and anything in quotes (Kite quotes what it echoes back), and stop at 240
  characters.
- **Clicks on pages** record the element's role and accessible name (40 characters at most, digit runs and emails
  masked, none for text fields), and a link's host and path. Never coordinates.
- **Fields on pages** record the role and the length when left, never the value.
- **Private (incognito) windows trace nothing**: no tab, page, input or download events, and their pages don't run
  the trace's page script. Their renderer processes still count in Kite's resource totals, with no tab or host.

## Clocks

Every record has `t` (wall clock, Unix milliseconds) and `m` (monotonic, milliseconds since boot, counting while the
Mac sleeps: `CLOCK_MONOTONIC_RAW`, the same in every process). Durations (`dur`, ms) and ordering use `m`; `t` lines
the trace up with other logs. A call's end is `m + dur`.

## Records

Every line:

| Field | Type | Meaning |
|---|---|---|
| `v` | int | Schema version, `1`. Changes only when a field is renamed, retyped or removed; new fields don't. |
| `kind` | string | `call`, `event` or `sample`. |
| `name` | string | The tool (`click`), the event (`handoff.step_done`) or the sample (`proc`). |
| `t`, `m` | number | Wall and monotonic start, ms. |
| `dur` | number? | Duration, ms. |
| `actor` | string? | `user`, `agent:<client>` (`agent:claude-code`, `agent:cli` for `kite call`), or `kite`. |
| `id` | string? | `<launch>-<n>`, unique across launches. Every call has one. |
| `parent` | string? | The batch a step belongs to, or the call an event happened inside. |
| `conn` | int? | The socket connection (one `kite mcp` or `kite` process). |
| `client` | string? | The MCP client's name from `initialize` (`clientInfo.name`), or `cli`. |
| `session` | string? | The Claude › session folder (the agent's `session`, or its tabs' folder). |
| `task` | string? | A Claude task Kite started itself. |
| `tab` | string? | Tab UUID. |
| `host`, `path` | string? | Where the tab was at the start (redacted as above). |
| `host_end`, `path_end` | string? | Where it was at the end of a call, when that changed. |
| `attrs` | object? | Per name, below: numbers, booleans and words Kite chose. |

### Calls (`kind: "call"`)

One per tool call, over MCP (`kite mcp`) or `kite call` (the same dispatcher, `AutomationController.perform`), and
one per batch step with `parent` set to the batch's `id`.

| Field | Meaning |
|---|---|
| `ok` | Whether it worked. |
| `error` | The redacted error, when it didn't. |
| `bytes`, `images` | The result's size as sent (text bytes plus base64 image bytes) and its image count. |
| `phases` | Where the time went, ms. They don't overlap and add up to at most `dur`. |

Phases: `queue` (the request's line arriving to the dispatcher starting it), `wait` (waiting on the page: a load
settling after an action, `wait_for`), `js` (DevTools round trips: scripts, the DOM, the accessibility tree), `input`
(mouse and key events), `screenshot` (Chromium rendering and encoding the image), `encode` (Kite's base64), `confirm`
(Ask Before Claude Acts' sheet), `user` (`handoff_status` and `sign_in` waiting on the person).

Call `attrs`, by tool (anything else is left out):

| Tool | attrs |
|---|---|
| `type` | `len`, `submit`, `target` (`ref`, `selector`), `field` (role) |
| `form_input` | `len`, `value_type` (`string`, `bool`, `number`), `target`, `field` |
| `computer` | `action`, `target` (`ref`, `selector`, `point`); `len` for type; `keys` (count), `enter`, `shortcut` for key; `scroll_direction`, `scroll_amount` |
| `click`, `upload_file` | `target`; `files` (count) |
| `navigate`, `tabs_create` | `url_host`, `url_path`, or `nav` (`back`, `forward`); `new_tab`, `active`, `claude_folder`, `space` (whether one was named) |
| `find` | `len` (of the query) |
| `javascript` | `len` (of the code) |
| `wait_for` | `condition`, `timeout_ms` |
| `read_page` | `filter`, `changes_only` |
| `screenshot` | `format` |
| `handle_dialog` | `accept`, `prompt_len` |
| `tab_status` | `state`, `note_len` |
| `handoff` | `steps`, `wait` |
| `handoff_status` | `wait`, `cancel` |
| `batch` | `steps` |
| `vpn`, `ui` | `action` |
| `move_to_folder` | `folder` (only `claude`) |

### Events (`kind: "event"`)

Agent and handoff:

| name | Fields and attrs |
|---|---|
| `connection.opened`, `connection.closed` | `conn` |
| `agent.reaction` | `dur`: a finished handoff step to this connection's next call; `next` (the tool) |
| `handoff.created` | `conn`, `session`; `handoff`, `steps` |
| `handoff.step_shown` | `tab`; `handoff`, `step` (Kite brought the step's tab forward) |
| `handoff.step_ringed` | `tab`; `handoff`, `step` (the ring first showed on the control) |
| `handoff.step_done`, `handoff.step_skipped` | `tab`, `conn`, `session`; `handoff`, `step`, `how` (`click`, `value`, `done`, `skip`, `navigation`, `withdrawn`, `other`), `since_created_ms` |
| `tab.state` | `tab`; `state` (`working`, `needs_you`, `done`, `stalled`, `idle`), `declared` and `note_len` for `tab_status` |
| `sign_in.started`, `sign_in.finished` | `tab`; `outcome` (`signedIn`, `cancelled`, `timedOut`), `dur` |
| `confirm.answered` | `tab`, `dur`; `allowed` |

Tabs and the sidebar (from diffing the sidebar after each change, `TraceLayout`; `actor` is whoever made it):

| name | attrs |
|---|---|
| `tab.opened`, `tab.closed` | `section` (`favorite`, `pinned`, `unpinned`) |
| `tab.moved`, `tab.pinned`, `tab.unpinned` | `from`, `to`, `space_changed`, `folder_changed`, `into_session` |
| `tab.selected` | `section` |
| `space.switched` | |
| `folder.created`, `folder.removed` | `folder` (its id) |
| `tab.discarded` | `reason` (`tab_limit`, `memory_pressure`): Kite hibernated the page |

Pages (Claude's tabs and the user's, normal windows only):

| name | Fields and attrs |
|---|---|
| `page.load_started` | `cause` (`command_bar`, `command_bar_history`, `search`, `back`, `forward`, `reload`, `link`, `agent`, `page`: a redirect, script or unseen link) |
| `page.commit` | `since_start_ms` |
| `page.load` | `dur` (start to load finished); `cause`, `engine`, `pid` (renderer), `intent_ms` (command bar opened to loaded), `crashed` |
| `page.timing` | From the page: `ttfb_ms`, `dcl_ms`, `load_ms`, `fcp_ms` (from navigation start), `nav` (`navigate`, `reload`, `back_forward`) |
| `page.url_changed` | The address changed without a load (pushState) |
| `page.crashed` | `code`, `engine` |
| `permission.prompt` | `permissions` (`camera`, `microphone`, `location`, `notifications`, …) |
| `permission.answered` | `dur`; `answer` (`allow`, `block`, `dismiss`) |
| `dialog.shown`, `dialog.answered` | `kind` (`alert`, `confirm`, `prompt`, `leave`, `reload`); `accepted`, `dur` |
| `input.click` | `role`, `name`, `button`, `link_host`, `link_path`, `new_tab` |
| `input.field_focus`, `input.field_blur` | `field` (role); `len`, `changed`, `dur` (focused time) on blur |
| `input.scroll` | `dx`, `dy`, `n` (scroll events collapsed into this one), `dur` |
| `download.started`, `download.finished` | host and path of the download URL; `total_bytes`; `state`, `bytes`, `dur` |
| `extension.opened_tab` | An extension opened a tab |

Kite's UI and the app:

| name | attrs |
|---|---|
| `command_bar.opened` | `mode` |
| `command_bar.picked` | `kind` (`open`, `search`, `site_search`, `switch_tab`, `history`, `command`, `instant_links`), `rank` (1-based), `query_len`, `results` |
| `command_bar.closed` | `dur` (open to closed) |
| `ui.menu`, `ui.shortcut` | `command` (the menu item's identifier or action) |
| `app.launch` | `dur` (process start to ready); `process_to_main_ms`, `main_to_did_finish_launching_ms`, `did_finish_launching_to_window_shown_ms`, `window_shown_to_ready_ms`, `engine` |
| `app.quit` | `dur` (since launch) |
| `app.active`, `app.inactive` | |
| `app.sleep`, `app.wake` | `dur` on wake (time asleep) |
| `app.hang` | `dur`: the main thread answered a ping this late (checked once a second while Kite is in front; 250 ms or more) |
| `trace.on`, `trace.off` | The setting changed |
| `system.memory_pressure` | `level` (`warning`, `critical`) |
| `system.thermal` | `state` (`nominal`, `fair`, `serious`, `critical`) |
| `system.low_power` | `on` |
| `system.power` | `on_battery` |

### Samples (`kind: "sample"`)

Every 10 s on AC, 30 s on battery, none while the Mac sleeps, and at once on memory pressure, a thermal change, Low
Power Mode or a power source change. Reading is `proc_pid_rusage` per process on a background queue.

| name | attrs |
|---|---|
| `proc` | `pid`, `proc` (`browser`, `gpu`, `renderer`, `extension`, `utility`, `other`), `service` (a utility's), `tabs`, `hosts`, `sessions` (what that renderer draws), `resident_mb`, `footprint_mb`; from the second reading of a process, over the interval (`dur`): `cpu_pct`, `wakeups_s` (interrupt), `idle_wakeups_s` (package idle), `energy_mj` (billed energy), `power_mw`. `tab`, `host` and `session` are set when there's only one. |
| `totals` | `processes`, `resident_mb`, `footprint_mb`, `cpu_pct`, `wakeups_s`, `energy_mj`, `power_mw`, `reason` (`interval`, `start`, `memory_pressure`, `thermal`, `power`, `low_power`) |
| `system` | `on_battery`, `battery_pct`, `drain_pct_h` (on battery, since the last sample), `minutes_to_empty`, `thermal`, `low_power`, `memory_pressure` (`normal`, `warning`, `critical`) |

Energy by host and by session in the summary shares each renderer's energy evenly between the hosts (and sessions)
it draws; processes with no tab count under `(gpu)`, `(browser)` and so on.

## Not traced (yet)

- WebKit pages (Kite's fallback engine) have no page script: no `input.*` or `page.timing` events.
- Peek, Little Kite and web app windows' pages.
- Extensions' toolbar buttons and their own actions beyond opening a tab.
- Renderer kills by the OS are `page.crashed` with the engine's code; Kite doesn't tell an out-of-memory kill apart.
