import Foundation
import Testing
@testable import KiteCore

@Suite struct MarqueeTests {
    @Test func aTitleThatFitsNeverMoves() {
        #expect(!Marquee.overflows(textWidth: 100, availableWidth: 100))
        #expect(Marquee.offset(textWidth: 100, availableWidth: 120, elapsed: 7) == 0)
    }

    @Test func restsUntilTheDelayIsOver() {
        // Before startAt (negative elapsed) Arc clamps to 0.
        #expect(Marquee.offset(textWidth: 300, availableWidth: 150, elapsed: -2) == 0)
        #expect(Marquee.offset(textWidth: 300, availableWidth: 150, elapsed: 0) == 0)
    }

    @Test func oneLoopTakesTwentySecondsAtAnyLength() {
        // cycle = 300 + 32 = 332; half way through the loop at 10 s.
        #expect(Marquee.offset(textWidth: 300, availableWidth: 150, elapsed: 10) == 166)
        #expect(Marquee.offset(textWidth: 300, availableWidth: 150, elapsed: 20) == 0)
        #expect(Marquee.offset(textWidth: 300, availableWidth: 150, elapsed: 25) == 83)
        // A longer title moves faster so the loop still takes 20 s.
        #expect(Marquee.pointsPerSecond(textWidth: 300) == 16.6)
        #expect(Marquee.pointsPerSecond(textWidth: 608) == 32)
    }

    @Test func arcsMiniPlayerNumbers() {
        #expect(Marquee.leadingFade == 4)
        #expect(Marquee.trailingFade == 8)
        #expect(Marquee.gap == 32)
        #expect(Marquee.startDelay == 3)
        #expect(Marquee.speed == 1)
    }
}
