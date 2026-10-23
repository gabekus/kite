# How Arc is built, and what Kite takes from it

An outside-in look at Arc 1.169.0 on Gabe's Mac (22 Oct 2026): text strings,
linked libraries, Info.plist, entitlements, its two `.metallib` files, and
module and resource names. Arc was **not** decompiled, so the techniques are
solid but exact values (spring constants, blur radii, colours) are unknown.
Getting those would need Ghidra and Gabe's explicit OK.

Source: the "What Arc teaches Komado" write-up; full notes on the Mac at
`~/rea-arc/arc-findings.md`. We take approaches, never Arc's code or assets.

Status: ✅ Kite already does this · 🟡 partial · ❌ gap.

## Rendering

| Arc | Kite | Notes |
|---|---|---|
| Theme background is a classic Metal pass: gradient layers offscreen, tiled grain on top, a final pass cuts a hole for the web page. Theme changes crossfade in the shader via a `progress` uniform. | ✅ | `Metal/ThemeView.swift` + `Shaders/Kite.metal` do the same (cutout, from/to grain, `progress`). Arc renders gradients offscreen first; we compute in one fragment pass, which is fine at our sizes. |
| Loading state is a soft edge glow (two colours, inset, intensity, looping `cycleProgress`), not a spinner. | ✅ | `Metal/GlowView.swift`. |
| Plain `NSVisualEffectView` materials, plus an animated `CIGaussianBlur` for transitions. No `CABackdropLayer`/`CAFilter` strings, so no private API. | 🟡 | We use materials. No animated blur transition yet; only worth it if a transition calls for it. |
| Cached bitmaps of tabs stand in during transitions and drags (inferred from module and type names). | ❌ | Needed for tab drag and for space-switch transitions. See *Gaps*. |

## Animation and idle cost

| Arc | Kite | Notes |
|---|---|---|
| A display-link wrapper that stops itself when nothing animates. | ✅ | `ThemeView` only runs its link during a crossfade; PR #3's FrameClock generalises this. |
| One spring manager drives every panel motion (damping, stiffness, settle time). | ❌ | Define two or three named springs once in KiteMac and use them everywhere, rather than per-view `.spring(...)` literals. Values have to be tuned by feel. |
| One shared Reduce Motion modifier for every animation. | 🟡 | Check that the crossfade, glow and sidebar animations all honour `accessibilityDisplayShouldReduceMotion` through one helper. |

## Structure

| Arc | Kite | Notes |
|---|---|---|
| ~140 Swift packages on The Composable Architecture. Side effects behind small `*Client` modules; each screen gets a narrow store; duplicate state updates dropped. | 🟡 | We don't need TCA. The lesson is the narrow observation: a change to one tab shouldn't re-render the whole sidebar. Worth profiling `BrowserStore.onChange` → `sync()` once the sidebar is large (Arc imports can be hundreds of tabs). |
| AppKit underneath (windows, web content, drag and drop, dock), SwiftUI on top, bridged with ~21 `NSViewRepresentable`s and SwiftUIIntrospect. | ✅ | Same split. |

## Window chrome and sidebar

| Arc | Kite | Notes |
|---|---|---|
| Real titlebar hidden behind a custom view; traffic lights moved into the sidebar with their own hover zone; controls dim when the window isn't key. | 🟡 | We use `.fullSizeContentView` + transparent titlebar, so the lights already sit over the sidebar, but at the system position. Missing: repositioning them to line up with the sidebar's first row, following the sidebar when it's hidden or resized, and dimming sidebar controls when the window isn't key. |
| Pinned favourites are a collection view with SwiftUI rows. | — | Owned by the sidebar session. |
| Sidebar saved as one versioned JSON file (`StorableSidebar.json`), items plus separate ordered-ID lists. | 🟡 | Relevant to the Arc importer (`KiteCore/ArcImport.swift`). For our own `SessionStore`: keep a `version` field and order as an ID list so a reorder is one small write and old saves still load. |
| Synced through CloudKit and Firestore side by side. | ❌ | Sync is on the roadmap; Arc shipping both suggests CloudKit alone wasn't enough for them (likely Windows). |
| A full custom drag system: the dragged tab is drawn in its own floating window so it can leave the sidebar smoothly. | ❌ | See *Gaps*. |

## Other features

| Feature | What Arc does | Kite |
|---|---|---|
| Command bar | Ranked by a small model trained on-device from what you pick, with an evaluation step and a fallback ranking. | `TabSearch.swift` is heuristic; a learned re-ranker is a later idea. |
| Little Arc, split view, auto-archive, Boosts | Each its own module. | Tracked in `arc-parity.md`. |
| Updates | Sparkle, beta and stable channels. | Roadmap: Sparkle with signing. |
| Feature flags | LaunchDarkly. | Not needed. |
| Telemetry | Segment, Datadog, Sentry, OpenTelemetry, MetricKit, Firebase. | MetricKit only, no third party. On macOS it delivers diagnostics only (hangs, crashes, CPU and disk-write exceptions); launch and energy metrics are iOS-only, so energy comes from our own benchmark. |

## Gaps worth building

1. **Tab drag with snapshots and a floating window.** On drag start, snapshot
   the row (and optionally the page) to an image, show it in a borderless,
   non-activating child window that follows the cursor, and keep the real
   sidebar static until drop. That lets a tab leave the sidebar (to a new
   window, a split, or another space) without re-laying out SwiftUI on every
   mouse move. Overlaps the sidebar session's area, so coordinate first.
2. **Traffic lights aligned with the sidebar.** Move the standard window
   buttons to sit in the sidebar's top row, re-place them on resize,
   full-screen exit and sidebar toggle, and dim sidebar chrome when the window
   resigns key.
3. **Named springs + one Reduce Motion helper**, so every motion matches.
4. **MetricKit** diagnostics (hangs, crashes, CPU exceptions) saved to the
   support folder. Not energy data: macOS doesn't deliver metric payloads.
