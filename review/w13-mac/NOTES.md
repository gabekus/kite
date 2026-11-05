# W13 Mac references: the favorites grid

Taken headless by `.github/workflows/mac-reference-captures.yml` (`scripts/mac-reference-captures.sh`) on gabe-mac-kite, macOS 15.7.4 (24G517), arm64.

Build: a debug test bundle (dev.gabek.Kite.dev, ad-hoc signed) from origin/main 208bb89 (`208bb896615e65c0135f6aa09e89a3d38dde85ff`), engine WebKit (no CEF in ThirdParty/cef, as in CI). Each state used a fresh `mktemp -d /tmp/k.XXXX` profile with its session as session.json, `defaults delete dev.gabek.Kite.dev SidebarWidth` first, `KITE_DIAGNOSTICS=1 KITE_TEST_BLOCK_VIEWS_WINDOWS=1 TYPESAFE_API_KEY=x KITE_WINDOW_SIZE=W,H` (downloads, web apps and browser data inside the profile), and Kite in the background throughout (never activated, input posted to its window only), quit afterwards.

**Capture path:** in-process, `kite ui capture '{"source":"in-process"}' -o NAME.png`, 2× (2560×1640). Screen Recording is never used on the runner, so every PNG is in-process: blurred materials are drawn unblurred, and Kite lists where they are:

> Window N captured at 2× (2560×1640 px), sRGB, by an in-process render.
> Drawn in Kite: blurred materials are their unblurred fallback (what's behind them isn't in it); the theme, the views and the pages are as on screen.
> Material (unblurred) at: [0,0 1280×820], [0,0 1280×28].
> Saved full resolution PNG to NAME.png.

| file | session | env | steps | holds | result |
|---|---|---|---|---|---|
| rest.png | `windows/helix/states/favorites.json` from `origin/helix/W13-favorites` (cf451f6) | none | none | six favorites three a row under the address field (YouTube, Hacker News, GitHub / Wikipedia, Google, Example Domain's globe), YouTube selected: white with its red tint and ring; the page's header under the grid | captured; unverified: YouTube is the selected tab, so its page loads and may replace the selected tile's icon with the one its page links (the red play logo either way, at its own size) |
| one.png | `windows/helix/states/favorites-1.json` from `origin/helix/W13-favorites` (cf451f6) | none | none | one favorite (Example Domain, no favicon: the globe) across the whole row, not selected | captured |
| four.png | `windows/helix/states/favorites-4.json` from `origin/helix/W13-favorites` (cf451f6) | none | none | four favorites in one row, none selected | captured |
| nine.png | `windows/helix/states/favorites-9.json` from `origin/helix/W13-favorites` (cf451f6) | none | none | nine favorites three by three (YouTube, Hacker News, GitHub / Wikipedia, Google, Example / Python, Mozilla, Apple), none selected | captured |
| missing-favicon.png | inline in request.json | none | none | favorites.json with Example Domain's favorite selected: white at 0.45, its globe, no tint or ring (no colour) | captured |
| empty.png | `windows/helix/states/sidebar.json` from `origin/helix/W13-favorites` (cf451f6) | none | none | a fresh profile with no favorites: the dashed "Drag to add Favorites" box (59pt, its subtitle on two lines) between the address field and Personal's header (near y 157), no close button (the pointer isn't on it) | captured |
| light-selected.png | `windows/helix/states/favorites-light.json` from `origin/helix/W13-favorites` (cf451f6) | none | none | favorites.json on a light theme (Work's peach): YouTube selected, white at 0.8 with its ring and no tint at rest; the others white at 0.35 | captured; unverified: as rest: YouTube's page loads and may report its own icon |
| light-empty.png | `windows/helix/states/favorites-empty-light.json` from `origin/helix/W13-favorites` (cf451f6) | none | none | no favorites on a light theme: the empty state's dashed outline and text in black at their opacities | captured |
| hover.png (none) | `windows/helix/states/favorites.json` from `origin/helix/W13-favorites` (cf451f6) | none | none | a hovered unselected favorite (white 0.20 for 0.10) | skipped, unverified: a pointer resting on a FavoritePaneView: not a SAFE_TARGETS view and no hover hook; Windows' --favorite-hover only |

## Frames (`kite ui tree '{"match":"FavoritePaneView"}'`, window points)

rest (after the capture; `rest.tree.txt` has launch, before and after):

```
Window 18086, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.1.1.0 FavoritePaneView [8,90 69.33×47]
0.3.1.2.0 FavoritePaneView [85.33,90 69.33×47]
0.3.1.3.0 FavoritePaneView [162.67,90 69.33×47]
0.3.1.4.0 FavoritePaneView [8,145 69.33×47]
0.3.1.5.0 FavoritePaneView [85.33,145 69.33×47]
0.3.1.6.0 FavoritePaneView [162.67,145 69.33×47]
</untrusted-page-content>
```

one (after the capture; `one.tree.txt` has launch, before and after):

```
Window 18088, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.1.1.0 FavoritePaneView [8,90 224×47]
</untrusted-page-content>
```

four (after the capture; `four.tree.txt` has launch, before and after):

```
Window 18091, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.1.1.0 FavoritePaneView [8,90 50×47]
0.3.1.2.0 FavoritePaneView [66,90 50×47]
0.3.1.3.0 FavoritePaneView [124,90 50×47]
0.3.1.4.0 FavoritePaneView [182,90 50×47]
</untrusted-page-content>
```

nine (after the capture; `nine.tree.txt` has launch, before and after):

```
Window 18093, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.1.1.0 FavoritePaneView [8,90 69.33×47]
0.3.1.2.0 FavoritePaneView [85.33,90 69.33×47]
0.3.1.3.0 FavoritePaneView [162.67,90 69.33×47]
0.3.1.4.0 FavoritePaneView [8,145 69.33×47]
0.3.1.5.0 FavoritePaneView [85.33,145 69.33×47]
0.3.1.6.0 FavoritePaneView [162.67,145 69.33×47]
0.3.1.7.0 FavoritePaneView [8,200 69.33×47]
0.3.1.8.0 FavoritePaneView [85.33,200 69.33×47]
0.3.1.9.0 FavoritePaneView [162.67,200 69.33×47]
</untrusted-page-content>
```

missing-favicon (after the capture; `missing-favicon.tree.txt` has launch, before and after):

```
Window 18095, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.1.1.0 FavoritePaneView [8,90 69.33×47]
0.3.1.2.0 FavoritePaneView [85.33,90 69.33×47]
0.3.1.3.0 FavoritePaneView [162.67,90 69.33×47]
0.3.1.4.0 FavoritePaneView [8,145 69.33×47]
0.3.1.5.0 FavoritePaneView [85.33,145 69.33×47]
0.3.1.6.0 FavoritePaneView [162.67,145 69.33×47]
</untrusted-page-content>
```

empty (after the capture; `empty.tree.txt` has launch, before and after):

```
Window 18097, 1280×820 pt at 2×. Points from the window's top-left.
Nothing matches "FavoritePaneView".
```

light-selected (after the capture; `light-selected.tree.txt` has launch, before and after):

```
Window 18099, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.3.1.1.0 FavoritePaneView [8,90 69.33×47]
0.3.1.2.0 FavoritePaneView [85.33,90 69.33×47]
0.3.1.3.0 FavoritePaneView [162.67,90 69.33×47]
0.3.1.4.0 FavoritePaneView [8,145 69.33×47]
0.3.1.5.0 FavoritePaneView [85.33,145 69.33×47]
0.3.1.6.0 FavoritePaneView [162.67,145 69.33×47]
</untrusted-page-content>
```

light-empty (after the capture; `light-empty.tree.txt` has launch, before and after):

```
Window 18101, 1280×820 pt at 2×. Points from the window's top-left.
Nothing matches "FavoritePaneView".
```

## Not verified headless

- rest: unverified: needs a real screen. YouTube is the selected tab, so its page loads and may replace the selected tile's icon with the one its page links (the red play logo either way, at its own size)
- light-selected: unverified: needs a real screen. as rest: YouTube's page loads and may report its own icon
- hover: unverified: needs a real screen. a pointer resting on a FavoritePaneView: not a SAFE_TARGETS view and no hover hook; Windows' --favorite-hover only

Each state's `kite ui` step output is in `NAME.steps.txt`. Kite's logs, full trees and the build log are in the workflow run's logs artifact (kept 7 days), not on this branch.
