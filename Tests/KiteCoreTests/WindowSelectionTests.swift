import Foundation
import Testing
@testable import KiteCore

@Suite struct WindowSelectionTests {
    func twoSpaces() -> BrowserState {
        let a = Space(name: "A", icon: "🅰️", theme: Theme.presets[0])
        let b = Space(name: "B", icon: "🅱️", theme: Theme.presets[1])
        var state = BrowserState(spaces: [a, b])
        _ = state.openTab(url: URL(string: "https://one.com")!, in: a.id)
        _ = state.openTab(url: URL(string: "https://two.com")!, in: b.id)
        return state
    }

    @Test func selectionRoundTrips() {
        var state = twoSpaces()
        let saved = state.selection
        state.selectSpace(state.spaces[0].id)
        state.select(saved)
        #expect(state.selection == saved)
        let decoded = try? JSONDecoder().decode(WindowSelection.self, from: JSONEncoder().encode(saved))
        #expect(decoded == saved)
    }

    @Test func adoptingKeepsThisWindowsSelection() {
        let window1 = twoSpaces()
        var window2 = window1.newWindowState(on: window1.spaces[0].id)
        #expect(window2.selectedSpaceID == window1.spaces[0].id && window2.selectedTab == nil)
        // Window 1 opens a tab in space A and selects it; window 2 sees the tab, keeps its own selection.
        var changed = window1
        let tab = changed.openTab(url: URL(string: "https://three.com")!, in: window1.spaces[0].id)
        window2 = window2.adoptingContent(of: changed)
        #expect(window2.spaces[0].tabs.contains { $0.id == tab })
        #expect(window2.selectedSpaceID == window1.spaces[0].id)
        #expect(window2.selectedTab == nil)
        // Space B, untouched in window 2, still follows its own (copied) selection.
        #expect(window2.spaces[1].selectedTabID == window1.spaces[1].selectedTabID)
    }

    @Test func closedTabLeavesNothingSelected() {
        var state = twoSpaces()
        let other = state
        let space = state.spaces[1].id
        let tab = state.spaces[1].selectedTabID!
        state.close(tab: tab)
        let adopted = other.adoptingContent(of: state)
        #expect(adopted.spaces[1].selectedTabID == nil)
        #expect(!adopted.allTabIDs.contains(tab))
        #expect(adopted.spaceIndex(space) == 1)
    }

    @Test func deletedSpaceFallsBack() {
        let state = twoSpaces()
        var window = state
        window.selectSpace(state.spaces[1].id)
        var changed = state
        changed.spaces.remove(at: 1)
        let adopted = window.adoptingContent(of: changed)
        #expect(adopted.selectedSpace.id == state.spaces[0].id)
    }
}
