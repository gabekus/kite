# Arc parity

Every Arc for Mac feature and shortcut we know of, and where Kite stands. The
plan is to port all of it, then strip what we don't want.

Sources (2026-10-22):
- Arc 1.169's own menu bar, read through the Accessibility API on Gabe's Mac
  (structure only, no personal data).
- Arc's settings keys (`defaults read company.thebrowser.Browser`, names only)
  and the `ARC_*` feature bundles inside Arc.app.
- Arc's help center: [Keyboard Shortcuts](https://resources.arc.net/hc/en-us/articles/20595231349911-Keyboard-Shortcuts),
  [Features](https://resources.arc.net/hc/en-us/categories/16435255982103-Features), [Arc Max](https://arc.net/max).

Status: ✅ done · 🟡 partial · ❌ missing.
Plan: **B1–B6** are small PR-sized batches worked down in order (see the end).
**Thread** means a bigger feature that gets its own design and PR series.
**Skip?** marks things we may decide not to port.

Gabe's Arc binds **⌘L to Add Split View** and **⇧⌘S to Next Space**. Arc's
documented defaults are ⌘L = edit URL and ⌥⌘→ = next space, so these look
like his remaps (Settings → Shortcuts). That's what "⌘L should be split view
by default" means. Kite keeps ⌘L as Open Location until split view exists,
then follows Gabe's binding, and shortcuts become remappable (B6).

## Shortcuts and menus

### Arc menu

| Arc item | Shortcut | Kite | Plan |
|---|---|---|---|
| About | | ✅ | |
| Settings… | ⌘, | ❌ | Thread: Settings window |
| Set as Default Browser | | ✅ (opens links from other apps in a new tab) | |
| Import from Another Browser… | | 🟡 Arc only | Thread: import (Chrome/Safari later) |
| Check for Updates… | | ❌ | Roadmap: Sparkle |
| Hide / Hide Others / Show All | ⌘H / ⌥⌘H | ✅ | |
| Quit, with optional warn-before-quit | ⌘Q | 🟡 no warning | B5 |
| Share Arc, Privacy Policy, Sign Out | | ❌ | Skip? (sign-out comes with sync) |

### File

| Arc item | Shortcut | Kite | Plan |
|---|---|---|---|
| New Tab… (opens the command bar) | ⌘T | ✅ | |
| New Window | ⌘N | ❌ | Thread: multiple windows |
| Blank Window | ⌃⌘N | ❌ | Thread: multiple windows |
| New Incognito Window | ⇧⌘N | ✅ in-memory profile per window (New Space moved off ⇧⌘N) | |
| New Little Arc Window | ⌥⌘N | ❌ | Thread: Little Arc |
| Restore Last Closed Tab | ⇧⌘T | ✅ | |
| Open Command Bar | (none) | ✅ via ⌘T/⌘L | |
| New Profile | | ❌ | Thread: profiles |
| New Easel | ⌃⇧E | ❌ | Thread: Easels (Skip?) |
| Close Window | ⇧⌘W | ✅ | |
| Archive Tab | ⌘W | 🟡 closes; Arc archives (findable in Library) | B3 |
| Share… | | ✅ | |
| Capture… / Full Page / Portrait | | ❌ | Thread: Capture |
| Save Page As | | ✅ MHTML (Chromium) / web archive (WebKit) | |
| Print | ⌘P | 🟡 Chromium's print opens its own window, no preview | Later: AppKit print sheet with preview |

### Edit

| Arc item | Shortcut | Kite | Plan |
|---|---|---|---|
| Undo / Redo (Undo includes "Undo Archive Tab") | ⌘Z / ⇧⌘Z | 🟡 text only | B3: undo close/archive |
| Cut / Copy / Paste / Select All | ⌘X/C/V/A | ✅ | |
| **Copy URL** (toast) | ⇧⌘C | ✅ this PR | |
| **Copy URL as Markdown** | ⌥⇧⌘C | ✅ this PR | |
| **Copy URL as Quote** | ⌃⇧⌘C | ✅ this PR (selection as a quote + link; Arc's exact format unverified) | |
| Paste and Match Style | ⇧⌘V | ✅ | |
| Delete | | ✅ | |
| Find… / Find Next / Find Previous | ⌘F / ⌘G / ⇧⌘G | ✅ find bar (match count on Chromium) | |
| Find and Replace | ⌥⌘F | ❌ | Skip? (text fields only) |
| Use Selection to Find / Jump to Selection | ⌘E / ⌘J | 🟡 ⌘E only | ⌘J later |
| Spelling, Substitutions, Transformations, Speech, Format, AutoFill, Dictation, Emoji | system | 🟡 all but Format and AutoFill | Later |

### View

| Arc item | Shortcut | Kite | Plan |
|---|---|---|---|
| Appearance: Automatic / Light / Dark (websites) | | 🟡 Dark Pages Off/Match/Always | Have it; the other session owns this |
| Show Sidebar | ⌘S | ✅ | |
| Show Toolbar (URL bar on top) | ⇧⌘D | ❌ | B5 (`topBarURLEnabled`) |
| Collapse Pinned Tabs | | ❌ | B3 |
| Stop Loading | ⌘. | ✅ | |
| Refresh / Force Refresh | ⌘R / ⇧⌘R | ✅ | |
| Clear Cookies and Refresh / Clear Cache and Refresh | | ✅ per site | |
| Add Split View | ⌘L (Gabe) / ⌃⇧= (default) | ❌ | Thread: Split view |
| Close Split Pane / Separate / Expand / focus pane N | ⌃⇧- / ⌃⇧1… | ❌ | Thread: Split view |
| Zoom Actual / In / Out | ⌘0 / ⌘+ / ⌘- | ✅ | |
| Cast | | ❌ | Skip? |
| Developer → View Source | ⌥⌘U | ✅ Chromium (new `view-source:` tab) | |
| Developer → Developer Tools | ⌥⌘I | ✅ | |
| Developer → Inspect Elements | ⌥⌘C | 🟡 opens DevTools, no picker yet | Later |
| Developer → JavaScript Console | ⌥⌘J | 🟡 opens DevTools, not on Console | Later |
| Developer → Network Inspector | | ❌ | Later, with the two above |
| Developer → Allow JavaScript from Apple Events | | ❌ | With AppleScript |
| Turn on Developer Mode for this site | ⌃D | ❌ | Thread: Developer Mode |
| Enter Full Screen | ⌃⌘F | ✅ | |
| Dark Page for This Site (Kite only) | ⌥⌘D | ✅ | |

### Spaces

| Arc item | Shortcut | Kite | Plan |
|---|---|---|---|
| New Space… | | ✅ | |
| Edit Theme… | | ❌ | Thread: space theme editor |
| Rename Space | | ✅ | |
| Change Profile | | ❌ | Thread: profiles |
| Next / Previous Space | ⇧⌘S (Gabe) or ⌥⌘→ / ⌥⌘← | ✅ all three | |
| Space 1…9 | ⌃1…⌃9 | ✅ | |
| Manage Spaces… | | ❌ | B3 (reorder, delete) |
| Swipe between spaces (two fingers) | gesture | ❌ | B3 |

### Tabs

| Arc item | Shortcut | Kite | Plan |
|---|---|---|---|
| Pin / Unpin Tab | ⌘D | ✅ | |
| New Folder… | | 🟡 imported folders only | B3 |
| Next / Previous Tab | ⌥⌘↓ / ⌥⌘↑ | ✅ (⌃⇧Tab also goes to the previous tab) | |
| Toggle recent tabs (MRU) | ⌃Tab | ✅ toggles the two most recent | Hold-⌃ cycling deeper later |
| Tab 1…8, last tab | ⌘1…⌘9 | ✅ | |
| Reveal Tab in Sidebar | | ❌ | B3 |
| Clear Today (unpinned tabs) | ⇧⌘K | ✅ archives them, with a toast | |
| Reset all tabs in this Space (pinned back to their saved URL) | | ❌ | B3 |
| Pinned tab: "back to pinned URL" / reset | | ❌ | B3 |
| Duplicate tab, move tab to space | context menu | 🟡 Duplicate Tab in the Tabs menu | Move to space with the sidebar work |
| Drag tabs between spaces / into folders | gesture | ❌ | Roadmap (other session owns sidebar) |

### Archive (history)

| Arc item | Shortcut | Kite | Plan |
|---|---|---|---|
| Go Back / Go Forward | ⌘[ / ⌘] (also ⌘← / ⌘→) | 🟡 no ⌘←/⌘→ | B3: only when no text field has focus, or they'd steal line-start/end |
| View History | ⌘Y | ❌ | Thread: Library (history page) |
| View Archive… / Clear Archive | | 🟡 archived tabs stored, no UI | Thread: Library |

### Extensions

| Arc item | Kite | Plan |
|---|---|---|
| One item per extension, Add / Manage Extensions | ❌ | Roadmap: Chrome-style CEF spike |

### Window

| Arc item | Shortcut | Kite | Plan |
|---|---|---|---|
| Minimize / Zoom | ⌘M | ✅ | macOS adds Fill, Center, tiling for free |
| Stay On Top | | ✅ | |
| Open Library… | ⇧⌘L | ❌ | Thread: Library |
| View Downloads… | ⇧⌘J | ❌ | Thread: Library (downloads) |
| View Easels… / Media… / Boosts… | | ❌ | Their threads |

### Help

| Arc item | Kite | Plan |
|---|---|---|
| Essential Keyboard Shortcuts (cheat sheet) | ✅ Help → Keyboard Shortcuts, built from the menus | |
| Restore Data, Reveal Data folder, Copy Info, Task Manager, Record Trace | 🟡 Reveal Kite Data, Copy Kite Info | Task Manager later |
| Getting Started, Contact, Help Center, Export Arc Notes | ❌ | Skip |

## Features without a menu item

| Feature | What it does in Arc | Kite | Plan |
|---|---|---|---|
| Command bar | Search tabs, history, actions, site search (type a site, Tab) | 🟡 URL/search + open tabs | B6: actions, history, site search |
| Sidebar | Favorites grid, pinned, unpinned "Today", folders, space switcher | 🟡 | Other session (favorites, folders, resize) |
| Sidebar hover reveal | Hidden sidebar slides in at the left edge | ❌ | B5 |
| Auto-archive | Unpinned tabs archive after 12h / 24h / 7d / 30d, per profile | 🟡 fixed 12h | B5: setting |
| Peek | Links from pinned tabs/favorites open in an overlay | ❌ | Thread: Peek |
| Hover cards / 5-second previews | ⇧ over a link shows a preview card | ❌ | Thread: Peek |
| Previews | Glance at favorites without switching | ❌ | Thread: Peek |
| Little Arc | Small window for links from other apps, ⌥⌘N, "open external links in Little Arc" | ❌ | Thread: Little Arc |
| Split View | Up to 4 panes, saved in the sidebar | ❌ | Thread: Split view |
| Mini Player / auto PiP | Media from a hidden tab plays in a sidebar player or PiP | ❌ | Thread: Mini player |
| Media pane | All tabs playing media | ❌ | Thread: Mini player |
| Boosts | Per-site CSS/JS/zap elements, shareable | ❌ | Thread: Boosts |
| Developer Mode | Per-site: URL bar shows localhost info, console pane | ❌ | Thread: Developer Mode |
| Easels | Freeform canvas of screenshots, live clips, text | ❌ | Skip? |
| Notes | Rich-text notes in the sidebar (Arc is phasing out) | ❌ | Skip |
| Capture | Screenshot tool for an area/full page | ❌ | Thread: Capture |
| Library | Downloads, archive, easels, media, boosts in one window | ❌ | Thread: Library |
| Air Traffic Control | Rules to route links from other apps to a space | ❌ | Thread: Little Arc / routing |
| Live folders | GitHub PRs/issues, RSS etc. as an auto-updating folder | ❌ | Later |
| Live calendars | Calendar favorite shows the next meeting | ❌ | Later |
| Share spaces, folders, splits | Public link or collaborator | ❌ | Roadmap: sync + sharing |
| Profiles | Separate cookies per space | ❌ | Thread: profiles |
| Incognito | Private window | ✅ | |
| Site control center | Per-site permissions, cookies, ad blocker toggle, Boosts | ❌ | Thread: Site controls (ad blocker thread owns the toggle) |
| Native ad blocker | uBlock-style lists | ❌ | Ad blocker thread |
| Translation | Translate page, "never translate" sites | ❌ | Later (Chromium translate isn't in CEF) |
| Instant Links | Command bar goes straight to the top result | ❌ | With Claude in the browser |
| Ask on Page | ⌘F asks AI about the page | ❌ | With Claude in the browser |
| ChatGPT/AI in command bar | Ask from the command bar | ❌ | With Claude in the browser |
| Tidy Tab Titles | Pinned tabs get short AI titles | ❌ | With Claude in the browser |
| Tidy Downloads | Downloads renamed by AI | ❌ | With Claude in the browser |
| Tidy Tabs | Groups Today tabs automatically | ❌ | With Claude in the browser |
| Browse for Me | AI builds a page from search results | ❌ | Skip? |
| Custom tab names | Rename a pinned tab | 🟡 imported names only | B3 |
| Themes | Space colors, grain, light/dark, gradient editor | 🟡 presets + imported | Thread: space theme editor |
| App icons | Alternate Dock icons | ❌ | Skip? (we draw our own) |
| Sound effects | Subtle UI sounds | ❌ | Later, our own sounds |
| Remappable shortcuts | Settings → Shortcuts | ❌ | B6 |
| AppleScript dictionary | windows, tabs (URL, title, execute JS), spaces | ❌ | With MCP/CLI thread; worth matching |
| Sync | Sidebar via CloudKit/Firebase | ❌ | Roadmap: sync |
| Default browser, handle links | | ✅ | |
| PWAs / installed apps | `app_mode_loader` shims | ❌ | Roadmap: PWAs |
| Sad tab | Crashed-tab page with reload | ❌ | B5 |
| Download from links, downloads list | | 🟡 WebKit saves files, no UI | Thread: Library |
| Picture in Picture | Video PiP | ❌ | Thread: Mini player |
| Gestures | Two-finger swipe back/forward | ❌ | B5 |
| Welcome / onboarding | | ❌ | Skip |

## Batches

Small and shortcut-level, one PR each, in this order:

- **B1. Copy commands** (this PR): Copy URL ⇧⌘C, as Markdown ⌥⇧⌘C, as Quote ⌃⇧⌘C, with a toast.
- **B2. Page commands:** Find (⌘F/⌘G/⇧⌘G/⌘E), Print ⌘P, Stop ⌘., Force Refresh ⇧⌘R,
  View Source ⌥⌘U, Inspect ⌥⌘C and Console ⌥⌘J (open DevTools for now), Full Screen ⌃⌘F,
  Paste and Match Style ⇧⌘V and the standard Edit submenus.
- **B3. Tabs and spaces:** ⌥⌘↓/⌥⌘↑ next/previous tab, ⌘←/⌘→ back/forward, ⌃Tab as MRU, Clear Today ⇧⌘K, ⌘W archives with
  ⌘Z undo, Reset tabs in space, back to pinned URL, New Folder, Rename tab/space, Reveal in sidebar,
  Collapse Pinned, ⇧⌘S next space, Manage Spaces, swipe between spaces. Avoids the sidebar files the
  other session is editing where possible.
- **B4. Windows:** ⇧⌘N incognito (done; New Space moved to the Spaces menu). ⌘N new window and ⌃⌘N
  blank window need per-window selection in `BrowserState` and pages that can move between windows, so
  they get their own thread.
- **B5. Small UX:** Show Toolbar ⇧⌘D, Stay On Top, sidebar hover reveal, auto-archive setting,
  warn before quit, Share…, Set as Default Browser, keyboard-shortcut cheat sheet, Reveal data folder,
  sad tab, swipe gestures, Save Page As, Clear Cookies/Cache and Refresh.
- **B6. Command bar and remapping:** command bar actions (every menu command searchable), history,
  site search; user-remappable shortcuts.

Bigger features, each its own thread: Split view, Peek (+ hover previews), Little Arc (+ link routing),
Mini player / PiP / media, Library (history, archive, downloads), Settings window, Boosts,
Developer Mode, Capture, Profiles, Space theme editor, Site controls. Already owned elsewhere: sandbox,
MCP/CLI and AI features, ad blocker, Arc import UI / favorites / folders / sidebar.
