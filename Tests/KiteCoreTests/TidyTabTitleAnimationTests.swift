import Foundation
import Testing
@testable import KiteCore

@Suite struct TidyTabTitleAnimationTests {
    @Test func masksMatchArcsGradient() {
        // w = 150, f = 70: stops [0, 150/370, 220/370, 1].
        let s = TidyTabTitleAnimation.stops(width: 150)
        #expect(s[0] == 0 && s[3] == 1)
        #expect(abs(s[1] - 150.0 / 370) < 1e-9 && abs(s[2] - 220.0 / 370) < 1e-9)
        #expect(TidyTabTitleAnimation.gradientX(progress: 0) == (start: -1.5, end: 1.5))
        #expect(TidyTabTitleAnimation.gradientX(progress: 1) == (start: 1, end: 3))
        #expect(TidyTabTitleAnimation.gradientX(progress: 2) == (start: 1, end: 3))
    }

    @Test func theNewTitleWipesInFromTheLeft() {
        let w = 150.0
        // At the start the new title is already half there at its left edge and gone further right.
        let left0 = TidyTabTitleAnimation.newTitleOpacity(at: 0, progress: 0, width: w)
        #expect(left0 > 0.4 && left0 < 0.6)
        #expect(TidyTabTitleAnimation.newTitleOpacity(at: 1, progress: 0, width: w) == 0)
        // Halfway the left is in and the right still old; at the end it's all new.
        #expect(TidyTabTitleAnimation.newTitleOpacity(at: 0, progress: 0.5, width: w) == 1)
        #expect(TidyTabTitleAnimation.newTitleOpacity(at: 1, progress: 0.5, width: w) < 1)
        for x in stride(from: 0.0, through: 1, by: 0.1) {
            #expect(TidyTabTitleAnimation.newTitleOpacity(at: x, progress: 1, width: w) == 1)
        }
    }

    @Test func sparksFollowTheEmitterAndDie() {
        let rate = TidyTabTitleAnimation.sparkBirthRate(rowWidth: 240, titleWidth: 120)
        #expect(rate == 150)
        #expect(TidyTabTitleAnimation.sparkCount(rowWidth: 240, titleWidth: 120) == 75)
        // Born in order across the wipe; none after it or once their lifetime is up.
        #expect(TidyTabTitleAnimation.spark(index: 0, time: 0, rowWidth: 240, rowHeight: 34, titleWidth: 120) != nil)
        #expect(TidyTabTitleAnimation.spark(index: 74, time: 0.1, rowWidth: 240, rowHeight: 34, titleWidth: 120) == nil)
        #expect(TidyTabTitleAnimation.spark(index: 75, time: 0.9, rowWidth: 240, rowHeight: 34, titleWidth: 120) == nil)
        #expect(TidyTabTitleAnimation.spark(index: 0, time: 1.2, rowWidth: 240, rowHeight: 34, titleWidth: 120) == nil)
        let late = TidyTabTitleAnimation.spark(index: 70, time: 0.47, rowWidth: 240, rowHeight: 34, titleWidth: 120)
        #expect(late.map { $0.x > 150 } == true)
        #expect(late.map { $0.opacity > 0.9 && $0.size > 2 } == true)
    }
}

@Suite struct TodayClearActionTests {
    private func space(tabs n: Int, selected: Int?) -> (BrowserState, [UUID]) {
        var space = Space(name: "S", icon: "🏠", theme: Theme.presets[0])
        space.tabs = (0..<n).map { BrowserTab(url: URL(string: "https://e.com/\($0)"), title: "T\($0)") }
        space.pinnedItems = [.tab(BrowserTab(url: URL(string: "https://p.com"), title: "P"))]
        space.selectedTabID = selected.map { space.tabs[$0].id } ?? space.pinned.first?.id
        return (BrowserState(spaces: [space]), space.tabs.map(\.id))
    }

    @Test func clearOthersWhenTheSelectedTabIsOneOfSeveralTodayTabs() {
        let (s, _) = space(tabs: 3, selected: 1)
        #expect(s.todayClearAction(inSpace: s.spaces[0].id) == .clearOthers)
        #expect(space(tabs: 1, selected: 0).0.todayClearAction(inSpace: s.spaces[0].id) == .clearAll)
        let pinnedSelected = space(tabs: 3, selected: nil).0
        #expect(pinnedSelected.todayClearAction(inSpace: pinnedSelected.spaces[0].id) == .clearAll)
    }

    @Test func clearOthersKeepsTheSelectedTab() {
        var (s, ids) = space(tabs: 3, selected: 1)
        let cleared = s.clearUnselectedToday(inSpace: s.spaces[0].id)
        #expect(cleared.map(\.id) == [ids[0], ids[2]])
        #expect(s.spaces[0].tabs.map(\.id) == [ids[1]])
        #expect(s.spaces[0].selectedTabID == ids[1])
        // With only the selected tab left it's Clear All again.
        #expect(s.todayClearAction(inSpace: s.spaces[0].id) == .clearAll)
    }

    @Test func clearAllWhenThereIsNothingToKeep() {
        var (s, _) = space(tabs: 2, selected: nil)
        #expect(s.clearUnselectedToday(inSpace: s.spaces[0].id).count == 2)
        #expect(s.spaces[0].tabs.isEmpty)
    }
}
