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

    @Test func aTestSafeWindowGoesAboveKitesFrontWindowSoKitesOwnOrderMatchesRealUse() {
        // Behind the other apps, but in front of Kite's other windows, as a real show would put it.
        #expect(WindowPresentation.decide(testSafe: true, kiteHasFrontWindow: true).order == .aboveKite)
        #expect(WindowPresentation.decide(testSafe: true, isVisible: true, kiteHasFrontWindow: true).order == .aboveKite)
        // Kite's first window has nothing of Kite's to go above: the back.
        #expect(WindowPresentation.decide(testSafe: true).order == .behind)
    }

    @Test func aVisibleTestSafeWindowWithNothingToGoAboveStaysPut() {
        #expect(WindowPresentation.decide(testSafe: true, isVisible: true).order == .keep)
    }

    @Test func skippedModalsAnswerAsDismissedExceptDownloadsInProgressWhichQuits() {
        #expect(!SkippedModal.alert.proceeds)
        #expect(!SkippedModal.openOrSavePanel.proceeds)
        #expect(!SkippedModal.quitConfirmation.proceeds)
        #expect(SkippedModal.downloadsInProgress.proceeds)
    }

    @Test func theAboutPanelIsTheOneWindowThatAppeared() {
        #expect(AboutPanelLookup.decide(appeared: [7], classMatches: []) == .found(7))
        // The class check only breaks a tie, or finds it when nothing appeared.
        #expect(AboutPanelLookup.decide(appeared: [7, 8], classMatches: [8]) == .found(8))
        #expect(AboutPanelLookup.decide(appeared: [Int](), classMatches: [9]) == .found(9))
    }

    @Test func anUnidentifiedAboutPanelSendsEveryNewWindowToTheBack() {
        // 2026-11-04: a class-only lookup found nothing and left the panel in front of the user's windows.
        #expect(AboutPanelLookup.decide(appeared: [7, 8], classMatches: []) == .orderBehind([7, 8]))
        #expect(AboutPanelLookup.decide(appeared: [7, 8], classMatches: [1, 2]) == .orderBehind([7, 8, 1, 2]))
        #expect(AboutPanelLookup.decide(appeared: [Int](), classMatches: [1, 2]) == .orderBehind([1, 2]))
        #expect(AboutPanelLookup.decide(appeared: [Int](), classMatches: []) == .orderBehind([]))
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
