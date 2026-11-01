import AppKit
import KiteCore

/// Keyboard shortcuts follow Arc where they don't collide with macOS conventions.
@MainActor
enum MainMenu {
    /// `target` is the MenuRouter, which hands each command to the browser window in front.
    static func build(target: AnyObject) -> NSMenu {
        // We provide Enter Full Screen (⌃⌘F) ourselves; stop AppKit adding its fn-F copy.
        UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere")
        let main = TypingSafeMenu()

        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = TypingSafeMenu(title: title)
            items.forEach(menu.addItem)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }

        /// `toTarget: false` sends the action up the responder chain (Edit menu, Quit, etc.).
        func item(
            _ title: String,
            _ action: Selector,
            _ key: String = "",
            _ modifiers: NSEvent.ModifierFlags = .command,
            tag: Int = 0,
            toTarget: Bool = true,
            id: String? = nil
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            // The command's stable name for shortcut overrides (KeyBindings), Arc's where Arc has one.
            item.identifier = id.map { NSUserInterfaceItemIdentifier(rawValue: $0) }
            item.keyEquivalentModifierMask = modifiers
            item.tag = tag
            item.target = toTarget ? target : nil
            return item
        }

        /// A second shortcut for a command: hidden, but its key equivalent still works.
        func alternate(_ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
            let hidden = item("", action, key, modifiers)
            hidden.isHidden = true
            hidden.allowsKeyEquivalentWhenHidden = true
            return hidden
        }

        /// A command Arc offers only in its command bar: hidden from the menu bar, still found by the command bar.
        func commandBarOnly(_ item: NSMenuItem) -> NSMenuItem {
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
            item.representedObject = MenuCommand.commandBarOnly
            return item
        }

        func submenuItem(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let menu = TypingSafeMenu(title: title)
            items.forEach(menu.addItem)
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.submenu = menu
            return parent
        }

        let left = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        let right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))

        func darkPagesMenu() -> NSMenuItem {
            let menu = TypingSafeMenu(title: "Dark Pages")
            let titles: [DarkPagesMode: String] = [.off: "Off", .matchSystem: "Match System", .always: "Always"]
            for (i, mode) in DarkPagesMode.allCases.enumerated() {
                menu.addItem(item(titles[mode]!, #selector(BrowserWindowController.setDarkPagesMode(_:)), tag: i))
            }
            let parent = NSMenuItem(title: "Dark Pages", action: nil, keyEquivalent: "")
            parent.submenu = menu
            return parent
        }

        submenu("Kite", [
            item("About Kite", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), toTarget: false, id: "aboutKite"),
            .separator(),
            // Claude's chat bubble at the bottom of the page; the menu item only carries the shortcut.
            item("Ask Claude", #selector(BrowserWindowController.toggleClaudeBubble(_:)), "j", id: "askClaude"),
            .separator(),
            item("Allow Claude to Control the Browser", #selector(AppDelegate.toggleClaudeControl(_:)), toTarget: false),
            item("Open Claude’s Tabs in a Claude Space", #selector(AppDelegate.toggleClaudeSpace(_:)), toTarget: false),
            item("Record Network for Claude", #selector(AppDelegate.toggleRecordNetwork(_:)), toTarget: false),
            item("Ask Claude in the Claude App", #selector(AppDelegate.toggleClaudeRunsInDesktop(_:)), toTarget: false),
            item("Connect Claude…", #selector(AppDelegate.connectClaudeCode(_:)), toTarget: false),
            // Lets Claude read Kite's own interface (the ui tool) while debugging Kite.
            item("Diagnostics for Claude", #selector(AppDelegate.toggleClaudeDiagnostics(_:)), toTarget: false),
            item("Set as Default Browser", #selector(BrowserWindowController.setAsDefaultBrowser(_:)), id: "defaultBrowser"),
            // Until there's a Settings window.
            item("Open Links from Other Apps in Little Kite", #selector(AppDelegate.toggleLittleKiteLinks(_:)), toTarget: false),
            item("Air Traffic Control…", #selector(AppDelegate.showAirTrafficControl(_:)), toTarget: false, id: "openAirTrafficControl"),
            // Arc Max's "5-Second Previews" (hoverCardsEnabled), off by default as in Arc.
            item("Link Previews (Hold ⇧ over a Link)", #selector(AppDelegate.toggleLinkPreviews(_:)), toTarget: false),
            // Arc: Settings → "Play Arc sound effects" (playUserInterfaceSoundsDisabled), on by default.
            item("Play Kite Sound Effects", #selector(AppDelegate.toggleSoundEffects(_:)), toTarget: false),
            // Arc Max's "Ask on Page" (askOnPageEnabled), off by default as in Arc.
            item("Ask on Page (⌘F)", #selector(AppDelegate.toggleAskOnPage(_:)), toTarget: false),
            // Arc Max's Tidy Tab Titles (renamePinnedTabsEnabled), on as in Gabe's Arc.
            item("Tidy Tab Titles", #selector(AppDelegate.toggleTidyTabTitles(_:)), toTarget: false),
            item("Low Battery Energy Saver (30 fps)", #selector(AppDelegate.toggleEnergySaver(_:)), toTarget: false),
            submenuItem("Archive tabs after", ArchiveInterval.allCases.enumerated().map { i, interval in
                item(interval.title, #selector(AppDelegate.setArchiveInterval(_:)), tag: i, toTarget: false)
            }),
            // Arc's Arc menu: "Import from Another Browser…", no shortcut, just before Check for Updates (read from its menu bar).
            item("Import from Another Browser…", #selector(BrowserWindowController.importFromAnotherBrowser(_:)), id: "importFromAnotherBrowser"),
            // Arc's Arc menu: "Check for Updates…", no shortcut, last item before Services (read from its menu bar).
            item("Check for Updates…", #selector(AppDelegate.checkForUpdates(_:)), toTarget: false, id: "checkForUpdates"),
            .separator(),
            item("Hide Kite", #selector(NSApplication.hide(_:)), "h", toTarget: false, id: "hideKite"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], toTarget: false, id: "hideOthers"),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), toTarget: false, id: "showAll"),
            .separator(),
            item("Warn Before Quitting", #selector(AppDelegate.toggleQuitWarning(_:)), toTarget: false),
            .separator(),
            item("Quit Kite", #selector(AppDelegate.quitKite(_:)), "q", toTarget: false, id: "quitKite"),
        ])

        submenu("File", [
            item("New Tab", #selector(BrowserWindowController.newTab(_:)), "t", id: "newTab"),
            // Arc's File menu: New Window ⌘N, Blank Window ⌃⌘N, New Incognito Window ⇧⌘N (read from its menu bar).
            item("New Window", #selector(MenuRouter.newWindow(_:)), "n", id: "newWindow"),
            item("Blank Window", #selector(MenuRouter.newBlankWindow(_:)), "n", [.command, .control], id: "newBlankWindow"),
            item("New Incognito Window", #selector(MenuRouter.newIncognitoWindow(_:)), "n", [.command, .shift], id: "newIncognitoWindow"),
            // Arc's File menu: "New Little Arc Window", ⌥⌘N, id newLittleBrowserWindow (MainMenu.nib).
            item("New Little Kite Window", #selector(MenuRouter.newLittleKiteWindow(_:)), "n", [.command, .option], id: "newLittleBrowserWindow"),
            // No key, like Gabe's Arc: ⌘L is Add Split View. Clicking the URL pill still edits the URL.
            item("Open Location…", #selector(BrowserWindowController.openLocation(_:)), id: "openLocation"),
            item("Reopen Closed Tab", #selector(BrowserWindowController.reopenClosedTab(_:)), "t", [.command, .shift], id: "reopenClosedTab"),
            .separator(),
            // Temporary: remove with ArcImportController.swift after Arc shuts down (2026-12-22).
            item("Import from Arc…", #selector(BrowserWindowController.importFromArc(_:)), id: "importFromArc"),
            .separator(),
            item("Archive Tab", #selector(BrowserWindowController.closeTab(_:)), "w", id: "archiveTab"),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift], toTarget: false, id: "closeWindow"),
            .separator(),
            item("Share…", #selector(BrowserWindowController.share(_:)), id: "share"),
            // Arc's File menu: Capture…, Capture Full Page (no shortcuts; ids from Arc's shortcut table).
            item("Capture…", #selector(BrowserWindowController.capturePage(_:)), id: "capturePage"),
            item("Capture Full Page", #selector(BrowserWindowController.captureFullPage(_:)), id: "captureFullPage"),
            item("Save Page As…", #selector(BrowserWindowController.savePageAs(_:)), id: "savePageAs"),
            // "Print", no ellipsis, as in Arc's File menu.
            item("Print", #selector(BrowserWindowController.printPage(_:)), "p", id: "printPage"),
            .separator(),
            // 1Password's own shortcut for its popup.
            item("1Password…", #selector(BrowserWindowController.showOnePassword(_:)), "x", [.command, .shift], id: "onePassword"),
        ])

        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z", toTarget: false, id: "undo"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift], toTarget: false, id: "redo"),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x", toTarget: false, id: "cut"),
            item("Copy", #selector(NSText.copy(_:)), "c", toTarget: false, id: "copy"),
            item("Paste", #selector(NSText.paste(_:)), "v", toTarget: false, id: "paste"),
            item("Paste and Match Style", #selector(BrowserWindowController.pasteMatchingStyle(_:)), "v", [.command, .shift], id: "pasteAndMatchStyle"),
            item("Delete", #selector(NSText.delete(_:)), toTarget: false, id: "delete"),
            item("Select All", #selector(NSText.selectAll(_:)), "a", toTarget: false, id: "selectAll"),
            .separator(),
            item("Copy URL", #selector(BrowserWindowController.copyURL(_:)), "c", [.command, .shift], id: "copyCurrentURL"),
            item("Copy URL as Markdown", #selector(BrowserWindowController.copyURLAsMarkdown(_:)), "c", [.command, .shift, .option], id: "copyCurrentURLAsMarkdown"),
            item("Copy URL as Quote", #selector(BrowserWindowController.copyURLAsQuote(_:)), "c", [.command, .shift, .control], id: "copyCurrentURLAsQuote"),
            .separator(),
            submenuItem("Find", [
                item("Find…", #selector(BrowserWindowController.showFind(_:)), "f", id: "find"),
                item("Find Next", #selector(BrowserWindowController.findNext(_:)), "g", id: "findNext"),
                item("Find Previous", #selector(BrowserWindowController.findPrevious(_:)), "g", [.command, .shift], id: "findPrevious"),
                item("Use Selection to Find", #selector(BrowserWindowController.useSelectionForFind(_:)), "e", id: "useSelectionForFind"),
            ]),
            submenuItem("Spelling and Grammar", [
                item("Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":", toTarget: false),
                item("Check Document Now", #selector(NSText.checkSpelling(_:)), ";", toTarget: false),
                .separator(),
                item("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:)), toTarget: false),
                item("Check Grammar With Spelling", #selector(NSTextView.toggleGrammarChecking(_:)), toTarget: false),
                item("Correct Spelling Automatically", #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)), toTarget: false),
            ]),
            submenuItem("Substitutions", [
                item("Show Substitutions", #selector(NSTextView.orderFrontSubstitutionsPanel(_:)), toTarget: false),
                .separator(),
                item("Smart Copy/Paste", #selector(NSTextView.toggleSmartInsertDelete(_:)), toTarget: false),
                item("Smart Quotes", #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)), toTarget: false),
                item("Smart Dashes", #selector(NSTextView.toggleAutomaticDashSubstitution(_:)), toTarget: false),
                item("Smart Links", #selector(NSTextView.toggleAutomaticLinkDetection(_:)), toTarget: false),
                item("Text Replacement", #selector(NSTextView.toggleAutomaticTextReplacement(_:)), toTarget: false),
            ]),
            submenuItem("Transformations", [
                item("Make Upper Case", #selector(NSResponder.uppercaseWord(_:)), toTarget: false),
                item("Make Lower Case", #selector(NSResponder.lowercaseWord(_:)), toTarget: false),
                item("Capitalize", #selector(NSResponder.capitalizeWord(_:)), toTarget: false),
            ]),
            submenuItem("Speech", [
                item("Start Speaking", #selector(NSTextView.startSpeaking(_:)), toTarget: false),
                item("Stop Speaking", #selector(NSTextView.stopSpeaking(_:)), toTarget: false),
            ]),
        ])

        submenu("View", [
            item("Toggle Sidebar", #selector(BrowserWindowController.toggleSidebar(_:)), "s", id: "toggleSidebar"),
            // Retitled "Hide Toolbar" while shown.
            item("Show Toolbar", #selector(BrowserWindowController.toggleToolbar(_:)), "d", [.command, .shift], id: "toggleToolbar"),
            // Arc 1.171's View menu, no shortcut; retitled "Expand Pinned Tabs" while collapsed.
            item("Collapse Pinned Tabs", #selector(BrowserWindowController.togglePinnedSection(_:)), id: "collapsePinnedSection"),
            .separator(),
            item("Stop Loading", #selector(BrowserWindowController.stopLoading(_:)), ".", id: "stopLoading"),
            item("Reload Page", #selector(BrowserWindowController.reload(_:)), "r", id: "reloadPage"),
            item("Force Reload Page", #selector(BrowserWindowController.forceReload(_:)), "r", [.command, .shift], id: "forceReloadPage"),
            item("Clear Cookies and Refresh", #selector(BrowserWindowController.clearCookiesAndRefresh(_:)), id: "clearCookiesAndRefresh"),
            item("Clear Cache and Refresh", #selector(BrowserWindowController.clearCacheAndRefresh(_:)), id: "clearCacheAndRefresh"),
            .separator(),
            // Arc's names and IDs from its MainMenu.nib. ⌘L is Gabe's binding; ⌃⇧= (Arc's default) still works.
            item("Add Split View", #selector(BrowserWindowController.addSplitView(_:)), "l", id: "addSplitView"),
            alternate(#selector(BrowserWindowController.addSplitView(_:)), "=", [.control, .shift]),
            item("Close this Split Pane", #selector(BrowserWindowController.closeSplitPane(_:)), "-", [.control, .shift], id: "removeSplitView"),
            item("Separate Page from Split View", #selector(BrowserWindowController.separateFromSplitView(_:)), id: "separateTabFromSplitView"),
            // Arc's `maximizeCurrentSplitViewPane:`, no shortcut; `expandSplitViewPane` is its command bar ID.
            item("Expand Current Split", #selector(BrowserWindowController.expandCurrentSplit(_:)), id: "expandSplitViewPane"),
        ] + (1...SplitView.maxPanes).map { n in
            // Arc builds these in code and hides them; their default keys aren't in its binary.
            let pane = item("Switch to Split View \(n)", #selector(BrowserWindowController.focusSplitPane(_:)), "\(n)", [.control, .shift], tag: n, id: "switchToSplitView\(n)")
            pane.isHidden = true
            pane.allowsKeyEquivalentWhenHidden = true
            return pane
        } + [
            {
                let next = item("Switch to Next Split View", #selector(BrowserWindowController.focusNextSplitPane(_:)), id: "switchToNextWindowPane")
                next.isHidden = true
                return next
            }(),
            {
                let previous = item("Switch to Previous Split View", #selector(BrowserWindowController.focusPreviousSplitPane(_:)), id: "switchToPreviousWindowPane")
                previous.isHidden = true
                return previous
            }(),
            // Arc's command bar actions for top/bottom splits: not in its menu bar, so hidden here too,
            // but offered in the command bar.
            commandBarOnly(item("Add Vertical Split View", #selector(BrowserWindowController.addVerticalSplitView(_:)), id: "newVerticalSplitView")),
            commandBarOnly(item("Convert to Vertical Split View", #selector(BrowserWindowController.convertToVerticalSplitView(_:)), id: "convertToVerticalSplitView")),
            commandBarOnly(item("Convert to Horizontal Split View", #selector(BrowserWindowController.convertToHorizontalSplitView(_:)), id: "convertToHorizontalSplitView")),
            .separator(),
            item("Actual Size", #selector(BrowserWindowController.actualSize(_:)), "0", id: "actualSize"),
            item("Zoom In", #selector(BrowserWindowController.zoomIn(_:)), "=", id: "zoomIn"),
            item("Zoom Out", #selector(BrowserWindowController.zoomOut(_:)), "-", id: "zoomOut"),
            .separator(),
            item("Dark Page for This Site", #selector(BrowserWindowController.toggleDarkPage(_:)), "d", [.command, .option], id: "darkPageForSite"),
            darkPagesMenu(),
            .separator(),
            item("Block Ads on This Site", #selector(BrowserWindowController.toggleAdblockForSite(_:)), "b", [.command, .option], id: "blockAdsForSite"),
            item("Block Ads and Trackers", #selector(BrowserWindowController.toggleAdblock(_:)), id: "blockAds"),
            .separator(),
            submenuItem("Developer", [
                item("View Source", #selector(BrowserWindowController.viewSource(_:)), "u", [.command, .option], id: "viewSource"),
                item("Developer Tools", #selector(BrowserWindowController.showDevTools(_:)), "i", [.command, .option], id: "developerTools"),
                item("Inspect Elements", #selector(BrowserWindowController.inspectElements(_:)), "c", [.command, .option], id: "inspectElements"),
                item("JavaScript Console", #selector(BrowserWindowController.showJavaScriptConsole(_:)), "j", [.command, .option], id: "javaScriptConsole"),
                item("Network Inspector", #selector(BrowserWindowController.showNetworkInspector(_:)), id: "networkInspector"),
                // Arc 1.169: ⌃D, no ⌘ (its menu's AXMenuItemCmdModifiers is 12).
                item("Turn on Developer Mode for this site", #selector(BrowserWindowController.toggleDeveloperMode(_:)), "d", [.control], id: "toggleDeveloperMode"),
            ]),
            .separator(),
            item("Enter Full Screen", #selector(BrowserWindowController.toggleFullScreenMode(_:)), "f", [.command, .control], id: "fullscreen"),
        ])

        submenu("History", [
            item("Back", #selector(BrowserWindowController.goBack(_:)), "[", id: "goBack"),
            item("Forward", #selector(BrowserWindowController.goForward(_:)), "]", id: "goForward"),
            // Arc 1.169 goes back/forward on ⌘← / ⌘→ in a page (seen on the Mac; not in its binding table,
            // so not remappable there). Chromium offers key equivalents to the page first, so a page
            // text field still moves its caret.
            alternate(#selector(BrowserWindowController.goBack(_:)), left, .command),
            alternate(#selector(BrowserWindowController.goForward(_:)), right, .command),
            .separator(),
            item("View History", #selector(BrowserWindowController.viewHistory(_:)), "y", id: "viewHistory"),
            item("View Archive…", #selector(BrowserWindowController.viewArchive(_:)), id: "viewArchive"),
            item("Clear Archive", #selector(BrowserWindowController.clearArchive(_:)), id: "clearArchive"),
        ])

        submenu("Tabs", [
            item("Pin / Unpin Tab", #selector(BrowserWindowController.togglePin(_:)), "d", id: "pinTab"),
            item("Duplicate Tab", #selector(BrowserWindowController.duplicateTab(_:)), id: "duplicate"),
            // Arc's command-bar action (no menu bar item or default shortcut there); here so the
            // command bar and shortcut overrides find it.
            item("Rename Current Tab…", #selector(BrowserWindowController.renameCurrentTab(_:)), id: "renameCurrentTab"),
            .separator(),
            item("Next Tab", #selector(BrowserWindowController.nextTab(_:)), down, [.command, .option], id: "nextTab"),
            item("Previous Tab", #selector(BrowserWindowController.previousTab(_:)), up, [.command, .option], id: "previousTab"),
            item("Switch to Recent Tab", #selector(BrowserWindowController.selectRecentTab(_:)), "\t", .control, id: "nextRecentTabItem"),
            alternate(#selector(BrowserWindowController.previousTab(_:)), "\t", [.control, .shift]),
            // Arc 1.171's Tabs menu: no shortcut by default; Arc's binding name.
            item("Reveal Tab in Sidebar", #selector(BrowserWindowController.revealTabInSidebar(_:)), id: "revealTabInSidebar"),
            .separator(),
            item("Clear Today", #selector(BrowserWindowController.clearToday(_:)), "k", [.command, .shift], id: "clearUnpinnedTabs"),
            item("Reset all tabs in this Space", #selector(BrowserWindowController.resetAllTabsInSpace(_:)), id: "resetSpace"),
            {
                // Arc has a `resetTab` binding ("Reset tab to original URL.") but no menu item for it:
                // hidden, so a shortcut set for it (or brought over from Arc) still works.
                let reset = item("Reset Tab to Original URL", #selector(BrowserWindowController.resetTab(_:)), id: "resetTab")
                reset.isHidden = true
                reset.allowsKeyEquivalentWhenHidden = true
                return reset
            }(),
            .separator(),
        ] + (1...9).map { n in
            item(n == 9 ? "Last Tab" : "Tab \(n)", #selector(BrowserWindowController.selectTabNumber(_:)), "\(n)", tag: n, id: n == 9 ? "lastTab" : "tab\(n)")
        })

        submenu("Spaces", [
            item("New Space", #selector(BrowserWindowController.newSpace(_:)), id: "newSpace"),
            item("Edit Theme…", #selector(BrowserWindowController.editTheme(_:)), id: "editTheme"),
            item("Rename Space", #selector(BrowserWindowController.renameSpace(_:)), id: "renameSpace"),
            .separator(),
            // ⇧⌘S is Gabe's Arc binding; ⌥⌘→ is Arc's default.
            item("Next Space", #selector(BrowserWindowController.nextSpace(_:)), "s", [.command, .shift], id: "nextSpace"),
            alternate(#selector(BrowserWindowController.nextSpace(_:)), right, [.command, .option]),
            item("Previous Space", #selector(BrowserWindowController.previousSpace(_:)), left, [.command, .option], id: "previousSpace"),
            .separator(),
        ] + (1...9).map { n in
            let space = item("Space \(n)", #selector(BrowserWindowController.selectSpaceNumber(_:)), "\(n)", .control, tag: n, id: "space\(n)")
            // Hidden while there's no such space, but ⌃n still reaches validation once there is.
            space.allowsKeyEquivalentWhenHidden = true
            return space
        })

        submenu("Window", [
            item("Stay On Top", #selector(BrowserWindowController.toggleStayOnTop(_:)), id: "stayOnTop"),
            .separator(),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", toTarget: false, id: "minimize"),
            item("Zoom", #selector(NSWindow.performZoom(_:)), toTarget: false, id: "zoomWindow"),
            .separator(),
            // Arc: Open Library… ⇧⌘L, then View Downloads… ⇧⌘J (MainMenu.nib ids viewLibrary, viewDownloads).
            item("Open Library…", #selector(BrowserWindowController.toggleLibrary(_:)), "l", [.command, .shift], id: "viewLibrary"),
            item("View Downloads…", #selector(BrowserWindowController.viewDownloads(_:)), "j", [.command, .shift], id: "viewDownloads"),
            // Arc: View Media…, no shortcut, after View Easels… (menudump Window).
            item("View Media…", #selector(BrowserWindowController.viewMedia(_:)), id: "viewMedia"),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), toTarget: false, id: "bringAllToFront"),
        ])

        submenu("Help", [
            item("Essential Keyboard Shortcuts", #selector(BrowserWindowController.showKeyboardShortcuts(_:)), id: "essentialKeyboardShortcuts"),
            .separator(),
            submenuItem("Troubleshooting", [
                // Arc: Record Trace, Open Task Manager, —, Reveal Arc Data, Copy Arc Info (no shortcuts).
                item("Open Task Manager", #selector(BrowserWindowController.openTaskManager(_:)), id: "openTaskManager"),
                .separator(),
                item("Reveal Kite Data", #selector(BrowserWindowController.revealDataFolder(_:)), id: "revealKiteData"),
                item("Copy Kite Info", #selector(BrowserWindowController.copyKiteInfo(_:)), id: "copyKiteInfo"),
            ]),
        ])

        return main
    }
}

/// A menu that never takes a keystroke without ⌘, ⌃, ⌥ or fn. AppKit matches a plain E
/// to its Edit › Emoji & Symbols (fn E), and CEF hands the menu every key a page doesn't
/// use, so a plain E anywhere on a page opened the emoji picker.
final class TypingSafeMenu: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !event.modifierFlags.isDisjoint(with: [.command, .control, .option, .function]) else { return false }
        return super.performKeyEquivalent(with: event)
    }
}
