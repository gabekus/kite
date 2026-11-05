# W21 Mac references: the find bar (Ctrl+F / ⌘F)

Taken headless by `.github/workflows/mac-reference-captures.yml` (`scripts/mac-reference-captures.sh`) on gabe-mac-kite, macOS 15.7.4 (24G517), arm64.

Build: a debug test bundle (dev.gabek.Kite.dev, ad-hoc signed) from origin/main 1eb72a9 (`1eb72a953f8740b7281fbbad6dc7f47f91eafdb5`), engine WebKit (no CEF in ThirdParty/cef, as in CI). Each state used a fresh `mktemp -d /tmp/k.XXXX` profile with its session as session.json, `defaults delete dev.gabek.Kite.dev SidebarWidth` first, `KITE_DIAGNOSTICS=1 KITE_TEST_BLOCK_VIEWS_WINDOWS=1 TYPESAFE_API_KEY=x KITE_WINDOW_SIZE=W,H` (downloads, web apps and browser data inside the profile), and Kite in the background throughout (never activated, input posted to its window only), quit afterwards.

**Capture path:** in-process, `kite ui capture '{"source":"in-process"}' -o NAME.png`, 2× (2560×1640). Screen Recording is never used on the runner, so every PNG is in-process: blurred materials are drawn unblurred, and Kite lists where they are:

> Window N captured at 2× (2560×1640 px), sRGB, by an in-process render.
> Drawn in Kite: blurred materials are their unblurred fallback (what's behind them isn't in it); the theme, the views and the pages are as on screen.
> Material (unblurred) at: [0,0 1280×820], [0,0 1280×28].
> The loading glow (Metal) isn't drawn.
> Saved full resolution PNG to NAME.png.

| file | session | env | steps | holds | result |
|---|---|---|---|---|---|
| find-empty.png | `windows/helix/states/find-bar.json` from `origin/helix/W21-find` (d785f97) | `KITE_TEST_FIND_OPEN=1` | wait 5 s; 1 s later, the capture | the find bar open and empty over example.com, 10pt in from the content card's top-right corner: the magnifier, "Find in page…", the arrows, the divider and close; no counter | captured |
| find-matches.png | `windows/helix/states/find-bar.json` from `origin/helix/W21-find` (d785f97) | `KITE_TEST_FIND=domain` | wait 5 s; 1 s later, the capture | the find bar with "domain" typed and the counter reading 1/2, the first match highlighted on the page | captured |
| find-none.png | `windows/helix/states/find-bar.json` from `origin/helix/W21-find` (d785f97) | `KITE_TEST_FIND=zqxj` | wait 5 s; 1 s later, the capture | the find bar with "zqxj" typed and "Not Found" in red where the counter goes | captured |

## Logged by the test hooks

find-empty:

```
KITE_TEST_FIND: page: made (URL to load: yes, saved state: none)
KITE_TEST_FIND: page: load asked (web view URL set: yes, loading: yes, progress: 0.10, content process: none)
KITE_TEST_FIND: armed: open, empty; waiting up to 20 s for the selected tab's page to load (covered pages answer: yes, window visible: no)
KITE_TEST_FIND: page: started
KITE_TEST_FIND: page: committed
KITE_TEST_FIND: ready: open, empty
KITE_TEST_FIND: page: finished
KITE_TEST_FIND: page: 2 s after the load (web view URL set: yes, loading: no, progress: 1.00, content process: running)
```

find-matches:

```
KITE_TEST_FIND: page: made (URL to load: yes, saved state: none)
KITE_TEST_FIND: page: load asked (web view URL set: yes, loading: yes, progress: 0.10, content process: none)
KITE_TEST_FIND: armed: query "domain"; waiting up to 20 s for the selected tab's page to load (covered pages answer: yes, window visible: no)
KITE_TEST_FIND: page: started
KITE_TEST_FIND: page: committed
KITE_TEST_FIND: page: finished
KITE_TEST_FIND: ready: "domain", found, counter ""
KITE_TEST_FIND: page: 2 s after the load (web view URL set: yes, loading: no, progress: 1.00, content process: running)
```

find-none:

```
KITE_TEST_FIND: page: made (URL to load: yes, saved state: none)
KITE_TEST_FIND: page: load asked (web view URL set: yes, loading: yes, progress: 0.10, content process: none)
KITE_TEST_FIND: armed: query "zqxj"; waiting up to 20 s for the selected tab's page to load (covered pages answer: yes, window visible: no)
KITE_TEST_FIND: page: started
KITE_TEST_FIND: page: committed
KITE_TEST_FIND: page: finished
KITE_TEST_FIND: ready: "zqxj", not found, counter "Not Found"
KITE_TEST_FIND: page: 2 s after the load (web view URL set: yes, loading: no, progress: 1.00, content process: running)
```

## Frames (`kite ui tree '{"match":"FindBar"}'`, window points)

find-empty (after the capture; `find-empty.tree.txt` has launch, before and after):

```
Window 18914, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.6 FindBar [960,20 300×32] bg=#FAFBFF radius=5 shadow=#151C32@0.3 opacity 1 radius 5 offset 0,-3
</untrusted-page-content>
```

find-matches (after the capture; `find-matches.tree.txt` has launch, before and after):

```
Window 18916, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.6 FindBar [960,20 300×32] bg=#FAFBFF radius=5 shadow=#151C32@0.3 opacity 1 radius 5 offset 0,-3
</untrusted-page-content>
```

find-none (after the capture; `find-none.tree.txt` has launch, before and after):

```
Window 18918, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.6 FindBar [960,20 300×32] bg=#FAFBFF radius=5 shadow=#151C32@0.3 opacity 1 radius 5 offset 0,-3
</untrusted-page-content>
```

Each state's `kite ui` step output is in `NAME.steps.txt`. Kite's logs, full trees and the build log are in the workflow run's logs artifact (kept 7 days), not on this branch.
