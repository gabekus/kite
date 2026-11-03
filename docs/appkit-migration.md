# Moving Kite for Mac from SwiftUI to AppKit

Goal: Kite's Mac interface in plain AppKit (still Swift), for less idle CPU, fewer wakeups and fewer
layers between Kite and the window server (see Shopify's [Back to native](https://shopify.engineering/back-to-native)).
The rule doesn't change: every view stays pixel-identical to what it replaces (AGENTS.md, "Matching Arc").

## Inventory (origin/main, 2 Nov 2026)

62 files under `Sources/` import SwiftUI, 20,299 lines in all, all in `Sources/KiteMac`. Columns count
lines that match: **Hosts** `NSHostingView`/`NSHostingController`; **Observation** `@Observable`,
`ObservableObject`, `@Published`, `@ObservedObject`, `@StateObject`, `@EnvironmentObject`, `@Bindable`;
**Anim** `withAnimation`, `.animation(`, `.transition(`, `matchedGeometryEffect`; **Timers/Timeline**
`Timer`, `TimelineView`, `.onReceive`, `asyncAfter`; **Geometry** `GeometryReader`, `PreferenceKey`,
`onGeometryChange`.

| File | Lines | Hosts | Observation | Anim | Timers/Timeline | Geometry | Main views |
|---|---:|---:|---:|---:|---:|---:|---|
| `Views/SidebarView.swift` | 2490 | 0 | 2 | 20 | 6 | 11 | SidebarView ListEdgeCompensation ChromeFill FavoriteFill TabPillFill ToolbarButton NavigationButtons DeveloperReloadOptionsButton |
| `BrowserWindowController.swift` | 1590 | 15 | 0 | 0 | 7 | 0 |  |
| `Views/FavoritePreviewCard.swift` | 711 | 2 | 5 | 0 | 7 | 2 | FavoritePreviewCardView FavoritePreviewRow |
| `Settings/SettingsPanes.swift` | 681 | 0 | 6 | 0 | 0 | 0 | AccountPane AutoUpdateToggle GeneralPane ProfilesPane DownloadLocationPicker ProfileList DataLink MaxPane |
| `Views/SidebarDragAndDrop.swift` | 638 | 1 | 1 | 3 | 12 | 2 | SidebarDragSource SidebarDragOverlay InsertionLine SplitDropPreview |
| `Views/LinkPreviewCard.swift` | 628 | 2 | 12 | 3 | 2 | 1 | LinkPreviewCardView LinkPreviewCardContent LinkPreviewSummaryView LinkPreviewDetailRow LinkPreviewSummaryLoadingView |
| `Views/SiteControlsView.swift` | 613 | 1 | 2 | 0 | 0 | 0 | SiteControlsView ActionButton SettingRow ControlsSectionHeader SiteBoostRow ExtensionTile AddExtensionTile SiteExtensionIcon |
| `Views/BoostsViews.swift` | 601 | 1 | 3 | 0 | 0 | 0 | BoostEditorView BoostsListView BoostRow |
| `Views/CommandBarView.swift` | 532 | 0 | 0 | 0 | 0 | 1 | CommandBarOverlay SiteSearchChip CommandBarView CommandBarPanel SuggestionRow |
| `Claude/ClaudeCodeBar.swift` | 514 | 0 | 1 | 0 | 0 | 0 | ClaudeCodeBar ClaudeCodeSessionRow ClaudeCodeFolderRow ClaudeCodeMark ClaudeCodeSwitchButton |
| `Views/ProfileDialogs.swift` | 457 | 0 | 0 | 0 | 0 | 0 | ArcSheetButton ArcSheet ProfileBadge CreateProfileView ChangeProfileView ProfilesListView RenameProfileView DeleteProfileView |
| `Views/SettingsPagesView.swift` | 443 | 0 | 0 | 2 | 0 | 0 | SettingsPageView DeleteBrowsingDataDialog |
| `Claude/ClaudeBubble.swift` | 435 | 0 | 2 | 0 | 0 | 1 | ClaudeBubble |
| `WebApps/WebAppInstallDialog.swift` | 414 | 2 | 2 | 3 | 2 | 1 | WebAppInstallDialog IconNameAndOrigin ScreenshotCarousel DialogButton WebAppInstallBanner |
| `Views/ThemeEditor.swift` | 389 | 1 | 0 | 0 | 0 | 3 | ThemeEditor ColorField DotGrid Handle IntensitySlider GrainDial |
| `Views/ZapPicker.swift` | 383 | 4 | 3 | 0 | 0 | 0 | ZapShelf ZapPanel |
| `Settings/ShortcutsPane.swift` | 354 | 0 | 2 | 0 | 0 | 0 | ShortcutsPane ArtKey ShortcutRow ShortcutRecorder |
| `Views/MediaPageView.swift` | 346 | 0 | 0 | 0 | 0 | 0 | MediaPageView WelcomeCard MediaTile MediaPreview |
| `Views/DownloadsView.swift` | 344 | 0 | 0 | 6 | 0 | 1 | LibrarySidebarButton LibraryIcon DownloadProgressBadge DownloadsList DownloadRow ProgressBar RowButton |
| `Views/SearchEnginesPageView.swift` | 343 | 0 | 0 | 0 | 0 | 0 | SearchEnginesPageView |
| `Views/ArcDialog.swift` | 342 | 1 | 2 | 0 | 0 | 0 | DialogView ArcDialogButton |
| `Views/SpaceIconPicker.swift` | 304 | 1 | 0 | 0 | 0 | 0 | SpaceIconView SpaceIconPicker |
| `Settings/SettingsPane.swift` | 300 | 0 | 2 | 0 | 0 | 0 | SettingsPaneContainer SettingsSection SettingsSeparator SettingsIcon SettingsRow SettingsSwitch CommandToggle UnsupportedToggle |
| `Views/ArchivePageView.swift` | 281 | 0 | 0 | 0 | 0 | 0 | ArchivePageView ArchiveRow |
| `Views/ExtensionsToolbar.swift` | 276 | 1 | 3 | 0 | 0 | 0 | ExtensionsToolbarItems PinnedExtensionButton ExtensionsMenu ExtensionTile ExtensionActions ExtensionIcon PasswordManagerFieldButton |
| `Automation/ClaudeHandoffCard.swift` | 275 | 1 | 0 | 4 | 1 | 1 | ClaudeHandoffCard HandoffStepCard HandoffPill HandoffHostingView |
| `Views/BoostStyleControls.swift` | 269 | 0 | 0 | 0 | 0 | 1 | BoostStyleControls BoostColorWheelView |
| `AirTrafficControlWindow.swift` | 259 | 1 | 3 | 0 | 0 | 0 | AirTrafficControlView RuleCard DestinationPicker |
| `RecentTabSwitcherController.swift` | 258 | 2 | 5 | 0 | 7 | 0 |  |
| `Views/MiniPlayerView.swift` | 257 | 0 | 0 | 5 | 0 | 1 | MiniPlayerView MiniPlayerButton |
| `BrowserWindowController+DownloadFlight.swift` | 231 | 1 | 0 | 0 | 1 | 0 | DownloadBinTile |
| `Claude/ClaudeSidebarButton.swift` | 229 | 0 | 1 | 0 | 0 | 1 | ClaudeSidebarButton |
| `Automation/ClaudeControlBanner.swift` | 223 | 1 | 1 | 1 | 0 | 2 | ClaudeControlBanner ClaudeControlBorder ClaudeBannerStrip BannerHostingView |
| `Views/EssentialShortcutsWindow.swift` | 218 | 1 | 0 | 0 | 0 | 0 | EssentialShortcutsView Keycaps Keycap |
| `SpaceSwipeController.swift` | 211 | 0 | 0 | 0 | 0 | 0 |  |
| `Engine/ExtensionsModel.swift` | 208 | 0 | 7 | 0 | 1 | 0 | ExtensionsSelectionView |
| `Views/SpaceCreationView.swift` | 203 | 0 | 0 | 0 | 0 | 0 | SpaceCreationView Illustration ProfilePill ChooseThemeRow AnchoredButton |
| `Views/UpdaterWindow.swift` | 200 | 1 | 3 | 0 | 0 | 0 | UpdaterView |
| `Views/HistoryPageView.swift` | 191 | 0 | 0 | 0 | 0 | 0 | HistoryPageView HistoryRow |
| `Views/LibraryView.swift` | 176 | 0 | 1 | 0 | 0 | 0 | LibraryView PageRow |
| `Views/LinkPreviewShare.swift` | 163 | 0 | 1 | 1 | 0 | 0 | LinkPreviewShareButton LinkPreviewShareSnapshot |
| `Views/PageToolbar.swift` | 161 | 0 | 0 | 0 | 0 | 0 | PageToolbar |
| `Claude/ClaudeTaskViews.swift` | 146 | 0 | 0 | 0 | 0 | 0 | ClaudeTaskEntryView ClaudeMarkdown |
| `Views/RecentTabSwitcherView.swift` | 139 | 0 | 1 | 2 | 0 | 1 | RecentTabSwitcherView |
| `Views/QuitDialog.swift` | 134 | 1 | 0 | 0 | 0 | 0 | QuitDialogView |
| `Views/PermissionPromptView.swift` | 133 | 2 | 0 | 0 | 0 | 0 | PermissionPromptView |
| `Engine/MailHandlers.swift` | 131 | 1 | 0 | 0 | 0 | 0 | MailHandlerPrompt |
| `Views/SiteSettingsPageView.swift` | 128 | 0 | 0 | 0 | 0 | 0 | SiteSettingsPageView |
| `Views/InstantLinksRow.swift` | 125 | 0 | 0 | 0 | 1 | 0 | InstantLinksRow SpinningMaxFlower MaxFlower |
| `Views/LiveFolderViews.swift` | 121 | 0 | 0 | 0 | 0 | 0 | LiveFoldersSpaceMenu LiveFolderMenu LiveUnreadDot LiveFolderIntro |
| `Views/FaviconView.swift` | 121 | 0 | 0 | 0 | 0 | 0 | FaviconView |
| `Settings/SettingsWindowController.swift` | 119 | 1 | 0 | 0 | 0 | 0 |  |
| `ExtensionsMenuBar.swift` | 111 | 1 | 0 | 0 | 0 | 0 |  |
| `BrowserWindowController+Profiles.swift` | 108 | 1 | 0 | 0 | 0 | 0 | SetProfileMenu |
| `Views/MarqueeText.swift` | 99 | 0 | 0 | 1 | 1 | 4 | MarqueeText |
| `BrowserWindowController+ToolbarMenu.swift` | 98 | 1 | 0 | 0 | 0 | 0 |  |
| `Views/NewItemMenu.swift` | 92 | 1 | 0 | 0 | 0 | 0 | NewItemMenu MenuRow |
| `Views/SpacePages.swift` | 91 | 1 | 1 | 0 | 0 | 1 | SpacePages PageSlide |
| `Views/TabSpeakerIcon.swift` | 89 | 0 | 0 | 4 | 0 | 0 | TabSpeakerIcon |
| `Views/SadTabView.swift` | 86 | 0 | 0 | 0 | 0 | 0 | SadTabView |
| `Views/SpaceTipWindow.swift` | 58 | 1 | 0 | 0 | 0 | 0 |  |
| `Views/AnchorView.swift` | 29 | 0 | 0 | 0 | 0 | 0 |  |

How it's hosted today:

- **Sidebar**: one `SidebarHostingView` (`NSHostingView<SidebarView>`, `SpacePages.swift`) for the whole
  column: header, address field, favorites, space pages, Mini Player and the space bar. Each space page was a
  SwiftUI `List`, which AppKit runs as an `NSTableView` with a `CellHostingView` per row; Kite already patches
  that table by swizzling (`SidebarRowsAnimator`) to get Arc's row animations.
- **Window chrome**: `BrowserWindowController` hosts the command bar (`CommandBarOverlay`), Claude bubble,
  Library, sad tab and the internal pages (History, Archive, Settings, Site Settings, Search Engines) in
  `NSHostingView`s; `PageToolbarHost` hosts `PageToolbar`.
- **Popovers and panels**: Site Controls, Extensions, New Item menu, Space Icon Picker, Theme Editor, Boosts,
  Zap, link and favorite preview cards, the space tip, permission prompts and dialogs (`ArcDialog`,
  `QuitDialog`, profile sheets, web app install) each host one SwiftUI root.
- **Settings window**: `SettingsWindowController` hosts a pane per tab.

State: the big models (`BrowserStore`, `HistoryStore`, `DownloadsModel`, `LibraryModel`, `AutomationController`,
Claude's controllers) are `@Observable`, which AppKit reads with `withObservationTracking` as easily as SwiftUI
does, so the models stay as they are. A few panels still use `ObservableObject` (`SettingsModel`,
`ExtensionsModel`, `UpdaterModel`, `ZapShelfModel`, link and favorite preview models).

Per-frame work in SwiftUI today (main thread, while shown):

- `ClaudeControlRing`: a 30 fps `TimelineView` per tab row Claude is driving (each tab `kite open` opens is
  driven for 15 s after the last call).
- `ClaudeWorkingMark`: a 30 fps `TimelineView` per Claude folder while Claude works in it.
- `AIRenameTitle`/`AIRenameSparks` (1.5 s per rename), `InstantLinksRow`'s flower, `MarqueeText` (Mini Player
  title while it overflows), Tidy's wand and the downloads badge (`repeatForever`).

## Order of work

1. **Sidebar space list** (this PR): the `List` becomes an AppKit `NSTableView` (`SidebarList.swift`,
   `SidebarListCells.swift`, `SidebarKit.swift`) inside the still-SwiftUI column. Tab, folder, split and New
   Tab rows are AppKit; drag and drop keeps `SidebarDragModel` but lists hand it their rows when a drag needs
   them instead of reporting every row's frame on every scroll step. Claude's ring and mark animate on the
   render server (Core Animation), not a main-thread timeline. The space header, Today divider and Instant
   Links row are still SwiftUI, hosted in their rows; so are the speaker and the Tidy Tab Titles rename,
   hosted only while they play.
2. **Sidebar column**: header buttons, address field, favorites tray, space bar (with icon reorder and the
   space tip), Mini Player, space pages and swipe; then the drag overlay, header, divider and Instant Links
   rows. After this `SidebarHostingView`, `SidebarRowsAnimator`'s swizzling and `SidebarDragSource` go.
3. **Command bar** (`CommandBarView.swift`, 532 lines) and the page toolbar.
4. **Popovers and cards** in the window: Site Controls, Extensions, link and favorite previews, Library and
   downloads, Claude bubble, banners and handoff cards, Mini Player.
5. **Internal pages** (History, Archive, Settings pages, Search Engines, Media) and the **Settings window**.
6. **Dialogs and sheets** (`ArcDialog`, profiles, quit, web app install, updater, essential shortcuts).

## Measuring

All numbers come from release builds bundled with the test bundle ID
(`KITE_BUNDLE_ID=dev.gabek.Kite.dev scripts/bundle-app.sh release`), launched on a fresh
`KITE_SUPPORT_PATH` with `KITE_TEST_BLOCK_VIEWS_WINDOWS=1`, `TYPESAFE_API_KEY=x`, `KITE_DIAGNOSTICS=1` and
`--disable-backgrounding-occluded-windows`, never /Applications/Kite.app.

- `scripts/perf/idle-measure.sh APP LABEL SECONDS`: opens ten static pages from a local server
  (`python3 -m http.server 18765` over `p1.html`…`p10.html`), closes the fresh profile's own tab, waits 30 s,
  then samples the main Kite process (not renderers or helpers) with `proc_pid_rusage`
  (`scripts/perf/rusage.c`): CPU milliseconds per second, interrupt wakeups per second, billed energy and
  the footprint. `top`'s IDLEW column turned out to be a running total (it showed a fixed 799 for a live
  Kite), and `powermetrics` needs a password, so neither is used. `HOVER=1` first sweeps the pointer over
  the sidebar and scrolls it; `SETTLE=1 … 10` samples while Claude's rings still show (every tab `kite open`
  opens is driven by Claude for 15 s after the last call).
- `scripts/perf/sidebar-capture.sh APP OUT`: the same pages (or `STATE=session.json`), then `ui capture` of
  the sidebar idle and hovered at fixed points, `ui tree`, and two `ui pointer` sweeps.
- `scripts/perf/imgdiff.swift` (max and mean channel delta, differing pixels, optional region) and
  `scripts/perf/treediff.py` (title, favicon and pill geometry) compare the two.

The Mac was shared with other work while measuring (other Kites running, memory under pressure), so single
runs vary; each figure below is the median of three.

## PR 1: the space list

### Idle cost (main process, medians of three)

| Scenario | CPU ms/s before | after | Wakeups/s before | after | Billed energy nJ/s before | after | Footprint MB before | after |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Idle, 10 tabs, 60 s after 30 s settle | 2.65 | 2.23 | 4.40 | 4.40 | 15,722 | 18,182 | 186.3 | 190.4 |
| After a hover sweep and a scroll | 2.40 | 1.93 | 4.32 | 4.17 | 13,472 | 5,796 | 185.8 | 185.4 |
| While Claude's rings show (10 s) | 126.85 | 15.14 | 145.6 | 29.2 | 1,911,513 | 26,885 | 190.3 | 192.0 |

All runs: base `base-idle 1.41 / 2.65 / 2.75`, `base-hover 2.85 / 1.25 / 2.40`, `base-rings 131.87 / 126.85 /
122.98` ms/s; after `after-idle 9.35 / 2.22 / 2.23`, `after-hover 1.93 / 1.87 / 2.09`, `after-rings 15.14 /
13.72 / 15.69` ms/s.

Truly idle, SwiftUI already did no work: the main process sleeps either way, and the differences are inside
run-to-run noise. The win is where SwiftUI ran per frame: ten rows with Claude's breathing ring cost the main
thread 127 ms of every second and 146 wakeups a second; the same rings as Core Animation cost 15 ms and 29
(the rest is the pages loading and Claude's control banner, which are not part of this change).

### Pixels (`ui capture` of the sidebar, 2x, before vs after)

The list's region (everything under the favorites, y ≥ 155 pt). Ten plain tabs on the default dark theme,
and a session with a pinned tab, an open folder with two tabs, a closed folder, a split and three Today
tabs, on a dark and a light theme. Hovered states are captured with `ui pointer` resting on each row.

| Capture | max delta (0–255) | mean delta | differing pixels |
|---|---:|---:|---:|
| 10 tabs dark: idle, hover tab, hover selected tab, hover New Tab, hover header | 27 | 0.049 | ~8,500 of 818,400 |
| rich dark: idle, hover pinned, folder child, tab, selected, split (both panes), New Tab, header | 39–40 | 0.040–0.050 | ~7,400 |
| rich dark: hover folder (chevron shown) | 86 | 0.044 | 7,422 |
| rich light: idle and the same hovers | 41–43 | 0.041–0.053 | ~6,500 |
| rich light: hover folder | 75 | 0.044 | 6,498 |

Every differing pixel is on the anti-aliased edges of an SF Symbol (the globe favicon, the New Tab plus, the
folder icon and chevron, the close button): AppKit draws symbols through NSImage, SwiftUI through its own
glyph renderer. Symbol placement was matched to SwiftUI's by measuring it (ImageRenderer against candidate
placements: across, the alignment rect centred and rounded up to the half point; down, centred on its
baseline; resizable symbols stretch their ink bounds). Even the best offset found by exhaustive search leaves
max deltas of 40–80 on glyph edges, so that is the floor for AppKit-drawn symbols. Text, pills, fills and
colours are identical (delta 0).

Tree geometry (`treediff.py`): every title's text box has the same origin and height (widths differ by at
most 0.5 pt, SwiftUI's fractional text width against AppKit's rounded one); favicons and the selected pill
have identical frames.

Pointer sweeps (`ui pointer` across and down the sidebar): the cursor is the arrow everywhere in both, and
each row's hover area is its 36 pt pill in both. The gaps between pills belong to the row (no window move),
as they did to the SwiftUI cell.

### Behaviour checked on the AppKit build

With `ui input` (rows taking the first click for the test only, as the main build's rows don't take a
background click either): a click selects a tab; the hover close button closes it; a click collapses and
re-expands a folder; a drag from a Today tab onto New Tab moves it to the top of Today; a double-click
renames in place (typed name, Return). The no-CEF build and `swift test` pass (900 tests).

### Not verified yet

- Context menus (they open a modal menu loop; built from the same items, in the same order, as the SwiftUI
  menus they replace).
- The spring-loaded folder open, the split offer and edge-of-list space switching during a drag (same
  `SidebarDragModel` code, now fed by the list).
- Animations frame by frame: rows fading in and out (same curve and duration as before), the speaker and
  Tidy Tab Titles rename (still SwiftUI, hosted), Claude's ring and mark (period and opacity range kept).
- VoiceOver: roles and labels are set, but the accessibility tree differs from SwiftUI's in shape.

## PR 2: header, Today divider and Instant Links rows

The last SwiftUI rows in the space list (`SidebarListRows.swift`). The list is now AppKit throughout;
`SpaceHeader`, `TodayDivider`, `InstantLinksRow` and its timeline-driven flower are gone.

| Scenario | CPU ms/s after PR 1 → PR 2 | Wakeups/s | Footprint MB |
|---|---|---|---|
| Idle | 2.23 → 2.66 | 4.40 → 4.17 | 190.4 → 179.2 |
| After hover + scroll | 1.93 → 2.48 | 4.17 → 4.33 | 185.4 → 178.0 |
| Claude's rings | 15.14 → 15.04 | 29.2 → 29.3 | 192.0 → 189.1 |

Flat within noise, as expected: these rows only animate while Claude tidies (the wand) or Instant Links loads
(the flower, now Core Animation instead of a per-frame timeline).

Pixels against main before PR 1 (list region): 10 dark tabs idle and hovered (header, tab) max 57, mean 0.06;
hovered divider (Tidy and Clear showing) max 14 in the divider; rich dark/light idle and hovered header,
chevron and divider max 57–85, mean ≤ 0.07. The emoji is drawn at its string size centred exactly, which is
where SwiftUI's `Text` puts it (ImageRenderer: 15pt in 26pt lands at (2.5, 3.5)); the rest is glyph
anti-aliasing. The Tidy pill is a capsule (SwiftUI clamps ChromeFill's 11pt corners to half its 18pt height).
"Clear" sits half a point above plain centring, measured. Un-framed symbols (wand, arrow, folder chevron)
draw at the image's own placement. The Max flower, drawn with the same geometry in Core Graphics, matches
SwiftUI's Canvas to max 36 at 2x (ImageRenderer).

Behaviour on the AppKit build (`ui input`, rows taking the first click for the test only): the chevron
collapses and expands the pinned section; a click on the selected space's name renames it in place (typed
name, Return); Clear (in its keep-the-selected-tab mode) clears the other Today tabs.

Not verified: the icon picker opening from the header (a popover), the space menu (a modal menu), Tidy's
turning wand and Clear's pressed arrow frame by frame, the arrow (clear-all) mode of Clear pixel-wise, and the
Instant Links row in place (it needs Instant Links running).

## PR 3: the column and space pages

`SidebarColumnView` (AppKit) is the sidebar now: the space pages are an AppKit strip (`SidebarPagesView`)
that a swipe or a space switch's settle moves as one view; the chrome SwiftUI still draws (header row,
address field, favorites, Mini Player, space bar) is one hosting view under them, with a placeholder where the
pages go; the drag overlay is shown only while something is dragged. `SidebarRowsAnimator` (NSTableView
swizzling for SwiftUI's List) and `BrowserStore`'s per-mutation row snapshot are gone.

| Scenario (median of 3) | CPU ms/s main before #262 → PR 3 | Wakeups/s | Footprint MB |
|---|---|---|---|
| Switching spaces every 0.5 s (`SWITCH=1`, 20 s) | 218.24 → 181.20 | 111.4 → 94.6 | 347 → 349 |
| Idle | 2.65 → 2.76 | 4.40 → 4.33 | 186 → 185 |
| After hover + scroll | 2.40 → 3.91 | 4.32 → 4.28 | 186 → 189 |
| Claude's rings | 126.85 → 14.95 | 145.6 → 29.3 | 190 → 191 |

(One switching run overlapped a compile; it is the slowest of the three and not the median.)

Pixels (whole sidebar, captured back to back with main from before #262): 10 dark tabs idle and hovered max 56,
mean 0.046; rich dark and light idle and hovered (header, divider, folder, split) max 56–85, mean ≤ 0.06, all
on emoji and SF Symbol edges. Captures of the same build an hour apart differ by up to 2/255 everywhere (the
window background drifts), so before/after pairs are now taken back to back. After ⌃2/⌃1 the pages land in the
same place as main's (back on the first space: max 56).

Not verified: a two-finger swipe (synthetic `ui input` scrolls don't reach the space-swipe interceptor on
either build), and the theme crossfade after a space switch on screen: in a covered test window both builds
freeze the crossfade part-way (main at a different point each run), since a covered window's display link
stops; ThemeView catches up when the window is visible.

## PR 4: header row and address field

`SidebarHeaderView` (AppKit): the sidebar toggle, back, forward, reload and the Developer Mode reload menu (or
the compact layout's More menu), and the address field with its moon, Site Controls and install icon fading in
on sidebar hover, the password manager's key (still SwiftUI, hosted) and the extensions button. The SwiftUI
column keeps placeholders where they were and no longer reads the selected tab's page status, so a page that
loads no longer re-renders the SwiftUI sidebar.

| Scenario (median of 3) | CPU ms/s main before #262 → PR 4 | Wakeups/s |
|---|---|---|
| **Reloading the front tab every 0.5 s** (`RELOAD=1`) | **120.10 → 69.05** | **65.55 → 42.30** |
| Switching spaces every 0.5 s | 218.24 → 182.06 | 111.4 → 95.95 |
| Idle | 2.65 → 1.97 | 4.40 → 4.20 |
| After hover + scroll | 2.40 → 1.96 | 4.32 → 4.25 |
| Claude's rings | 126.85 → 14.60 | 145.6 → 29.0 |

Symbols: SwiftUI's placement of SF Symbols didn't follow any one rule across the 19 measured (half-pixel rounding
goes either way per glyph), so `SymbolOrigins` records where SwiftUI draws each symbol the sidebar uses (ImageRenderer,
quarter-point search), corrected for the header's against captures of the SwiftUI sidebar on screen
(ImageRenderer put five of them half a point higher than a window does). Symbols not in the table use the rule.

Pixels (captured back to back with main before #262, header region): idle max 28, mean 0.02. `SymbolButton`'s
tracking area is now its bounds: an `.inVisibleRect` area showed the extensions button hovered with the pointer
at (700, 400) (macOS 14+ views don't clip). Disabled back/forward dim to 0.125 like SwiftUI's disabled plain
buttons.

Behaviour (both builds): a click on the field opens the command bar; the toggle hides the sidebar.

Not verified: the field buttons' own hover state against main (SwiftUI's buttons in the big hosting view
don't take `ui pointer` hover in a background window; the AppKit ones show the wash as specified: 0.1 white,
6pt corners, opacity 0.9), the developer reload and More menus (modal), the compact layout under 212pt.

## PR 5: favorites tray

`FavoritesTrayView` (AppKit): tiles 47pt high, 8pt apart, at most four a row and balanced, favorite splits as one
tile, the selected tile's white fill, favicon-colour tint and 2pt ring, the hover preview card, the context menu,
drags out of the tray (the tile stays, invisible) and into it (the open slot), and the empty state. The SwiftUI
column keeps a placeholder of the tray's height (`SidebarChromeMetrics`).

| Scenario (median) | CPU ms/s main before #262 → PR 5 | Wakeups/s |
|---|---|---|
| Idle (5 runs: 1.94, 4.92, 5.03, 1.99, 1.85) | 2.65 → 1.99 | 4.40 → 4.23 |
| After hover + scroll | 2.40 → 2.12 | 4.32 → 4.17 |
| Reloading the front tab every 0.5 s | 120.10 → 70.91 | 65.55 → 41.25 |
| Claude's rings | 126.85 → 15.17 | 145.6 → 29.1 |

Pixels (captured back to back with main before #262, the tray's region; five favorites with a coloured favicon,
one selected, dark and light): max 76 dark / 55 light, mean ≤ 0.23. Matching needed the ring as its own view
(AppKit re-orders a view's sublayers to follow its subviews, which had put a hand-added ring layer under the
fills: ring 247,211,208 instead of SwiftUI's 243,185,180) and continuous corners (a 2pt border with continuous
corners covers the band SwiftUI's 2pt stroke on the shape inset by 1 does). Empty state: title identical, dashed
outline max 8, subtitle max 65 (glyph rendering; positions identical).

Behaviour (AppKit build, tiles taking the first click for the test only): a click selects the favorite; dragging
a tile reorders the tray (order read from the saved session); dragging a Today tab onto the tray adds it.

Not verified: tile hover against main (main's tiles, in the big hosting view, take no `ui pointer` hover in a
background window), the preview card opening, the context menu, favorite splits' tiles pixel-wise, and the empty
state's dismiss button.

## PR 6: space bar

`SpaceBarView` (AppKit): the Library button (its download badge still SwiftUI, drawing nothing unless files
download), the space icons centred between the end buttons on Arc's 34pt pitch, each crossfading from grey to
colour with its share of the sidebar while the pages slide, the hover backing and Arc's tip, drag-to-reorder with
the open slot and the landing slide, tab drops onto an icon, the space menu and the + menu.

| Scenario (median of 3) | CPU ms/s main before #262 → PR 6 | Wakeups/s |
|---|---|---|
| **Switching spaces every 0.5 s** | **218.24 → 161.21** | 111.4 → 96.25 |
| Idle | 2.65 → 1.96 | 4.40 → 4.07 |
| After hover + scroll | 2.40 → 1.93 | 4.32 → 4.13 |
| Claude's rings | 126.85 → 13.71 | 145.6 → 27.3 |

A first cut relaid out the bar and reset every dot's fill on each frame of a switch (120 wakeups/s); now a frame
only changes the icons' opacities (96).

Pixels (captured back to back with main before #262, the bar's region): dark max 75, light max 93, mean ≤ 0.19:
the colour emoji at 12.5pt (AppKit and SwiftUI rasterise small colour emoji differently; positions identical) and
the greyed icon within 22 once its 45% fade moved inside the icon view (the cell's crossfade had overwritten it).
Whole sidebar max 142: list favicons' hard edges (the test server's red favicon resampled from 32px; visually
identical; high-quality redrawing made it worse).

Behaviour (AppKit build): clicking an icon switches spaces; dragging Personal past Work reorders them; dropping a
Today tab on Work's icon moves it there (rows taking the first click for the test only).

Not verified: the hover backing and tip against main (main's cells take no `ui pointer` hover in a background
window), the + menu and space menu (modal), overflowing strips (scrolling), and the download badge.

## PR 7: no SwiftUI root in the sidebar

`SidebarColumnView` lays out the whole sidebar itself: header, favorites, pages, space bar, and, while they show,
the Mini Player and Arc's Create a Space page, each still SwiftUI in a hosting view that exists only then (the
sidebar-sized hosting view with placeholders for the AppKit parts is gone). `SidebarView` is now
`SidebarConfiguration`, the plain value the window controller builds the sidebar from. The column lays out again
only when what shows changes.

| Scenario (median of 3) | CPU ms/s main before #262 → PR 7 | Wakeups/s |
|---|---|---|
| Switching spaces every 0.5 s | 218.24 → 158.57 | 111.4 → 96.30 |
| Reloading the front tab every 0.5 s | 120.10 → 67.78 | 65.55 → 41.45 |
| Idle | 2.65 → 1.95 | 4.40 → 4.20 |
| After hover + scroll | 2.40 → 1.93 | 4.32 → 4.22 |
| Claude's rings | 126.85 → 14.55 | 145.6 → 27.2 |

Pixels (captured back to back with main before #262, whole sidebar): the rich session idle max 142 (the list
favicons' resampled edges, as in PR 6), mean 0.13; Create a Space (opened with a test key binding in the profile's
keybindings.json) max 41 in the sidebar, the rest the window background's ambient ±1 drift. The page fills the room
between the top row and the space bar, as SwiftUI's did (its stack ends in a Spacer).

Not verified: the Mini Player (the test page's audio autoplay was blocked, so nothing played), and Create a Space's
controls (typing a name, the theme row, Create, Cancel).

## PR 8: command bar

`CommandBarOverlayView` / `CommandBarPanelView` (AppKit): the panel (blurred page under a dark tint, hairline
border, black outline, the wide soft shadow), the field with its magnifier or the Site Search site's icon, the
inline Site Search completion, Tab into a site's search (its brand-colour chip), Backspace out of it, the hint
and keycap, and the suggestions with the highlighted row, arrow keys, Return, ⇧Return and Escape. The SwiftUI
`CommandBarPanel` stays for ⌘J's Claude bar.

| Scenario (median of 3) | CPU ms/s main before #262 → PR 8 | Wakeups/s |
|---|---|---|
| **Opening the bar, typing "static page", closing it, every second** (`TYPE=1`) | **139.83 → 105.95** | **59.40 → 31.10** |
| Idle (6 runs: 1.87, 1.93, 2.35, 4.98, 6.75, 11.70) | 2.65 → 3.67 | 4.40 → 4.22 |

A first cut rebuilt every suggestion row on every keystroke and re-rendered its symbol images (165 ms/s, more than
SwiftUI); rows are reused now and symbol images drawn once. The idle spikes aren't the bar: a 20 s `sample` of an
idle instance has every main-thread sample in the run loop's wait; the extra time is on Chromium's threads.

Pixels (captured back to back with main before #262, dark and light): the empty bar max 27/28, mean ≤ 0.30, its
shadow equal at every sampled point once drawn by a plain layer (AppKit resets a view's own layer's shadow;
SwiftUI's shadow radius is Core Animation's `shadowRadius`). The panel sits on the half point like SwiftUI's
ZStack centres it; the magnifier rounds up to 23; NSTextField's text is 1.5pt above SwiftUI's TextField's in the
same box (measured); row contents centre on the pixel grid rounding up. A highlighted row matches to max 153 /
mean 1.6 (dark), 130 / 2.6 (light): text edges and the blurred backdrop inside the panel, which reads a flat 21
in AppKit where SwiftUI's varies 18–24 under a long list. The field with a Site Search chip: max 126.

Behaviour (both builds): a URL and Return opens it in a new tab; Escape closes the bar. Main highlights whichever
row the real pointer is over (SwiftUI's row hover follows the real pointer over the covered test window), so
initial highlights were compared one row apart.

Not verified: ⇧Return (Instant Links), clicking a suggestion, the menu-command rows, and the inline completion's
selection against main (main's code selects through `NSApp.keyWindow`, which is nil in a background window).

## Where the main thread's time goes now (after PR 8)

A 15 s `sample` of the AppKit build (PR 8) while the front tab reloads every half second: of 11,522 main-thread
samples, about 90 are the test harness's own `ui input` handling and the reloads themselves, and 27 are SwiftUI
graph updates (the hosting views that stay in the window while hidden: the page toolbar's `PageToolbar.body`, the
Library and the Claude bubble). The rest is the run loop waiting. At idle every main-thread sample is the run loop
waiting. The process's remaining CPU in these scenarios is on Chromium's threads.

So the sidebar and command bar ports took out nearly all of the main thread's UI cost in the scenarios measured
here. What's left in SwiftUI (popovers, cards, internal pages, Settings, dialogs) exists only while shown, except
those three hosts; letting them leave the window while hidden (or making them lazily) is the next cheap win
(~1.8 ms/s during page loads), and porting the rest is about fewer layers more than CPU.

## PR 9: hidden SwiftUI hosts leave the window

`DetachingContainer` takes the page toolbar's, the Library's and the ⌘J bar's place (constraints, z-order,
appearance) and holds each SwiftUI hosting view in the window only while it's shown. Hidden in the window they
kept re-rendering on store changes.

Main-thread SwiftUI frames in a 15 s `sample` while the front tab reloads every 0.5 s: 29 on main (#272) → 1.

| Scenario (median of 3) | CPU ms/s main (#272) → PR 9 | Wakeups/s |
|---|---|---|
| Reloading the front tab every 0.5 s | 57.60 → 54.31 | 34.35 → 36.30 |
| Idle (runs: main 2.20 / 2.20 / 11.60; PR 9 2.09 / 13.39 / 4.68) | 2.20 → 4.68 | 4.25 → 4.35 |

Main's own reload cost dropped since PR 8 (68 → 58 ms/s) with other work merged in between, so this compares against
main as of #272. Idle is dominated by Chromium-thread spikes on both builds (see "Where the main thread's time goes").

Geometry (`ui tree`, both builds, a session with Show Toolbar on): the toolbar host's frame is identical
([330,10 940×33]); the open Library's tree is identical. Pixels not captured: `ui capture` hung on both builds from
08:10 UTC (a pending system prompt, likely Screen Recording's re-confirmation); the hosted views themselves are
unchanged.

Not verified: the ⌘J bar opening (its host is attached the same way), and pixels (see above).

## PR 10: Claude's page border, sign-in pill and handoff card

The page border Claude draws while it drives the tab in front is one layer now (`ClaudeControlBorderView`: a 2pt
border in #D97757 at 0.85, radius 6, continuous corners, fading over 0.2 s ease-in-out like the SwiftUI
`.animation`). sign_in's pill and the handoff card stay SwiftUI, but each sits in a `DetachingContainer` that holds
its host in the window only while it shows; clicks on the container itself go through to the page.
The card waits a turn after its host attaches before it shows (`HandoffCardGate`), so it still slides in, and
its host leaves 0.4 s after it closes, so it still fades out.

Idle window (`ui tree`, a fresh profile, nothing from Claude):

| | main (dc7f03c) | PR 10 |
|---|---|---|
| Claude views in the window | `BannerHostingView<ClaudeControlBorder>` [330,10 940×800], `HandoffHostingView` [330,10 940×800], `BannerHostingView<ClaudeBannerStrip>` [0,772 1280×28] | `ClaudeControlBorderView` [330,10 940×800] opacity 0 |
| Tracking areas over the page | the handoff host's tooltip area [330,10 940×800] | none |

Main-thread SwiftUI samples in a 15 s `sample` while the front tab reloads every 0.5 s: 1 → 0 (two runs each).
SwiftUI was already cheap here after PR 9, so the gain is fewer views and layers, not CPU.

Behaviour (`ui tree` while driving Kite with `kite call` on a fresh profile):
- Claude drives the front tab: the border goes to opacity 1, frame [330,10 940×800], the same as the old host.
- handoff (a command step): the card's host attaches and shows the "Claude needs you: 1 steps" pill.
- sign_in on the front tab with a handoff waiting: the pill's host attaches, its label "Claude is waiting for you to
  sign in" is there within 1 s (3 of 3 runs, the same as main), and the handoff host leaves. One earlier run, in
  a longer script, didn't show the pill within 4 s; it didn't repeat in six more runs.
- A click on the pill's Cancel at the button's centre (`ui input`) lands on the page on both main and this
  build, so that is not a change from this PR. Not checked whether a real click does the same.

Not verified: pixels (captures still hang), the card's slide-in and fade-out (only the timing is in code), the
handoff card's Done and Skip after the move (its buttons weren't in the tree as named buttons).

## PR 11: the password manager's key in the address field

The key at the address field's right end (`PasswordManagerFieldButton`) was a SwiftUI view in an
`NSHostingView<AnyView>`. That host's mouse-moved tracking area spanned the whole window ([0,0 1280×820]:
`.inVisibleRect` on a view near the window's root), so every mouse move in the window went to SwiftUI. The key is
now a `SymbolButton` ("key.fill", 11pt semibold, 30×30, opacity 0.6 and 0.9 on hover, like the field's other
buttons). Its wash keeps SwiftUI's `Color.primary.opacity(0.1)` rather than the chrome fill: the label colour at
216/255 alpha, a tenth of it. It watches the window's `ExtensionsSelection` and its model as SwiftUI did, and
takes no width while there's no password manager to show.

Checks, main (dc7f03c) vs this PR, on fresh profiles (`ui tree`, `ui pointer`, `kite probe <pid> tree --text`):

| | main | PR 11 |
|---|---|---|
| Frame | [260,49 30×30] | [260,49 30×30] |
| Opacity, then hovered | 0.6, 0.9 | 0.6, 0.9 |
| Hover wash, dark / light | #FFFFFF@0.08 / #000000@0.08, radius 6 continuous | the same |
| Label | AXButton "Add 1Password to this profile" | the same |
| Tracking areas | moved-events area over the whole window, and a tooltip area | the button's own bounds |

Not verified: pixels (the glyph's placement: SwiftUI's ink is at [271.5,57 7.5×14]), the key opening the password
manager or adding it (a fresh profile only offers to add it, and I didn't install it).

## Helix M2: the page toolbar and its extension icons

View › Show Toolbar's bar (`PageToolbar`) was a SwiftUI view in an `NSHostingView` with the pinned extensions and the
extensions button inside it; it's a plain view now: a background layer and divider, `SymbolButton`s (back, forward,
reload, Site Controls with its ring, Split View), the address (`ToolbarAddressButton`), the install icon, and
`ToolbarExtensionItems` (pinned icons, the button and its popover). Frames follow the SwiftUI layout, SwiftUI's
rounding to the pixel grid included. The symbols' origins were measured on screen against the SwiftUI bar
(`SymbolOrigins`); the link icon is laid out by its alignment rect, as SwiftUI sizes an `Image`.

UI match (2x captures, the toolbar's own region, main 2955795 vs M2, a session with Show Toolbar on and a local page
with Back enabled):

| Region | max channel delta |
|---|---|
| background, divider, text | 0 |
| back, forward, reload (and its loading xmark) | 31, 13, 31 (9) |
| link icon, install icon (and hovered) | 29, 19 (19) |
| extensions button, a pinned extension | 42, 44 |
| Site Controls | 35 |
| Split View | 92 (294 px): stretched stroke placement; semibold here is closest to SwiftUI's stretched medium |

Geometry (`ui tree`): every frame matches main's, also with Back hidden and with the full URL shown.

CPU, main process, ms/s, two 30 s runs each (main → M2):

| Scenario | main | M2 |
|---|---|---|
| toolbar hidden (the default), idle | 4.82 / 6.48 | 4.81 / 2.02 |
| toolbar hidden, reloading every 0.5 s | 56.45 / 80.55 | 65.91 / 65.52 |
| toolbar shown, idle | 2.05 / 1.67 | 1.96 / 3.07 |
| toolbar shown, reloading every 0.5 s | 62.51 / 48.94 | 46.88 / 76.86 |

Runs of the same build vary by 30–50%, so there's no measurable change either way. A hidden bar stops following the store
(it follows it only while it's in the window); its extension items still re-check, coalesced, when extensions or
defaults change.

Behaviour, with posted events on a background test Kite (`kite ui input`):
- back, forward, the address (opens the command bar), Site Controls, the extensions button and a pinned extension
  (each opens its popover or popup) all work;
- the bar's right-click menu, and ⌃-click on any of its controls, show the bar's menu; the pinned icon's is "Unpin |
  Turn Off | --- | Remove…" (both read through `KITE_TEST_CONTEXT_MENU`); a ⌃-click doesn't press the control.

Differences from main:
- The toolbar's controls take the click that brings a background window forward, as the sidebar's do (on main, the
  SwiftUI host only did so for some of them).
- Right-clicking a pinned extension shows its own menu (Unpin, Turn Off, Options, Remove…), the one SwiftUI's
  `.contextMenu` declared; on main the bar's host took every right-click, so it showed the bar's menu instead.
  Arc's behaviour here isn't measured.
- The bar follows the store only while it's in the window: a hidden bar (the default) doesn't update with it.

Not verified: a real pointer (the headless rule); the extensions popover's own contents (still SwiftUI, unchanged).

## Helix Mc: `kite ui capture` without Screen Recording

`ui capture` takes `source`: `screen` (ScreenCaptureKit), `window-server` (`CGWindowListCreateImage` of Kite's own
window), `in-process`, or `auto` (the default). On macOS 15 the window server gives an app its own window only with
Screen Recording too: launched through LaunchServices as `dev.gabek.Kite.dev` with no grant (`open -g`), it returned
nothing. So the in-process render is what works without the permission: the window's material view, the Metal theme
rendered again off screen (`ThemeView.snapshot`), the views with those two hidden, then each visible page from
Chromium's own frame (`Page.captureScreenshot` through the page's DevTools bridge, no port), clipped to its card and
to the window's continuous 10pt corners. `auto` uses ScreenCaptureKit only when `CGPreflightScreenCaptureAccess()`
says it's granted (so it never puts a prompt up), and the output names the path that ran.

In-process against ScreenCaptureKit, the same window state, 2x (max / mean channel delta):

| State | sidebar | card | page |
|---|---|---|---|
| sidebar.json (dark) | 67 / 2.53 | 44 / 0.09 | 8 / 0.00 |
| two-spaces.json (light pink theme) | 67 / 3.44 | 67 / 0.12 | 1 / 0.00 |
| a rich dark session | 69 / 2.58 | 44 / 0.09 | 0 / 0.00 |
| a rich light session | 243 / 4.72 | 243 / 0.19 | 0 / 0.00 |
| favorites | 104 / 2.54 | 44 / 0.09 | 0 / 0.00 |
| toolbar shown | 69 / 2.62 | 81 / 0.09 | 0 / 0.00 |
| command bar open | 69 / 2.56 | 232 / 1.16 | 232 / 1.19 |

(The rich light run predates the corner mask; its max is the window's corners, as two-spaces' was before it.)
The old view render it replaces: sidebar 65 / 11.56, page 210 / 4.40 (no theme, no page).

What's left:
- Materials. The window's behind-window material blurs the desktop, which no in-process render can see: the sidebar's
  background reads 2–3 levels off (#282828 against #2B2B28). The command bar's panel blurs the page under it, drawn
  unblurred here (its 232). The output lists every material's frame so a diff can mark them material-only.
- Glyph edges: the space bar's emoji and the favorites tray's dashed border (max 58–67, a few hundred pixels).

## Checks of what PR 1–6 left unverified

**Context menus** (KITE_TEST_CONTEXT_MENU, which the sidebar's AppKit menus now go through): a right-click on each
logs the same items in the same order as the SwiftUI menus they replaced:
- Favorite: `Remove from Favorites | Edit Pinned Page ▸ [Edit… / Replace Pinned URL with Current] | Copy Link | --- | Unload Tab`
- Space header and space icon: `Change Space Icon… | Rename Space… | What's This Space For?… | Edit Theme Color… | Set Profile ▸ [Default / --- / New Profile…] | --- | New Folder | Live Folders ▸ [GitHub] | --- | Delete Space`
- Pinned tab: `Add to Favorites | Unpin Tab | Edit Pinned Page ▸ […] | Copy Link | Rename… | --- | Unload Tab`
- Folder: `Delete | --- | Copy All Links | --- | Rename…`
- Today tab: `Add to Favorites | Pin Tab | Copy Link | Rename… | --- | Close Tab`
- Split: `Separate All Tabs | Add Tab… | Convert to Vertical Split View | --- | (Tab Options) | <pane> ▸ [Separate from Split View / --- / (Mute) / Copy Link / Copy link as Markdown / --- / Archive Item] … | --- | Archive Item`
- The Today divider has none, as before.

Picking through the hook: Pin Tab on a Today tab pins it (3 → 4 pinned items); Rename… on a folder opens its field.

**Drag edge cases** (`ui input` drags with `hold`, rows taking the first click for the test only):
- The split offer: a Today tab held 0.8 s over another tab's middle and dropped makes a split (1 → 2 splits).
- Spring-loaded folders: a tab held 1.2 s over a collapsed folder opens it and drops in (closed, 1 tab → open, 2).

Still not verified: edge-of-list space switching during a drag, a real two-finger swipe, VoiceOver.
