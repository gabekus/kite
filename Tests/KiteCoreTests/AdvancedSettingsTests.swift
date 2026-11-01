import Foundation
import Testing
@testable import KiteCore

@Suite struct AdvancedSettingsTests {
    private func defaults() -> UserDefaults {
        let name = "AdvancedSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func allThreeAreOnUntilTurnedOff() {
        let d = defaults()
        #expect(TabReorderHaptics.isEnabled(in: d))
        #expect(WindowRestore.isEnabled(in: d))
        #expect(PageTopWindowDrag.isEnabled(in: d))
        d.set(true, forKey: TabReorderHaptics.disabledKey)
        d.set(false, forKey: WindowRestore.enabledKey)
        d.set(false, forKey: PageTopWindowDrag.enabledKey)
        #expect(!TabReorderHaptics.isEnabled(in: d))
        #expect(!WindowRestore.isEnabled(in: d))
        #expect(!PageTopWindowDrag.isEnabled(in: d))
    }

    @Test func arcKeyNames() {
        #expect(TabReorderHaptics.disabledKey == "tabReorderingHapticsDisabled")
        #expect(PageTopWindowDrag.enabledKey == "contentWindowDraggingEnabled")
    }

    @Test func bandIsTheTop60PointsLessTheScroller() {
        let w = 800.0
        #expect(PageTopWindowDrag.contains(x: 0, y: 0, cardWidth: w, toolbarHeight: 0))
        #expect(PageTopWindowDrag.contains(x: 785, y: 59.5, cardWidth: w, toolbarHeight: 0))
        #expect(!PageTopWindowDrag.contains(x: 786, y: 10, cardWidth: w, toolbarHeight: 0))
        #expect(!PageTopWindowDrag.contains(x: 100, y: 60, cardWidth: w, toolbarHeight: 0))
        #expect(!PageTopWindowDrag.contains(x: -1, y: 10, cardWidth: w, toolbarHeight: 0))
    }

    @Test func bandStartsBelowTheToolbar() {
        #expect(!PageTopWindowDrag.contains(x: 100, y: 30, cardWidth: 800, toolbarHeight: 40))
        #expect(PageTopWindowDrag.contains(x: 100, y: 40, cardWidth: 800, toolbarHeight: 40))
        #expect(!PageTopWindowDrag.contains(x: 100, y: 59, cardWidth: 800, toolbarHeight: 60))
    }

    @Test func dragStartsPastOnePoint() {
        #expect(!PageTopWindowDrag.startsDrag(dx: 0.6, dy: 0.6))
        #expect(!PageTopWindowDrag.startsDrag(dx: 1, dy: 0))
        #expect(PageTopWindowDrag.startsDrag(dx: 1, dy: 0.5))
    }
}
