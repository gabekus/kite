import AppKit
import KiteCore

/// Keyboard shortcuts follow Arc where they don't collide with macOS conventions.
@MainActor
enum MainMenu {
    /// `target` is the MenuRouter, which hands each command to the browser window in front.
    static func build(target: AnyObject) -> NSMenu {
        // We provide Enter Full Screen (⌃⌘F) ourselves; stop AppKit adding its fn-F copy.
        UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere")
        let main = NSMenu()

        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
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
            toTarget: Bool = true
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
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

        func submenuItem(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let menu = NSMenu(title: title)
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
            let menu = NSMenu(title: "Dark Pages")
            let titles: [DarkPagesMode: String] = [.off: "Off", .matchSystem: "Match System", .always: "Always"]
            for (i, mode) in DarkPagesMode.allCases.enumerated() {
                menu.addItem(item(titles[mode]!, #selector(BrowserWindowController.setDarkPagesMode(_:)), tag: i))
            }
            let parent = NSMenuItem(title: "Dark Pages", action: nil, keyEquivalent: "")
            parent.submenu = menu
            return parent
        }

        submenu("Kite", [
            item("About Kite", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), toTarget: false),
            .separator(),
            item("Allow Claude to Control the Browser", #selector(AppDelegate.toggleClaudeControl(_:)), toTarget: false),
            item("Allow Claude to Run JavaScript Without Asking", #selector(AppDelegate.toggleClaudeJavaScript(_:)), toTarget: false),
            item("Open Claude’s Tabs in a Claude Space", #selector(AppDelegate.toggleClaudeSpace(_:)), toTarget: false),
            item("Connect Claude Code…", #selector(AppDelegate.connectClaudeCode(_:)), toTarget: false),
            item("Set as Default Browser", #selector(BrowserWindowController.setAsDefaultBrowser(_:))),
            // Until there's a Settings window.
            item("Low Battery Energy Saver (30 fps)", #selector(AppDelegate.toggleEnergySaver(_:)), toTarget: false),
            .separator(),
            item("Hide Kite", #selector(NSApplication.hide(_:)), "h", toTarget: false),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], toTarget: false),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), toTarget: false),
            .separator(),
            item("Quit Kite", #selector(NSApplication.terminate(_:)), "q", toTarget: false),
        ])

        submenu("File", [
            item("New Tab", #selector(BrowserWindowController.newTab(_:)), "t"),
            item("New Incognito Window", #selector(MenuRouter.newIncognitoWindow(_:)), "n", [.command, .shift]),
            item("Open Location…", #selector(BrowserWindowController.openLocation(_:)), "l"),
            item("Reopen Closed Tab", #selector(BrowserWindowController.reopenClosedTab(_:)), "t", [.command, .shift]),
            .separator(),
            // Temporary: remove with ArcImportController.swift after Arc shuts down (2026-12-22).
            item("Import from Arc…", #selector(BrowserWindowController.importFromArc(_:))),
            .separator(),
            item("Close Tab", #selector(BrowserWindowController.closeTab(_:)), "w"),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift], toTarget: false),
            .separator(),
            item("Share…", #selector(BrowserWindowController.share(_:))),
            item("Save Page As…", #selector(BrowserWindowController.savePageAs(_:))),
            item("Print…", #selector(BrowserWindowController.printPage(_:)), "p"),
        ])

        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z", toTarget: false),
            item("Redo", Selector(("redo:")), "z", [.command, .shift], toTarget: false),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x", toTarget: false),
            item("Copy", #selector(NSText.copy(_:)), "c", toTarget: false),
            item("Paste", #selector(NSText.paste(_:)), "v", toTarget: false),
            item("Paste and Match Style", #selector(BrowserWindowController.pasteMatchingStyle(_:)), "v", [.command, .shift]),
            item("Delete", #selector(NSText.delete(_:)), toTarget: false),
            item("Select All", #selector(NSText.selectAll(_:)), "a", toTarget: false),
            .separator(),
            item("Copy URL", #selector(BrowserWindowController.copyURL(_:)), "c", [.command, .shift]),
            item("Copy URL as Markdown", #selector(BrowserWindowController.copyURLAsMarkdown(_:)), "c", [.command, .shift, .option]),
            item("Copy URL as Quote", #selector(BrowserWindowController.copyURLAsQuote(_:)), "c", [.command, .shift, .control]),
            .separator(),
            submenuItem("Find", [
                item("Find…", #selector(BrowserWindowController.showFind(_:)), "f"),
                item("Find Next", #selector(BrowserWindowController.findNext(_:)), "g"),
                item("Find Previous", #selector(BrowserWindowController.findPrevious(_:)), "g", [.command, .shift]),
                item("Use Selection to Find", #selector(BrowserWindowController.useSelectionForFind(_:)), "e"),
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
            item("Toggle Sidebar", #selector(BrowserWindowController.toggleSidebar(_:)), "s"),
            .separator(),
            item("Stop Loading", #selector(BrowserWindowController.stopLoading(_:)), "."),
            item("Reload Page", #selector(BrowserWindowController.reload(_:)), "r"),
            item("Force Reload Page", #selector(BrowserWindowController.forceReload(_:)), "r", [.command, .shift]),
            item("Clear Cookies and Refresh", #selector(BrowserWindowController.clearCookiesAndRefresh(_:))),
            item("Clear Cache and Refresh", #selector(BrowserWindowController.clearCacheAndRefresh(_:))),
            .separator(),
            item("Actual Size", #selector(BrowserWindowController.actualSize(_:)), "0"),
            item("Zoom In", #selector(BrowserWindowController.zoomIn(_:)), "="),
            item("Zoom Out", #selector(BrowserWindowController.zoomOut(_:)), "-"),
            .separator(),
            item("Dark Page for This Site", #selector(BrowserWindowController.toggleDarkPage(_:)), "d", [.command, .option]),
            darkPagesMenu(),
            .separator(),
            submenuItem("Developer", [
                item("View Source", #selector(BrowserWindowController.viewSource(_:)), "u", [.command, .option]),
                item("Developer Tools", #selector(BrowserWindowController.showDevTools(_:)), "i", [.command, .option]),
                // Both open DevTools for now; picking the element or panel needs the DevTools frontend.
                item("Inspect Elements", #selector(BrowserWindowController.showDevTools(_:)), "c", [.command, .option]),
                item("JavaScript Console", #selector(BrowserWindowController.showDevTools(_:)), "j", [.command, .option]),
            ]),
            .separator(),
            item("Enter Full Screen", #selector(BrowserWindowController.toggleFullScreenMode(_:)), "f", [.command, .control]),
        ])

        submenu("History", [
            item("Back", #selector(BrowserWindowController.goBack(_:)), "["),
            item("Forward", #selector(BrowserWindowController.goForward(_:)), "]"),
        ])

        submenu("Tabs", [
            item("Pin / Unpin Tab", #selector(BrowserWindowController.togglePin(_:)), "d"),
            item("Duplicate Tab", #selector(BrowserWindowController.duplicateTab(_:))),
            .separator(),
            item("Next Tab", #selector(BrowserWindowController.nextTab(_:)), down, [.command, .option]),
            item("Previous Tab", #selector(BrowserWindowController.previousTab(_:)), up, [.command, .option]),
            item("Switch to Recent Tab", #selector(BrowserWindowController.selectRecentTab(_:)), "\t", .control),
            alternate(#selector(BrowserWindowController.previousTab(_:)), "\t", [.control, .shift]),
            .separator(),
            item("Clear Today", #selector(BrowserWindowController.clearToday(_:)), "k", [.command, .shift]),
            .separator(),
        ] + (1...9).map { n in
            item(n == 9 ? "Last Tab" : "Tab \(n)", #selector(BrowserWindowController.selectTabNumber(_:)), "\(n)", tag: n)
        })

        submenu("Spaces", [
            item("New Space", #selector(BrowserWindowController.newSpace(_:))),
            item("Rename Space…", #selector(BrowserWindowController.renameSpace(_:))),
            .separator(),
            // ⇧⌘S is Gabe's Arc binding; ⌥⌘→ is Arc's default.
            item("Next Space", #selector(BrowserWindowController.nextSpace(_:)), "s", [.command, .shift]),
            alternate(#selector(BrowserWindowController.nextSpace(_:)), right, [.command, .option]),
            item("Previous Space", #selector(BrowserWindowController.previousSpace(_:)), left, [.command, .option]),
            .separator(),
        ] + (1...9).map { n in
            let space = item("Space \(n)", #selector(BrowserWindowController.selectSpaceNumber(_:)), "\(n)", .control, tag: n)
            // Hidden while there's no such space, but ⌃n still reaches validation once there is.
            space.allowsKeyEquivalentWhenHidden = true
            return space
        })

        submenu("Window", [
            item("Stay On Top", #selector(BrowserWindowController.toggleStayOnTop(_:))),
            .separator(),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", toTarget: false),
            item("Zoom", #selector(NSWindow.performZoom(_:)), toTarget: false),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), toTarget: false),
        ])

        submenu("Help", [
            item("Keyboard Shortcuts", #selector(BrowserWindowController.showKeyboardShortcuts(_:))),
            .separator(),
            submenuItem("Troubleshooting", [
                item("Reveal Kite Data", #selector(BrowserWindowController.revealDataFolder(_:))),
                item("Copy Kite Info", #selector(BrowserWindowController.copyKiteInfo(_:))),
            ]),
        ])

        return main
    }
}
