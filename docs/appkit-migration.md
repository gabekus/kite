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
