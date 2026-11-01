import Foundation
import Testing
@testable import KiteCore

@Suite struct PortraitCaptureTests {
    let utc = TimeZone(identifier: "UTC")!
    /// 2026-11-01 15:45:07 UTC.
    let date = Date(timeIntervalSince1970: 1_793_547_907)

    @Test func backgroundIsStoredAsArcsOptionalBool() {
        #expect(PortraitCapture.background(stored: nil) == .wallpaper)
        #expect(PortraitCapture.background(stored: false) == .color)
        #expect(PortraitCapture.background(stored: true) == .website)
        for background in PortraitCapture.Background.allCases {
            #expect(PortraitCapture.background(stored: PortraitCapture.stored(background)) == background)
        }
    }

    @Test func paletteIsArcsNineBrandColours() {
        #expect(PortraitCapture.palette.count == 9)
        #expect(PortraitCapture.palette.first == PortraitCapture.RGB(0.95, 0.918, 0.894))
        #expect(PortraitCapture.palette.last?.space == .displayP3)
    }

    @Test func sliderPositionPicksTwoStopsAndAFraction() {
        let start = PortraitCapture.paletteStop(at: 0)
        #expect(start.from == 0 && start.to == 1 && start.fraction == 0)
        let middle = PortraitCapture.paletteStop(at: 0.5)
        #expect(middle.from == 4 && middle.to == 5 && middle.fraction == 0)
        let between = PortraitCapture.paletteStop(at: 0.5625)
        #expect(between.from == 4 && between.to == 5 && abs(between.fraction - 0.5) < 1e-9)
        let end = PortraitCapture.paletteStop(at: 1)
        #expect(end.from == 8 && end.to == 8 && end.fraction == 0)
        let past = PortraitCapture.paletteStop(at: 3)
        #expect(past.from == 8 && past.to == 8)
    }

    @Test func layoutInsetsThePageByAShareOfItsLongerSide() {
        let layout = PortraitCapture.layout(pageWidth: 1000, pageHeight: 600)
        #expect(layout.page == Capture.Rect(x: 60, y: 60, width: 1000, height: 600))
        #expect(layout.width == 1120 && layout.height == 720)
        #expect(layout.cornerRadius == 15)
        #expect(layout.watermarkHeight == 19)
    }

    @Test func filenameIsTimestamped() {
        #expect(PortraitCapture.filename(date: date, timeZone: utc) == "Portrait Capture-2026-11-01-154507.png")
    }
}

@Suite struct TraceRecordingTests {
    let utc = TimeZone(identifier: "UTC")!
    let date = Date(timeIntervalSince1970: 1_793_547_907)

    @Test func durationsAreArcsFour() {
        #expect(TraceRecording.Duration.allCases.map(\.title) == ["5 seconds", "15 seconds", "30 seconds", "1 minute"])
        #expect(TraceRecording.Duration.allCases.map(\.seconds) == [5, 15, 30, 60])
    }

    @Test func countdownLabel() {
        #expect(TraceRecording.remainingLabel(seconds: 14.2) == "15 seconds remaining")
        #expect(TraceRecording.remainingLabel(seconds: 1) == "1 second remaining")
        #expect(TraceRecording.remainingLabel(seconds: 0.3) == "1 second remaining")
    }

    @Test func bundleIsNamedLikeArcs() {
        #expect(TraceRecording.bundleName(date: date, timeZone: utc) == "kite_trace_bundle_2026-11-01_15-45-07")
    }

    @Test func descriptionSaysWhatWasAsked() {
        let text = TraceRecording.descriptionText(issue: "  Slow scrolling ", duration: .thirtySeconds, kiteVersion: "1.0 (5)",
                                                  engine: "Chromium", macOS: "15.6", date: date, timeZone: utc)
        #expect(text.hasPrefix("Issue: Slow scrolling\nDuration: 30 seconds\nStarted: 2026-11-01 15:45:07 Z\n"))
        let empty = TraceRecording.descriptionText(issue: "", duration: .fiveSeconds, kiteVersion: "1", engine: "WebKit",
                                                   macOS: "15", date: date, timeZone: utc)
        #expect(empty.hasPrefix("Issue: (none given)"))
    }
}
