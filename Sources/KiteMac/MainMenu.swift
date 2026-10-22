import AppKit
import KiteCore

/// Keyboard shortcuts follow Arc where they don't collide with macOS conventions.
@MainActor
enum MainMenu {
    static func build(target: BrowserWindowController) -> NSMenu {
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

        let left = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        let right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))

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
            item("Hide Kite", #selector(NSApplication.hide(_:)), "h", toTarget: false),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], toTarget: false),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), toTarget: false),
            .separator(),
            item("Quit Kite", #selector(NSApplication.terminate(_:)), "q", toTarget: false),
        ])

        submenu("File", [
            item("New Tab", #selector(BrowserWindowController.newTab(_:)), "t"),
            item("Open Location…", #selector(BrowserWindowController.openLocation(_:)), "l"),
            item("Reopen Closed Tab", #selector(BrowserWindowController.reopenClosedTab(_:)), "t", [.command, .shift]),
            .separator(),
            // Temporary: remove with ArcImportController.swift after Arc shuts down (2026-12-22).
            item("Import from Arc…", #selector(BrowserWindowController.importFromArc(_:))),
            .separator(),
            item("Close Tab", #selector(BrowserWindowController.closeTab(_:)), "w"),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift], toTarget: false),
        ])

        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z", toTarget: false),
            item("Redo", Selector(("redo:")), "z", [.command, .shift], toTarget: false),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x", toTarget: false),
            item("Copy", #selector(NSText.copy(_:)), "c", toTarget: false),
            item("Paste", #selector(NSText.paste(_:)), "v", toTarget: false),
            item("Select All", #selector(NSText.selectAll(_:)), "a", toTarget: false),
        ])

        submenu("View", [
            item("Toggle Sidebar", #selector(BrowserWindowController.toggleSidebar(_:)), "s"),
            .separator(),
            item("Reload Page", #selector(BrowserWindowController.reload(_:)), "r"),
            .separator(),
            item("Actual Size", #selector(BrowserWindowController.actualSize(_:)), "0"),
            item("Zoom In", #selector(BrowserWindowController.zoomIn(_:)), "="),
            item("Zoom Out", #selector(BrowserWindowController.zoomOut(_:)), "-"),
            .separator(),
            item("Dark Page for This Site", #selector(BrowserWindowController.toggleDarkPage(_:)), "d", [.command, .option]),
            darkPagesMenu(),
            .separator(),
            item("Developer Tools", #selector(BrowserWindowController.showDevTools(_:)), "i", [.command, .option]),
        ])

        submenu("History", [
            item("Back", #selector(BrowserWindowController.goBack(_:)), "["),
            item("Forward", #selector(BrowserWindowController.goForward(_:)), "]"),
        ])

        submenu("Tabs", [
            item("Next Tab", #selector(BrowserWindowController.nextTab(_:)), "\t", .control),
            item("Previous Tab", #selector(BrowserWindowController.previousTab(_:)), "\t", [.control, .shift]),
            item("Pin / Unpin Tab", #selector(BrowserWindowController.togglePin(_:)), "d"),
            .separator(),
        ] + (1...9).map { n in
            item(n == 9 ? "Last Tab" : "Tab \(n)", #selector(BrowserWindowController.selectTabNumber(_:)), "\(n)", tag: n)
        })

        submenu("Spaces", [
            item("New Space", #selector(BrowserWindowController.newSpace(_:)), "n", [.command, .shift]),
            item("Next Space", #selector(BrowserWindowController.nextSpace(_:)), right, [.command, .option]),
            item("Previous Space", #selector(BrowserWindowController.previousSpace(_:)), left, [.command, .option]),
            .separator(),
        ] + (1...9).map { n in
            item("Space \(n)", #selector(BrowserWindowController.selectSpaceNumber(_:)), "\(n)", .control, tag: n)
        })

        submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", toTarget: false),
            item("Zoom", #selector(NSWindow.performZoom(_:)), toTarget: false),
        ])

        return main
    }
}
