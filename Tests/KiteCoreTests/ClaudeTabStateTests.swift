import Foundation
import Testing
@testable import KiteCore

/// Every tab Claude opened or acted on shows one of three states, never none (Gabe, 5 Nov 2026: the Mouser cart tab
/// showed nothing, so he couldn't tell done from stalled from needed).
@Suite struct ClaudeTabStateTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func untouchedTabsShowNothing() {
        #expect(ClaudeTabState.of(step: nil, declared: nil, active: false, lastTouched: nil) == nil)
        // Read only, while reading: working; afterwards nothing (reading the user's own tab isn't work on it).
        #expect(ClaudeTabState.of(step: nil, declared: nil, active: true, lastTouched: nil) == .working(note: nil))
    }

    @Test func workingThenStoppedHere() {
        #expect(ClaudeTabState.of(step: nil, declared: nil, active: true, lastTouched: t0) == .working(note: nil))
        // Claude's tools went quiet and it never said done: orange, "Claude stopped here".
        let stalled = ClaudeTabState.of(step: nil, declared: nil, active: false, lastTouched: t0)
        #expect(stalled == .needsYou(step: ClaudeTabState.stoppedHere, stalled: true))
        #expect(stalled?.isNeedsYou == true && stalled?.help.contains("without saying it's done") == true)
    }

    @Test func doneIsGreenUntilClaudeActsAgain() {
        let done = ClaudeTabState.Declared(kind: .done, note: "Order placed", at: t0.addingTimeInterval(10))
        #expect(ClaudeTabState.of(step: nil, declared: done, active: false, lastTouched: t0) == .done(note: "Order placed"))
        // Reading it again afterwards leaves it done.
        #expect(ClaudeTabState.of(step: nil, declared: done, active: true, lastTouched: t0) == .done(note: "Order placed"))
        // Acting on it again is work again, and stalls again if Claude leaves it.
        let later = t0.addingTimeInterval(20)
        #expect(ClaudeTabState.of(step: nil, declared: done, active: true, lastTouched: later) == .working(note: nil))
        #expect(ClaudeTabState.of(step: nil, declared: done, active: false, lastTouched: later)?.isNeedsYou == true)
    }

    @Test func aHandoffStepIsNeedsYouWhateverElse() {
        let done = ClaudeTabState.Declared(kind: .done, note: nil, at: t0)
        #expect(ClaudeTabState.of(step: "Tick I am human", declared: done, active: true, lastTouched: t0)
            == .needsYou(step: "Tick I am human", stalled: false))
    }

    @Test func declaredWorkingLastsAsLongAsTheTools() {
        let working = ClaudeTabState.Declared(kind: .working, note: "Comparing carts", at: t0)
        #expect(ClaudeTabState.of(step: nil, declared: working, active: true, lastTouched: t0) == .working(note: "Comparing carts"))
        #expect(ClaudeTabState.of(step: nil, declared: working, active: false, lastTouched: t0)?.isNeedsYou == true)
    }

    @Test func theToolTakesOnlyWorkingOrDone() throws {
        #expect(try AutomationCommand(tool: "tab_status", arguments: ["tab": "T", "state": "done", "note": " Cart ready "])
            == .tabStatus(tab: "T", state: .done, note: "Cart ready"))
        #expect(throws: AutomationCommand.InvalidArguments.self) { try AutomationCommand(tool: "tab_status", arguments: ["state": "idle"]) }
        #expect(throws: AutomationCommand.InvalidArguments.self) {
            try AutomationCommand(tool: "tab_status", arguments: ["state": "done", "note": .string(String(repeating: "x", count: 121))])
        }
    }
}

/// The user's form details: one source of truth, never secrets, and a check that catches a wrong street.
@Suite struct FormProfileTests {
    // Not the user's real details: a made-up address.
    let home = FormProfile.Address(label: "home", street: "12 Example Ave", unit: "Apt 3B", city: "Queens", region: "NY",
                                   postalCode: "11101-1234")

    @Test func checksAnAddressWordForWord() {
        let profile = FormProfile(name: "Pat Doe", addresses: [home])
        let same = FormProfile.Address(label: "home", street: "12 Example Avenue", unit: "3B", city: "queens", region: "ny", postalCode: "11101")
        #expect(profile.check(same, against: "home") == "It matches the user's \"home\" address.")
        // The street from an old order email: flagged.
        let wrong = FormProfile.Address(label: "home", street: "12 Example Street", unit: "3B", city: "Queens", region: "NY", postalCode: "11101")
        let result = profile.check(wrong, against: "Home")
        #expect(result.hasPrefix("MISMATCH") && result.contains("street: the page has “12 Example Street”"))
        #expect(profile.check(same, against: "work").contains("There's no address \"work\""))
    }

    @Test func neverKeepsSecrets() {
        #expect(throws: AutomationCommand.InvalidArguments.self) {
            try AutomationCommand(tool: "form_profile", arguments: ["action": "set", "phone": "4242 4242 4242 4242"])
        }
        #expect(throws: AutomationCommand.InvalidArguments.self) {
            try AutomationCommand(tool: "form_profile", arguments: ["action": "set", "password": "x"])
        }
        #expect(throws: AutomationCommand.InvalidArguments.self) { try AutomationCommand(tool: "form_profile", arguments: ["action": "set"]) }
    }

    @Test func parsesSetAndCheck() throws {
        let set = try AutomationCommand(tool: "form_profile", arguments: [
            "action": "set", "company": "Example Co",
            "address": ["label": "home", "street": "12 Example Ave", "unit": "Apt 3B", "city": "Queens", "state": "NY", "zip": "11101-1234"],
        ])
        #expect(set == .formProfile(.set(.init(company: "Example Co", address: home))))
        #expect(try AutomationCommand(tool: "form_profile", arguments: nil) == .formProfile(.get))
        let check = try AutomationCommand(tool: "form_profile", arguments: [
            "action": "check", "label": "home", "address": ["street": "1 Main St", "city": "X", "state": "NY", "zip": "10001"],
        ])
        if case .formProfile(.check(let shown, let label)) = check { #expect(label == "home" && shown.street == "1 Main St") }
        else { Issue.record("not a check") }
    }

    @Test func keepsChangesAndStoresThemPrivately() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = FormProfile.fileURL(supportDirectory: dir)
        let confirmed = Date(timeIntervalSince1970: 2_000_000)
        let profile = FormProfile().merging(.init(name: "Pat Doe", address: home), confirmed: confirmed)
        try profile.save(to: url)
        let loaded = FormProfile.load(from: url)
        #expect(loaded.name == "Pat Doe" && loaded.address("HOME")?.confirmed == confirmed)
        #expect(loaded.report.contains("address \"home\": street 12 Example Ave, unit Apt 3B"))
        #if !os(Windows)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #endif
        // A new address under the same label replaces the old one.
        let moved = loaded.merging(.init(address: .init(label: "home", street: "1 New St", city: "X", region: "NY", postalCode: "10001")),
                                   confirmed: confirmed)
        #expect(moved.addresses.count == 1 && moved.address("home")?.street == "1 New St")
    }
}

/// Chromium not starting after a restart used to drop Kite onto WebKit silently (other cookies, empty carts).
@Suite struct EngineFallbackTests {
    @Test func triesAgainBeforeFallingBack() {
        #expect(EngineFallback.attempt(environment: [:]) == 1)
        #expect(EngineFallback.attempt(environment: [EngineFallback.attemptKey: "3"]) == 3)
        #expect(EngineFallback.shouldRetry(attempt: 1) && !EngineFallback.shouldRetry(attempt: EngineFallback.maxAttempts))
        #expect(EngineFallback.toolError.contains("quit Kite (⌘Q) and open it again"))
    }
}
