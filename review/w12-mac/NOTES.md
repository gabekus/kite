# W12 Mac references: the sidebar's top row and hiding the sidebar

Taken headless by `.github/workflows/mac-reference-captures.yml` (`scripts/mac-reference-captures.sh`) on gabe-mac-kite, macOS 15.7.4 (24G517), arm64.

Build: a debug test bundle (dev.gabek.Kite.dev, ad-hoc signed) from origin/main 208bb89 (`208bb896615e65c0135f6aa09e89a3d38dde85ff`), engine WebKit (no CEF in ThirdParty/cef, as in CI). Each state used a fresh `mktemp -d /tmp/k.XXXX` profile with its session as session.json, `defaults delete dev.gabek.Kite.dev SidebarWidth` first, `KITE_DIAGNOSTICS=1 KITE_TEST_BLOCK_VIEWS_WINDOWS=1 TYPESAFE_API_KEY=x KITE_WINDOW_SIZE=W,H` (downloads, web apps and browser data inside the profile), and Kite in the background throughout (never activated, input posted to its window only), quit afterwards.

**Capture path:** in-process, `kite ui capture '{"source":"in-process"}' -o NAME.png`, 2× (2560×1640). Screen Recording is never used on the runner, so every PNG is in-process: blurred materials are drawn unblurred, and Kite lists where they are:

> Window N captured at 2× (2560×1640 px), sRGB, by an in-process render.
> Drawn in Kite: blurred materials are their unblurred fallback (what's behind them isn't in it); the theme, the views and the pages are as on screen.
> Material (unblurred) at: [0,0 1280×820], [0,0 1280×28].
> Saved full resolution PNG to NAME.png.

**Coordinates:** at launch the tree showed every frame the request's points assume (rest: [71,7.5 32×32], [134,7.5 32×32], [168,7.5 32×32], [202,7.5 32×32]; loading: [71,7.5 32×32], [134,7.5 32×32], [168,7.5 32×32], [202,7.5 32×32]).

| file | session | env | steps | holds | result |
|---|---|---|---|---|---|
| rest.png | `windows/helix/states/three-spaces.json` from `origin/helix/W12-top-row` (28f82cf) | none | none | the top row at rest on example.com: the toggle at 0.6, back and forward disabled (0.125), reload enabled | captured |
| loading.png | `windows/helix/states/top-row-loading.json` from `origin/helix/W12-top-row` (28f82cf) | none | none | reload is the X while https://httpbin.org/delay/10 loads (it answers after 10 s; the capture comes about 3 s after launch); back and forward disabled | captured; unverified: the X shows only while the runner reaches httpbin.org and it hasn't answered yet: if the capture shows reload's arrow, the page had already loaded (or failed at once) |
| history.png (none) | `windows/helix/states/three-spaces.json` from `origin/helix/W12-top-row` (28f82cf) | none | none | back enabled, forward disabled, after the page has gone somewhere | skipped, unverified: needs a page with history: a session can't carry any (Chromium reloads a restored tab without its history), session URLs are public http(s) only, and the steps can't navigate (no keys, no Return, text only into the command bar). Windows' capture holds the state with --page-status back |
| hover.png (none) | `windows/helix/states/three-spaces.json` from `origin/helix/W12-top-row` (28f82cf) | none | none | the pointer resting on reload: no change to the button (SymbolButton has no hoverOpacity or hoverWash in the top row), and its Reload tooltip after AppKit's delay | skipped, unverified: the tooltip needs a real pointer resting on the button, and kite ui input has no plain move; the button itself draws no hover |
| hidden.png (none) | `windows/helix/states/three-spaces.json` from `origin/helix/W12-top-row` (28f82cf) | none | none | after the toggle (Hide Sidebar): no sidebar, the card from 10pt in, the traffic lights where they were | skipped, unverified: needs a click on the toggle (a SymbolButton, not in SAFE_TARGETS: the class is shared with the header's More and Developer buttons, whose menus have no test hook) or ⌘S (keys are refused). A safe target for the toggle alone (its accessibility label, Toggle Sidebar) would let this run: click [87, 23.5] |
| shown-again.png (none) | `windows/helix/states/three-spaces.json` from `origin/helix/W12-top-row` (28f82cf) | none | none | after Hide Sidebar and Show Sidebar: the same as rest | skipped, unverified: as hidden, and the hidden sidebar's toggle is off the window, so showing it again needs ⌘S (keys are refused) or the hover reveal |

## Frames (`kite ui tree '{"match":"SymbolButton"}'`, window points)

rest (after the capture; `rest.tree.txt` has launch, before and after):

```
Window 17906, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.0.0 SymbolButton [71,7.5 32×32] alpha=0.6 opacity=0.6
0.3.0.1 SymbolButton [134,7.5 32×32] alpha=0.13 opacity=0.13
0.3.0.2 SymbolButton [168,7.5 32×32] alpha=0.13 opacity=0.13
0.3.0.3 SymbolButton [202,7.5 32×32] alpha=0.6 opacity=0.6
0.3.0.4 SymbolButton [0,0 0×0] hidden=true alpha=0.6 opacity=0.6
0.3.0.5 SymbolButton [0,0 0×0] hidden=true alpha=0.6 opacity=0.6
0.3.0.6.2.0 SymbolButton [8,46 0×0] hidden=true alpha=0.6 opacity=0.6
0.3.0.6.2.1 SymbolButton [198,49 30×30] alpha=0.6 opacity=0.6
0.3.0.6.2.2 SymbolButton [8,46 0×0] hidden=true alpha=0.6 opacity=0.6
0.3.0.6.3 SymbolButton [8,46 0×0] hidden=true alpha=0.6 opacity=0.6
0.3.1.0.2 SymbolButton [210,100 18×18] hidden=true alpha=0.5 opacity=0.5
0.3.2.0.0 SymbolButton [8,779 32×32] alpha=0.7 opacity=0.7
0.3.2.1 SymbolButton [200,779 32×32] alpha=0.7 opacity=0.7
0.3.3.0.0.0.0.0.0.1.2 SymbolButton [205,150 26×26] alpha=0 opacity=0
0.3.3.0.0.0.0.0.1.1.1.5 SymbolButton [8,186.5 0×0] hidden=true alpha=0.6 opacity=0.6
0.3.3.0.0.0.0.0.1.1.1.6 SymbolButton [8,186.5 0×0] hidden=true alpha=0.6 opacity=0.6
0.3.3.0.0.0.0.0.1.1.2.1 SymbolButton [207,188.5 16×16] alpha=0 opacity=0
0.3.3.0.0.0.0.0.2.1.5 SymbolButton [8,225 0×0] hidden=true
0.3.3.0.0.0.0.0.5.1.1.5 SymbolButton [8,334.5 0×0] hidden=true alpha=0.6 opacity=0.6
0.3.3.0.0.0.0.0.5.1.1.6 SymbolButton [8,334.5 0×0] hidden=true alpha=0.6 opacity=0.6
0.3.3.0.0.0.0.0.5.1.2.1 SymbolButton [207,336.5 16×16] alpha=0 opacity=0
0.3.3.0.1.0.0.0.0.1.2 SymbolButton [445,150 26×26] alpha=0 opacity=0
0.3.3.0.1.0.0.0.1.1.1.5 SymbolButton [248,186.5 0×0] hidden=true alpha=0.6 opacity=0.6
0.3.3.0.1.0.0.0.1.1.1.6 SymbolButton [248,186.5 0×0] hidden=true alpha=0.6 opacity=0.6
0.3.3.0.1.0.0.0.1.1.2.1 SymbolButton [447,188.5 16×16] alpha=0 opacity=0
</untrusted-page-content>
```

loading (after the capture; `loading.tree.txt` has launch, before and after):

```
Window 17908, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.0.0 SymbolButton [71,7.5 32×32] alpha=0.6 opacity=0.6
0.3.0.1 SymbolButton [134,7.5 32×32] alpha=0.13 opacity=0.13
0.3.0.2 SymbolButton [168,7.5 32×32] alpha=0.13 opacity=0.13
0.3.0.3 SymbolButton [202,7.5 32×32] alpha=0.6 opacity=0.6
0.3.0.4 SymbolButton [0,0 0×0] hidden=true alpha=0.6 opacity=0.6
0.3.0.5 SymbolButton [0,0 0×0] hidden=true alpha=0.6 opacity=0.6
0.3.0.6.2.0 SymbolButton [8,46 0×0] hidden=true alpha=0.6 opacity=0.6
0.3.0.6.2.1 SymbolButton [198,49 30×30] alpha=0.6 opacity=0.6
0.3.0.6.2.2 SymbolButton [8,46 0×0] hidden=true alpha=0.6 opacity=0.6
0.3.0.6.3 SymbolButton [8,46 0×0] hidden=true alpha=0.6 opacity=0.6
0.3.1.0.2 SymbolButton [210,100 18×18] hidden=true alpha=0.5 opacity=0.5
0.3.2.0.0 SymbolButton [8,779 32×32] alpha=0.7 opacity=0.7
0.3.2.1 SymbolButton [200,779 32×32] alpha=0.7 opacity=0.7
0.3.3.0.0.0.0.0.0.1.2 SymbolButton [205,150 26×26] alpha=0 opacity=0
0.3.3.0.0.0.0.0.1.1.1.5 SymbolButton [8,186.5 0×0] hidden=true alpha=0.6 opacity=0.6
0.3.3.0.0.0.0.0.1.1.1.6 SymbolButton [8,186.5 0×0] hidden=true alpha=0.6 opacity=0.6
0.3.3.0.0.0.0.0.1.1.2.1 SymbolButton [207,188.5 16×16] alpha=0 opacity=0
0.3.3.0.0.0.0.0.2.1.5 SymbolButton [8,225 0×0] hidden=true
0.3.3.0.0.0.0.0.5.1.1.5 SymbolButton [8,334.5 0×0] hidden=true alpha=0.6 opacity=0.6
0.3.3.0.0.0.0.0.5.1.1.6 SymbolButton [8,334.5 0×0] hidden=true alpha=0.6 opacity=0.6
0.3.3.0.0.0.0.0.5.1.2.1 SymbolButton [207,336.5 16×16] alpha=0 opacity=0
0.3.3.0.1.0.0.0.0.1.2 SymbolButton [445,150 26×26] alpha=0 opacity=0
0.3.3.0.1.0.0.0.1.1.1.5 SymbolButton [248,186.5 0×0] hidden=true alpha=0.6 opacity=0.6
0.3.3.0.1.0.0.0.1.1.1.6 SymbolButton [248,186.5 0×0] hidden=true alpha=0.6 opacity=0.6
0.3.3.0.1.0.0.0.1.1.2.1 SymbolButton [447,188.5 16×16] alpha=0 opacity=0
</untrusted-page-content>
```

## Not verified headless

- loading: unverified: needs a real screen. the X shows only while the runner reaches httpbin.org and it hasn't answered yet: if the capture shows reload's arrow, the page had already loaded (or failed at once)
- history: unverified: needs a real screen. needs a page with history: a session can't carry any (Chromium reloads a restored tab without its history), session URLs are public http(s) only, and the steps can't navigate (no keys, no Return, text only into the command bar). Windows' capture holds the state with --page-status back
- hover: unverified: needs a real screen. the tooltip needs a real pointer resting on the button, and kite ui input has no plain move; the button itself draws no hover
- hidden: unverified: needs a real screen. needs a click on the toggle (a SymbolButton, not in SAFE_TARGETS: the class is shared with the header's More and Developer buttons, whose menus have no test hook) or ⌘S (keys are refused). A safe target for the toggle alone (its accessibility label, Toggle Sidebar) would let this run: click [87, 23.5]
- shown-again: unverified: needs a real screen. as hidden, and the hidden sidebar's toggle is off the window, so showing it again needs ⌘S (keys are refused) or the hover reveal

Each state's `kite ui` step output is in `NAME.steps.txt`. Kite's logs, full trees and the build log are in the workflow run's logs artifact (kept 7 days), not on this branch.
