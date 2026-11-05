import Testing
@testable import KiteCore

struct UITextEntryTests {
    @Test func aRealProfileTypesKeyByKeyAsBefore() {
        #expect(UITextEntry.decide(testSafe: false, firstResponderIsCommandBarEditor: true) == .keyEvents)
        #expect(UITextEntry.decide(testSafe: false, firstResponderIsCommandBarEditor: false) == .keyEvents)
    }

    @Test func aTestSafeRunInsertsIntoTheCommandBarWithoutKeyEvents() {
        // No key events means no input method: a Japanese input source can't mark the text or show its candidates.
        #expect(UITextEntry.decide(testSafe: true, firstResponderIsCommandBarEditor: true) == .insertIntoCommandBar)
    }

    @Test func aTestSafeRunRefusesTextAnywhereElse() {
        // A web page, the rename field, another app's text: never typed into on a test-safe run.
        #expect(UITextEntry.decide(testSafe: true, firstResponderIsCommandBarEditor: false) == .refused(UITextEntry.refusal))
    }

    @Test func keysThatTypeACharacterAreTheOnesATestSafeRunRefuses() throws {
        for typing in ["a", "shift+a", "1", "space", "/"] {
            #expect(UITextEntry.typesCharacter(try KeyChord.parse(typing)), "\(typing) types a character")
        }
        for notTyping in ["cmd+a", "ctrl+1", "alt+a", "cmd+shift+z", "Enter", "Escape", "Tab", "Backspace", "ArrowLeft"] {
            #expect(!UITextEntry.typesCharacter(try KeyChord.parse(notTyping)), "\(notTyping) doesn't type")
        }
    }

    @Test func onlyATestSafeEnvironmentSwitchesItOn() {
        let testSafe = WindowPresentation.isTestSafe(environment: ["KITE_DIAGNOSTICS": "1", "KITE_SUPPORT_PATH": "/tmp/k.abcd"])
        #expect(UITextEntry.decide(testSafe: testSafe, firstResponderIsCommandBarEditor: false) != .keyEvents)
        let realProfile = WindowPresentation.isTestSafe(environment: ["KITE_DIAGNOSTICS": "1"])
        #expect(UITextEntry.decide(testSafe: realProfile, firstResponderIsCommandBarEditor: false) == .keyEvents)
    }
}
