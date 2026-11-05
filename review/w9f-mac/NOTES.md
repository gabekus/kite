# W9f Mac references: the space bar's + menu and Create a Space

Taken headless by `.github/workflows/mac-reference-captures.yml` (`scripts/mac-reference-captures.sh`) on gabe-mac-kite, macOS 15.7.4 (24G517), arm64.

Build: a debug test bundle (dev.gabek.Kite.dev, ad-hoc signed) from origin/main 577062a (`577062ae63ea3e417804fead912021886ab3a359`), engine WebKit (no CEF in ThirdParty/cef, as in CI). Each state used a fresh `mktemp -d /tmp/k.XXXX` profile with its session as session.json, `defaults delete dev.gabek.Kite.dev SidebarWidth` first, `KITE_DIAGNOSTICS=1 KITE_TEST_BLOCK_VIEWS_WINDOWS=1 TYPESAFE_API_KEY=x KITE_WINDOW_SIZE=W,H` (downloads, web apps and browser data inside the profile), and Kite in the background throughout (never activated, input posted to its window only), quit afterwards.

**Capture path:** in-process, `kite ui capture '{"source":"in-process"}' -o NAME.png`, 2× (2560×1640). Screen Recording is never used on the runner, so every PNG is in-process: blurred materials are drawn unblurred, and Kite lists where they are:

> Window N captured at 2× (2560×1640 px), sRGB, by an in-process render.
> Drawn in Kite: blurred materials are their unblurred fallback (what's behind them isn't in it); the theme, the views and the pages are as on screen.
> Material (unblurred) at: [0,0 1280×820], [0,0 1280×28].
> Saved full resolution PNG to NAME.png.
> A popover is drawn over the window from its views (382×534 pt).

**Coordinates: CHECK.** The tree at launch didn't show frames the request's points assume: create-empty: [68,778 36×34], [102,778 36×34], [136,778 36×34]; create-named: [68,778 36×34], [102,778 36×34], [136,778 36×34]; create-filled: [68,778 36×34], [102,778 36×34], [136,778 36×34]. Those states ran at the request's points anyway; read their `.tree.txt` and rerun with the tree's.

| file | session | env | steps | holds | result |
|---|---|---|---|---|---|
| rest.png | `windows/helix/states/three-spaces.json` from `origin/main` (577062a) | none | none | the three spaces at rest, Personal selected, the bar's Library and + buttons at its ends (where the + menu opens from) | captured |
| plus-menu.png (none) | `windows/helix/states/three-spaces.json` from `origin/main` (577062a) | none | none | the + menu's popover over the + button: New Space, New Folder, a line, New Split ⌘L, New Tab ⌘T (222pt wide, 40pt rows) | skipped, unverified: needs a hook: KITE_TEST_NEW_ITEM_MENU=1 (proposed, not added). On a test-safe run only, once the main window is up, it would run NewItemMenu.present from the bar's + button with nothing activated, log "KITE_TEST_NEW_ITEM_MENU: New Space \| New Folder \| --- \| New Split ⌘L \| New Tab ⌘T" and its popover's frame, and run no item; the capture would also need the popover's window drawn (kite ui capture draws the main window in-process, and NSPopover is a window of its own). Widening SAFE_TARGETS to SymbolButton instead isn't safe: the sidebar header's Developer and More buttons are SymbolButtons whose menus pop up without the hook. |
| create-empty.png | `windows/helix/states/three-spaces.json` from `origin/main` (577062a) | `KITE_TEST_NEW_SPACE=1` | none | Create a Space in the sidebar of the new draft space right after Personal: the cards, the title and its line, Space name… and What's it for? (for Claude) empty, Profile Default, Choose a Theme, Create Space at half strength and Cancel; the bar with only its four cells (Library and + hidden) | captured |
| create-named.png | `windows/helix/states/three-spaces.json` from `origin/main` (577062a) | `KITE_TEST_NEW_SPACE=1`, `KITE_TEST_NEW_SPACE_NAME=Reading list` | none | the same page with Reading list in the name field (set, not typed: no caret blink or input method), Create Space on, What's it for? empty | captured |
| create-filled.png | `windows/helix/states/three-spaces.json` from `origin/main` (577062a) | `KITE_TEST_NEW_SPACE=1`, `KITE_TEST_NEW_SPACE_NAME=Reading list`, `KITE_TEST_NEW_SPACE_THEME=4` | none | the same page with Reading list in the name field and the theme editor's fourth preset picked (the backdrop in its colours), the theme editor's popover open from Choose a Theme pointing at the row. What's it for? stays empty (the Windows capture has Books and long reads there; compare that field's box only) | captured |

## Logged by the test hooks

create-empty:

```
KITE_TEST_SIDEBAR: armed: Create a Space
KITE_TEST_SIDEBAR: ready: app active no; no popover; Create a Space
```

create-named:

```
KITE_TEST_SIDEBAR: armed: Create a Space, name "Reading list"
KITE_TEST_SIDEBAR: ready: app active no; no popover; Create a Space, name "Reading list"
```

create-filled:

```
KITE_TEST_SIDEBAR: armed: Create a Space, name "Reading list", preset 4, theme editor open
KITE_TEST_SIDEBAR: ready: app active no; popover key no, level 0, parent the main window; Create a Space, name "Reading list", preset 4, theme editor open
```

## Frames (`kite ui tree '{"match":"SpaceCellView"}'`, window points)

rest (after the capture; `rest.tree.txt` has launch, before and after):

```
Window 20198, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.2.2.0.0.0 SpaceCellView [68,778 36×34]
0.3.2.2.0.0.1 SpaceCellView [102,778 36×34]
0.3.2.2.0.0.2 SpaceCellView [136,778 36×34]
0.3.2.3 SpaceCellView [0,770 0×0] hidden=true
</untrusted-page-content>
```

create-empty (after the capture; `create-empty.tree.txt` has launch, before and after):

```
Window 20200, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.2.2.0.0.0 SpaceCellView [51,778 36×34]
0.3.2.2.0.0.1 SpaceCellView [119,778 36×34]
0.3.2.2.0.0.2 SpaceCellView [153,778 36×34]
0.3.2.2.0.0.3 SpaceCellView [85,778 36×34]
0.3.2.3 SpaceCellView [0,770 0×0] hidden=true
</untrusted-page-content>
```

create-named (after the capture; `create-named.tree.txt` has launch, before and after):

```
Window 20202, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.2.2.0.0.0 SpaceCellView [51,778 36×34]
0.3.2.2.0.0.1 SpaceCellView [119,778 36×34]
0.3.2.2.0.0.2 SpaceCellView [153,778 36×34]
0.3.2.2.0.0.3 SpaceCellView [85,778 36×34]
0.3.2.3 SpaceCellView [0,770 0×0] hidden=true
</untrusted-page-content>
```

create-filled (after the capture; `create-filled.tree.txt` has launch, before and after):

```
Window 20204, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.2.2.0.0.0 SpaceCellView [51,778 36×34]
0.3.2.2.0.0.1 SpaceCellView [119,778 36×34]
0.3.2.2.0.0.2 SpaceCellView [153,778 36×34]
0.3.2.2.0.0.3 SpaceCellView [85,778 36×34]
0.3.2.3 SpaceCellView [0,770 0×0] hidden=true
</untrusted-page-content>
```

## Not verified headless

- plus-menu: unverified: needs a real screen. needs a hook: KITE_TEST_NEW_ITEM_MENU=1 (proposed, not added). On a test-safe run only, once the main window is up, it would run NewItemMenu.present from the bar's + button with nothing activated, log "KITE_TEST_NEW_ITEM_MENU: New Space | New Folder | --- | New Split ⌘L | New Tab ⌘T" and its popover's frame, and run no item; the capture would also need the popover's window drawn (kite ui capture draws the main window in-process, and NSPopover is a window of its own). Widening SAFE_TARGETS to SymbolButton instead isn't safe: the sidebar header's Developer and More buttons are SymbolButtons whose menus pop up without the hook.

Each state's `kite ui` step output is in `NAME.steps.txt`. Kite's logs, full trees and the build log are in the workflow run's logs artifact (kept 7 days), not on this branch.
