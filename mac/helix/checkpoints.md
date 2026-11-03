# Kite for Mac checkpoints: SwiftUI to AppKit

Helix (docs/helix.md) applied to moving Kite for Mac's SwiftUI parts to AppKit, for lower idle CPU and wakeups
and fewer layers, with the UI unchanged. Main is the reference: each checkpoint has to look and behave as main
does, except where it says otherwise. Notes, measurements and evidence go in docs/appkit-migration.md.

Status: planned → approved → in progress → in review (#PR) → done (#PR). Each checkpoint is one PR, on its own
branch `helix/M<n>-<slug>` from main.

## Gates, in order

1. **Tests.** `swift build --build-tests` and `swift test` in a checkout with CEF, and `swift test` in one
   without it (no `ThirdParty/cef`).
2. **UI match** (skipped when nothing visible changes): main and the checkpoint loaded with the same
   `session.json`, at the same window size, captured at 2× with `kite ui capture` and diffed
   (scripts/perf/imgdiff.swift), dark and light, plain and hovered; the `kite ui tree` geometry compared, and a
   `kite ui pointer` sweep for anything hover-driven.
3. **CPU.** Idle and the checkpoint's own scenario, main against the checkpoint (scripts/perf/idle-measure.sh,
   proc_pid_rusage).
4. **Adversarial review.** Two fresh subagents, given the diff and the evidence but not the implementer's
   reasoning: A for correctness and parity with main and Arc, B for architecture and performance. Fixes loop
   until both answer APPROVE.
5. **Live verification** on a bundled test build (`scripts/bundle-app.sh debug`, a fresh `KITE_SUPPORT_PATH`).
6. **Gabe**, by merging the PR.

## Done before Helix

| PR | what moved |
|---|---|
| #262 | the sidebar's space list |
| #264 | the sidebar's header, Today divider and Instant Links rows |
| #265 | the sidebar column and space pages |
| #267 | the header row and address field |
| #268 | the favorites tray |
| #269 | the space bar |
| #271 | no SwiftUI root in the sidebar; the Mini Player and Create a Space as islands |
| #272 | the command bar |
| #275 | hidden SwiftUI hosts leave the window (page toolbar, Library, Claude bubble) |
| #277 | sidebar menus through KITE_TEST_CONTEXT_MENU; menu and drag checks |
| #280 | Escape closes the Library, as in Arc |
| #285 | Claude's page border; the sign-in pill and handoff card leave the window when empty |
| #286 | the address field's password manager key |

## Checkpoints

| id | checkpoint | moves (SwiftUI → AppKit) | status |
|---|---|---|---|
| M1 | Test-safe sign_in and password manager: on a test profile (`KITE_DIAGNOSTICS` with `KITE_SUPPORT_PATH`), sign_in doesn't bring Kite forward; the address field's key, ⇧⌘X and the sign-in pill's button don't open or add the password manager, and launch doesn't offer to add it; each logs what it would do | none (a test hook in AutomationController+SignIn.swift, ExtensionsToolbar.swift, BrowserWindowController+ExtensionTabs.swift, PasswordManagerIntegration.swift) | in progress |
| M1b | The sign-in pill's buttons take clicks: its host let every click through to the page, SwiftUI's own buttons included | none (a fix in ClaudeControlBanner.swift) | planned [after the handoff-reliability work: shares the handoff card's pass-through host] |
| M2 | Page toolbar and its extension icons: the bar, its buttons, the address, the install icon, pinned extensions and the extensions button | PageToolbar.swift, ExtensionsToolbar.swift (ExtensionsToolbarItems) | in progress |
| M3 | Site Controls popover | SiteControlsView.swift | planned |
| M4 | The extensions popover | ExtensionsToolbar.swift (ExtensionsMenu) | planned |
| M5 | Link preview card | LinkPreviewCard.swift | planned |
| M6 | Favorite preview card | FavoritePreviewCard.swift | planned |
| M7 | Library and its pages; downloads and the Library button's badge | LibraryView.swift, ArchivePageView.swift, DownloadsView.swift | planned |
| M8 | Claude's ⌘J bubble | Claude/ClaudeBubble.swift, ClaudeTaskViews.swift, ClaudeCodeBar.swift | planned |
| M9 | Banners and prompts: permission prompts, the space tip | PermissionPromptView.swift, SpaceTipWindow.swift | planned [the handoff card waits for the handoff-reliability work] |
| M10 | Internal pages hosted in the window | SiteSettingsPageView.swift, SearchEnginesPageView.swift, MediaPageView.swift, BoostsViews.swift | planned |
| M11 | Settings window | Settings/ | planned |
| M12 | Dialogs | ArcDialog.swift, QuitDialog.swift, WebAppInstallDialog.swift, UpdaterWindow.swift | planned |
