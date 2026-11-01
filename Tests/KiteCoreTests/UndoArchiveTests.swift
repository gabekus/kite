import Foundation
import Testing
@testable import KiteCore

@Suite struct UndoArchiveTests {
    @Test func reopensTheTabUndoNamesNotJustTheLast() {
        var state = BrowserState.makeDefault()
        let a = state.openTab(url: URL(string: "https://a.com")!)
        let b = state.openTab(url: URL(string: "https://b.com")!)
        let indexOfA = state.selectedSpace.tabs.firstIndex { $0.id == a }!
        state.close(tab: a)
        state.close(tab: b)
        #expect(state.reopenClosed(tab: a) == a)
        // Back where it was (b is still closed), selected, and out of the archive.
        #expect(state.selectedSpace.tabs.firstIndex { $0.id == a } == min(indexOfA, state.selectedSpace.tabs.count - 1))
        #expect(state.selectedTab?.id == a)
        #expect(!state.archived.contains { $0.tab.id == a })
        #expect(state.recentlyClosed.map(\.tab.id) == [b])
        // Already open: nothing to undo.
        #expect(state.reopenClosed(tab: a) == nil)
        #expect(state.reopenLastClosed() == b)
    }
}
