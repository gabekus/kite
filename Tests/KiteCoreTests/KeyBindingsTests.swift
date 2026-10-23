import Foundation
import Testing
@testable import KiteCore

@Suite struct KeyBindingsTests {
    let shiftCmdS = KeyShortcut("s", [.shift, .command])
    let cmdL = KeyShortcut("l", [.command])

    @Test func displaysLikeMenus() {
        #expect(shiftCmdS.displayString == "⇧⌘S")
        #expect(KeyShortcut("right", [.option, .command]).displayString == "⌥⌘→")
        #expect(KeyShortcut("C", [.control, .command, .shift]).displayString == "⌃⇧⌘C")
    }

    @Test func roundTripsThroughJSON() throws {
        var bindings = KeyBindings()
        bindings.set(KeyBindingOverride(action: "addSplitView", shortcut: cmdL, source: .arc))
        bindings.set(KeyBindingOverride(action: "toggleSidebar", shortcut: nil))
        let data = try JSONEncoder().encode(bindings)
        #expect(try JSONDecoder().decode(KeyBindings.self, from: data) == bindings)
    }

    @Test func oneOverridePerAction() {
        var bindings = KeyBindings()
        bindings.set(KeyBindingOverride(action: "nextSpace", shortcut: cmdL))
        bindings.set(KeyBindingOverride(action: "nextSpace", shortcut: shiftCmdS))
        #expect(bindings.userOverrides.count == 1)
        #expect(bindings.override(for: "nextSpace")?.shortcut == shiftCmdS)
        bindings.reset("nextSpace")
        #expect(bindings.userOverrides.isEmpty)
    }

    @Test func overrideTakesTheShortcutFromOtherCommands() {
        let defaults: [String: KeyShortcut?] = [
            "openLocation": cmdL,
            "addSplitView": nil,
            "toggleSidebar": KeyShortcut("s", [.command]),
        ]
        let bindings = KeyBindings(userOverrides: [
            KeyBindingOverride(action: "addSplitView", shortcut: cmdL),
            KeyBindingOverride(action: "toggleSidebar", shortcut: nil),
            KeyBindingOverride(action: "notAKiteCommand", shortcut: shiftCmdS),
        ])
        let resolved = bindings.resolve(defaults: defaults)
        #expect(resolved["addSplitView"] == .some(cmdL))
        #expect(resolved["openLocation"] == .some(nil))
        #expect(resolved["toggleSidebar"] == .some(nil))
        #expect(resolved["notAKiteCommand"] == nil)
    }
}
