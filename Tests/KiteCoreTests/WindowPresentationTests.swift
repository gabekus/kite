import Testing
@testable import KiteCore

struct WindowPresentationTests {
    @Test func aRealProfileShowsWindowsAsBefore() {
        #expect(WindowPresentation.decide(testSafe: false)
            == WindowPresentation(order: .keyAndFront, activates: false, level: nil))
        #expect(WindowPresentation.decide(testSafe: false, activate: true, level: 3)
            == WindowPresentation(order: .keyAndFront, activates: true, level: nil))
        #expect(WindowPresentation.decide(testSafe: false, key: false, hasParent: true).order == .front)
    }

    @Test func aTestSafeRunNeverFrontsMakesKeyOrActivates() {
        let shown = WindowPresentation.decide(testSafe: true, activate: true)
        #expect(shown == WindowPresentation(order: .behind, activates: false, level: nil))
        #expect(WindowPresentation.decide(testSafe: true, key: false).order == .behind)
    }

    @Test func aTestSafeRunDropsFloatingAndModalLevelsToNormal() {
        // NSWindow.Level.floating is 3 and .modalPanel 8: either would sit over the user's windows even at the back.
        #expect(WindowPresentation.decide(testSafe: true, level: 3).level == WindowPresentation.normalLevel)
        #expect(WindowPresentation.decide(testSafe: true, level: 8).level == WindowPresentation.normalLevel)
        #expect(WindowPresentation.decide(testSafe: true, level: -1).level == nil)
    }

    @Test func aTestSafeChildWindowStaysJustAboveItsParent() {
        #expect(WindowPresentation.decide(testSafe: true, key: false, hasParent: true).order == .aboveParent)
    }

    @Test func testSafeNeedsBothDiagnosticsAndATestProfile() {
        #expect(WindowPresentation.isTestSafe(environment: ["KITE_DIAGNOSTICS": "1", "KITE_SUPPORT_PATH": "/tmp/k.x"]))
        #expect(!WindowPresentation.isTestSafe(environment: ["KITE_DIAGNOSTICS": "1"]))
        #expect(!WindowPresentation.isTestSafe(environment: ["KITE_SUPPORT_PATH": "/tmp/k.x"]))
        #expect(!WindowPresentation.isTestSafe(environment: ["KITE_DIAGNOSTICS": "0", "KITE_SUPPORT_PATH": "/tmp/k.x"]))
        #expect(!WindowPresentation.runsModals(testSafe: true))
        #expect(WindowPresentation.runsModals(testSafe: false))
    }
}
