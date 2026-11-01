import Foundation
import Testing
@testable import KiteCore

@Suite struct CommandBarFocusTests {
    /// Windows with open command bars sharing one field editor, as SwiftUI's text fields do.
    /// Taking the editor knocks the window that had it back to "no field", which tells it its
    /// first responder changed. Returns how many hand-overs happened before things settled.
    private func settle(owner initialOwner: Int, key: Int?, opening: Int, limit: Int = 1000) -> (handOvers: Int, owner: Int?) {
        var owner: Int? = initialOwner
        var pending: [(window: Int, trigger: CommandBarFocus.Trigger)] = [(opening, .opened)]
        var handOvers = 0
        while !pending.isEmpty, handOvers < limit {
            let (window, trigger) = pending.removeFirst()
            guard owner != window, CommandBarFocus.takesFocus(after: trigger, inFront: window == key) else { continue }
            if let previous = owner { pending.append((previous, .responderChanged)) }
            owner = window
            handOvers += 1
        }
        return (handOvers, owner)
    }

    @Test func twoBackgroundWindowsDontFightOverTheFieldEditor() {
        // g66: ⌘N twice with Kite in the background, two new windows each with the bar open, neither key.
        let result = settle(owner: 1, key: nil, opening: 2)
        #expect(result.handOvers == 1)
        #expect(result.owner == 2)
    }

    @Test func theKeyWindowGetsItsFieldBack() {
        // A background window's bar opening takes the editor once; the key window takes it back, once.
        let result = settle(owner: 1, key: 1, opening: 2)
        #expect(result.handOvers == 2)
        #expect(result.owner == 1)
    }

    @Test func aNewKeyWindowKeepsItsBar() {
        // ⌘N with Kite in front: the new window is key and opens its bar while the old one's is open.
        let result = settle(owner: 1, key: 2, opening: 2)
        #expect(result.handOvers == 1)
        #expect(result.owner == 2)
    }

    @Test func pagesStillLoseTheKeyboardToTheBarInFront() {
        // A page that navigates while the bar is open takes the keyboard; the bar in front takes it back.
        #expect(CommandBarFocus.takesFocus(after: .responderChanged, inFront: true))
        #expect(CommandBarFocus.takesFocus(after: .stillOpen, inFront: true))
        #expect(!CommandBarFocus.takesFocus(after: .stillOpen, inFront: false))
        #expect(CommandBarFocus.takesFocus(after: .becameKey, inFront: true))
    }
}
