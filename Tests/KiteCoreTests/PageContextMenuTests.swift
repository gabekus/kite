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
            + [.saveLinkAs, .copyLinkAddress, .copyEmailAddress, .back, .forward, .reload, .savePageAs, .print,
               .openImageInNewTab, .saveImageAs, .copyImage, .copyImageAddress, .lookUp, .searchSelection, .copy,
               .copyLinkToHighlight, .speech, .startSpeaking, .stopSpeaking, .viewPageSource, .inspect]
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

    // MARK: Whole menu (Chromium)

    private let page = URL(string: "https://example.com/article")!

    private func titles(_ context: PageContextMenu.Context, host: PageContextMenu.Host = .init()) -> [String] {
        (PageContextMenu.menu(for: context, host: host) ?? []).map { entry in
            guard entry.item != .separator else { return "---" }
            return entry.isEnabled ? entry.title : "(\(entry.title))"
        }
    }

    @Test func pageMenuIsArcsPageAndDeveloperItems() {
        let context = PageContextMenu.Context(pageURL: page, canGoBack: true)
        #expect(titles(context) == [
            "Back", "(Forward)", "Reload", "---", "Save As…", "Print…", "---", "View Page Source", "Inspect",
        ])
    }

    @Test func selectionMenuPutsLookUpAndSearchFirstAndSpeechLast() {
        let context = PageContextMenu.Context(selectionText: "kites\nfly", pageURL: page)
        #expect(titles(context) == [
            "Look Up “kites fly”", "---", "Search Google for “kites fly”", "Copy", "Copy Link to Highlight",
            "Print…", "---", "Inspect", "---", "Speech",
        ])
        let speech = PageContextMenu.menu(for: context, host: .init())!.last!
        #expect(speech.children.map(\.title) == ["Start Speaking", "Stop Speaking"])
        #expect(speech.children.map(\.isEnabled) == [true, false])
        #expect(PageContextMenu.searchURL(context: context)?.absoluteString == "https://www.google.com/search?q=kites%20fly")
    }

    @Test func selectedAddressOffersGoTo() {
        var context = PageContextMenu.Context(selectionText: "example.org/a", pageURL: page, searchEngine: .kagi)
        #expect(PageContextMenu.title(.searchSelection, context: context) == "Go to example.org/a")
        #expect(PageContextMenu.searchURL(context: context)?.absoluteString == "https://example.org/a")
        context.selectionText = "kites"
        #expect(PageContextMenu.title(.searchSelection, context: context) == "Search Kagi for “kites”")
    }

    @Test func longSelectionIsCutAtAWord() {
        let text = String(repeating: "kite ", count: 20)
        let printable = PageContextMenu.printableSelection(text)
        #expect(printable.hasSuffix("kite…"))
        #expect(printable.count <= 50)
    }

    @Test func selectionInALinkKeepsLinkItemsFirstWithoutLookUp() {
        let context = PageContextMenu.Context(linkURL: link, selectionText: "a", pageURL: page)
        let menu = titles(context)
        #expect(menu.first == "Open Link in New Tab")
        #expect(!menu.contains { $0.hasPrefix("Look Up") })
        #expect(Array(menu.suffix(10)) == [
            "Copy Link Address", "---", "Copy", "Copy Link to Highlight", "Search Google for “a”", "Print…", "---",
            "Inspect", "---", "Speech",
        ])
    }

    @Test func linkMenuEndsWithInspect() {
        let menu = titles(PageContextMenu.Context(linkURL: link, pageURL: page))
        #expect(Array(menu.suffix(4)) == ["Save Link As…", "Copy Link Address", "---", "Inspect"])
        #expect(!menu.contains("Back") && !menu.contains("Copy Link Text"))
    }

    @Test func imageMenuIsArcsImageItems() {
        let image = URL(string: "https://example.com/a.png")!
        #expect(titles(PageContextMenu.Context(imageURL: image, pageURL: page)) == [
            "Open Image in New Tab", "Save Image As…", "Copy Image", "Copy Image Address", "---", "Inspect",
        ])
        let both = titles(PageContextMenu.Context(linkURL: link, imageURL: image, pageURL: page))
        #expect(Array(both.suffix(8)) == [
            "Copy Link Address", "---", "Open Image in New Tab", "Save Image As…", "Copy Image", "Copy Image Address",
            "---", "Inspect",
        ])
    }

    @Test func editableContentKeepsTheEnginesMenu() {
        #expect(PageContextMenu.menu(for: .init(selectionText: "a", isEditable: true), host: .init()) == nil)
    }

    @Test func noHighlightLinkOffTheWeb() {
        let context = PageContextMenu.Context(selectionText: "a", pageURL: URL(string: "file:///tmp/a.html"))
        #expect(!titles(context).contains("Copy Link to Highlight"))
    }

    // MARK: Text fragments

    @Test func shortSelectionLinksToTheExactText() {
        let url = TextFragment.link(to: URL(string: "https://example.com/a#intro")!, selection: " Kites, fly-high & far ")
        #expect(url?.absoluteString == "https://example.com/a#intro:~:text=Kites%2C%20fly%2Dhigh%20%26%20far")
    }

    @Test func longSelectionLinksToARange() {
        let words = (1...80).map { "w\($0)" }.joined(separator: " ")
        let url = TextFragment.link(to: URL(string: "https://example.com/a#:~:text=old")!, selection: words)
        #expect(url?.absoluteString == "https://example.com/a#:~:text=w1%20w2%20w3,w78%20w79%20w80")
        let lines = TextFragment.link(to: page, selection: "one two three four\nfive six seven eight")
        #expect(lines?.absoluteString == "https://example.com/article#:~:text=one%20two%20three,six%20seven%20eight")
        #expect(TextFragment.link(to: page, selection: "  \n ") == nil)
    }
}
