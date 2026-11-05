# W14 Mac references: folders, renamed tabs, a drifted pinned tab, unpinning

Taken headless by `.github/workflows/mac-reference-captures.yml` (`scripts/mac-reference-captures.sh`) on gabe-mac-kite, macOS 15.7.4 (24G517), arm64.

Build: a debug test bundle (dev.gabek.Kite.dev, ad-hoc signed) from origin/main 46ed602 (`46ed602d58699ab93da6c591666ce2f5759e286b`), engine WebKit (no CEF in ThirdParty/cef, as in CI). Each state used a fresh `mktemp -d /tmp/k.XXXX` profile with its session as session.json, `defaults delete dev.gabek.Kite.dev SidebarWidth` first, `KITE_DIAGNOSTICS=1 KITE_TEST_BLOCK_VIEWS_WINDOWS=1 TYPESAFE_API_KEY=x KITE_WINDOW_SIZE=W,H` (downloads, web apps and browser data inside the profile), and Kite in the background throughout (never activated, input posted to its window only), quit afterwards.

**Capture path:** in-process, `kite ui capture '{"source":"in-process"}' -o NAME.png`, 2× (2560×1640). Screen Recording is never used on the runner, so every PNG is in-process: blurred materials are drawn unblurred, and Kite lists where they are:

> Window N captured at 2× (2560×1640 px), sRGB, by an in-process render.
> Drawn in Kite: blurred materials are their unblurred fallback (what's behind them isn't in it); the theme, the views and the pages are as on screen.
> Material (unblurred) at: [0,0 1280×820], [0,0 1280×28].
> Saved full resolution PNG to NAME.png.

| file | session | env | steps | holds | result |
|---|---|---|---|---|---|
| folders.png | `windows/helix/states/folders.json` from `origin/helix/W14-pin-rename` (dd6df99) | none | none | pinned: Example Domain, then Reading open (folder icon, semibold name) holding Example Domain and Elsewhere one level in and Old articles closed (folder.fill), then Recipes closed; the divider, New Tab, and the selected Example Domain in Today. Folders show their chevron only on hover, so none here | captured |
| renamed-tab.png | `windows/helix/states/renamed-tab.json` from `origin/helix/W14-pin-rename` (dd6df99) | none | none | pinned Team inbox (example.org renamed; its page title Example Domain doesn't show) and Example Domain; Today: Docs (example.com renamed, selected: its page loads and titles itself Example Domain, and the row still says Docs) and Elsewhere | captured |
| drifted.png | `windows/helix/states/drifted-pinned.json` from `origin/helix/W14-pin-rename` (dd6df99) | none | none | pinned: Example Domain (example.org, selected) and Elsewhere (pinned at example.com/, now on example.com/elsewhere); at rest a drifted pinned tab looks like any other (Back to Pinned URL shows only on hover); Today: Example Domain | captured |
| unpinned.png | `windows/helix/states/drifted-unpinned.json` from `origin/helix/W14-pin-rename` (dd6df99) | none | none | drifted-pinned.json after Pin Tab (⌘D) on its selected pinned tab: Elsewhere alone in pinned; Today: Example Domain (example.org, selected, now on top of Today) then Example Domain (example.net). The same session Windows makes with --run-command pinTab (kitecore tab pin writes exactly this file) | captured |
| drifted-hover.png (none) | `windows/helix/states/drifted-pinned.json` from `origin/helix/W14-pin-rename` (dd6df99) | none | none | drifted-pinned.json with the pointer resting on Elsewhere's row: the hover pill, the close button (xmark) at the pill's end and Back to Pinned URL (arrow.uturn.backward) left of it | skipped, unverified: needs the pointer resting on a TabRowCell, and kite ui input has no plain move (a click or drag start must land on SAFE_TARGETS, which has no row). Smallest Mac hook: a {"move": [x, y]} input in kite ui input (UIInputSender posting one mouseMoved to the test window, no click, no real pointer), allowed by this script; the move would be [120, 257.5] (the row's middle under the favorites' empty state) |
| tab-rename.png (none) | `windows/helix/states/renamed-tab.json` from `origin/helix/W14-pin-rename` (dd6df99) | none | none | renamed-tab.json with Docs being renamed (Rename Current Tab…, or a double-click on its row): the RenameField over the title, Docs all selected, in the field editor over textBackgroundColor, no close button | skipped, unverified: needs a double-click on a TabRowCell (count 2 is refused, and the row isn't in SAFE_TARGETS) or Rename Current Tab… from the command bar (Return can't be sent). Smallest Mac hook: KITE_TEST_RENAME=<tab or folder id>, read once the window is up, calling store.beginRenaming(tab:) or beginRenaming(folder:) for that id (no menu, no key, no pointer), classified flag-like (an id) in HOOKS |
| folder-rename.png (none) | `windows/helix/states/folders.json` from `origin/helix/W14-pin-rename` (dd6df99) | none | none | folders.json with Reading being renamed (its menu's Rename…): the RenameField in the folder's 14pt semibold, Reading all selected, no placeholder | skipped, unverified: needs the folder's context menu (FolderRowCell isn't in SAFE_TARGETS, even with KITE_TEST_CONTEXT_MENU). The same KITE_TEST_RENAME hook as tab-rename would reach it, with Reading's id A1B2C3D4-0002-4A00-8000-00000000F001 |

## Frames (`kite ui tree '{"match":"RowCell"}'`, window points)

folders (after the capture; `folders.tree.txt` has launch, before and after):

```
Window 18248, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.3.0.0.0.0.0.0.1 SpaceHeaderRowCell #header [8,157 224×39]
0.3.3.0.0.0.0.0.1.1 TabRowCell #tab [8,196 224×41]
0.3.3.0.0.0.0.0.2.1 FolderRowCell #folder [8,237 224×41]
0.3.3.0.0.0.0.0.3.1 TabRowCell #tab [8,278 224×41]
0.3.3.0.0.0.0.0.4.1 TabRowCell #tab [8,319 224×41]
0.3.3.0.0.0.0.0.5.1 FolderRowCell #folder [8,360 224×41]
0.3.3.0.0.0.0.0.6.1 FolderRowCell #folder [8,401 224×41]
0.3.3.0.0.0.0.0.7.1 TodayDividerRowCell #divider [8,442 224×25]
0.3.3.0.0.0.0.0.8.1 NewTabRowCell #newTab [8,467 224×41]
0.3.3.0.0.0.0.0.9.1 TabRowCell #tab [8,508 224×41]
</untrusted-page-content>
```

renamed-tab (after the capture; `renamed-tab.tree.txt` has launch, before and after):

```
Window 18249, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.3.0.0.0.0.0.0.1 SpaceHeaderRowCell #header [8,157 224×39]
0.3.3.0.0.0.0.0.1.1 TabRowCell #tab [8,196 224×41]
0.3.3.0.0.0.0.0.2.1 TabRowCell #tab [8,237 224×41]
0.3.3.0.0.0.0.0.3.1 TodayDividerRowCell #divider [8,278 224×25]
0.3.3.0.0.0.0.0.4.1 NewTabRowCell #newTab [8,303 224×41]
0.3.3.0.0.0.0.0.5.1 TabRowCell #tab [8,344 224×41]
0.3.3.0.0.0.0.0.6.1 TabRowCell #tab [8,385 224×41]
</untrusted-page-content>
```

drifted (after the capture; `drifted.tree.txt` has launch, before and after):

```
Window 18250, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.3.0.0.0.0.0.0.1 SpaceHeaderRowCell #header [8,157 224×39]
0.3.3.0.0.0.0.0.1.1 TabRowCell #tab [8,196 224×41]
0.3.3.0.0.0.0.0.2.1 TabRowCell #tab [8,237 224×41]
0.3.3.0.0.0.0.0.3.1 TodayDividerRowCell #divider [8,278 224×25]
0.3.3.0.0.0.0.0.4.1 NewTabRowCell #newTab [8,303 224×41]
0.3.3.0.0.0.0.0.5.1 TabRowCell #tab [8,344 224×41]
</untrusted-page-content>
```

unpinned (after the capture; `unpinned.tree.txt` has launch, before and after):

```
Window 18251, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.3.0.0.0.0.0.0.1 SpaceHeaderRowCell #header [8,157 224×39]
0.3.3.0.0.0.0.0.1.1 TabRowCell #tab [8,196 224×41]
0.3.3.0.0.0.0.0.2.1 TodayDividerRowCell #divider [8,237 224×25]
0.3.3.0.0.0.0.0.3.1 NewTabRowCell #newTab [8,262 224×41]
0.3.3.0.0.0.0.0.4.1 TabRowCell #tab [8,303 224×41]
0.3.3.0.0.0.0.0.5.1 TabRowCell #tab [8,344 224×41]
</untrusted-page-content>
```

## Not verified headless

- drifted-hover: unverified: needs a real screen. needs the pointer resting on a TabRowCell, and kite ui input has no plain move (a click or drag start must land on SAFE_TARGETS, which has no row). Smallest Mac hook: a {"move": [x, y]} input in kite ui input (UIInputSender posting one mouseMoved to the test window, no click, no real pointer), allowed by this script; the move would be [120, 257.5] (the row's middle under the favorites' empty state)
- tab-rename: unverified: needs a real screen. needs a double-click on a TabRowCell (count 2 is refused, and the row isn't in SAFE_TARGETS) or Rename Current Tab… from the command bar (Return can't be sent). Smallest Mac hook: KITE_TEST_RENAME=<tab or folder id>, read once the window is up, calling store.beginRenaming(tab:) or beginRenaming(folder:) for that id (no menu, no key, no pointer), classified flag-like (an id) in HOOKS
- folder-rename: unverified: needs a real screen. needs the folder's context menu (FolderRowCell isn't in SAFE_TARGETS, even with KITE_TEST_CONTEXT_MENU). The same KITE_TEST_RENAME hook as tab-rename would reach it, with Reading's id A1B2C3D4-0002-4A00-8000-00000000F001

Each state's `kite ui` step output is in `NAME.steps.txt`. Kite's logs, full trees and the build log are in the workflow run's logs artifact (kept 7 days), not on this branch.
