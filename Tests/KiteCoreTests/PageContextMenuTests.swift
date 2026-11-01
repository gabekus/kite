import Foundation
import Testing
@testable import KiteCore

@Suite struct PageContextMenuTests {
    private let link = URL(string: "https://example.com/a")!

    @Test func linkItemsFollowArcsOrder() {
        let items = PageContextMenu.linkItems(for: link, host: .init())
        #expect(items == [
            .open(.newTab), .open(.newWindow), .open(.splitView), .open(.littleKite), .open(.incognitoWindow),
            .separator, .saveLinkAs, .copyLinkAddress, .separator,
        ])
        #expect(items.map(PageContextMenu.title) == [
            "Open Link in New Tab", "Open Link in New Window", "Open Link in Split View", "Open Link in Little Kite",
            "Open Link in Incognito Window", "", "Save Link As…", "Copy Link Address", "",
        ])
    }

    @Test func littleKiteHasNoSplitOrLittleKiteItems() {
        let items = PageContextMenu.linkItems(for: link, host: .littleKite)
        #expect(!items.contains(.open(.splitView)))
        #expect(!items.contains(.open(.littleKite)))
        #expect(items.first == .open(.newTab))
    }

    @Test func incognitoDisablesOpenInIncognito() {
        let host = PageContextMenu.Host(showsLittleKite: false, isIncognito: true)
        #expect(!PageContextMenu.isEnabled(.open(.incognitoWindow), host: host))
        #expect(PageContextMenu.isEnabled(.open(.newTab), host: host))
        #expect(!PageContextMenu.linkItems(for: link, host: host).contains(.open(.littleKite)))
    }

    @Test func fullSplitDisablesSplitItem() {
        let host = PageContextMenu.Host(canAddSplitPane: false)
        #expect(PageContextMenu.linkItems(for: link, host: host).contains(.open(.splitView)))
        #expect(!PageContextMenu.isEnabled(.open(.splitView), host: host))
    }

    @Test func mailtoCopiesTheAddress() {
        let mail = URL(string: "mailto:someone%40x@example.com?subject=hi")!
        let items = PageContextMenu.linkItems(for: mail, host: .init())
        #expect(items.contains(.copyEmailAddress) && !items.contains(.copyLinkAddress))
        #expect(PageContextMenu.copiedText(for: .copyEmailAddress, url: mail) == "someone@x@example.com")
        #expect(PageContextMenu.copiedText(for: .copyLinkAddress, url: link) == "https://example.com/a")
    }

    @Test func commandIDsRoundTrip() {
        let items: [PageContextMenu.Item] = PageContextMenu.LinkTarget.allCases.map(PageContextMenu.Item.open)
            + [.saveLinkAs, .copyLinkAddress, .copyEmailAddress]
        #expect(Set(items.map(PageContextMenu.commandID)).count == items.count)
        for item in items { #expect(PageContextMenu.item(commandID: PageContextMenu.commandID(item)) == item) }
        #expect(PageContextMenu.item(commandID: 0) == nil)
    }

    @Test func openLinkInSplitAddsAFocusedPaneWithTheLink() {
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        let first = state.openTab(url: URL(string: "https://one.example"))
        state.select(tab: first)
        #expect(state.canAddSplitPane)
        let pane = UUID()
        #expect(state.openLinkInSplit(url: link, id: pane) == .added(pane))
        #expect(state.selectedSplit?.tabIDs == [first, pane])
        #expect(state.tab(pane)?.url == link)
        for _ in 0..<2 { state.openLinkInSplit(url: link) }
        #expect(!state.canAddSplitPane)
        #expect(state.openLinkInSplit(url: link) == .full)
    }
}
