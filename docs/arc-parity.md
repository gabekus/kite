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
by default" means. Kite follows Gabe's bindings by default: ⌘L is Add Split View (Open Location
has no key; the URL pill still opens it), and shortcuts are remappable (B6).

## Shortcuts and menus

### Arc menu

| Arc item | Shortcut | Kite | Plan |
|---|---|---|---|
| About | | ✅ | |
| Settings… | ⌘, | ❌ | Thread: Settings window |
| Set as Default Browser | | ✅ (opens links from other apps in a new tab) | |
| Import from Another Browser… | | 🟡 Arc: spaces, pinned tabs, folders, favorites, themes, split views, archive (latest 500), history, Site Search, shortcut changes, and the settings Kite has (warn before quitting, Little Arc for links, archive interval). Kite › Import from Another Browser…: bookmarks (a space per browser, as pinned tabs and folders) and history from Safari (explains Full Disk Access), Chrome, Brave, Edge, Vivaldi, Opera, Opera GX | Thread: import. Not yet: passwords, cookies, autofill, Firefox, other browser profiles, Arc’s bookmark picker; from Arc: link routing, boosts, easels/notes, extensions, other profiles |
| Check for Updates… | | 🟡 checks GitHub releases, opens the release; no auto-install or sidebar banner yet | Sparkle once releases are signed and notarised |
| Hide / Hide Others / Show All | ⌘H / ⌥⌘H | ✅ | |
| Quit, with optional warn-before-quit | ⌘Q | 🟡 "Quit Kite?" with Arc's three buttons; look unmeasured, Kite menu toggle until Settings | B5 |
| Share Arc, Privacy Policy, Sign Out | | ❌ | Skip? (sign-out comes with sync) |

### File

| Arc item | Shortcut | Kite | Plan |
|---|---|---|---|
| New Tab… (opens the command bar) | ⌘T | ✅ | |
| New Window | ⌘N | 🟡 Another window on the shared sidebar (spaces, pinned, favourites, tabs) with its own space and tab, opening on the command bar; restored on relaunch (windows.json). A tab selected in two windows has one page: it moves to the window that selected it last (or comes forward), and the other shows a blurred snapshot, as Arc's content placeholder | |
| Blank Window | ⌃⌘N | 🟡 Arc's standalone-sidebar window: its own "Explore" tabs outside the spaces, restored on relaunch. Moving its tabs into a space not built | |
| New Incognito Window | ⇧⌘N | ✅ in-memory profile per window (New Space moved off ⇧⌘N) | |
| New Little Arc Window | ⌥⌘N | ✅ "New Little Kite Window" (`newLittleBrowserWindow`) | |
| Restore Last Closed Tab | ⇧⌘T | ✅ | |
| Open Command Bar | (none) | ✅ via ⌘T/⌘L | |
| New Profile | | ✅ Arc's two-step Create a new Profile sheet (name, then which spaces) | Sheet layout not measured from Arc |
| New Easel | ⌃⇧E | ❌ | Thread: Easels (Skip?) |
| Close Window | ⇧⌘W | ✅ | |
| Archive Tab | ⌘W | ✅ "Archive Tab" (`archiveTab`); closed unpinned tabs go to the archive. "Undo Archive Tab" (⌘Z) still to do | B3 |
| Share… | | ✅ | |
| Capture… / Full Page / Portrait | (none) | 🟡 Capture… (`capturePage`) and Capture Full Page (`captureFullPage`); Portrait Mode, click-to-capture an element and ⌘⇧-drag still to do | Thread: Capture |
| Save Page As | | ✅ MHTML (Chromium) / web archive (WebKit) | |
| Print | ⌘P | ✅ "Print": the macOS print sheet with a page preview, both engines (Chromium via a PDF). Arc likely shows Chromium's print preview instead (see arc-visual-spec) | |

### Edit

| Arc item | Shortcut | Kite | Plan |
|---|---|---|---|
| Undo / Redo (Undo includes "Undo Archive Tab") | ⌘Z / ⇧⌘Z | 🟡 Archiving or closing a tab registers "Archive Tab" on the window's undo manager: Edit › Undo Archive Tab puts that tab back where it was, selected; Redo archives it again. Text undo unchanged. Pinned tabs come back selected but reloaded | |
| Cut / Copy / Paste / Select All | ⌘X/C/V/A | ✅ | |
| **Copy URL** (toast) | ⇧⌘C | ✅ "Copied Current URL" toast | |
| **Copy URL as Markdown** | ⌥⇧⌘C | ✅ `[title](url)`, same "Copied Current URL" toast as Arc | |
| **Copy URL as Quote** | ⌃⇧⌘C | 🟡 Arc uploads the selection to arc.net and copies a share link (toast "Copied Link / With Quote"); Kite has no server, so it copies a local Markdown quote + link. Nothing happens with no selection, as in Arc | |
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
| Show Toolbar (URL bar on top) | ⇧⌘D | ✅ View → Show/Hide Toolbar: a 32pt bar over the page with back/forward/reload, the host, Site Controls and Split View; the sidebar drops its nav buttons and URL field. Kite menu → Show Full URL in Toolbar (Arc's "Show full URL when Toolbar is enabled", off by default) prints the whole address instead of the host. No right-click menu on the toolbar yet (Arc's has Show/Hide Full URL) | B5 (`topBarURLEnabled`) |
| Collapse Pinned Tabs | | ✅ View › "Collapse Pinned Tabs" ("Expand Pinned Tabs" while collapsed) and a chevron in the space header | B3 |
| Stop Loading | ⌘. | ✅ | |
| Refresh / Force Refresh | ⌘R / ⇧⌘R | ✅ | |
| Clear Cookies and Refresh / Clear Cache and Refresh | | ✅ per site | |
| Add Split View | ⌘L (Gabe) / ⌃⇧= (default) | ✅ `addSplitView`, empty pane + command bar (live check pending) | Thread: Split view |
| Close Split Pane / Separate / Expand / focus pane N | ⌃⇧- / ⌃⇧1… | ✅ Expand Current Split (no key, as Arc) fills the split with the focused pane; one-way, as Arc (focusing another pane restores, inferred) | Thread: Split view |
| Zoom Actual / In / Out | ⌘0 / ⌘+ / ⌘- | ✅ | |
| Cast | | ❌ | Skip? |
| Developer → View Source | ⌥⌘U | ✅ Chromium (new `view-source:` tab) | |
| Developer → Developer Tools | ⌥⌘I | ✅ | |
| Developer → Inspect Elements | ⌥⌘C | 🟡 opens DevTools, no picker yet | Later |
| Developer → JavaScript Console | ⌥⌘J | 🟡 opens DevTools, not on Console | Later |
| Developer → Network Inspector | | ❌ | Later, with the two above |
| Developer → Allow JavaScript from Apple Events | | ✅ off by default, per profile; gates AppleScript `execute` | |
| Developer → Inspect Elements | ⌥⌘C | ✅ Chromium: DevTools with the element picker on (WebKit: Web Inspector's element selection) | |
| Developer → JavaScript Console | ⌥⌘J | ✅ DevTools on Console | |
| Developer → Network Inspector | | ✅ Chromium: DevTools on Network (WebKit: opens Web Inspector as it was) | |
| Developer → Allow JavaScript from Apple Events | | ❌ | With AppleScript |
| Turn on Developer Mode for this site | ⌃D | 🟡 Per-host switch (title flips to "Turn off…"), remembered across relaunches; on a Developer Mode site the sidebar's reload button gets Arc's reload options (Reload this page / Refresh (Ignore Cache) / Clear Cookies and Refresh) and reloads the way last chosen. Site Controls has Arc's Developer Mode row (On / Off) | Gap 16 |
| Enter Full Screen | ⌃⌘F | ✅ | |
| Dark Page for This Site (Kite only) | ⌥⌘D | ✅ | |

### Spaces

| Arc item | Shortcut | Kite | Plan |
|---|---|---|---|
| New Space… | | ✅ | |
| Edit Theme… | | ✅ popover laid out from Arc's | Grid mapping unmeasured |
| Rename Space | | ✅ | |
| Change Profile | | ✅ profile picker with New Profile, Cancel / Change Profile; plus Spaces › Profiles… (rename, delete) until Settings exists | Sheet layout not measured from Arc |
| Next / Previous Space | ⇧⌘S (Gabe) or ⌥⌘→ / ⌥⌘← | ✅ all three | |
| Space 1…9 | ⌃1…⌃9 | ✅ | |
| Manage Spaces… | | ❌ | B3 (reorder, delete) |
| Swipe between spaces (two fingers) | gesture | ✅ | Physics not yet fitted to Arc |

### Tabs

| Arc item | Shortcut | Kite | Plan |
|---|---|---|---|
| Pin / Unpin Tab | ⌘D | ✅ | |
| New Folder… | | 🟡 imported folders only | B3 |
| Next / Previous Tab | ⌥⌘↓ / ⌥⌘↑ | ✅ (⌃⇧Tab also goes to the previous tab) | |
| Toggle recent tabs (MRU) | ⌃Tab | ✅ toggles the two most recent | Hold-⌃ cycling deeper later |
| Tab 1…8, last tab | ⌘1…⌘9 | ✅ | |
| Reveal Tab in Sidebar | | ✅ shows the sidebar, opens enclosing folders, scrolls to the row | Arc's highlight on reveal unverified |
| Clear Today (unpinned tabs) | ⇧⌘K | ✅ archives them, with a toast | |
| Reset all tabs in this Space (pinned back to their saved URL) | | ✅ | |
| Pinned tab: "back to pinned URL" / reset | | 🟡 hover button, context menu (with Separate From Pinned Tab), hidden `resetTab` command; Edit Pinned Page › Edit… (Edit Pinned URL dialog) and Replace Pinned URL with Current on pinned tabs and favorites | Arc's icon and placement unverified; Arc's command-bar "Replace Pin with Current Page" not built |
| Duplicate tab, move tab to space | context menu | 🟡 Duplicate Tab in the Tabs menu | Move to space with the sidebar work |
| Drag tabs between spaces / into folders | gesture | ❌ | Roadmap (other session owns sidebar) |

### Archive (history)

| Arc item | Shortcut | Kite | Plan |
|---|---|---|---|
| Go Back / Go Forward | ⌘[ / ⌘] (also ⌘← / ⌘→ in a page) | ✅ ⌘←/⌘→ as hidden alternates; text fields keep them for caret moves (seen in Arc; not in its binding table) | B3 |
| View History | ⌘Y | 🟡 History › View History opens kite://history in a new tab (Arc: chrome://history "in a new Today tab"): search, one card per day, Open in New Tab / Copy Link / More from This Site / Remove from History, Clear History…. One row per URL (last visit), not one per visit; Chromium's page sizes not measured | |
| View Archive… / Clear Archive | | 🟡 History › View Archive… opens the Library on its Archive page (kite://archive still works as a tab): Today / Yesterday / Earlier This Week, then by month; search; Filter Archived Tabs by space and Auto-Closed / Manually Closed, with removable chips; Restore and Delete on hover and in the context menu; "Tab restored to <space>" toast. Clear Archive asks Arc's "Are you sure you'd like to Clear Archive?" first. Sizes are Kite's | |

### Extensions

| Arc item | Kite | Plan |
|---|---|---|
| One item per extension, Add / Manage Extensions | ❌ | Roadmap: Chrome-style CEF spike |

### Window

| Arc item | Shortcut | Kite | Plan |
|---|---|---|---|
| Minimize / Zoom | ⌘M | ✅ | macOS adds Fill, Center, tiling for free |
| Stay On Top | | ✅ checkmark in the menu, window floats, no in-window indicator (as in Arc) | |
| Open Library… | ⇧⌘L | 🟡 Window › Open Library… toggles the window's Library over the sidebar and card: Downloads, Archive and Media pages, last page remembered, "Exit the Library" button; switching tab or space leaves it | Easels, Boosts, Spaces pages (Kite has none of them); sizes, icons and animation unmeasured |
| View Downloads… | ⇧⌘J | ✅ Window menu, opens the downloads list (Arc opens Library › Downloads) | Follow-up: open Library › Downloads instead, as Arc does |
| View Easels… | | ❌ | Their threads |
| View Media… | | 🟡 Window › View Media… opens the Library's Media page, as in Arc: pictures and videos from Documents, Desktop, Downloads and screenshots after Arc's "Your Media in the Library" / Allow Access card, plus Kite's own Captures (now kept in Captures/); Today / Yesterday / Earlier This Week, then by month; search; "Show media from:" toggles; preview on click (Esc closes); Copy, Show in Finder, Open in Preview, Open/Copy Source URL, Delete (Capture), Hide from Kite. Sizes are Kite's | AirDrop / Send via iMessage; Hide Media toggle title |
| View Boosts… | | 🟡 Window menu, opens a Boosts window (Arc opens Library › Boosts): every Boost with Enable/Disable, rename, delete, double-click to edit | Move into the Library when it exists |

### Help

| Arc item | Kite | Plan |
|---|---|---|
| Essential Keyboard Shortcuts (cheat sheet) | ✅ Arc's floating 475×458 window: 5 fixed commands with their live shortcuts as blue keycaps; "View All" opens the full list. Split View and Little Arc rows show a shortcut only once remapped or built | |
| Restore Data, Reveal Data folder, Copy Info, Task Manager, Record Trace | 🟡 Reveal Kite Data, Copy Kite Info, Open Task Manager (Chromium's default columns, End Task; Network reads N/A) | Task manager search and categories, Network column, extension and spare renderer rows; Record Trace |
| Getting Started, Contact, Help Center, Export Arc Notes | ❌ | Skip |

## Features without a menu item

| Feature | What it does in Arc | Kite | Plan |
|---|---|---|---|
| Command bar | Search tabs, history, actions, site search (type a site, Tab) | ✅ URL/search, open tabs, history, every menu command, site search (Arc's 19 defaults plus anything imported from Arc) | Site Search editor: Settings thread. Site Search looks like Arc's (favicon, "Search YouTube" + Tab keycap, brand-colour chip, "Search...", inline completion of shortcuts); whether Arc also completes history URLs inline is unverified |
| Sidebar | Favorites grid, pinned, unpinned "Today", folders, space switcher | 🟡 | Other session (favorites, folders, resize) |
| Sidebar hover reveal | Hidden sidebar slides in at the left edge | ❌ | Thread: sidebar left-edge peek |
| Auto-archive | "Archive tabs after": Never / 1 hour / 6 hours / 12 hours / 24 hours / 7 days / 30 days, per profile | ✅ Kite menu → Archive tabs after (moves to Settings; no profiles yet) | B5 |
| Peek | Links from pinned tabs/favorites open in an overlay | 🟡 Links from a pinned tab or favorite to another site, and ⇧-clicked links, open in a card over the page (Arc's size, corner, shadow and spring), growing from the clicked element's own frame and closing back to it; close (Esc, ⌘W, button, click outside), Open as Tab, Create/Add to Split View | Not yet: the source snapshot crossfade (Kite fades the card in), the peeked item in the sidebar, swipe right to dismiss, reopen-closed-Peek undo, the Links settings toggles; button look unmeasured |
| Hover cards / 5-second previews | ⇧ over a link shows a preview card | ❌ | Thread: Peek |
| Peek | Links from pinned tabs/favorites open in an overlay | ❌ | Thread: Peek |
| Hover cards / 5-second previews | ⇧ over a link shows a preview card | 🟡 ⇧-hover shows a card (title, description, image, site) sized and timed from Arc's binary; `LinkPreviewController`. Off by default as in Arc; Kite menu › Link Previews | No AI summary (Arc's quickSummary + detail rows), no instant cards on HN/X/Google, no share button yet |
| Previews | Glance at favorites without switching | ❌ | Thread: Peek |
| Little Arc | Small window for links from other apps, ⌥⌘N, "open external links in Little Arc" | 🟡 Little Kite: own window, toolbar measured from Arc, "Open in <Space>" (⌘O) moves the live page into the main window, ⌘W closes, Kite menu → Open Links from Other Apps in Little Kite (on by default) | No profile indicator, extensions button, downloads tray, searchable space picker, auto-archive or global hotkey yet |
| Split View | Up to 4 panes, saved in the sidebar | 🟡 horizontal and top/bottom panes, divider (Arc's 10pt gap and hit area, 220pt minimum pane, 14pt centre snap, double-click evens out a pair in 0.2s ease-out; adding a pane is instant, as recorded in Arc), sidebar row; command bar Add Vertical Split View, Convert to Horizontal/Vertical and Add Left/Right/Top/Bottom Split (Arc has those in the command bar, not the menu bar); drop a page link on a content edge to open it in a new pane (real drag pending a hands-on check). Not yet: the pane's Split View Controls menu, the sidebar plus menu's New Right/Bottom Split, dragging sidebar tabs into a split, moving panes | Thread: Split view, gaps 40/41 |
| ⌥⌘-click a link into Split View | A ⌘-click with ⌥ held opens the link in a new pane | 🟡 WebKit and Chromium: the link opens in a pane next to the clicked tab and takes focus; ⇧⌘ stays a foreground tab, ⇧ stays Peek, a full split does nothing. Kite has no ⌥⌘ Little Arc entry point, so ⌥⌘ always splits (Arc with that toggle off). Not yet: ⌥-middle-click on WebKit, ⌥⌘ on a `target=_blank` link in Chromium | Gap 37 |
| Mini Player / auto PiP | Media from a hidden tab plays in a sidebar player or PiP | 🟡 | Sidebar Mini Player (play/pause, prev/next, tab mute, PiP, close, back to tab); auto PiP on leaving a playing video. No volume slider, mic/camera, marquee, Arc PiP window |
| Zap (Boosts) | Pick elements on a page; they stay hidden on that site | 🟡 Zap button in the Boost editor opens the picker over the page (hover highlight, click → Zap this / Zap all related elements / Cancel), shelf listing the Boost's zaps with remove; zaps are stored on the site's Boost and applied by the Boost script, live on change, off with the Boost and in incognito; old zaps.json migrated once | No candidate slider, zap preview images or Copy selector mode; highlight colour/cursor and the Zap button's icon unmeasured. Gap 22 |
| Media pane | All tabs playing media | ✅ n/a: Arc has no such pane: its "Media" is the Library's gallery of pictures, videos and Captures (see View Media…) | — |
| Media pane | All tabs playing media | ❌ | Thread: Mini player |
| Tab audio button | Speaker on a sidebar tab that is playing or muted; click (or context menu Mute/Unmute) to toggle | 🟡 24pt button between favicon and title, Arc's tooltips and menu titles | Arc's animated speaker (waves, slash) is SF Symbols here |
| Mute / Unmute All Tabs | Command-bar actions that mute or unmute every tab | ✅ hidden Tabs-menu commands found by the command bar (Arc's titles and action ids); every live page in the window, all spaces | Arc's scope (window vs app) untraced |
| Boosts | Per-site CSS/JS/zap elements, shareable | 🟡 Code Boosts and Zap: New Boost / Edit Boost in the command bar (Arc's hidden menu actions and keywords) open an editor window with CSS and JS for the site's domain and a Zap tool; boosts.json in the profile; applied at page load on both engines, top frame, never in incognito; zaps also apply live | Not yet: colours, fonts, text size/case, site control centre entry, live CSS/JS without reload, sharing/gallery, Arc import |
| Page right-click menu | Chromium's page menu with Arc's Open Link in Split View / Little Arc and Capture Image... | 🟡 Link section as Arc on both engines (New Tab, New Window, Split View, Little Kite, Incognito Window, Save Link As…, Copy Link/Email Address); image section on both (Open Image in New Tab, Save Image As…, Copy Image, Copy Image Address); on Chromium Arc's whole menu: page (Back, Forward, Reload, Save As…, Print…), selection (Look Up, Search … for / Go to, Copy, Copy Link to Highlight, Print…, Speech), View Page Source, Inspect | Gap 36, g54. Not yet: WebKit keeps its own selection and page sections; Capture Image...; Cast/Translate/Search for Image (Kite has none); Customize Page › Boosts needs Boosts. Copy Link Text skipped: Arc only shows it for touch |
| Developer Mode | Per-site switch and dev reload options (Arc's strings show no console pane or URL change) | 🟡 See the Developer menu row | Gap 16 |
| Easels | Freeform canvas of screenshots, live clips, text | ❌ | Skip? |
| Notes | Rich-text notes in the sidebar (Arc is phasing out) | ❌ | Skip |
| Capture | Screenshot tool for an area/full page | ❌ | Thread: Capture |
| Library | Downloads, archive, easels, media, boosts (Arc: in the browser window, not a separate one) | 🟡 Downloads, Archive and Media pages in the window (⇧⌘L) | Easels & Notes, Boosts, Spaces pages; Library button in the sidebar with download badge and fly-in |
| Capture | Screenshot tool for an area/full page | 🟡 Area (drag) and full page: Copy / Save; no Easels, no Portrait Mode | Thread: Capture |
| Library | Downloads, archive, easels, media, boosts in one window | ❌ | Thread: Library |
| Air Traffic Control | Rules to route links from other apps to a space | 🟡 | Kite menu → Air Traffic Control…: URL "Is equal to"/"Contains" routes to a space or Little Kite, plus a default. No profile destination; editor lives in its own window until Settings exists |
| Live folders | GitHub PRs/issues, RSS etc. as an auto-updating folder | ❌ | Later |
| Live calendars | Calendar favorite shows the next meeting | ❌ | Later |
| Share spaces, folders, splits | Public link or collaborator | ❌ | Roadmap: sync + sharing |
| Profiles | Separate cookies per space | 🟡 Each profile is its own Chromium profile folder (Default, Profile 1…), as Arc: cookies, logins, history, extensions, favorites and 1Password per profile; spaces point at one; space menu › Set Profile ("Switch it up" confirm); delete only unused profiles, typed-name confirm, folder removed next launch | Not yet: Arc import of profiles, Little Kite profile picker, per-profile search engine / auto-archive / downloads settings, dialogs measured from Arc |
| Incognito | Private window | ✅ | |
| Site control center | Per-site permissions, cookies, ad blocker toggle, Boosts | 🟡 Popover from the toolbar's sliders button and the sidebar URL field's hover button: Copy URL, Share, Block Ads & Trackers, Developer Mode, camera/mic/location/notifications (Chromium content settings; not on WebKit), Secure/Insecure, Clear Cache / Clear Cookies / All Site Settings… (and the Settings header, "More" on hover) opening the site's permissions page in a new tab (kite://site-settings; Arc opens Chromium's siteDetails page). No Boosts, capture, extensions section, sidebar Preview row | Gap 8, g59 |
| Site permission prompts | A site asks for camera, mic, location or notifications | 🟡 Arc's card at the page's top-leading corner: the permission's icon, "Allow <site> to access your camera?" / "…to send you notifications?", Not Now / Allow, "Click the lock 🔒 to change this any time"; pops in like Arc's. Chromium stores the answer per site (Site Controls shows it); WebKit asks each time, camera and mic only. Not over a Peek; other permission types (MIDI, downloads, storage…) keep Chromium's default | Gap 35 |
| Native ad blocker | uBlock-style lists | ❌ | Ad blocker thread |
| Translation | Translate page, "never translate" sites | ❌ | Later (Chromium translate isn't in CEF) |
| Instant Links | Command bar goes straight to the top result | 🟡 ⇧⏎ on a search: Kite's Claude splits it into Google queries (Arc's V1 schema: title, queries, tab/folder/split), a hidden web view opens each top result; tabs, a split or a folder. Falls back to the input as the query without Claude Code, and to the results page on a captcha | No loading cell in the sidebar (Arc's `InstantLinksCellView`), no V2 typed actions (images, maps, news, counts), no intent suggestion row, no settings toggle |
| Ask on Page | ⌘F asks AI about the page | 🟡 Find bar reads "Find or ask…"; Return on a query with no match asks Kite's Claude (`claude -p`, no tools, page innerText); answer under the bar with clickable quotes. Off by default as in Arc; Kite menu › Ask on Page (⌘F) | Panel geometry and styling not measured in Arc; no hint/upsell, no "No matches" label, no per-tab conversation |
| ChatGPT/AI in command bar | Ask from the command bar | ❌ | With Claude in the browser |
| Tidy Tab Titles | Pinned tabs get short AI titles | 🟡 pinning a tab (any path) asks Kite's Claude (`claude -p`, haiku, no tools) for a 1–3 word name, set as the tab's custom name; renaming or unpinning first wins; on by default as in Gabe's Arc, Kite menu › Tidy Tab Titles; `TidyTabTitles`, `TidyTabTitlesController` | No title animation (Arc's isAnimatingAiRename), no per-site rules (Arc's TidyTitleConfiguration), no feedback report, no settings row |
| Tidy Downloads | Downloads renamed by AI | ❌ | With Claude in the browser |
| Tidy Tabs | Groups Today tabs automatically | 🟡 Tidy button on the Today divider (on hover) asks Kite's Claude, then shows each group under a header with Close tab group and Remove header; Undo Tidy Tabs; Kite menu toggle (on, like Gabe's Arc). Button and header sizes are Kite's | Gap 27: measure Arc's divider buttons; Clear button; tidyAndClear |
| Tidy Downloads | Downloads renamed by AI | 🟡 A finished download is renamed by Kite's Claude (`claude -p`, fast model), extension kept, never overwrites; "Download renamed!" toast with Undo. On by default (Gabe's `renameDownloadsEnabled`); Kite menu › Tidy Downloads | Renames after completion (Arc names it before it lands), no sidebar rename banner, no Settings row |
| Tidy Tabs | Groups Today tabs automatically | ❌ | With Claude in the browser |
| Browse for Me | AI builds a page from search results | ❌ | Skip? |
| Custom tab names | Rename a pinned tab | ✅ any tab: Rename… in its menu, double-click, Tabs › Rename Current Tab…; kept when the page title changes, imported from Arc | B3 |
| Themes | Space colors, grain, light/dark, gradient editor | 🟡 presets + imported | Thread: space theme editor |
| App icons | Alternate Dock icons | ❌ | Skip? (we draw our own) |
| Sound effects | Subtle UI sounds | 🟡 Kite › Play Kite Sound Effects (on, like Arc); Kite's own capture sound made in code, played at Arc's 0.7 volume when Capture… or Capture Full Page takes an image | Gap 30. Not yet: tab-reorder haptics (tab-drag thread) |
| Remappable shortcuts | Settings → Shortcuts | 🟡 overrides in keybindings.json, keyed by Arc-style action IDs on every menu item; Import from Arc brings over Arc's StorableKeyBindings.json; the Settings editor is to come | B6 |
| AppleScript dictionary | windows, tabs (URL, title, execute JS), spaces | 🟡 Arc’s sdef: windows, tabs (id, title, URL, loading, location; make, select, close, go back/forward, reload, stop, execute), spaces read only, Little Kite tabs; no `focus` or settable `location` yet | Gap 28 |
| Sync | Sidebar via CloudKit/Firebase | ❌ | Roadmap: sync |
| Default browser, handle links | | ✅ | |
| Web mail for mailto: links | A site registers itself (`navigator.registerProtocolHandler`), "Make %@ your default mail app?"; Arc registers for mailto | 🟡 both engines: the prompt, mailto: links in pages and from other apps open the site's compose page, Site Controls row to turn it off; prompt layout and button titles unobserved; Chromium path and other-app path not run | Gap 39 |
| PWAs / installed apps | Not in Arc (no menu item; only Chromium's permission name in its binary). **Kite addition beyond Arc**, following Chrome | 🟡 The install icon (Chrome's monitor and arrow, "Install <name>") appears in the address field and toolbar for pages with an installable manifest. It opens Chrome's tab-modal flow: the intro, detailed (description and wide-screenshot carousel) or simple; then Next, the Mac options step, Install, progress, and Open tab in app / Show in Finder. File › Install Page as App… installs any page (falling back to its title and icon). The app opens in its own window, tinted with theme_color and staying within its scope (out-of-scope link clicks open in the main window). A launcher goes in ~/Applications/Kite Apps/<Name>.app and opens `kite-app://<id>`. Window › Web Apps opens or uninstalls apps, and the command bar has Open / Uninstall <app>. Apps are stored in the profile's webapps.json; parsing and scope logic are in `WebApps` | Gap 29. Not yet: real Dock tile per app (the launcher hands off to Kite), app windows restored on relaunch, live theme-color updates, permission prompts in app windows, "Open in app" for an installed site, Chromium path, Launch Services registration |
| Sad tab | Crashed-tab page: face, "Tab crashed. Maybe reload the page?", exit code bottom-right | ✅ Chromium; WebKit still reloads on its own | B5 |
| Download from links, downloads list | | 🟡 Both engines list downloads (downloads.json): progress ring on a bottom-bar button, popover with progress, open, Show in Finder, copy, hide, trash, cancel. "Downloads in progress" when quitting with downloads running (Close Kite cancels them, Keep browsing stays). No Library page or flying-icon animation yet | Thread: Library |
| Picture in Picture | Video PiP | ❌ | Thread: Mini player |
| Gestures | Two-finger swipe back/forward: Chromium's `HistorySwiper` + history overlay (dark circle with arrow sliding in from the edge), only when the page can't scroll that way | 🟡 WebKit (system gesture); Chromium: Kite's own recogniser with Chromium's overlay geometry, threshold for trackpads unverified | B5 |
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
- **B4. Windows:** ⇧⌘N incognito (done; New Space moved to the Spaces menu). ⌘N and ⌃⌘N done: each normal
  window has its own `BrowserState` copy (`WindowSelection`), kept in step by `WindowLink`. Still to do: pages
  that move between windows instead of loading twice.
- **B5. Small UX:** Show Toolbar ⇧⌘D, Stay On Top, sidebar hover reveal, auto-archive setting,
  warn before quit, Share…, Set as Default Browser, keyboard-shortcut cheat sheet, Reveal data folder,
  sad tab, swipe gestures, Save Page As, Clear Cookies/Cache and Refresh.
- **B6. Command bar and remapping:** command bar actions (every menu command searchable), history,
  site search; user-remappable shortcuts.

Bigger features, each its own thread: Split view, Peek (+ hover previews), Little Arc (+ link routing),
Mini player / PiP / media, Library (history, archive, downloads), Settings window, Boosts,
Developer Mode, Capture, Profiles, Space theme editor, Site controls. Already owned elsewhere: sandbox,
MCP/CLI and AI features, ad blocker, Arc import UI / favorites / folders / sidebar.
