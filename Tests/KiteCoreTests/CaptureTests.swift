import Foundation
import Testing
@testable import KiteCore

@Suite struct CaptureTests {
    let utc = TimeZone(identifier: "UTC")!
    /// 2026-11-01 15:45:07 UTC.
    let date = Date(timeIntervalSince1970: 1_793_547_907)

    @Test func areaFilenameMatchesArcsSavePanel() {
        #expect(Capture.areaFilename(date: date, timeZone: utc) == "Capture-2026-11-01-154507.png")
    }

    @Test func fullPageFilenameIsTheTitleThenTimeAndDay() {
        #expect(Capture.fullPageFilename(title: "Example Domain", date: date, timeZone: utc) == "Example Domain · 3.45PM · 11-01.png")
    }

    @Test func fullPageTitleKeepsOnlyArcsCharacters() {
        #expect(Capture.sanitizedTitle("Kite: a browser (beta) — v1.2/3") == "Kite a browser beta v123")
        #expect(Capture.sanitizedTitle("snake_case-name") == "snake_case-name")
        #expect(Capture.fullPageFilename(title: "日本語", date: date, timeZone: utc) == "Capture · 3.45PM · 11-01.png")
    }

    @Test func selectionIsNormalisedAndClampedToThePage() {
        let rect = Capture.selection(from: (300, 250), to: (-20, 40), within: 800, 600)
        #expect(rect == Capture.Rect(x: 0, y: 40, width: 300, height: 210))
        let past = Capture.selection(from: (700, 500), to: (900, 700), within: 800, 600)
        #expect(past == Capture.Rect(x: 700, y: 500, width: 100, height: 100))
    }

    @Test func tinyDragsAreClicksNotSelections() {
        #expect(!Capture.isCapturable(Capture.Rect(x: 10, y: 10, width: 3, height: 100)))
        #expect(Capture.isCapturable(Capture.Rect(x: 10, y: 10, width: 4, height: 4)))
    }

    @Test func fullPageScaleStaysUnderTheTextureLimit() {
        #expect(Capture.fullPageScale(contentHeight: 3000, deviceScale: 2) == 1)
        #expect(Capture.fullPageScale(contentHeight: 16_384, deviceScale: 2) == 0.5)
        #expect(Capture.fullPageScale(contentHeight: 0, deviceScale: 2) == 1)
    }
}
