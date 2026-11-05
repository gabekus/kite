import Foundation
import Testing
@testable import KiteCore

struct PageRestoreTests {
    @Test func aPageThatNeverCommittedKeepsNoState() {
        // Its state is an empty back/forward list: restored, the tab would stay blank and never load.
        #expect(!PageRestore.keepsState(hasCurrentItem: false))
        #expect(PageRestore.keepsState(hasCurrentItem: true))
    }

    @Test func aRestoredStateWithNoPageFallsBackToTheTabsURL() {
        // An empty state saved by an older Kite (or anywhere): nothing restored, so load the URL.
        #expect(PageRestore.loadsURLAfterRestoring(hasURL: true, restoredCurrentItem: false, restoredURL: false, restoredLoading: false))
        // A state that restored a page keeps it, back/forward list and all.
        #expect(!PageRestore.loadsURLAfterRestoring(hasURL: true, restoredCurrentItem: true, restoredURL: true, restoredLoading: true))
        #expect(!PageRestore.loadsURLAfterRestoring(hasURL: true, restoredCurrentItem: true, restoredURL: false, restoredLoading: false))
        #expect(!PageRestore.loadsURLAfterRestoring(hasURL: true, restoredCurrentItem: false, restoredURL: true, restoredLoading: false))
        #expect(!PageRestore.loadsURLAfterRestoring(hasURL: true, restoredCurrentItem: false, restoredURL: false, restoredLoading: true))
        // Kite's own pages have no URL to load (the window draws them over a blank page).
        #expect(!PageRestore.loadsURLAfterRestoring(hasURL: false, restoredCurrentItem: false, restoredURL: false, restoredLoading: false))
    }

    @Test func aFindHookRunSaysWhereANewPagesStateCameFrom() {
        #expect(FindTestHook.pageMadeLine(hasURL: true, restoredFrom: .none)
            == "KITE_TEST_FIND: page: made (URL to load: yes, saved state: none)")
        #expect(FindTestHook.pageMadeLine(hasURL: true, restoredFrom: .file)
            == "KITE_TEST_FIND: page: made (URL to load: yes, saved state: Tab History file)")
        #expect(!FindTestHook.pageMadeLine(hasURL: false, restoredFrom: .thisWindow).contains("ready"))
    }

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
    }

    @Test func webKitKeepsAndRestoresOnlyStatesThatHoldAPage() throws {
        let webKit = try source("Sources/KiteMac/Engine/WebKitEngine.swift")
        #expect(webKit.contains("PageRestore.keepsState(hasCurrentItem: webView.backForwardList.currentItem != nil) ? webView.interactionState : nil"))
        let start = try #require(webKit.range(of: "func makePage(url: URL?, restoring state: Any?) -> WebPage {"))
        let end = try #require(webKit.range(of: "\n    }\n", range: start.upperBound..<webKit.endIndex))
        let makePage = webKit[start.upperBound..<end.lowerBound]
        let restore = try #require(makePage.range(of: "page.webView.interactionState = state"))
        let fallback = try #require(makePage.range(of: "if PageRestore.loadsURLAfterRestoring("))
        #expect(restore.upperBound <= fallback.lowerBound)
        #expect(makePage.contains("} else if let url {\n            page.load(url)\n        }"))
    }

    @Test func thePoolStillPrefersTheSameSavedStates() throws {
        // This window's sleeping page, then another window's, then the Tab History file: as before, only logged now.
        let pool = try source("Sources/KiteMac/Engine/PagePool.swift")
        let mine = try #require(pool.range(of: "var restoring = savedState.removeValue(forKey: tab.id)"))
        let other = try #require(pool.range(of: "if restoring == nil, let state = shared?.takeSavedState(tab.id, excluding: self)"))
        let file = try #require(pool.range(of: "if restoring == nil, let state = url.flatMap({ historyFiles?.load(tab: tab.id, url: $0, profile: engine.profileDirectory) })"))
        let made = try #require(pool.range(of: "let page = engine.makePage(url: url, restoring: restoring)"))
        #expect(mine.upperBound <= other.lowerBound && other.upperBound <= file.lowerBound && file.upperBound <= made.lowerBound)
        let runner = try source("Sources/KiteMac/Diagnostics/FindTestHookRunner.swift")
        let log = try #require(runner.range(of: "static func logPageMade(hasURL: Bool, restoredFrom source: PageRestore.Source) {"))
        #expect(runner[log.upperBound...].hasPrefix("\n        guard configured != nil else { return }"))
    }
}
