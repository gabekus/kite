# Kite for Windows checkpoints

The ordered plan Helix works through (docs/helix.md). Status: planned →
approved → in progress → in review (#PR) → done (#PR). Gabe approves or
reorders; the agent proposes more as earlier ones land. W0–W3a share one branch
(windows-shell, #260) because they were bootstrapped together; from W3 each checkpoint
gets its own `helix/W<n>-…` branch.

| id | checkpoint | ports (Mac) | status |
|---|---|---|---|
| W0 | Win32 window, profile path, CI launch | AppDelegate.supportDirectory, BrowserWindowController (window sizes) | in review (#260) [UI gate not run: nothing to compare until W3 draws; no 200% Windows display yet] |
| W1 | Model core: tabs, folders, spaces, themes, favorites per profile, session.json shared with the Mac, `kitecore` | KiteCore Models, BrowserState (open, select, spaces), Profiles (favorites), SessionStore, URLInput | in review (#260) |
| W2 | UI gate plumbing: Windows `--capture`, `--window-size`, `--capture-scale`; Mac `KITE_WINDOW_SIZE`; first `states/` fixture | `kite ui capture` | in review (#260) [CI checks the capture's size and pixels at 100%; the 2× run and the Mac side need Gabe's PC and Mac] |
| W3a | Theme colour math (OKLab, lightness, glow, accent) | Theme.swift | in review (#260) |
| W3 | DirectComposition root and the theme backdrop (HLSL port of Kite.metal), drawing only on change, rebuilt after a lost GPU; `--capture` saves the window's presented frame at a set scale | KiteMac/Metal, Shaders/Kite.metal | in progress (#261) |
| W3b | Full-size content: the backdrop under the title bar with Windows' caption buttons over it, like the Mac's `.fullSizeContentView` with a transparent title bar | BrowserWindowController (styleMask, titlebar) | planned |
| W4 | Sidebar skeleton: space title, pinned and unpinned rows from the session, static; `--capture` reads the composed window once there's more than one visual | Views/SidebarView.swift, ArcMetrics.swift | planned |
| W5 | Closing, archiving and reopening tabs | BrowserState close/reopen/archive, Archive.swift | planned |
| W6 | CEF windowed: one browser per tab, page beside the sidebar | Engine/ChromiumEngine.swift, CEFBridge | planned (needs Gabe's OK to download CEF) |
| W7 | Command bar (Ctrl+T): URL input and tab search | Views/CommandBarView.swift, CommandSearch.swift, TabSearch.swift | planned |
| W8 | Keyboard shortcuts (Ctrl in place of ⌘) | MainMenu.swift, KeyBindings.swift | planned |
| W9 | Spaces switching and swipe | SpaceSwipe.swift, sidebar space bar | planned |
| W10 | CEF off-screen spike: shared D3D11 texture in the composition tree, frame time, input latency | docs/windows.md Rendering | planned |
