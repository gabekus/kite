# W21 Mac references: the find bar (Ctrl+F / ⌘F)

Taken headless by `.github/workflows/mac-reference-captures.yml` (`scripts/mac-reference-captures.sh`) on gabe-mac-kite, macOS 15.7.4 (24G517), arm64.

Build: a debug test bundle (dev.gabek.Kite.dev, ad-hoc signed) from origin/main 4943b34 (`4943b3493d2120f6310dcd8c38723ebe112cc80d`), engine WebKit (no CEF in ThirdParty/cef, as in CI). Each state used a fresh `mktemp -d /tmp/k.XXXX` profile with its session as session.json, `defaults delete dev.gabek.Kite.dev SidebarWidth` first, `KITE_DIAGNOSTICS=1 KITE_TEST_BLOCK_VIEWS_WINDOWS=1 TYPESAFE_API_KEY=x KITE_WINDOW_SIZE=W,H` (downloads, web apps and browser data inside the profile), and Kite in the background throughout (never activated, input posted to its window only), quit afterwards.

**Capture path:** in-process, `kite ui capture '{"source":"in-process"}' -o NAME.png`, 2× (2560×1640). Screen Recording is never used on the runner, so every PNG is in-process: blurred materials are drawn unblurred, and Kite lists where they are:

> Window N captured at 2× (2560×1640 px), sRGB, by an in-process render.
> Drawn in Kite: blurred materials are their unblurred fallback (what's behind them isn't in it); the theme, the views and the pages are as on screen.
> Material (unblurred) at: [0,0 1280×820], [0,0 1280×28].
> Saved full resolution PNG to NAME.png.

| file | session | env | steps | holds | result |
|---|---|---|---|---|---|
| find-empty.png | `windows/helix/states/find-bar.json` from `origin/helix/W21-find` (697aa82) | `KITE_TEST_FIND_OPEN=1` | wait 5 s; 1 s later, the capture | the find bar open and empty over example.com, 10pt in from the content card's top-right corner: the magnifier, "Find in page…", the arrows, the divider and close; no counter | captured |
| find-matches.png | `windows/helix/states/find-bar.json` from `origin/helix/W21-find` (697aa82) | `KITE_TEST_FIND=domain` | wait 5 s; 1 s later, the capture | the find bar with "domain" typed and the counter reading 1/2, the first match highlighted on the page | captured |
| find-none.png | `windows/helix/states/find-bar.json` from `origin/helix/W21-find` (697aa82) | `KITE_TEST_FIND=zqxj` | wait 5 s; 1 s later, the capture | the find bar with "zqxj" typed and "Not Found" in red where the counter goes | captured |

## Logged by the test hooks

find-empty:

```
KITE_TEST_FIND: armed: open, empty; waiting up to 20 s for the selected tab's page to load (covered pages answer: yes, window visible: no)
KITE_TEST_FIND: no page finished loading in 20 s, so the find bar opens without it (finished loads seen: 0, of the selected tab: 0; selected tab: yes, page shown: yes, loading: unknown, progress: unknown; web view loading: no, web view progress: 0.00, web view URL set: no, content process ended: 0 times, content process: running; window visible: no, ordered in: yes, on a screen: yes, screens: 1)
KITE_TEST_FIND: ready (fallback, the page never loaded): open, empty
```

find-matches:

```
KITE_TEST_FIND: armed: query "domain"; waiting up to 20 s for the selected tab's page to load (covered pages answer: yes, window visible: no)
KITE_TEST_FIND: no page finished loading in 20 s, so the find bar opens without it (finished loads seen: 0, of the selected tab: 0; selected tab: yes, page shown: yes, loading: unknown, progress: unknown; web view loading: no, web view progress: 0.00, web view URL set: no, content process ended: 0 times, content process: running; window visible: no, ordered in: yes, on a screen: yes, screens: 1)
KITE_TEST_FIND: ready (fallback, the page never loaded): "domain" set, no find result
```

find-none:

```
KITE_TEST_FIND: armed: query "zqxj"; waiting up to 20 s for the selected tab's page to load (covered pages answer: yes, window visible: no)
KITE_TEST_FIND: no page finished loading in 20 s, so the find bar opens without it (finished loads seen: 0, of the selected tab: 0; selected tab: yes, page shown: yes, loading: unknown, progress: unknown; web view loading: no, web view progress: 0.00, web view URL set: no, content process ended: 0 times, content process: running; window visible: no, ordered in: yes, on a screen: yes, screens: 1)
KITE_TEST_FIND: ready (fallback, the page never loaded): "zqxj" set, no find result
```

## Frames (`kite ui tree '{"match":"FindBar"}'`, window points)

find-empty (after the capture; `find-empty.tree.txt` has launch, before and after):

```
Window 18904, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.6 FindBar [960,20 300×32] bg=#FAFBFF radius=5 shadow=#151C32@0.3 opacity 1 radius 5 offset 0,-3
</untrusted-page-content>
```

find-matches (after the capture; `find-matches.tree.txt` has launch, before and after):

```
Window 18906, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.6 FindBar [960,20 300×32] bg=#FAFBFF radius=5 shadow=#151C32@0.3 opacity 1 radius 5 offset 0,-3
</untrusted-page-content>
```

find-none (after the capture; `find-none.tree.txt` has launch, before and after):

```
Window 18908, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.6 FindBar [960,20 300×32] bg=#FAFBFF radius=5 shadow=#151C32@0.3 opacity 1 radius 5 offset 0,-3
</untrusted-page-content>
```

Each state's `kite ui` step output is in `NAME.steps.txt`. Kite's logs, full trees and the build log are in the workflow run's logs artifact (kept 7 days), not on this branch.
