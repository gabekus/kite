import Testing
@testable import KiteCore

struct SpacePagingTests {
    @Test func settleIsCriticallyDampedAndLands() {
        #expect(SpaceSwipe.settle(from: 240, elapsed: 0, response: 0.1) == 240)
        // No overshoot: it never crosses rest on the way in.
        var last = 240.0
        for step in 1...40 {
            let x = SpaceSwipe.settle(from: 240, elapsed: Double(step) / 120, response: 0.1)
            #expect(x >= 0 && x <= last)
            last = x
        }
        // Arc's slide: about 97% of the way 0.09s in, at rest by 0.2s.
        #expect(abs(SpaceSwipe.settle(from: 240, elapsed: 0.09, response: 0.1)) < 240 * 0.04)
        #expect(SpaceSwipe.settle(from: 240, elapsed: 0.25, response: 0.1) == 0)
    }

    @Test func builtPagesKeepNeighboursAndTheAnchor() {
        #expect(SpaceSwipe.builtPages(selected: 0, anchor: nil, count: 3) == [0, 1])
        #expect(SpaceSwipe.builtPages(selected: 1, anchor: nil, count: 3) == [0, 1, 2])
        // Mid-settle after landing on 2: the pages left behind stay, nothing new is built.
        #expect(SpaceSwipe.builtPages(selected: 2, anchor: 1, count: 4) == [0, 1, 2])
        // A far jump keeps the old neighbourhood and adds the new space.
        #expect(SpaceSwipe.builtPages(selected: 4, anchor: 0, count: 6) == [0, 1, 4])
        #expect(SpaceSwipe.builtPages(selected: 0, anchor: nil, count: 0) == [])
    }

    @Test func highlightHandsOverWithTheSlide() {
        let built = [0, 1, 2]
        func lit(_ i: Int, _ offset: Double) -> Double {
            SpaceSwipe.highlight(of: i, selected: 1, built: built, offset: offset, pageWidth: 200)
        }
        #expect(lit(1, 0) == 1)
        #expect(lit(2, 0) == 0)
        // Halfway towards the next space.
        #expect(abs(lit(1, -100) - 0.5) < 1e-9)
        #expect(abs(lit(2, -100) - 0.5) < 1e-9)
        #expect(lit(0, -100) == 0)
        // Rubber-banding past the first space keeps it fully lit.
        #expect(SpaceSwipe.highlight(of: 0, selected: 0, built: [0, 1], offset: 60, pageWidth: 200) == 1)
        #expect(lit(1, 0) + lit(0, 0) + lit(2, 0) == 1)
    }
}
