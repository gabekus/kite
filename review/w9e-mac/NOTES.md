# W9e Mac references: Change Space Icon…'s picker

Taken headless by `.github/workflows/mac-reference-captures.yml` (`scripts/mac-reference-captures.sh`) on gabe-mac-kite, macOS 15.7.4 (24G517), arm64.

Build: a debug test bundle (dev.gabek.Kite.dev, ad-hoc signed) from origin/main 577062a (`577062ae63ea3e417804fead912021886ab3a359`), engine WebKit (no CEF in ThirdParty/cef, as in CI). Each state used a fresh `mktemp -d /tmp/k.XXXX` profile with its session as session.json, `defaults delete dev.gabek.Kite.dev SidebarWidth` first, `KITE_DIAGNOSTICS=1 KITE_TEST_BLOCK_VIEWS_WINDOWS=1 TYPESAFE_API_KEY=x KITE_WINDOW_SIZE=W,H` (downloads, web apps and browser data inside the profile), and Kite in the background throughout (never activated, input posted to its window only), quit afterwards.

**Capture path:** in-process, `kite ui capture '{"source":"in-process"}' -o NAME.png`, 2× (2560×1640). Screen Recording is never used on the runner, so every PNG is in-process: blurred materials are drawn unblurred, and Kite lists where they are:

> Window N captured at 2× (2560×1640 px), sRGB, by an in-process render.
> Drawn in Kite: blurred materials are their unblurred fallback (what's behind them isn't in it); the theme, the views and the pages are as on screen.
> Material (unblurred) at: [0,0 1280×820], [0,0 1280×28].
> Saved full resolution PNG to NAME.png.
> A popover is drawn over the window from its views (298×294 pt).
> A popover is drawn over the window from its views (298×315 pt).

**Coordinates:** at launch the tree showed every frame the request's points assume (rest: [68,778 36×34], [102,778 36×34], [136,778 36×34]; picker-emoji: [68,778 36×34], [102,778 36×34], [136,778 36×34]; picker-icon: [68,778 36×34], [102,778 36×34], [136,778 36×34]; icon-changed: [68,778 36×34], [102,778 36×34], [136,778 36×34]).

| file | session | env | steps | holds | result |
|---|---|---|---|---|---|
| rest.png | `windows/helix/states/three-spaces.json` from `origin/main` (577062a) | none | none | the three spaces at rest, Personal (🏠) selected | captured |
| picker-emoji.png | `windows/helix/states/three-spaces.json` from `origin/main` (577062a) | `KITE_TEST_ICON_PICKER=Personal` | none | Change Space Icon…'s popover under Personal's header icon on the Emoji tab (Personal's icon is an emoji): Emoji \| Icon \| Image with the bin, Search, the first five rows of Smileys & People, the category bar | captured |
| picker-icon.png | `windows/helix/states/three-spaces.json` from `origin/main` (577062a) | `KITE_TEST_ICON_PICKER=Work` | none | the same popover for Work, on the Icon tab (Work's icon is the briefcase symbol): 7 rows of 8 symbols, the briefcase lit. Work is selected, so the backdrop and header are Work's; compare the popover's boxes, not its colours | captured |
| icon-changed.png | inline in request.json | none | none | Personal's icon 😁 (what the Windows capture picked: the Emoji tab's fourth cell) in its header and its cell in the bar, lit | captured |

## Logged by the test hooks

picker-emoji:

```
KITE_TEST_SIDEBAR: armed: icon picker for "Personal"
KITE_TEST_SIDEBAR: ready: app active no; popover key no, level 0, parent the main window; icon picker for "Personal"
```

picker-icon:

```
KITE_TEST_SIDEBAR: armed: icon picker for "Work"
KITE_TEST_SIDEBAR: ready: app active no; popover key no, level 0, parent the main window; icon picker for "Work"
```

## Frames (`kite ui tree '{"match":"SpaceCellView"}'`, window points)

rest (after the capture; `rest.tree.txt` has launch, before and after):

```
Window 20209, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.2.2.0.0.0 SpaceCellView [68,778 36×34]
0.3.2.2.0.0.1 SpaceCellView [102,778 36×34]
0.3.2.2.0.0.2 SpaceCellView [136,778 36×34]
0.3.2.3 SpaceCellView [0,770 0×0] hidden=true
</untrusted-page-content>
```

picker-emoji (after the capture; `picker-emoji.tree.txt` has launch, before and after):

```
Window 20211, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.2.2.0.0.0 SpaceCellView [68,778 36×34]
0.3.2.2.0.0.1 SpaceCellView [102,778 36×34]
0.3.2.2.0.0.2 SpaceCellView [136,778 36×34]
0.3.2.3 SpaceCellView [0,770 0×0] hidden=true
</untrusted-page-content>
```

picker-icon (after the capture; `picker-icon.tree.txt` has launch, before and after):

```
Window 20214, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.2.2.0.0.0 SpaceCellView [68,778 36×34]
0.3.2.2.0.0.1 SpaceCellView [102,778 36×34]
0.3.2.2.0.0.2 SpaceCellView [136,778 36×34]
0.3.2.3 SpaceCellView [0,770 0×0] hidden=true
</untrusted-page-content>
```

icon-changed (after the capture; `icon-changed.tree.txt` has launch, before and after):

```
Window 20217, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.2.2.0.0.0 SpaceCellView [68,778 36×34]
0.3.2.2.0.0.1 SpaceCellView [102,778 36×34]
0.3.2.2.0.0.2 SpaceCellView [136,778 36×34]
0.3.2.3 SpaceCellView [0,770 0×0] hidden=true
</untrusted-page-content>
```

Each state's `kite ui` step output is in `NAME.steps.txt`. Kite's logs, full trees and the build log are in the workflow run's logs artifact (kept 7 days), not on this branch.
