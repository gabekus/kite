import Foundation
import Testing
@testable import KiteCore

@Suite struct ArcKeyBindingsImportTests {
    // The shape of Arc 1.169's StorableKeyBindings.json.
    let json = #"""
    {
        "userOverrides": [
            {
                "priority": "promptAfterConsumedByWebView",
                "default": {
                    "typeTravelTriggers": ["Add Split View", "Split"],
                    "priority": "promptAfterConsumedByWebView",
                    "shortcut": {"deviceIndependentModifierFlags": 393216, "keyEquivalent": "="}
                },
                "state": {"valid": {"_0": {"keyEquivalent": "l", "deviceIndependentModifierFlags": 1048576}}},
                "action": {"name": "Add Split View", "identifier": "addSplitView"},
                "source": "userDefined"
            },
            {
                "priority": "overrideWebView",
                "default": {"shortcut": {"deviceIndependentModifierFlags": 1048576, "keyEquivalent": "l"}, "priority": "overrideWebView"},
                "state": {"unset": {}},
                "action": {"identifier": "addressBar", "name": "Open Command Bar"},
                "source": "userDefined"
            },
            {
                "priority": "low",
                "default": {"shortcut": {"deviceIndependentModifierFlags": 1572864, "keyEquivalent": "→"}, "priority": "low"},
                "state": {"valid": {"_0": {"deviceIndependentModifierFlags": 1179648, "keyEquivalent": "s"}}},
                "action": {"identifier": "focusNextSpace", "name": "Next Space"},
                "source": "userDefined"
            },
            {
                "priority": "low",
                "default": {"shortcut": {"deviceIndependentModifierFlags": 1048576, "keyEquivalent": "x"}, "priority": "low"},
                "state": {"somethingNew": {}},
                "action": {"identifier": "futureThing", "name": "Future Thing"},
                "source": "userDefined"
            }
        ],
        "version": 1
    }
    """#

    @Test func readsArcOverrides() throws {
        let overrides = try ArcKeyBindingsImport.parse(Data(json.utf8))
        #expect(overrides == [
            KeyBindingOverride(action: "addSplitView", shortcut: KeyShortcut("l", [.command]), source: .arc),
            KeyBindingOverride(action: "openLocation", shortcut: nil, source: .arc),
            KeyBindingOverride(action: "nextSpace", shortcut: KeyShortcut("s", [.shift, .command]), source: .arc),
        ])
    }

    @Test func decodesModifiersAndArrows() {
        let shortcut = ArcKeyBindingsImport.shortcut(.init(keyEquivalent: "→", deviceIndependentModifierFlags: 1572864))
        #expect(shortcut == KeyShortcut("right", [.option, .command]))
        // Caps Lock and other bits are ignored.
        let withCapsLock = ArcKeyBindingsImport.shortcut(.init(keyEquivalent: "=", deviceIndependentModifierFlags: 393216 | 1 << 16))
        #expect(withCapsLock == KeyShortcut("=", [.control, .shift]))
    }

    @Test func skipsShortcutsThatWouldFireWhileTyping() {
        // fn E (Emoji & Symbols) must not come across as a bare E.
        #expect(ArcKeyBindingsImport.shortcut(.init(keyEquivalent: "e", deviceIndependentModifierFlags: 1 << 23)) == nil)
        #expect(ArcKeyBindingsImport.shortcut(.init(keyEquivalent: "e", deviceIndependentModifierFlags: 0)) == nil)
        #expect(ArcKeyBindingsImport.shortcut(.init(keyEquivalent: "E", deviceIndependentModifierFlags: 1 << 17)) == nil)
    }

    @Test func importedOverridesFreeArcsKeys() throws {
        let bindings = KeyBindings(userOverrides: try ArcKeyBindingsImport.parse(Data(json.utf8)))
        let resolved = bindings.resolve(defaults: [
            "openLocation": KeyShortcut("l", [.command]),
            "nextSpace": KeyShortcut("s", [.shift, .command]),
            "savePageAs": nil,
        ])
        #expect(resolved["openLocation"] == .some(nil))
        #expect(resolved["nextSpace"] == .some(KeyShortcut("s", [.shift, .command])))
    }
}
