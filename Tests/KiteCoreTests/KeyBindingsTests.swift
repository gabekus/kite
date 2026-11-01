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

    @Test func prioritiesDefaultToArcs() {
        let bindings = KeyBindings()
        #expect(bindings.priority(for: "newTab") == .overrideWebView)
        #expect(bindings.priority(for: "addSplitView") == .promptAfterConsumedByWebView)
        #expect(bindings.priority(for: "find") == .low)
        #expect(bindings.priority(for: "askClaude") == .low)
    }

    @Test func priorityKeepsTheShortcutAndShortcutKeepsThePriority() {
        var bindings = KeyBindings()
        bindings.setPriority(.low, for: "newTab", shortcut: KeyShortcut("t", [.command]))
        #expect(bindings.override(for: "newTab") == KeyBindingOverride(action: "newTab", shortcut: KeyShortcut("t", [.command]), priority: .low))
        bindings.setShortcut(cmdL, for: "newTab")
        #expect(bindings.priority(for: "newTab") == .low)
        #expect(bindings.override(for: "newTab")?.shortcut == cmdL)
        // Back to the default priority: none stored.
        bindings.setPriority(.overrideWebView, for: "newTab", shortcut: cmdL)
        #expect(bindings.override(for: "newTab")?.priority == nil)
        #expect(bindings.override(for: "newTab")?.shortcut == cmdL)
    }

    @Test func readsFilesFromBeforePriorities() throws {
        let old = #"{"version":1,"userOverrides":[{"action":"addSplitView","shortcut":{"key":"l","modifiers":["command"]},"source":"arc"}]}"#
        let bindings = try JSONDecoder().decode(KeyBindings.self, from: Data(old.utf8))
        #expect(bindings.override(for: "addSplitView") == KeyBindingOverride(action: "addSplitView", shortcut: cmdL, source: .arc))
        let unknown = #"{"version":1,"userOverrides":[{"action":"pinTab","source":"user","priority":"somethingNew"}]}"#
        #expect(try JSONDecoder().decode(KeyBindings.self, from: Data(unknown.utf8)).priority(for: "pinTab") == .promptAfterConsumedByWebView)
    }

    @Test func secondPressRunsKitesCommand() {
        var gate = ShortcutPriorityGate()
        let r1 = gate.press("pinTab", window: 1, at: 10, isRepeat: false)
        #expect(!r1)
        let r2 = gate.pageConsumed("pinTab", window: 1, pressedAt: 10)
        #expect(r2)
        let r3 = gate.pageConsumed("pinTab", window: 1, pressedAt: 10)
        #expect(!r3)
        // Held down: repeats don't count.
        let r4 = gate.press("pinTab", window: 1, at: 10.5, isRepeat: true)
        #expect(!r4)
        let r5 = gate.press("pinTab", window: 1, at: 12, isRepeat: false)
        #expect(r5)
        // Then it starts over.
        let r6 = gate.press("pinTab", window: 1, at: 12.5, isRepeat: false)
        #expect(!r6)
    }

    @Test func secondPressOnlyCountsSoonInTheSameWindowAfterAKeptKey() {
        var gate = ShortcutPriorityGate()
        _ = gate.press("pinTab", window: 1, at: 10, isRepeat: false)
        let r7 = gate.press("pinTab", window: 2, at: 11, isRepeat: false)
        #expect(!r7)
        let r8 = gate.press("pinTab", window: 2, at: 20, isRepeat: false)
        #expect(!r8)
        // The page passed it on: the menu ran it, so there's nothing to ask.
        gate.commandRan("pinTab")
        let r9 = gate.pageConsumed("pinTab", window: 2, pressedAt: 20)
        #expect(!r9)
        let r10 = gate.press("pinTab", window: 2, at: 21, isRepeat: false)
        #expect(!r10)
        #expect(ShortcutPriorityGate.prompt(shortcut: KeyShortcut("d", [.command]), title: "Pin Tab") == "Press ⌘D again to Pin Tab")
        #expect(ShortcutPriorityGate.prompt(shortcut: cmdL, title: "Print…") == "Press ⌘L again to Print")
    }

    @Test func onlyModifiedShortcutsAreSafeKeyEquivalents() {
        #expect(cmdL.isSafeKeyEquivalent)
        #expect(KeyShortcut("e", [.option]).isSafeKeyEquivalent)
        #expect(!KeyShortcut("e", []).isSafeKeyEquivalent)
        #expect(!KeyShortcut("e", [.shift]).isSafeKeyEquivalent)
        #expect(!KeyShortcut("escape", []).isSafeKeyEquivalent)
    }
}
