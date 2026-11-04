# W9d Mac references: the space bar's drag, the space menu, renaming, New Space

Taken headless by `.github/workflows/mac-reference-captures.yml` (`scripts/mac-reference-captures.sh`) on gabe-mac-kite, macOS 15.7.4 (24G517), arm64.

Build: a debug test bundle (dev.gabek.Kite.dev, ad-hoc signed) from origin/main 208bb89 (`208bb896615e65c0135f6aa09e89a3d38dde85ff`), engine WebKit (no CEF in ThirdParty/cef, as in CI). Each state used a fresh `mktemp -d /tmp/k.XXXX` profile with its session as session.json, `defaults delete dev.gabek.Kite.dev SidebarWidth` first, `KITE_DIAGNOSTICS=1 KITE_TEST_BLOCK_VIEWS_WINDOWS=1 TYPESAFE_API_KEY=x KITE_WINDOW_SIZE=W,H` (downloads, web apps and browser data inside the profile), and Kite in the background throughout (never activated, input posted to its window only), quit afterwards.

**Capture path:** in-process, `kite ui capture '{"source":"in-process"}' -o NAME.png`, 2× (2560×1640). Screen Recording is never used on the runner, so every PNG is in-process: blurred materials are drawn unblurred, and Kite lists where they are:

> Window N captured at 2× (2560×1640 px), sRGB, by an in-process render.
> Drawn in Kite: blurred materials are their unblurred fallback (what's behind them isn't in it); the theme, the views and the pages are as on screen.
> Material (unblurred) at: [0,0 1280×820], [0,0 1280×28].
> Saved full resolution PNG to NAME.png.

**Coordinates:** at launch the tree showed every frame the request's points assume (rest: [68,778 36×34], [102,778 36×34], [136,778 36×34]; drag: [68,778 36×34], [102,778 36×34], [136,778 36×34]; dropped: [68,778 36×34], [102,778 36×34], [136,778 36×34]; menu: [68,778 36×34], [102,778 36×34], [136,778 36×34]; rename: [68,778 36×34], [102,778 36×34], [136,778 36×34]).

| file | session | env | steps | holds | result |
|---|---|---|---|---|---|
| rest.png | `windows/helix/states/three-spaces.json` from `origin/helix/W9d-space-editing` (1b3595a) | none | none | the three spaces at rest | captured |
| drag.png | `windows/helix/states/three-spaces.json` from `origin/helix/W9d-space-editing` (1b3595a) | none | `kite ui input '{"from":[86,795],"to":[150,795],"steps":10,"hold":10}'`; captured 0.5 s into the 10 s hold | Personal's icon picked up as the ghost (with its backing) at x 150, Work and Reading slid into slots 0 and 1 | captured |
| dropped.png | `windows/helix/states/three-spaces.json` from `origin/helix/W9d-space-editing` (1b3595a) | none | `kite ui input '{"from":[86,795],"to":[150,795],"steps":10}'`; 1 s later, the capture | Work, Reading, Personal, Personal selected (the order is in the frames below) | captured |
| menu.png (none) | `windows/helix/states/three-spaces.json` from `origin/helix/W9d-space-editing` (1b3595a) | `KITE_TEST_CONTEXT_MENU=1` | `kite ui input '{"click":[86,795],"button":"right"}'`; 1 s later, the frames (no capture) | the space menu over Personal's cell, and its items as AppKit logs them | logged; unverified: menu.png is the real NSMenu, which needs a real right-click and screencapture while it's open (it's modal, so kite ui capture can't run under it). This run only logs its items, with KITE_TEST_CONTEXT_MENU=1 and a posted right-click. |
| rename.png | `windows/helix/states/three-spaces.json` from `origin/helix/W9d-space-editing` (1b3595a) | `KITE_TEST_CONTEXT_MENU=Rename Space…` | `kite ui input '{"click":[86,795],"button":"right"}'`; 1 s later, the capture | the header's rename field, the name all selected, Done at the right | captured |
| new-space.png | `review/w9d-win/three-spaces-new-space.json` from `origin/review/w9d-win` (d58b0cb) | none | none | Projects' dot lit between Personal and Work | captured |

## Logged by the test hooks

menu:

```
KITE_TEST_CONTEXT_MENU: Change Space Icon… | Rename Space… | What's This Space For?… | Edit Theme Color… | Set Profile ▸ [Default / --- / New Profile…] | --- | New Folder | Live Folders ▸ [GitHub] | --- | Delete Space
```

rename:

```
KITE_TEST_CONTEXT_MENU: Change Space Icon… | Rename Space… | What's This Space For?… | Edit Theme Color… | Set Profile ▸ [Default / --- / New Profile…] | --- | New Folder | Live Folders ▸ [GitHub] | --- | Delete Space
```

## Frames (`kite ui tree '{"match":"SpaceCellView"}'`, window points)

rest (after the capture; `rest.tree.txt` has launch, before and after):

```
Window 17800, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.2.2.0.0.0 SpaceCellView [68,778 36×34]
0.3.2.2.0.0.1 SpaceCellView [102,778 36×34]
0.3.2.2.0.0.2 SpaceCellView [136,778 36×34]
0.3.2.3 SpaceCellView [0,770 0×0] hidden=true
</untrusted-page-content>
```

drag (after the capture; `drag.tree.txt` has launch, before and after):

```
Window 17802, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.2.2.0.0.0 SpaceCellView [136,778 36×34] alpha=0 opacity=0
0.3.2.2.0.0.1 SpaceCellView [68,778 36×34]
0.3.2.2.0.0.2 SpaceCellView [102,778 36×34]
0.3.2.3 SpaceCellView [132,778 36×34]
</untrusted-page-content>
```

dropped (after the capture; `dropped.tree.txt` has launch, before and after):

```
Window 17804, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.2.2.0.0.0 SpaceCellView [136,778 36×34]
0.3.2.2.0.0.1 SpaceCellView [68,778 36×34]
0.3.2.2.0.0.2 SpaceCellView [102,778 36×34]
0.3.2.3 SpaceCellView [136,778 36×34] hidden=true
</untrusted-page-content>
```

menu (after the steps; `menu.tree.txt` has launch, before and after):

```
Window 17806, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.2.2.0.0.0 SpaceCellView [68,778 36×34]
0.3.2.2.0.0.1 SpaceCellView [102,778 36×34]
0.3.2.2.0.0.2 SpaceCellView [136,778 36×34]
0.3.2.3 SpaceCellView [0,770 0×0] hidden=true
</untrusted-page-content>
```

rename (after the capture; `rename.tree.txt` has launch, before and after):

```
Window 17808, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.2.2.0.0.0 SpaceCellView [68,778 36×34]
0.3.2.2.0.0.1 SpaceCellView [102,778 36×34]
0.3.2.2.0.0.2 SpaceCellView [136,778 36×34]
0.3.2.3 SpaceCellView [0,770 0×0] hidden=true
</untrusted-page-content>
```

new-space (after the capture; `new-space.tree.txt` has launch, before and after):

```
Window 17810, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.2.2.0.0.0 SpaceCellView [51,778 36×34]
0.3.2.2.0.0.1 SpaceCellView [85,778 36×34]
0.3.2.2.0.0.2 SpaceCellView [119,778 36×34]
0.3.2.2.0.0.3 SpaceCellView [153,778 36×34]
0.3.2.3 SpaceCellView [0,770 0×0] hidden=true
</untrusted-page-content>
```

## Not verified headless

- menu: unverified: needs a real screen. menu.png is the real NSMenu, which needs a real right-click and screencapture while it's open (it's modal, so kite ui capture can't run under it). This run only logs its items, with KITE_TEST_CONTEXT_MENU=1 and a posted right-click.

Each state's `kite ui` step output is in `NAME.steps.txt`. Kite's logs, full trees and the build log are in the workflow run's logs artifact (kept 7 days), not on this branch.
