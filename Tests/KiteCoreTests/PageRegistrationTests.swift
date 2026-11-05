import Foundation
import Testing
@testable import KiteCore

struct PageRegistrationTests {
    @Test func aPageAlreadyLoadingWhenRegisteredShowsAsLoading() {
        // The engine started the load in makePage, before the pool listened: its "loading" event went unheard.
        #expect(PageRegistration.loadingToRecord(pageIsLoading: true, recorded: nil) == true)
        #expect(PageRegistration.loadingToRecord(pageIsLoading: true, recorded: false) == true)
    }

    @Test func otherwiseTheStoreIsLeftAsItIs() {
        // Not loading yet: its load reports itself when it starts. Already recorded: nothing to add.
        #expect(PageRegistration.loadingToRecord(pageIsLoading: false, recorded: nil) == nil)
        #expect(PageRegistration.loadingToRecord(pageIsLoading: false, recorded: true) == nil)
        #expect(PageRegistration.loadingToRecord(pageIsLoading: true, recorded: true) == nil)
    }

    @Test func thePoolRecordsItRightAfterRegisteringANewPage() throws {
        // KiteMac isn't a test target: read PagePool.makePage(for:) from its source.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/KiteMac/Engine/PagePool.swift"), encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let start = try #require(source.range(of: "private func makePage(for tab: BrowserTab) -> WebPage {"))
        let end = try #require(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        let made = try #require(body.range(of: "let page = engine.makePage(url: url, restoring: restoring)\n        register(page, id: tab.id)\n"))
        let check = try #require(body.range(of: "if PageRegistration.loadingToRecord(pageIsLoading: page.isLoading, recorded: store.pages[tab.id]?.isLoading) == true {"))
        // Straight after register (comments between), before anything else touches the page.
        let between = body[made.upperBound..<check.lowerBound]
        #expect(between.split(separator: "\n").allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") })
        let recorded = body[check.upperBound...]
        #expect(recorded.hasPrefix("\n            store.updatePage(tab.id) { $0.isLoading = true }\n            onLoadingChanged?(tab.id, page, true)\n        }"))
        // The engine API is unchanged: makePage still takes the URL and starts the load itself.
        #expect(source.contains("let page = engine.makePage(url: url, restoring: restoring)"))
    }
}
