import Foundation
import Testing
@testable import KiteCore

@Suite struct SpaceSwipeTests {
    @Test func pagesFollowTheFingersTowardsANeighbour() {
        var swipe = SpaceSwipe(pageWidth: 300, hasPrevious: true, hasNext: true)
        swipe.move(by: -120, at: 1)
        #expect(swipe.offset == -120)
        #expect(swipe.direction == 1)
        #expect(abs(swipe.progress - 0.4) < 1e-9)
    }

    @Test func pagesNeverPassAWholePage() {
        var swipe = SpaceSwipe(pageWidth: 300, hasPrevious: true, hasNext: true)
        swipe.move(by: 500, at: 1)
        #expect(swipe.offset == 300)
        #expect(swipe.progress == 1)
    }

    @Test func pastTheLastSpaceItRubberBands() {
        var swipe = SpaceSwipe(pageWidth: 300, hasPrevious: true, hasNext: false)
        swipe.move(by: -300, at: 1)
        #expect(swipe.offset < 0 && swipe.offset > -300 * 0.4)
        #expect(swipe.direction == 0)
        #expect(swipe.progress == 0)
        #expect(swipe.landing == 0)
    }

    @Test func halfAPageLandsOnTheNeighbour() {
        var short = SpaceSwipe(pageWidth: 300, hasPrevious: true, hasNext: true)
        short.move(by: 140, at: 1)
        #expect(short.landing == 0)
        var far = SpaceSwipe(pageWidth: 300, hasPrevious: true, hasNext: true)
        far.move(by: 160, at: 1)
        #expect(far.landing == -1)
    }

    @Test func aFlickGoesHoweverShort() {
        var swipe = SpaceSwipe(pageWidth: 300, hasPrevious: true, hasNext: true)
        // 20pt every 10ms: 2000 points a second towards the next space.
        for i in 1...3 { swipe.move(by: -20, at: Double(i) * 0.01) }
        #expect(swipe.landing == 1)
    }

    @Test func aFlickBackStaysPut() {
        var swipe = SpaceSwipe(pageWidth: 300, hasPrevious: true, hasNext: true)
        swipe.move(by: -200, at: 0)
        for i in 1...4 { swipe.move(by: 20, at: Double(i) * 0.01) }
        #expect(swipe.offset == -120)
        #expect(swipe.landing == 0)
    }
}

@Suite struct SpaceEditingTests {
    private func makeState() -> BrowserState {
        BrowserState(spaces: [
            Space(name: "A", icon: "🅰️", theme: .arcDefault),
            Space(name: "B", icon: "🅱️", theme: .arcDefault),
            Space(name: "C", icon: "©️", theme: .arcDefault),
        ])
    }

    @Test func deletingTheSelectedSpaceSelectsTheOneBefore() {
        var state = makeState()
        state.selectSpace(at: 2)
        state.deleteSpace(state.spaces[2].id)
        #expect(state.spaces.map(\.name) == ["A", "B"])
        #expect(state.selectedSpace.name == "B")
    }

    @Test func theLastSpaceStays() {
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: .arcDefault)])
        state.deleteSpace(state.spaces[0].id)
        #expect(state.spaces.count == 1)
    }

    @Test func deletingAnotherSpaceKeepsTheSelection() {
        var state = makeState()
        state.selectSpace(at: 2)
        state.deleteSpace(state.spaces[0].id)
        #expect(state.selectedSpace.name == "C")
    }

    @Test func anIconIsOneCharacter() {
        var state = makeState()
        state.setSpaceIcon(state.spaces[0].id, to: " 🚀🌙 ")
        #expect(state.spaces[0].icon == "🚀")
        state.setSpaceIcon(state.spaces[0].id, to: "symbol:star.fill")
        #expect(state.spaces[0].icon == "symbol:star.fill")
        // Arc's icon picker can remove the icon, leaving a dot.
        state.setSpaceIcon(state.spaces[0].id, to: "  ")
        #expect(state.spaces[0].icon == "")
    }

    @Test func aNewSpaceGoesRightAfterTheCurrentOne() {
        var state = makeState()
        state.selectSpace(at: 0)
        let id = state.insertSpace(name: "", icon: "", theme: .arcDefault)
        #expect(state.spaces.map(\.name) == ["A", "", "B", "C"])
        #expect(state.selectedSpaceID == id)
    }

    @Test func movingASpace() {
        var state = makeState()
        state.moveSpace(state.spaces[0].id, to: 2)
        #expect(state.spaces.map(\.name) == ["B", "C", "A"])
    }
}
