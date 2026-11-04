import Foundation
import Testing
@testable import KiteCore

@Suite struct UserHandoffTests {
    @Test func parsesTheTool() throws {
        let command = try AutomationCommand(tool: "handoff", arguments: [
            "reason": "  My safety check won't let me change nameservers. ",
            "tab": "T",
            "wait": 120,
            "steps": [
                ["instruction": "Approve Apple", "text": "Approve"],
                ["instruction": "Click Save", "tab": "U", "selector": "button[type=submit]"],
                ["instruction": "Tick Super Administrator", "ref": "e42", "why": "Only you can grant admin."],
                ["instruction": "Run the secrets script", "command": "bash ~/x.sh 2>&1 | tee log"],
            ],
        ])
        #expect(command == .handoff(.init(reason: "My safety check won't let me change nameservers.", steps: [
            .init(instruction: "Approve Apple", target: .text("Approve")),
            .init(instruction: "Click Save", tab: "U", target: .selector("button[type=submit]")),
            .init(instruction: "Tick Super Administrator", target: .ref("e42"), why: "Only you can grant admin."),
            .init(instruction: "Run the secrets script", command: "bash ~/x.sh 2>&1 | tee log"),
        ], tab: "T", wait: 120)))
        #expect(try AutomationCommand(tool: "handoff_status", arguments: nil) == .handoffStatus(id: nil, wait: 0, cancel: false))
        #expect(try AutomationCommand(tool: "handoff_status", arguments: ["id": "h2", "wait": 600, "cancel": true])
            == .handoffStatus(id: "h2", wait: 600, cancel: true))
    }

    @Test(arguments: [
        ("handoff", ["steps": [["instruction": "Click"]]]),
        ("handoff", ["reason": " ", "steps": [["instruction": "Click"]]]),
        ("handoff", ["reason": "Why", "steps": []]),
        ("handoff", ["reason": "Why", "steps": [["text": "Save"]]]),
        ("handoff", ["reason": "Why", "steps": [["instruction": "Click", "ref": "e1", "text": "Save"]]]),
        ("handoff", ["reason": "Why", "steps": [["instruction": "Run", "command": "ls", "text": "Save"]]]),
        ("handoff", ["reason": "Why", "steps": [["instruction": "Click"]], "wait": 601]),
        ("handoff", ["reason": "Why", "steps": ["Click"]]),
        ("handoff_status", ["wait": -1]),
    ] as [(String, JSONValue)])
    func rejectsBadArguments(tool: String, arguments: JSONValue) {
        #expect(throws: AutomationCommand.InvalidArguments.self) {
            try AutomationCommand(tool: tool, arguments: arguments)
        }
    }

    @Test func refusesTooManySteps() {
        let steps = JSONValue.array((0...UserHandoff.maxSteps).map { _ -> JSONValue in ["instruction": "Click"] })
        #expect(throws: AutomationCommand.InvalidArguments.self) {
            try AutomationCommand(tool: "handoff", arguments: ["reason": "Why", "steps": steps])
        }
    }

    @Test func isListedForClaude() throws {
        let tools = MCPServer(version: "1").tools.arrayValue ?? []
        let handoff = try #require(tools.first { $0["name"]?.stringValue == "handoff" })
        #expect(handoff["inputSchema"]?["required"] == ["reason", "steps"])
        #expect(handoff["inputSchema"]?["properties"]?["steps"]?["items"]?["properties"]?["command"] != nil)
        #expect(tools.contains { $0["name"]?.stringValue == "handoff_status" })
        #expect(AutomationCommand.Tool.handoff.takesTab)
        #expect(AutomationCommand.Tool.handoffStatus.isReadOnly)
        #expect(!AutomationCommand.Tool.handoff.isDestructive)
        #expect(MCPServer.instructions.contains("call handoff"))
        #expect(ClaudeInvocation.systemPrompt.contains("handoff"))
    }

    private func sample() -> (Handoff, UUID, UUID) {
        let a = UUID(), b = UUID()
        let handoff = Handoff(id: "h1", reason: "Safety check", steps: [
            .init(id: "h1.1", number: 1, instruction: "Approve Apple", tab: a, locator: .text("Approve")),
            .init(id: "h1.2", number: 2, instruction: "Click Save", tab: a, locator: .text("Save")),
            .init(id: "h1.3", number: 3, instruction: "Request code", tab: b),
            .init(id: "h1.4", number: 4, instruction: "Run it", command: "ls"),
        ])
        return (handoff, a, b)
    }

    @Test func stepsOnOneTabGoInOrder() {
        let (start, a, b) = sample()
        var handoff = start
        #expect(handoff.current(on: a)?.id == "h1.1")
        let clicked = handoff.finish("h1.1", .done, how: "the user clicked the highlighted control")
        #expect(clicked)
        #expect(handoff.current(on: a)?.id == "h1.2")
        #expect(handoff.current(on: b)?.id == "h1.3")
        // An ended step stays ended: a late click doesn't undo a Skip.
        let skipped = handoff.finish("h1.3", .skipped, how: "the user skipped it")
        let late = handoff.finish("h1.3", .done, how: "late")
        #expect(skipped)
        #expect(!late)
        #expect(handoff.steps[2].state == .skipped)
        #expect(handoff.waiting.map(\.id) == ["h1.2", "h1.4"])
        #expect(!handoff.isFinished)
        handoff.finishAll(.skipped, how: "the user closed the tab") { $0.tab == a }
        #expect(handoff.waiting.map(\.id) == ["h1.4"])
        handoff.finishAll(.done, how: "the user pressed Done")
        #expect(handoff.isFinished)
    }

    @Test func reportsWhatTheUserDid() {
        let (start, a, _) = sample()
        var handoff = start
        let place: (UUID) -> (url: String?, title: String)? = { $0 == a ? ("https://dash.example/dns", "DNS") : nil }
        let waiting = handoff.report(place: place)
        #expect(waiting.hasPrefix("Handoff h1: 0 of 4 done, 4 waiting for the user."))
        #expect(waiting.contains("1. [waiting] Approve Apple · tab \(a.uuidString) at https://dash.example/dns (“DNS”)"))
        #expect(waiting.contains("now closed"))
        #expect(waiting.contains("handoff_status with id \"h1\""))
        handoff.finish("h1.1", .done, how: "the user clicked the highlighted control")
        handoff.finishAll(.skipped, how: "the user dismissed the handoff")
        let ended = handoff.report(place: place)
        #expect(ended.hasPrefix("Handoff h1: 1 of 4 done, 3 skipped."))
        #expect(ended.contains("1. [done] Approve Apple (the user clicked the highlighted control)"))
        #expect(ended.contains("don't do them yourself"))
    }

    @Test func backReopensTheStepBefore() throws {
        let (start, a, _) = sample()
        var handoff = start
        #expect(handoff.previous(before: "h1.1") == nil)
        #expect(handoff.previous(before: "h1.3")?.id == "h1.2")
        #expect(handoff.previous(before: "h9.9") == nil)
        handoff.finish("h1.1", .done, how: "the user clicked the highlighted control")
        handoff.finish("h1.2", .skipped, how: "the user skipped it")
        handoff.steps[1].found = true
        handoff.steps[1].blocker = .offPage
        // Back from step 3: step 2 waits again, is the one its tab shows, and the ring looks for it afresh.
        let reopened = handoff.reopen("h1.2")
        #expect(reopened)
        #expect(handoff.steps[1].state == .waiting && handoff.steps[1].found == nil && handoff.steps[1].blocker == nil)
        #expect(handoff.current(on: a)?.id == "h1.2")
        #expect(handoff.waiting.map(\.id) == ["h1.2", "h1.3", "h1.4"])
        // A step still waiting (passed with Next) has nothing to reopen.
        let again = handoff.reopen("h1.3")
        #expect(!again)
        // handoff_status tells Claude it's waiting again, and what it had been.
        let report = handoff.report { _ in nil }
        #expect(report.hasPrefix("Handoff h1: 1 of 4 done, 3 waiting for the user."))
        #expect(report.contains("2. [waiting] Click Save (the user went back to it after it was skipped)"))
        #expect(report.contains("don't count it as done or skipped"))
        // Done again, it's done, with what did it.
        handoff.finish("h1.2", .done, how: "the user pressed Done")
        #expect(handoff.steps[1].how == "the user pressed Done")
        #expect(!handoff.report { _ in nil }.contains("went back"))
        // Saved and loaded across a relaunch, it still waits.
        handoff.reopen("h1.1")
        let loaded = try JSONDecoder().decode(Handoff.self, from: JSONEncoder().encode(handoff))
        #expect(loaded.steps[0].state == .waiting && loaded.steps[0].how == "the user went back to it after it was done")
    }

    @Test func tabsAClickOpenedArentSaved() throws {
        let (start, _, _) = sample()
        var handoff = start
        handoff.finish("h1.1", .done, how: "the user clicked the highlighted control")
        handoff.opened.append(.init(step: 1, tab: UUID()))
        // Only news for a wait that's under way: not saved.
        let loaded = try JSONDecoder().decode(Handoff.self, from: JSONEncoder().encode(handoff))
        #expect(loaded.opened.isEmpty && loaded.steps.count == 4)
    }

    @Test func theReportTellsClaudeToKeepWaiting() {
        let (handoff, _, _) = sample()
        let now = handoff.report { _ in nil }
        #expect(now.contains("Now call handoff_status with id \"h1\" and wait 600"))
        #expect(now.contains("Don't end your turn while steps wait"))
        #expect(handoff.report(waitedOut: true) { _ in nil }.contains("wait 600 again"))
        let tools = MCPServer(version: "1").tools.arrayValue ?? []
        let describe = { (name: String) in tools.first { $0["name"]?.stringValue == name }?["description"]?.stringValue ?? "" }
        #expect(describe("handoff").contains("don't end your turn while steps wait"))
        #expect(describe("handoff").contains("opens a new tab"))
        #expect(describe("handoff_status").contains("don't end your turn while steps wait"))
        #expect(MCPServer.instructions.contains("don't end your turn while steps wait"))
        #expect(ClaudeInvocation.systemPrompt.contains("wait 600"))
    }

    @Test func theHandbackSaysWhetherClaudeIsTakingOver() {
        let tab = UUID()
        let waiting = HandoffHandback(handoff: "h3", kind: .finished, claudeWaiting: true)
        #expect(waiting.message == "You're done. Claude is taking over again.")
        #expect(HandoffHandback(handoff: "h3", kind: .openedTab(tab), claudeWaiting: true).message.contains("taking over from there"))
        // Nothing is waiting: Kite can't wake Claude, so the user gets the words to tell it.
        let idle = HandoffHandback(handoff: "h3", kind: .openedTab(tab), claudeWaiting: false)
        #expect(idle.message.contains("Claude isn't waiting for this"))
        #expect(idle.note.contains("handoff_status for h3") && idle.note.contains(tab.uuidString))
        #expect(HandoffHandback(handoff: "h3", kind: .finished, claudeWaiting: false).note
            == "I've done the steps in Kite (handoff h3). Check handoff_status for h3 and carry on.")
    }

    @Test func buildsTheRingScript() throws {
        let step = Handoff.Step(id: "h1.2", number: 2, instruction: "Tick “Super Administrator”", tab: UUID(),
                                locator: .marker("h1.2", label: "Super Administrator"))
        let config = UserHandoff.RingConfig(step: step, scroll: true)
        #expect(config.marker == "h1.2" && config.text == "Super Administrator" && config.selector == nil)
        // A slept or reloaded page loses the mark: the ring looks the control up by its place, then its words.
        let reloaded = UserHandoff.RingConfig(step: .init(id: "h1.3", number: 3, instruction: "Save", tab: UUID(),
            locator: .marker("h1.3", label: "Save", path: "#form > button:nth-of-type(2)")), scroll: true)
        #expect(reloaded.path == "#form > button:nth-of-type(2)" && reloaded.text == "Save")
        #expect(UserHandoff.ringScript(reloaded).contains("c.path"))
        let script = UserHandoff.ringScript(config)
        #expect(script.hasPrefix("((cfg) => {"))
        #expect(script.contains(#""step":"h1.2""#))
        // The ring reports clicks through the binding, only trusted ones, from inside a closed shadow root.
        #expect(script.contains(UserHandoff.bindingName))
        #expect(script.contains("e.isTrusted"))
        #expect(script.contains("mode: 'closed'"))
        #expect(script.contains(UserHandoff.markerAttribute))
        #expect(UserHandoff.RingState(json: #"{"found":true,"done":"click"}"#) == .init(found: true, done: "click"))
        #expect(UserHandoff.RingState(json: #"{"found":false,"done":null}"#) == .init(found: false))
        #expect(UserHandoff.RingEvent(json: #"{"step":"h1.2","how":"change"}"#)?.step == "h1.2")
        #expect(UserHandoff.describe("change") == "the user changed the highlighted control")
    }

    @Test func reportsBlockedSteps() throws {
        var handoff = Handoff(id: "h2", reason: "Only you can invite", steps: [
            .init(id: "h2.1", number: 1, instruction: "Invite members", tab: UUID(), locator: .text("Invite members")),
            .init(id: "h2.2", number: 2, instruction: "Click Save", tab: UUID(), locator: .text("Save")),
        ])
        // The ring's report: a disabled control and the page's reason.
        let state = try #require(UserHandoff.RingState(json: #"{"found":true,"done":null,"disabled":true,"why":"Only Super Administrators"}"#))
        #expect(state.blocker == .disabled(why: "Only Super Administrators"))
        #expect(UserHandoff.RingState(json: #"{"found":false,"disabled":true}"#)?.blocker == nil)
        #expect(UserHandoff.RingState(json: #"{"found":true,"disabled":false}"#)?.blocker == nil)
        handoff.steps[0].found = true
        handoff.steps[0].blocker = state.blocker
        handoff.steps[1].found = false
        let report = handoff.report { _ in nil }
        #expect(report.contains("1. [waiting] Invite members — BLOCKED: its control is on the page but turned off"))
        // The reason is the page's words, so it reaches Claude marked as page content.
        #expect(report.contains(UntrustedContent.wrap("Only Super Administrators", source: "the step's control")))
        #expect(report.contains("2. [waiting] Click Save — Kite can't find its control on the page right now"))
        #expect(report.contains("Fix what blocks it yourself"))
        // Without a reason, the usual suspects.
        handoff.steps[0].blocker = .disabled(why: nil)
        #expect(handoff.report { _ in nil }.contains("is probably missing"))
        // What blocks a step is only what the last look saw: it isn't saved.
        let data = try JSONEncoder().encode(handoff)
        let loaded = try JSONDecoder().decode(Handoff.self, from: data)
        #expect(loaded.steps[0].blocker == nil && loaded.steps[0].found == nil)
        // A probe asks the page script only to look.
        let probe = UserHandoff.RingConfig(step: handoff.steps[0], scroll: false, probe: true)
        #expect(UserHandoff.ringScript(probe).contains(#""probe":true"#))
        #expect(handoff.steps[0].targetName == "Invite members")
    }

    @Test func blockedOnlyWithNothingBeforeIt() throws {
        let tab = UUID(), other = UUID()
        var handoff = Handoff(id: "h3", reason: "r", steps: [
            .init(id: "h3.1", number: 1, instruction: "Grant yourself Super Admin", tab: other, locator: .text("Super Admin")),
            .init(id: "h3.2", number: 2, instruction: "Invite members", tab: tab, locator: .text("Invite members")),
        ])
        handoff.steps[1].found = true
        handoff.steps[1].blocker = .disabled(why: nil)
        // Step 1 (on another tab) may be what turns step 2's control on: not blocked yet.
        #expect(!handoff.isBlocked(handoff.steps[1]) && handoff.blockedSteps.isEmpty)
        let early = handoff.report { _ in nil }
        #expect(early.contains("turned off for now, probably until the steps before it are done"))
        #expect(!early.contains("BLOCKED") && !early.contains("Fix what blocks it"))
        handoff.finish("h3.1", .done, how: "the user pressed Done")
        #expect(handoff.blockedSteps.map(\.id) == ["h3.2"])
        #expect(handoff.report { _ in nil }.contains("BLOCKED"))
    }

    @Test func blockedStepsEndAWaitOncePerStep() throws {
        var handoff = Handoff(id: "h4", reason: "r", steps: [
            .init(id: "h4.1", number: 1, instruction: "Invite members", tab: UUID(), locator: .text("Invite members")),
        ])
        let start = Date(timeIntervalSince1970: 1_000)
        var watch = HandoffBlockWatch()
        let r1 = watch.shouldReport(handoff, now: start, delay: 2)
        #expect(!r1)
        handoff.steps[0].blocker = .disabled(why: nil)
        let r2 = watch.shouldReport(handoff, now: start.addingTimeInterval(1), delay: 2)
        #expect(!r2)
        // A redraw that briefly shows no blocker starts the clock again.
        handoff.steps[0].blocker = nil
        let r3 = watch.shouldReport(handoff, now: start.addingTimeInterval(2), delay: 2)
        #expect(!r3)
        handoff.steps[0].blocker = .disabled(why: nil)
        let r4 = watch.shouldReport(handoff, now: start.addingTimeInterval(3), delay: 2)
        #expect(!r4)
        let r5 = watch.shouldReport(handoff, now: start.addingTimeInterval(5), delay: 2)
        #expect(r5)
        // Handed over blocked: at once.
        var fresh = HandoffBlockWatch()
        let r6 = fresh.shouldReport(handoff, now: start, delay: 0)
        #expect(r6)
        // Already told: a later wait isn't cut short by the same step.
        var told = HandoffBlockWatch(reported: ["h4.1"])
        let r7 = told.shouldReport(handoff, now: start, delay: 0)
        #expect(!r7)
        let r8 = told.shouldReport(handoff, now: start.addingTimeInterval(60), delay: 2)
        #expect(!r8)
    }

    @Test func knowsWhenATabHasLeftTheStepsPage() {
        let step = "https://dash.cloudflare.com/abc/members/invite"
        let url = { (s: String) in URL(string: s)! }
        #expect(Handoff.isOffPage(stepURL: step, current: url("https://www.google.com/")))
        #expect(Handoff.isOffPage(stepURL: step, current: url("https://dash.cloudflare.com/abc/home")))
        // The same address, however it's written.
        #expect(!Handoff.isOffPage(stepURL: step, current: url("https://DASH.cloudflare.com:443/abc/members/invite/")))
        // A fragment is part of the page: Gmail keeps an open compose there.
        #expect(Handoff.isOffPage(stepURL: "https://mail.google.com/mail/u/0/#inbox?compose=abc",
                                  current: url("https://mail.google.com/mail/u/0/#inbox")))
        // No page to go back to.
        #expect(!Handoff.isOffPage(stepURL: nil, current: url("https://example.com")))
        #expect(!Handoff.isOffPage(stepURL: "about:blank", current: url("https://example.com")))
        #expect(!Handoff.canReturn(to: url("file:///etc/hosts")) && !Handoff.canReturn(to: url("data:text/html,hi")))
        #expect(Handoff.canReturn(to: url("http://127.0.0.1:8080/x")))
    }

    @Test func offPageAndClosedTabsDontEndAWait() throws {
        var handoff = Handoff(id: "h5", reason: "r", steps: [
            .init(id: "h5.1", number: 1, instruction: "Tick Super Admin", tab: UUID(), locator: .text("Super Admin")),
            .init(id: "h5.2", number: 2, instruction: "Send", tab: UUID(), locator: .text("Send"),
                  url: "https://mail.google.com/mail/u/0/#inbox?compose=abc"),
        ])
        handoff.steps[1].blocker = .offPage
        handoff.finish("h5.1", .done, how: "the user pressed Done")
        // A page left or a tab closed is a click on the card away: Claude's wait goes on.
        var watch = HandoffBlockWatch()
        let left = watch.shouldReport(handoff, now: Date(), delay: 0)
        #expect(!left && handoff.blockedSteps.isEmpty)
        #expect(handoff.report { _ in nil }.contains("the tab is no longer on the step's page (https://mail.google.com/mail/u/0/#inbox?compose=abc)"))
        handoff.steps[1].blocker = .tabClosed
        let closed = watch.shouldReport(handoff, now: Date(), delay: 0)
        #expect(!closed && handoff.blockedSteps.isEmpty)
        #expect(handoff.report { _ in nil }.contains("its tab is closed; Kite offers the user a button to reopen it"))
        // The page is saved with the step; what blocks it isn't.
        let loaded = try JSONDecoder().decode(Handoff.self, from: JSONEncoder().encode(handoff))
        #expect(loaded.steps[1].url == "https://mail.google.com/mail/u/0/#inbox?compose=abc" && loaded.steps[1].blocker == nil)
        // A file saved before steps had pages still loads.
        let old = #"{"id":"h1","reason":"r","created":0,"steps":[{"id":"h1.1","number":1,"instruction":"x","state":"waiting"}]}"#
        #expect(try JSONDecoder().decode(Handoff.self, from: Data(old.utf8)).steps[0].url == nil)
    }

    @Test func keepsHandoffsAcrossLaunches() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = Handoff.fileURL(supportDirectory: folder)
        let (start, tab, _) = sample()
        var handoff = start
        _ = handoff.finish("h1.1", .done, how: "the user clicked the highlighted control")
        handoff.steps[1].found = true
        handoff.steps[1].locator = .marker("h1.2", label: "Save")
        var old = Handoff(id: "h7", reason: "Old", created: Date(timeIntervalSinceNow: -8 * 24 * 3600),
                          steps: [.init(id: "h7.1", number: 1, instruction: "Gone")])
        old.steps[0].state = .waiting
        try Handoff.save([old, handoff], to: url)

        let loaded = Handoff.load(from: url)
        // A week-old handoff is dropped; the rest comes back as the user left it, minus what the ring last saw.
        #expect(loaded.map(\.id) == ["h1"])
        #expect(loaded[0].steps[0].state == .done && loaded[0].steps[0].how == "the user clicked the highlighted control")
        #expect(loaded[0].steps[1].locator == .marker("h1.2", label: "Save") && loaded[0].steps[1].found == nil)
        #expect(loaded[0].current(on: tab)?.id == "h1.2")
        #expect(loaded[0].steps[3].command == "ls")
        #expect(Handoff.lastNumber(in: [old, handoff]) == 7)
        #expect(Handoff.load(from: folder.appendingPathComponent("missing.json")).isEmpty)
    }

    @Test func keepsOnlyTheNewestFinishedHandoffs() {
        func make(_ n: Int, done: Bool) -> Handoff {
            var h = Handoff(id: "h\(n)", reason: "R", steps: [.init(id: "h\(n).1", number: 1, instruction: "Do")])
            if done { h.finishAll(.done, how: "the user pressed Done") }
            return h
        }
        let all = (1...25).map { make($0, done: $0 != 3) }
        let kept = Handoff.pruned(all)
        #expect(kept.filter(\.isFinished).count == Handoff.keptFinished)
        #expect(kept.contains { $0.id == "h3" })
        #expect(kept.last?.id == "h25")
    }

    @Test func stopsWatchingOldHandoffs() {
        let now = Date()
        var fresh = Handoff(id: "h1", reason: "R", created: now.addingTimeInterval(-3600), steps: [.init(id: "h1.1", number: 1, instruction: "Do")])
        let old = Handoff(id: "h2", reason: "R", created: now.addingTimeInterval(-UserHandoff.watchLimit - 1),
                          steps: [.init(id: "h2.1", number: 1, instruction: "Do")])
        #expect(fresh.isWatched(now: now))
        // A day on, the step still waits (card, sidebar, ring), but Kite no longer looks twice a second.
        #expect(!old.isWatched(now: now) && !old.isFinished && old.current(on: UUID()) == nil)
        fresh.finishAll(.done, how: "the user pressed Done")
        #expect(!fresh.isWatched(now: now))
    }
}
