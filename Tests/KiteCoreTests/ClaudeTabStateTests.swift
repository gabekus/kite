import Foundation
import Testing
@testable import KiteCore

/// Every tab Claude opened or acted on shows one of three states, never none (Gabe, 5 Nov 2026: the Mouser cart tab
/// showed nothing, so he couldn't tell done from stalled from needed).
@Suite struct ClaudeTabStateTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func untouchedTabsShowNothing() {
        #expect(ClaudeTabState.of(step: nil, declared: nil, active: false, lastTouched: nil) == nil)
        #expect(ClaudeTabState.of(step: nil, record: nil, active: false, inClaudeFolder: { false }) == nil)
    }

    // A tab Claude touched never shows no state, even after a restart (Gabe, 5 Nov 2026: five Claude-folder tabs showed
    // nothing after Kite restarted for an update).

    @Test func aReadOnlyTouchIsATouch() {
        let read = ClaudeTabState.Record(touched: t0)
        // Reading while the connection is live: working.
        #expect(ClaudeTabState.of(step: nil, record: read, active: true, inClaudeFolder: { false }) == .working(note: nil))
        // Then quiet without a word: "Claude stopped here", not nothing.
        #expect(ClaudeTabState.of(step: nil, record: read, active: false, inClaudeFolder: { false })
            == .needsYou(step: ClaudeTabState.stoppedHere, stalled: true))
        // A read after done leaves it done: only acting ends a done.
        var done = ClaudeTabState.Record(touched: t0, acted: t0, declared: .init(kind: .done, note: "Cart ready", at: t0))
        done.touched = t0.addingTimeInterval(30)
        #expect(ClaudeTabState.of(step: nil, record: done, active: true, inClaudeFolder: { false }) == .done(note: "Cart ready"))
    }

    @Test func aTouchedTabKeepsItsStateAcrossARestart() throws {
        let tab = BrowserTab(url: URL(string: "https://www.mcmaster.com"))
        var state = BrowserState(spaces: [Space(name: "Komado", icon: "🪵", theme: Theme.presets[0], tabs: [tab])])
        let done = BrowserTab(url: URL(string: "https://www.amazon.com"))
        state.spaces[0].tabs.append(done)
        state.claudeTabs[tab.id] = .init(touched: t0, acted: t0, session: "Shop purchase prep")
        state.claudeTabs[done.id] = .init(touched: t0, acted: t0, declared: .init(kind: .done, note: "Cart ready", at: t0))
        // Saved and read back, as Kite does when it restarts; no connection is live after a restart.
        let restarted = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(state))
        #expect(restarted.claudeTabs == state.claudeTabs)
        #expect(ClaudeTabState.of(step: nil, record: restarted.claudeTabs[tab.id], active: false, inClaudeFolder: { false })
            == .needsYou(step: ClaudeTabState.stoppedHere, stalled: true))
        #expect(ClaudeTabState.of(step: nil, record: restarted.claudeTabs[done.id], active: false, inClaudeFolder: { false })
            == .done(note: "Cart ready"))
        // Sessions saved before this have no records and still load.
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        old["claudeTabs"] = nil
        #expect(try JSONDecoder().decode(BrowserState.self, from: JSONSerialization.data(withJSONObject: old)).claudeTabs.isEmpty)
    }

    @Test func aClaudeFolderTabWithNoRecordNeedsYou() throws {
        let inFolder = BrowserTab(url: URL(string: "https://www.homedepot.com"))
        let outside = BrowserTab(url: URL(string: "https://example.com"))
        var state = BrowserState(spaces: [Space(name: "Komado", icon: "🪵", theme: Theme.presets[0], tabs: [outside])])
        let space = state.spaces[0].id
        let made = state.claudeSessionFolder(named: "Shop purchase prep", inSpace: space)
        let folder = try #require(made)
        #expect(state.spaces[0].pinnedItems.updateFolder(folder) { $0.items.append(.tab(inFolder)) })
        #expect(state.isInClaudeFolder(tab: inFolder.id) && !state.isInClaudeFolder(tab: outside.id))
        #expect(ClaudeTabState.of(step: nil, record: nil, active: false, inClaudeFolder: { state.isInClaudeFolder(tab: inFolder.id) })
            == .needsYou(step: ClaudeTabState.stoppedHere, stalled: true))
        // Outside the Claude folders, a tab Claude never touched shows nothing.
        #expect(ClaudeTabState.of(step: nil, record: nil, active: false, inClaudeFolder: { state.isInClaudeFolder(tab: outside.id) }) == nil)
        // The user's Clear Claude's Mark clears it, until Claude touches the tab again.
        var cleared = ClaudeTabState.Record(cleared: t0)
        #expect(ClaudeTabState.of(step: nil, record: cleared, active: false, inClaudeFolder: { true }) == nil)
        cleared.touched = t0.addingTimeInterval(1)
        #expect(ClaudeTabState.of(step: nil, record: cleared, active: false, inClaudeFolder: { true })?.isNeedsYou == true)
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

    // Orange never without a ring on the page (Gabe, 5 Nov 2026: "its orange with no highlight - this should NEVER
    // HAPPEN": the Ocooch tab went orange while its agent was alive, busy on other tabs).

    @Test func declaredWorkingStaysWorkingWhileItsConnectionIsLive() {
        let working = ClaudeTabState.Declared(kind: .working, note: "next, after McMaster", at: t0)
        let record = ClaudeTabState.Record(touched: t0, acted: t0, declared: working)
        // Three minutes on, the control lapsed (active false), the agent busy elsewhere: still working, with its note.
        #expect(ClaudeTabState.of(step: nil, record: record, active: false, connectionLive: true, inClaudeFolder: { true })
            == .working(note: "next, after McMaster"))
        // Touched without a note: working too.
        #expect(ClaudeTabState.of(step: nil, record: .init(touched: t0), active: false, connectionLive: true, inClaudeFolder: { false })
            == .working(note: nil))
        // The connection gone: orange, with the page outlined.
        let gone = ClaudeTabState.of(step: nil, record: record, active: false, connectionLive: false, inClaudeFolder: { true })
        #expect(gone == .needsYou(step: ClaudeTabState.stoppedHere, stalled: true) && gone?.ring == .pageOutline)
        // Done stays green, connected or not.
        let done = ClaudeTabState.Record(touched: t0, acted: t0, declared: .init(kind: .done, note: "Cart ready", at: t0))
        #expect(ClaudeTabState.of(step: nil, record: done, active: false, connectionLive: true, inClaudeFolder: { true }) == .done(note: "Cart ready"))
        #expect(ClaudeTabState.of(step: nil, record: done, active: false, connectionLive: false, inClaudeFolder: { true }) == .done(note: "Cart ready"))
    }

    @Test func orangeAlwaysHasARingOnThePage() {
        let declarations: [ClaudeTabState.Declared?] = [nil, .init(kind: .working, note: nil, at: t0), .init(kind: .working, note: "n", at: t0),
                                                         .init(kind: .done, note: nil, at: t0), .init(kind: .done, note: "n", at: t0)]
        let times: [Date?] = [nil, t0.addingTimeInterval(-10), t0, t0.addingTimeInterval(10)]
        var seen = 0
        for step in [nil, "Tick I am human"] as [String?] {
            for declared in declarations {
                for active in [false, true] {
                    for live in [false, true] {
                        for acted in times {
                            for read in times {
                                for folder in [false, true] {
                                    let state = ClaudeTabState.of(step: step, declared: declared, active: active, connectionLive: live,
                                                                  lastTouched: acted, lastRead: read, inClaudeFolder: folder)
                                    guard let state, state.isNeedsYou else { continue }
                                    seen += 1
                                    // Orange: a ringed handoff step, or the page outline.
                                    #expect(state.ring != nil)
                                    if step != nil { #expect(state.ring == .handoffStep) }
                                    // Stalled only once nothing of Claude's is live on the tab.
                                    if state.isStalled { #expect(!active && !live || (acted == nil && read == nil && declared == nil)) }
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(seen > 0)
        #expect(ClaudeTabState.working(note: nil).ring == nil && ClaudeTabState.done(note: nil).ring == nil)
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

    /// A profile another Kite has open (CEF 24: the launch was handed to it) used to retry, fall back to WebKit and
    /// hang before finishing launching (5 Nov 2026). It's retried (that Kite may be quitting), then refused.
    @Test func aProfileInUseIsRefusedNeverWebKit() {
        for code: Int32 in [21, 24] {
            #expect(EngineFallback.next(attempt: 1, exitCode: code) == .retry)
            #expect(EngineFallback.next(attempt: EngineFallback.maxAttempts, exitCode: code) == .refuseProfileInUse)
        }
        // Anything else is Chromium itself failing: WebKit, in a fresh process.
        #expect(EngineFallback.next(attempt: EngineFallback.maxAttempts, exitCode: 1) == .webKit)
        #expect(EngineFallback.next(attempt: EngineFallback.maxAttempts - 1, exitCode: 1) == .retry)
    }

    @Test func theLockNamesTheKiteHoldingTheProfile() {
        #expect(EngineFallback.lockHolderPID(lockTarget: "Gabes-Macbook.local-62875") == 62875)
        #expect(EngineFallback.lockHolderPID(lockTarget: "nohyphen") == nil)
        #expect(EngineFallback.lockHolderPID(lockTarget: "host-0") == nil)
        let message = EngineFallback.profileInUseMessage(profile: "/tmp/k.AbCd/Chromium", holder: "PID 62875 (/x/Kite.app)")
        #expect(message.contains("already open in another Kite, PID 62875 (/x/Kite.app)"))
    }
}

/// The user's step done, the tab goes straight back to working (Gabe, 5 Nov 2026: "as soon as i do what claude tells me
/// from the highlight, it should go back to the cranking state with shiny text, rn it takes a while to kick in").
@Suite struct HandoffPickUpTests {
    @Test func aDoneStepTurnsItsTabBackToWorkingAtOnce() {
        let signUp = UUID(), cart = UUID()
        let before = Handoff(id: "h1", reason: "Yours to agree", steps: [
            .init(id: "h1.1", number: 1, instruction: "Agree to terms", tab: signUp, locator: .text("I agree")),
            .init(id: "h1.2", number: 2, instruction: "Pay", tab: cart, locator: .text("Place order")),
        ])
        var after = before
        let finished = after.finish("h1.1", .done, how: "the user clicked the highlighted control")
        #expect(finished)
        // Same change, no tool call in between: the step's tab is picked up, and the next step's tab now shows its step.
        #expect(after.tabsPickedUp(since: before) == [signUp])
        #expect(after.current(on: cart)?.id == "h1.2")
        // As the controller applies it: a touch from the handoff's connection, which is live.
        let now = Date()
        let record = ClaudeTabState.Record(touched: now)
        let signUpState = ClaudeTabState.of(step: after.current(on: signUp)?.instruction, record: record, active: true,
                                            connectionLive: true, inClaudeFolder: { true })
        #expect(signUpState == .working(note: nil))
        let cartState = ClaudeTabState.of(step: after.current(on: cart)?.instruction, record: nil, active: false,
                                          connectionLive: false, inClaudeFolder: { true })
        #expect(cartState == .needsYou(step: "Pay", stalled: false) && cartState?.ring == .handoffStep)
        // Nothing more ended: nothing picked up again.
        #expect(after.tabsPickedUp(since: after).isEmpty)
    }

    @Test func aTabWithAnotherStepWaitingStaysOrange() {
        let tab = UUID()
        let before = Handoff(id: "h2", reason: "r", steps: [
            .init(id: "h2.1", number: 1, instruction: "Approve", tab: tab, locator: .text("Approve")),
            .init(id: "h2.2", number: 2, instruction: "Save", tab: tab, locator: .text("Save")),
        ])
        var after = before
        after.finish("h2.1", .done, how: "pressed Done")
        #expect(after.tabsPickedUp(since: before).isEmpty && after.current(on: tab)?.id == "h2.2")
        var last = after
        last.finish("h2.2", .skipped, how: "skipped it")
        #expect(last.tabsPickedUp(since: after) == [tab])
    }
}
