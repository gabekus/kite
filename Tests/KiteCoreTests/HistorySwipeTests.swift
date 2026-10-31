import Foundation
import Testing
@testable import KiteCore

@Suite struct HistorySwipeTests {
    @Test func decidesDirectionFromScrollDeltas() {
        // Too little movement to tell yet.
        #expect(HistorySwipe.direction(dx: 3, dy: 0) == nil)
        #expect(!HistorySwipe.isDecided(dx: 3, dy: 1))
        // Content pulled right goes back; pushed left goes forward (Chromium: deltaX < 0 is forwards).
        #expect(HistorySwipe.direction(dx: 20, dy: 0) == .back)
        #expect(HistorySwipe.direction(dx: -20, dy: 2) == .forward)
        // Too vertical: |dy| * 1.3 > |dx|.
        #expect(HistorySwipe.direction(dx: 20, dy: 16) == nil)
        #expect(HistorySwipe.isDecided(dx: 20, dy: 16))
        #expect(HistorySwipe.direction(dx: 0, dy: -30) == nil)
    }

    @Test func navigatesOnlyWhenThePageCantScrollThatWay() {
        let flat = HistorySwipe.PageScroll(canScrollLeft: false, canScrollRight: false, blocksOverscroll: false)
        #expect(flat.allowsNavigation(.back) && flat.allowsNavigation(.forward))
        let atStart = HistorySwipe.PageScroll(canScrollLeft: false, canScrollRight: true, blocksOverscroll: false)
        #expect(atStart.allowsNavigation(.back))
        #expect(!atStart.allowsNavigation(.forward))
        let middle = HistorySwipe.PageScroll(canScrollLeft: true, canScrollRight: true, blocksOverscroll: false)
        #expect(!middle.allowsNavigation(.back) && !middle.allowsNavigation(.forward))
        let contained = HistorySwipe.PageScroll(canScrollLeft: false, canScrollRight: false, blocksOverscroll: true)
        #expect(!contained.allowsNavigation(.back))
    }

    @Test func parsesTheRendererAnswer() {
        #expect(HistorySwipe.PageScroll(["left": true, "right": false, "blocked": false])
            == HistorySwipe.PageScroll(canScrollLeft: true, canScrollRight: false, blocksOverscroll: false))
        #expect(HistorySwipe.PageScroll(nil) == nil)
        #expect(HistorySwipe.PageScroll("nope") == nil)
    }

    @Test func progressReachesOneAtThirtyPercentOfTheWidth() {
        let half = HistorySwipe.progress(dx: 150, direction: .back, pageWidth: 1000)
        #expect(half.progress == 0.5 && !half.finished)
        let done = HistorySwipe.progress(dx: -300, direction: .forward, pageWidth: 1000)
        #expect(done.progress == 1 && done.finished)
        // Moving the wrong way doesn't go negative.
        #expect(HistorySwipe.progress(dx: -50, direction: .back, pageWidth: 1000).progress == 0)
        #expect(HistorySwipe.progress(dx: 900, direction: .back, pageWidth: 1000).progress == 1)
    }

    @Test func shieldMatchesChromiumsHistoryOverlay() {
        // Hidden off the left edge at the start, alpha floored at 0.25.
        let start = HistorySwipe.shield(direction: .back, progress: 0, finished: false, parentWidth: 800, parentHeight: 600)
        #expect(start.frame == HistorySwipe.Frame(x: -140, y: 230, width: 140, height: 140))
        #expect(start.alpha == 0.25)
        // Halfway: 35 pt showing, alpha follows progress.
        let mid = HistorySwipe.shield(direction: .back, progress: 0.5, finished: false, parentWidth: 800, parentHeight: 600)
        #expect(mid.frame.x + mid.frame.width == 35 && mid.alpha == 0.5)
        // Near the end alpha caps at 0.65; once finished it grows 10 pt taller at 0.75.
        #expect(HistorySwipe.shield(direction: .back, progress: 0.9, finished: false, parentWidth: 800, parentHeight: 600).alpha == 0.65)
        let done = HistorySwipe.shield(direction: .forward, progress: 1, finished: true, parentWidth: 800, parentHeight: 600)
        #expect(done.frame == HistorySwipe.Frame(x: 730, y: 225, width: 140, height: 150))
        #expect(done.alpha == 0.75)
    }

    @Test func scrollabilityScriptCarriesThePoint() {
        let script = HistorySwipe.scrollabilityScript(x: 12.5, y: 40)
        #expect(script.contains("x = 12.5, y = 40.0"))
    }
}
