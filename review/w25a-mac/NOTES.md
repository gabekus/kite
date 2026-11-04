# W25a Mac references: the command bar's history rows

Taken headless by `.github/workflows/mac-reference-captures.yml` (`scripts/mac-reference-captures.sh`) on gabe-mac-kite, macOS 15.7.4 (24G517), arm64.

Build: a debug test bundle (dev.gabek.Kite.dev, ad-hoc signed) from origin/fix/test-safe-text-input 9261122 (`92611226a9834ac52b95a77268bf1f5647f08490`), engine WebKit (no CEF in ThirdParty/cef, as in CI). Each state used a fresh `mktemp -d /tmp/k.XXXX` profile with its session as session.json, `defaults delete dev.gabek.Kite.dev SidebarWidth` first, `KITE_DIAGNOSTICS=1 KITE_TEST_BLOCK_VIEWS_WINDOWS=1 TYPESAFE_API_KEY=x KITE_WINDOW_SIZE=W,H` (downloads, web apps and browser data inside the profile), and Kite in the background throughout (never activated, input posted to its window only), quit afterwards.

**Capture path:** in-process, `kite ui capture '{"source":"in-process"}' -o NAME.png`, 2× (2560×1640). Screen Recording is never used on the runner, so every PNG is in-process: blurred materials are drawn unblurred, and Kite lists where they are:

> Window N captured at 2× (2560×1640 px), sRGB, by an in-process render.
> Drawn in Kite: blurred materials are their unblurred fallback (what's behind them isn't in it); the theme, the views and the pages are as on screen.
> Material (unblurred) at: [0,0 1280×820], [257.5,303 765×278], [0,0 1280×28].
> Saved full resolution PNG to NAME.png.

| file | session | env | steps | holds | result |
|---|---|---|---|---|---|
| command-bar-history.png | `windows/helix/states/command-bar-history.json` from `origin/helix/W25a-history` (57e1c74) | none; profile: `history.json` = {"history": {"entries": {"https://docs.example.com/page": {"lastVisit": 789000050.0, "title": "Docs", "url": "https://docs.example.com/page", "visitCount": 9}, "https://example.com/": {"lastVisit": 789000000.0, "title": "Example Domain", "url": "https://example.com/", "visitCount": 4}, "https://news.example/weekly-recipes-roundup": {"lastVisit": 789000200.0, "title": "Weekly Recipes Roundup", "url": "https://news.example/weekly-recipes-roundup", "visitCount": 1}, "https://recipes.example/": {"lastVisit": 789000400.0, "title": "", "url": "https://recipes.example/", "visitCount": 1}, "https://recipes.example/pasta-carbonara": {"lastVisit": 789000500.0, "title": "Pasta Carbonara Recipe", "url": "https://recipes.example/pasta-carbonara", "visitCount": 5}, "https://www.blog.example/2026/01/recipe-index": {"lastVisit": 789000300.0, "title": "Recipe Index: Weeknight Dinners", "url": "https://www.blog.example/2026/01/recipe-index", "visitCount": 3}, "https://www.cooking.example/recipes/risotto": {"lastVisit": 789000100.0, "title": "Mushroom Risotto", "url": "https://www.cooking.example/recipes/risotto", "visitCount": 2}}}, "version": 1} | `kite ui input '{"keys":"cmd+t"}'`; then `kite ui input '{"text":"recipe"}'`; 1 s later, the capture | Ctrl+T's bar with "recipe" typed: the DuckDuckGo search highlighted, then three pages from history, Pasta Carbonara Recipe — recipes.example/pasta-carbonara, recipes.example (no subtitle: it has no title), Recipe Index: Weeknight Dinners — blog.example/2026/01/recipe-index; no tab rows (no open tab matches) | captured |

## Frames (`kite ui tree '{"match":"SuggestionRowView"}'`, window points)

command-bar-history (after the capture; `command-bar-history.tree.txt` has launch, before and after):

```
Window 17896, 1280×820 pt at 2×. Points from the window's top-left.
<untrusted-page-content source="Kite window">
0.9.0.8 SuggestionRowView [265,371.5 750×50]
0.9.0.9 SuggestionRowView [265,421.5 750×50]
0.9.0.10 SuggestionRowView [265,471.5 750×50]
0.9.0.11 SuggestionRowView [265,521.5 750×50]
</untrusted-page-content>
```

Each state's `kite ui` step output is in `NAME.steps.txt`. Kite's logs, full trees and the build log are in the workflow run's logs artifact (kept 7 days), not on this branch.
