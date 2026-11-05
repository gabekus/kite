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

    private static let pool: String = {
        // KiteMac isn't a test target: PagePool is read from its source.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return ((try? String(contentsOf: root.appendingPathComponent("Sources/KiteMac/Engine/PagePool.swift"), encoding: .utf8)) ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
    }()

    /// From `signature` to the end of that member (the next line closing at four spaces' indent).
    private func body(_ signature: String) throws -> Substring {
        let source = Self.pool
        let start = try #require(source.range(of: signature), "no \(signature)")
        let end = try #require(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        return source[start.upperBound..<end.lowerBound]
    }

    /// Only blank lines and comments between `first` and `then` in `code`.
    private func straightAfter(_ first: String, _ then: String, in code: Substring) throws -> Bool {
        let a = try #require(code.range(of: first), "no \(first)")
        let b = try #require(code.range(of: then, range: a.upperBound..<code.endIndex), "no \(then) after \(first)")
        return code[a.upperBound..<b.lowerBound].split(separator: "\n").allSatisfy {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line.isEmpty || line.hasPrefix("//")
        }
    }

    @Test func thePoolRecordsItRightAfterRegisteringANewPage() throws {
        let makePage = try body("private func makePage(for tab: BrowserTab) -> WebPage {")
        #expect(try straightAfter("let page = engine.makePage(url: url, restoring: restoring)\n        register(page, id: tab.id)\n",
                                  "recordLoadingAtRegistration(page, id: tab.id)", in: makePage))
        // The engine API is unchanged: makePage still takes the URL and starts the load itself.
        #expect(makePage.contains("let page = engine.makePage(url: url, restoring: restoring)"))
        let record = try body("private func recordLoadingAtRegistration(_ page: WebPage, id: UUID) {")
        #expect(record.contains("guard PageRegistration.loadingToRecord(pageIsLoading: page.isLoading, recorded: store.pages[id]?.isLoading) == true else { return }"))
        #expect(record.contains("store.updatePage(id) { $0.isLoading = true }"))
        #expect(record.contains("onLoadingChanged?(id, page, true)"))
    }

    @Test func pagesMadeElsewhereAreRecordedToo() throws {
        // A Peek's page, a popup and Little Kite's page were made (and may be loading) before this pool listened.
        let existing = try body("func register(existing page: WebPage, id: UUID, profileDirectory: String?) {")
        #expect(existing.contains("recordLoadingAtRegistration(page, id: id)"))
        let adopt = try body("func adopt(_ page: WebPage, profileDirectory: String? = nil) -> UUID {")
        #expect(adopt.contains("recordLoadingAtRegistration(page, id: id)"))
        let openTab = try body("func openTab(with page: WebPage, url: URL? = nil, opener: UUID? = nil, source: UUID? = nil, profileDirectory: String? = nil) {")
        // After the tab exists in the store.
        let added = try #require(openTab.range(of: "store.mutateWithoutUndo { state in"))
        let recorded = try #require(openTab.range(of: "recordLoadingAtRegistration(page, id: newID)"))
        #expect(added.upperBound <= recorded.lowerBound)
    }

    @Test func aSaveWithNoStateRemovesTheOldFile() throws {
        // A page with nothing committed has no state (PageRestore): an older file must not restore what's gone.
        let save = try body("private func saveHistory(of id: UUID) {")
        #expect(save.contains("guard let state = page.hibernationState() as? Data else {\n            historyFiles?.remove(tab: id)\n            return\n        }"))
    }
}
