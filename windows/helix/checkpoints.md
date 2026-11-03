# Kite for Windows checkpoints

The ordered plan Helix works through (docs/helix.md). Status: planned →
approved → in progress → in review (#PR) → done (#PR). Gabe approves or
reorders; the agent proposes more as earlier ones land. W0–W3a share one branch
(windows-shell, #260) because they were bootstrapped together; from W3 each checkpoint
gets its own `helix/W<n>-…` branch.

| id | checkpoint | ports (Mac) | status |
|---|---|---|---|
| W0 | Win32 window, profile path, CI launch | AppDelegate.supportDirectory, BrowserWindowController (window sizes) | in review (#260) [UI gate not run: nothing to compare until W3 draws] |
| W1 | Model core: tabs, folders, spaces, themes, favorites per profile, session.json shared with the Mac, `kitecore` | KiteCore Models, BrowserState (open, select, spaces), Profiles (favorites), SessionStore, URLInput | in review (#260) |
| W2 | UI gate plumbing: Windows `--capture`, `--window-size`, `--capture-scale`; Mac `KITE_WINDOW_SIZE`; first `states/` fixture | `kite ui capture` | in review (#260) [from W3 (#261) CI runs the 1× and 2× captures on its 100% display; the Mac side needs Gabe's Mac] |
| W3a | Theme colour math (OKLab, lightness, glow, accent) | Theme.swift | in review (#260) |
| W3 | DirectComposition root and the theme backdrop (HLSL port of Kite.metal), drawing only on change, rebuilt after a lost GPU; `--capture` saves the window's presented frame at a set scale | KiteMac/Metal, Shaders/Kite.metal | in progress (#261) |
| W3b | Full-size content: the backdrop under the title bar with Windows' caption buttons over it, like the Mac's `.fullSizeContentView` with a transparent title bar | BrowserWindowController (styleMask, titlebar) | planned |
| W4 | Sidebar skeleton: space title, pinned and unpinned rows from the session, static; `--capture` reads the composed window once there's more than one visual | Views/SidebarView.swift, ArcMetrics.swift | planned |
| W5 | Closing, archiving and reopening tabs | BrowserState close/reopen/archive, Archive.swift | planned [a tab Kite closes goes through DoClose like a page closing itself: mark Kite's own closes so they don't also report pageClosed; drop a self-closed popup's tab from the session; move W6's popup handback (opener, else the neighbouring tab, as BrowserState.close) into core with tests; port PagePool's live-page cap (maxLiveTabs 6, least recently used discarded, discard on a profile change) before tab switching lands] |
| W6 | CEF windowed: one browser per tab, the selected tab's page on the content card (right of the sidebar's 240pt, 10pt inset), popups hosted as tabs with their opener, titles and addresses saved to the session; `--smoke-test` waits for the first page | Engine/ChromiumEngine.swift, CEFBridge (KCRuntime, KCBrowser) | in progress (helix/W6-cef) [moved ahead of W4–W5 at Gabe's ask, 2026-11-03; the card's 6pt corners wait for W10's off-screen pages] |
| W6b | Chromium's sandbox: CEF's bootstrap executable with Kite as its DLL, as the Mac's helpers enter the sandbox | KiteHelper/main.mm | planned [build the wrapper with USE_SANDBOX=ON again and give Kite the same CEF_API_VERSION; the helpers load Kite's DLL under win32k lockdown, so delay-load user32/shell32/ole32 and everything else the helper path doesn't touch] |
| W7 | Command bar (Ctrl+T): URL input and tab search | Views/CommandBarView.swift, CommandSearch.swift, TabSearch.swift | planned [the window's focus goes to the page today (WM_SETFOCUS → the browser); the command bar needs a focus block like the Mac's `focusBlocked`] |
| W8 | Keyboard shortcuts (Ctrl in place of ⌘) | MainMenu.swift, KeyBindings.swift | planned |
| W9 | Spaces switching and swipe | SpaceSwipe.swift, sidebar space bar | planned |
| W10 | CEF off-screen spike: shared D3D11 texture in the composition tree, frame time, input latency | docs/windows.md Rendering | planned [keep multi_threaded_message_loop: OnAcceleratedPaint runs on CEF's thread and its texture goes back to the pool when it returns, so copy and present each page there, on its own D3D11 device or a multithread-protected context; WasHidden from Kite's own occlusion tracking, so a covered window stops drawing too] |
