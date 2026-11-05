# W17 Mac references: the sidebar's row menus (tab, pinned tab, folder, favorite)

Taken headless by `.github/workflows/mac-reference-captures.yml` (`scripts/mac-reference-captures.sh`) on gabe-mac-kite, macOS 15.7.4 (24G517), arm64.

Build: a debug test bundle (dev.gabek.Kite.dev, ad-hoc signed) from origin/main 0d5d5ba (`0d5d5ba21fb37629f4f2372311cbdfe4eeec6dcc`), engine WebKit (no CEF in ThirdParty/cef, as in CI). Each state used a fresh `mktemp -d /tmp/k.XXXX` profile with its session as session.json, `defaults delete dev.gabek.Kite.dev SidebarWidth` first, `KITE_DIAGNOSTICS=1 KITE_TEST_BLOCK_VIEWS_WINDOWS=1 TYPESAFE_API_KEY=x KITE_WINDOW_SIZE=W,H` (downloads, web apps and browser data inside the profile), and Kite in the background throughout (never activated, input posted to its window only), quit afterwards.

**Capture path:** in-process, `kite ui capture '{"source":"in-process"}' -o NAME.png`, 2× (2560×1640). Screen Recording is never used on the runner, so every PNG is in-process: blurred materials are drawn unblurred, and Kite lists where they are:

> Window N captured at 2× (2560×1640 px), sRGB, by an in-process render.
> Drawn in Kite: blurred materials are their unblurred fallback (what's behind them isn't in it); the theme, the views and the pages are as on screen.
> Material (unblurred) at: [0,0 1280×820], [0,0 1280×28].
> The loading glow (Metal) isn't drawn.
> Saved full resolution PNG to NAME.png.

**Coordinates:** at launch the tree showed every frame the request's points assume (tab-menu: [8,344 224×41]; pinned-menu: [8,237 224×41]; folder-menu: [8,237 224×41]; folder-menu-closed: [8,401 224×41]).

| file | session | env | steps | holds | result |
|---|---|---|---|---|---|
| tab-rest.png | `windows/helix/states/drifted-pinned.json` from `origin/main` (0d5d5ba) | none | none | drifted-pinned.json at rest: the empty favorites box, pinned Example Domain (example.org, selected) and Elsewhere (pinned at example.com/, now on /elsewhere), the divider, New Tab, then Example Domain (example.net) in Today. The tab and pinned-tab menus open over this sidebar | captured |
| tab-menu.png (none) | `windows/helix/states/drifted-pinned.json` from `origin/main` (0d5d5ba) | `KITE_TEST_CONTEXT_MENU=1` | `kite ui input '{"click":[120,364.5],"button":"right"}'`; 1 s later, the frames (no capture) | the Today tab's menu (right-click on Example Domain in Today): Add to Favorites \| Pin Tab \| Copy Link \| Copy link as Markdown \| Rename… \| --- \| Open in Split View \| Duplicate \| Move to ▸ [(🏠 Personal)] \| --- \| Close Tab \| (Archive Other Tabs) \| (Archive Tabs Below) \| (Archive Tabs Above), with the Mac's own enabled states for Open in Split View and Move to's spaces (Windows greys both out until split view and moving between spaces are ported) | logged; unverified: the menu itself (logged, not drawn). The point is the Today row's middle: its TabRowCell is [8,344 224×41] in review/w14-mac's drifted tree (157 + 187 + 20.5, under the favorites' empty state) |
| pinned-menu.png (none) | `windows/helix/states/drifted-pinned.json` from `origin/main` (0d5d5ba) | `KITE_TEST_CONTEXT_MENU=1` | `kite ui input '{"click":[120,257.5],"button":"right"}'`; 1 s later, the frames (no capture) | the drifted pinned tab's menu (right-click on Elsewhere): Add to Favorites \| Unpin Tab \| Back to Pinned URL \| Separate From Pinned Tab \| Edit Pinned Page ▸ [Edit… / Replace Pinned URL with Current] \| Copy Link \| Copy link as Markdown \| Rename… \| --- \| Open in Split View \| Duplicate \| Move to ▸ [(🏠 Personal)] \| --- \| Unload Tab | logged; unverified: the menu itself (logged, not drawn). The point is Elsewhere's middle: its TabRowCell is [8,237 224×41] in review/w14-mac's drifted tree (157 + 80 + 20.5) |
| folders-rest.png | `windows/helix/states/folders.json` from `origin/main` (0d5d5ba) | none | none | folders.json at rest: pinned Example Domain, Reading open (Example Domain, Elsewhere, Old articles closed inside), Recipes closed, the divider, New Tab, and the selected Example Domain in Today | captured |
| folder-menu.png (none) | `windows/helix/states/folders.json` from `origin/main` (0d5d5ba) | `KITE_TEST_CONTEXT_MENU=1` | `kite ui input '{"click":[120,257.5],"button":"right"}'`; 1 s later, the frames (no capture) | Reading's menu (right-click on its row): Duplicate \| --- \| Delete \| --- \| New Nested Folder… \| Turn “Reading” into Space \| Copy All Links \| Copy All Links as Markdown \| --- \| Rename…, every item enabled | logged; unverified: the menu itself (logged, not drawn). The point is Reading's middle: its FolderRowCell is [8,237 224×41] in review/w14-mac's folders tree (157 + 80 + 20.5) |
| folder-menu-closed.png (none) | `windows/helix/states/folders.json` from `origin/main` (0d5d5ba) | `KITE_TEST_CONTEXT_MENU=1` | `kite ui input '{"click":[120,421.5],"button":"right"}'`; 1 s later, the frames (no capture) | Recipes' menu, a closed folder holding a tab: Duplicate \| --- \| Delete \| --- \| New Nested Folder… \| Turn “Recipes” into Space \| Copy All Links \| Copy All Links as Markdown \| --- \| Rename… | logged; unverified: the menu itself (logged, not drawn). The point is Recipes' middle: its FolderRowCell is [8,401 224×41] in review/w14-mac's folders tree (157 + 244 + 20.5) |
| favorites-rest.png | `windows/helix/states/favorites.json` from `origin/main` (0d5d5ba) | none | none | favorites.json at rest: six favorites in two rows of three (YouTube selected), then pinned Docs, the Work stuff folder, the divider, New Tab and example.com in Today | captured |
| favorite-menu.png (none) | `windows/helix/states/favorites.json` from `origin/main` (0d5d5ba) | `KITE_TEST_CONTEXT_MENU=1` | `kite ui input '{"click":[42.5,113.5],"button":"right"}'`; 1 s later, the frames (no capture) | YouTube's menu (right-click on its pane): Remove from Favorites \| Edit Pinned Page ▸ [Edit… / Replace Pinned URL with Current] \| Copy Link \| --- \| Unload Tab | logged; unverified: the menu itself (logged, not drawn). The point is YouTube's middle: its FavoritePaneView is [8,90 69.33×47] in review/w13-mac's rest tree (8 + 69.3 / 2, 90 + 47 / 2); the RowCell tree doesn't list favorites, so no expect_frames, and the script refuses the click unless it lands on the pane |
| control-click.png (none) | `windows/helix/states/folders.json` from `origin/main` (0d5d5ba) | `KITE_TEST_CONTEXT_MENU=1` | none | a ⌃-click on Reading's row opens the same menu as the right-click (SidebarRowCell.mouseDown: '⌃-click is a right-click'), and selects or toggles nothing | skipped, unverified: needs a left click with the control modifier on a FolderRowCell: the script's rows (RIGHT_CLICK_TARGETS) take only a plain right-click, never a left or ⌃-click. The right-click states above cover the same menu(for:) path (SidebarRowCell.mouseDown sends a ⌃-click to rightMouseDown); this one stays unverified on the Mac (Windows' smoke test checks its Ctrl+click) |

## Logged by the test hooks

tab-menu:

```
KITE_TEST_CONTEXT_MENU: Add to Favorites | Pin Tab | Copy Link | Copy link as Markdown | Rename… | --- | Open in Split View | Duplicate | Move to ▸ [(🏠 Personal)] | --- | Close Tab | (Archive Other Tabs) | (Archive Tabs Below) | (Archive Tabs Above)
```

pinned-menu:

```
KITE_TEST_CONTEXT_MENU: Add to Favorites | Unpin Tab | Back to Pinned URL | Separate From Pinned Tab | Edit Pinned Page ▸ [Edit… / Replace Pinned URL with Current] | Copy Link | Copy link as Markdown | Rename… | --- | Open in Split View | Duplicate | Move to ▸ [(🏠 Personal)] | --- | Unload Tab
```

folder-menu:

```
KITE_TEST_CONTEXT_MENU: Duplicate | --- | Delete | --- | New Nested Folder… | Turn “Reading” into Space | Copy All Links | Copy All Links as Markdown | --- | Rename…
```

folder-menu-closed:

```
KITE_TEST_CONTEXT_MENU: Duplicate | --- | Delete | --- | New Nested Folder… | Turn “Recipes” into Space | Copy All Links | Copy All Links as Markdown | --- | Rename…
```

favorite-menu:

```
KITE_TEST_CONTEXT_MENU: Remove from Favorites | Edit Pinned Page ▸ [Edit… / Replace Pinned URL with Current] | Copy Link | --- | Unload Tab
```

## Frames (`kite ui tree '{"match":"RowCell"}'`, window points)

tab-rest (after the capture; `tab-rest.tree.txt` has launch, before and after):

```
Window 18925, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.3.0.0.0.0.0.0.1 SpaceHeaderRowCell #header [8,157 224×39]
0.3.3.0.0.0.0.0.1.1 TabRowCell #tab [8,196 224×41]
0.3.3.0.0.0.0.0.2.1 TabRowCell #tab [8,237 224×41]
0.3.3.0.0.0.0.0.3.1 TodayDividerRowCell #divider [8,278 224×25]
0.3.3.0.0.0.0.0.4.1 NewTabRowCell #newTab [8,303 224×41]
0.3.3.0.0.0.0.0.5.1 TabRowCell #tab [8,344 224×41]
</untrusted-page-content>
```

tab-menu (after the steps; `tab-menu.tree.txt` has launch, before and after):

```
Window 18927, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.3.0.0.0.0.0.0.1 SpaceHeaderRowCell #header [8,157 224×39]
0.3.3.0.0.0.0.0.1.1 TabRowCell #tab [8,196 224×41]
0.3.3.0.0.0.0.0.2.1 TabRowCell #tab [8,237 224×41]
0.3.3.0.0.0.0.0.3.1 TodayDividerRowCell #divider [8,278 224×25]
0.3.3.0.0.0.0.0.4.1 NewTabRowCell #newTab [8,303 224×41]
0.3.3.0.0.0.0.0.5.1 TabRowCell #tab [8,344 224×41]
</untrusted-page-content>
```

pinned-menu (after the steps; `pinned-menu.tree.txt` has launch, before and after):

```
Window 18929, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.3.0.0.0.0.0.0.1 SpaceHeaderRowCell #header [8,157 224×39]
0.3.3.0.0.0.0.0.1.1 TabRowCell #tab [8,196 224×41]
0.3.3.0.0.0.0.0.2.1 TabRowCell #tab [8,237 224×41]
0.3.3.0.0.0.0.0.3.1 TodayDividerRowCell #divider [8,278 224×25]
0.3.3.0.0.0.0.0.4.1 NewTabRowCell #newTab [8,303 224×41]
0.3.3.0.0.0.0.0.5.1 TabRowCell #tab [8,344 224×41]
</untrusted-page-content>
```

folders-rest (after the capture; `folders-rest.tree.txt` has launch, before and after):

```
Window 18931, 1280×820 pt at 2×. Points from the window's top-left.
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

folder-menu (after the steps; `folder-menu.tree.txt` has launch, before and after):

```
Window 18933, 1280×820 pt at 2×. Points from the window's top-left.
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

folder-menu-closed (after the steps; `folder-menu-closed.tree.txt` has launch, before and after):

```
Window 18935, 1280×820 pt at 2×. Points from the window's top-left.
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

favorites-rest (after the capture; `favorites-rest.tree.txt` has launch, before and after):

```
Window 18937, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.3.0.0.0.0.0.0.1 SpaceHeaderRowCell #header [8,200 224×39]
0.3.3.0.0.0.0.0.1.1 TabRowCell #tab [8,239 224×41]
0.3.3.0.0.0.0.0.2.1 FolderRowCell #folder [8,280 224×41]
0.3.3.0.0.0.0.0.3.1 TodayDividerRowCell #divider [8,321 224×25]
0.3.3.0.0.0.0.0.4.1 NewTabRowCell #newTab [8,346 224×41]
0.3.3.0.0.0.0.0.5.1 TabRowCell #tab [8,387 224×41]
0.3.3.0.1.0.0.0.0.1 SpaceHeaderRowCell #header [248,200 224×39]
0.3.3.0.1.0.0.0.1.1 TabRowCell #tab [248,239 224×41]
0.3.3.0.1.0.0.0.2.1 TodayDividerRowCell #divider [248,280 224×25]
0.3.3.0.1.0.0.0.3.1 NewTabRowCell #newTab [248,305 224×41]
</untrusted-page-content>
```

favorite-menu (after the steps; `favorite-menu.tree.txt` has launch, before and after):

```
Window 18939, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.3.0.0.0.0.0.0.1 SpaceHeaderRowCell #header [8,200 224×39]
0.3.3.0.0.0.0.0.1.1 TabRowCell #tab [8,239 224×41]
0.3.3.0.0.0.0.0.2.1 FolderRowCell #folder [8,280 224×41]
0.3.3.0.0.0.0.0.3.1 TodayDividerRowCell #divider [8,321 224×25]
0.3.3.0.0.0.0.0.4.1 NewTabRowCell #newTab [8,346 224×41]
0.3.3.0.0.0.0.0.5.1 TabRowCell #tab [8,387 224×41]
0.3.3.0.1.0.0.0.0.1 SpaceHeaderRowCell #header [248,200 224×39]
0.3.3.0.1.0.0.0.1.1 TabRowCell #tab [248,239 224×41]
0.3.3.0.1.0.0.0.2.1 TodayDividerRowCell #divider [248,280 224×25]
0.3.3.0.1.0.0.0.3.1 NewTabRowCell #newTab [248,305 224×41]
</untrusted-page-content>
```

## Not verified headless

- tab-menu: unverified: needs a real screen. the menu itself (logged, not drawn). The point is the Today row's middle: its TabRowCell is [8,344 224×41] in review/w14-mac's drifted tree (157 + 187 + 20.5, under the favorites' empty state)
- pinned-menu: unverified: needs a real screen. the menu itself (logged, not drawn). The point is Elsewhere's middle: its TabRowCell is [8,237 224×41] in review/w14-mac's drifted tree (157 + 80 + 20.5)
- folder-menu: unverified: needs a real screen. the menu itself (logged, not drawn). The point is Reading's middle: its FolderRowCell is [8,237 224×41] in review/w14-mac's folders tree (157 + 80 + 20.5)
- folder-menu-closed: unverified: needs a real screen. the menu itself (logged, not drawn). The point is Recipes' middle: its FolderRowCell is [8,401 224×41] in review/w14-mac's folders tree (157 + 244 + 20.5)
- favorite-menu: unverified: needs a real screen. the menu itself (logged, not drawn). The point is YouTube's middle: its FavoritePaneView is [8,90 69.33×47] in review/w13-mac's rest tree (8 + 69.3 / 2, 90 + 47 / 2); the RowCell tree doesn't list favorites, so no expect_frames, and the script refuses the click unless it lands on the pane
- control-click: unverified: needs a real screen. needs a left click with the control modifier on a FolderRowCell: the script's rows (RIGHT_CLICK_TARGETS) take only a plain right-click, never a left or ⌃-click. The right-click states above cover the same menu(for:) path (SidebarRowCell.mouseDown sends a ⌃-click to rightMouseDown); this one stays unverified on the Mac (Windows' smoke test checks its Ctrl+click)

Each state's `kite ui` step output is in `NAME.steps.txt`. Kite's logs, full trees and the build log are in the workflow run's logs artifact (kept 7 days), not on this branch.
