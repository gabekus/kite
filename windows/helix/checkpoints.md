# Kite for Windows checkpoints

The ordered plan Helix works through (docs/helix.md). Status: planned →
approved → in progress → done. Gabe approves or reorders; the agent proposes
more as earlier ones land.

| id | checkpoint | ports (Mac) | status |
|---|---|---|---|
| W0 | Win32 window, profile path, CI launch | AppDelegate.supportDirectory | done (#260) |
| W1 | Model core: tabs, folders, spaces, themes, session.json shared with the Mac, `kitecore` | KiteCore Models, BrowserState (open, select, spaces), SessionStore, URLInput | done (#260) |
| W2 | `--capture` and `--window-size` for the UI gate; first `states/` fixture | `kite ui capture` | in review (#260) |
| W3 | DirectComposition root and the theme backdrop (HLSL port of Kite.metal), drawing only on change | KiteMac/Metal, Shaders/Kite.metal, Theme.swift (OKLab) | planned |
| W4 | Sidebar skeleton: space title, pinned and unpinned rows from the session, static | Views/SidebarView.swift, ArcMetrics.swift | planned |
| W5 | Closing, archiving and reopening tabs | BrowserState close/reopen/archive, Archive.swift | planned |
| W6 | CEF windowed: one browser per tab, page beside the sidebar | Engine/ChromiumEngine.swift, CEFBridge | needs CEF download OK |
| W7 | Command bar (Ctrl+T): URL input and tab search | Views/CommandBarView.swift, CommandSearch.swift, TabSearch.swift | planned |
| W8 | Keyboard shortcuts (Ctrl in place of ⌘) | MainMenu.swift, KeyBindings.swift | planned |
| W9 | Spaces switching and swipe | SpaceSwipe.swift, sidebar space bar | planned |
| W10 | CEF off-screen spike: shared D3D11 texture in the composition tree, frame time, input latency | docs/windows.md Rendering | planned |
