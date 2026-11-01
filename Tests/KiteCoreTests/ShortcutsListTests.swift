import Foundation
import Testing
@testable import KiteCore

@Suite struct ShortcutsListTests {
    let cmdL = KeyShortcut("l", [.command])
    let cmdE = KeyShortcut("e", [.command])

    var entries: [ShortcutEntry] {
        [
            ShortcutEntry(id: "addSplitView", title: "Add Split View", menuPath: ["View"], shortcut: cmdL, defaultShortcut: cmdL),
            ShortcutEntry(id: "useSelectionForFind", title: "Use Selection to Find", menuPath: ["Edit", "Find"], shortcut: cmdE, defaultShortcut: cmdE),
            ShortcutEntry(id: "toggleSidebar", title: "Toggle Sidebar", menuPath: ["View"], shortcut: KeyShortcut("s", [.command, .shift]), defaultShortcut: KeyShortcut("s", [.command])),
            ShortcutEntry(id: "openLocation", title: "Open Location…", menuPath: ["File"], shortcut: nil, defaultShortcut: nil),
        ]
    }

    @Test func findsConflictsButNotItself() {
        #expect(ShortcutsList.conflicts(for: cmdL, excluding: "openLocation", in: entries).map(\.id) == ["addSplitView"])
        #expect(ShortcutsList.conflicts(for: cmdL, excluding: "addSplitView", in: entries).isEmpty)
        #expect(ShortcutsList.conflicts(for: nil, excluding: "x", in: entries).isEmpty)
    }

    @Test func describesConflictsLikeArc() {
        let e = entries
        #expect(ShortcutsList.conflictDescription([]) == nil)
        #expect(ShortcutsList.conflictDescription([e[0]]) == "is already in use by “Add Split View”")
        #expect(ShortcutsList.conflictDescription([e[0], e[1]]) == "is already in use by “Add Split View” and one other action")
        #expect(ShortcutsList.conflictDescription([e[0], e[1], e[2]]) == "is already in use by “Add Split View” and 2 other actions")
    }

    @Test func splitsCustomizedFromDefaults() {
        let sections = ShortcutsList.sections(entries, query: "")
        #expect(sections.customized.map(\.id) == ["toggleSidebar"])
        #expect(sections.defaults.map(\.id) == ["addSplitView", "useSelectionForFind", "openLocation"])
    }

    @Test func searchesNamesAndMenus() {
        #expect(ShortcutsList.sections(entries, query: "split").defaults.map(\.id) == ["addSplitView"])
        #expect(ShortcutsList.sections(entries, query: "FIND").defaults.map(\.id) == ["useSelectionForFind"])
        #expect(ShortcutsList.sections(entries, query: "  ").defaults.count == 3)
    }

    @Test func searchesShortcutsInWordsOrSymbols() {
        let ids = { (q: String) in ShortcutsList.sections(self.entries, query: q).defaults.map(\.id) + ShortcutsList.sections(self.entries, query: q).customized.map(\.id) }
        #expect(ids("Command E") == ["useSelectionForFind"])
        #expect(ids("cmd+l") == ["addSplitView"])
        #expect(ids("⇧⌘S") == ["toggleSidebar"])
        #expect(ids("shift") == ["toggleSidebar"])
        // A bare letter searches names only: "x" is in no name, though it's no one's shortcut either.
        #expect(ids("x").isEmpty)
        #expect(ids("l").sorted() == ["addSplitView", "openLocation", "toggleSidebar", "useSelectionForFind"].sorted())
    }

    @Test func parsesShortcutQueries() {
        #expect(ShortcutsList.parseShortcut("Command E")! == ("e", [.command]))
        #expect(ShortcutsList.parseShortcut("ctrl shift tab")! == ("tab", [.control, .shift]))
        #expect(ShortcutsList.parseShortcut("⌘-")! == ("-", [.command]))
        #expect(ShortcutsList.parseShortcut("e") == nil)
        #expect(ShortcutsList.parseShortcut("add split") == nil)
    }
}

@Suite struct ChromeButtonTests {
    @Test func everyButtonIsShownUntilHidden() throws {
        let defaults = try #require(UserDefaults(suiteName: "ChromeButtonTests-\(UUID().uuidString)"))
        #expect(ChromeButton.allCases.allSatisfy { $0.isShown(in: defaults) })
        ChromeButton.darkPage.setShown(false, in: defaults)
        #expect(!ChromeButton.darkPage.isShown(in: defaults))
        #expect(ChromeButton.extensions.isShown(in: defaults))
        ChromeButton.darkPage.setShown(true, in: defaults)
        #expect(defaults.object(forKey: ChromeButton.darkPage.hiddenKey) == nil)
    }
}
