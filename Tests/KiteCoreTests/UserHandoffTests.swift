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
            ],
        ])
        #expect(command == .handoff(.init(reason: "My safety check won't let me change nameservers.", steps: [
            .init(instruction: "Approve Apple", target: .text("Approve")),
            .init(instruction: "Click Save", tab: "U", target: .selector("button[type=submit]")),
            .init(instruction: "Tick Super Administrator", target: .ref("e42"), why: "Only you can grant admin."),
        ], tab: "T", wait: 50)))
        #expect(try AutomationCommand(tool: "handoff_status", arguments: nil) == .handoffStatus(id: nil, wait: 0, cancel: false))
        #expect(try AutomationCommand(tool: "handoff_status", arguments: ["id": "h2", "wait": 600, "cancel": true])
            == .handoffStatus(id: "h2", wait: 50, cancel: true))
    }

    @Test(arguments: [
        ("handoff", ["steps": [["instruction": "Click", "text": "Save"]]]),
        ("handoff", ["reason": " ", "steps": [["instruction": "Click", "text": "Save"]]]),
        ("handoff", ["reason": "Why", "steps": []]),
        ("handoff", ["reason": "Why", "steps": [["text": "Save"]]]),
        ("handoff", ["reason": "Why", "steps": [["instruction": "Click", "ref": "e1", "text": "Save"]]]),
        ("handoff", ["reason": "Why", "steps": [["instruction": "Run", "command": "ls", "text": "Save"]]]),
        // Kite shows a step only beside its control: no command, note or tab-only steps.
        ("handoff", ["reason": "Why", "steps": [["instruction": "Run", "command": "ls"]]]),
        ("handoff", ["reason": "Why", "steps": [["instruction": "Click"]]]),
        ("handoff", ["reason": "Why", "steps": [["instruction": "Click", "tab": "T"]]]),
        ("handoff", ["reason": "Why", "steps": [["instruction": "Click", "text": "Save"]], "wait": -1]),
        ("handoff", ["reason": "Why", "steps": ["Click"]]),
        ("handoff_status", ["wait": -1]),
    ] as [(String, JSONValue)])
    func rejectsBadArguments(tool: String, arguments: JSONValue) {
        #expect(throws: AutomationCommand.InvalidArguments.self) {
            try AutomationCommand(tool: tool, arguments: arguments)
        }
    }

    @Test func refusesTooManySteps() {
        let steps = JSONValue.array((0...UserHandoff.maxSteps).map { _ -> JSONValue in ["instruction": "Click", "text": "Save"] })
        #expect(throws: AutomationCommand.InvalidArguments.self) {
            try AutomationCommand(tool: "handoff", arguments: ["reason": "Why", "steps": steps])
        }
    }

    @Test func isListedForClaude() throws {
        let tools = MCPServer(version: "1").tools.arrayValue ?? []
        let handoff = try #require(tools.first { $0["name"]?.stringValue == "handoff" })
        #expect(handoff["inputSchema"]?["required"] == ["reason", "steps"])
        // No command steps: Kite can only show a step beside its control.
        #expect(handoff["inputSchema"]?["properties"]?["steps"]?["items"]?["properties"]?["command"] == nil)
        #expect(handoff["description"]?.stringValue?.contains("shows a card") == false)
        // No Done button: steps finish by themselves, and say what done looks like.
        #expect(handoff["description"]?.stringValue?.contains("There's no Done button") == true)
        #expect(handoff["inputSchema"]?["properties"]?["steps"]?["items"]?["properties"]?["done_when"] != nil)
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
            .init(id: "h1.3", number: 3, instruction: "Request code", tab: b, locator: .text("Send code")),
            .init(id: "h1.4", number: 4, instruction: "Grant access", tab: b, locator: .selector("#grant")),
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

    @Test func theTagsSkipAndDoneEndTheStep() {
        // The ring's report: a click or change on the control does the step; the tag's Done does it, its Skip skips it.
        #expect(UserHandoff.state("click") == .done && UserHandoff.state("change") == .done)
        #expect(UserHandoff.state("done") == .done && UserHandoff.state("skip") == .skipped)
        #expect(UserHandoff.describe("done") == "the user pressed Done" && UserHandoff.describe("skip") == "the user skipped it")
        // Only a press on the control itself can be what opened a tab.
        #expect(UserHandoff.onControl("click") && UserHandoff.onControl("change"))
        #expect(!UserHandoff.onControl("done") && !UserHandoff.onControl("skip"))
        let (start, a, _) = sample()
        var handoff = start
        handoff.finish("h1.1", UserHandoff.state("skip"), how: UserHandoff.describe("skip"))
        #expect(handoff.steps[0].state == .skipped && handoff.current(on: a)?.id == "h1.2")
        #expect(handoff.report { _ in nil }.contains("1. [skipped] Approve Apple (the user skipped it)"))
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
        #expect(now.contains("Now call handoff_status with id \"h1\" and wait 50"))
        #expect(now.contains("Don't end your turn while steps wait"))
        #expect(handoff.report(waitedOut: true) { _ in nil }.contains("wait 50 again"))
        let tools = MCPServer(version: "1").tools.arrayValue ?? []
        let describe = { (name: String) in tools.first { $0["name"]?.stringValue == name }?["description"]?.stringValue ?? "" }
        #expect(describe("handoff").contains("don't end your turn while steps wait"))
        #expect(describe("handoff").contains("opens a new tab"))
        #expect(describe("handoff_status").contains("don't end your turn while steps wait"))
        #expect(MCPServer.instructions.contains("don't end your turn while steps wait"))
        #expect(ClaudeInvocation.systemPrompt.contains("wait 50"))
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
        // The tag beside the ring is the only place the step shows: its words, Skip (no Done), and Claude's reason.
        #expect(script.contains("press('skip')") && !script.contains("press('done')"))
        let why = UserHandoff.RingConfig(step: step, why: "Only you can grant admin.", scroll: false)
        #expect(why.why == "Only you can grant admin.")
        #expect(UserHandoff.ringScript(why).contains(#""why":"Only you can grant admin.""#))
        // A step's own why wins over the handoff's reason.
        var own = step
        own.why = "It's your account."
        #expect(UserHandoff.RingConfig(step: own, why: "Reason", scroll: false).why == "It's your account.")
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
        // Step 1 waits before it, and may bring its control up: not blocked yet.
        #expect(report.contains("2. [waiting] Click Save — Kite can't find its control on the page yet"))
        #expect(report.contains("Fix what's in the way yourself"))
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

    @Test func unshownStepsEndAWait() throws {
        var handoff = Handoff(id: "h5", reason: "r", steps: [
            .init(id: "h5.1", number: 1, instruction: "Tick Super Admin", tab: UUID(), locator: .text("Super Admin")),
            .init(id: "h5.2", number: 2, instruction: "Send", tab: UUID(), locator: .text("Send"),
                  url: "https://mail.google.com/mail/u/0/#inbox?compose=abc"),
        ])
        // There's no card to take the user back: a page left, a tab closed or a control Kite can't find leaves the user
        // nothing to see, so Claude hears it, once the step is the one to do.
        handoff.steps[1].blocker = .offPage
        #expect(handoff.steps[1].isUnshown && handoff.blockedSteps.isEmpty)
        #expect(handoff.report { _ in nil }.contains("the tab is no longer on the step's page (https://mail.google.com/mail/u/0/#inbox?compose=abc)"))
        handoff.finish("h5.1", .done, how: "the user pressed Done")
        #expect(handoff.blockedSteps.map(\.id) == ["h5.2"])
        #expect(handoff.report { _ in nil }.contains("NOT SHOWN: the tab is no longer on the step's page"))
        let start = Date(timeIntervalSince1970: 1_000)
        var watch = HandoffBlockWatch()
        // Unshown waits out its own, longer delay: the next page may still be drawing the control.
        let r1 = watch.shouldReport(handoff, now: start, delay: 2, unshownDelay: 5)
        let r2 = watch.shouldReport(handoff, now: start.addingTimeInterval(3), delay: 2, unshownDelay: 5)
        let r3 = watch.shouldReport(handoff, now: start.addingTimeInterval(5), delay: 2, unshownDelay: 5)
        #expect(!r1 && !r2 && r3)
        handoff.steps[1].blocker = .tabClosed
        #expect(handoff.report { _ in nil }.contains("NOT SHOWN: its tab is closed"))
        handoff.steps[1].blocker = nil
        handoff.steps[1].found = false
        #expect(handoff.report { _ in nil }.contains("NOT SHOWN: Kite can't find its control on the page"))
        // No card falls back for it (Gabe: no box over the page, ever): Claude hears how to fix the step instead.
        #expect(handoff.report { _ in nil }.contains("such as a CAPTCHA or a card field, by its visible text or a selector"))
        // A selector that matches only something hidden (a field a site draws its own box over) says so.
        handoff.steps[1].controlHidden = true
        #expect(handoff.report { _ in nil }.contains("NOT SHOWN: its control is on the page but hidden"))
        handoff.steps[1].controlHidden = nil
        #expect(handoff.report { _ in nil }.contains("blocked or unshown step"))
        handoff.steps[1].found = true
        #expect(!handoff.steps[1].isUnshown && handoff.blockedSteps.isEmpty)
        // The page is saved with the step; what blocks it isn't.
        handoff.steps[1].blocker = .offPage
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
        #expect(loaded[0].steps[3].locator == .selector("#grant"))
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
        let tab = UUID()
        var fresh = Handoff(id: "h1", reason: "R", created: now.addingTimeInterval(-3600),
                            steps: [.init(id: "h1.1", number: 1, instruction: "Do", tab: tab)])
        let old = Handoff(id: "h2", reason: "R", created: now.addingTimeInterval(-UserHandoff.watchLimit - 1),
                          steps: [.init(id: "h2.1", number: 1, instruction: "Do", tab: tab)])
        #expect(fresh.isWatched(now: now))
        // A day on, the step still waits on its tab (sidebar, ring), but Kite no longer looks twice a second.
        #expect(!old.isWatched(now: now))
        #expect(!old.isFinished && old.current(on: tab)?.id == "h2.1")
        #expect(old.report { _ in nil }.contains("[waiting]"))
        fresh.finishAll(.done, how: "the user pressed Done")
        #expect(!fresh.isWatched(now: now))
    }

    @Test func pollsOnlyForAFreshStepOnAShownTab() {
        let now = Date()
        let shownTab = UUID(), hiddenTab = UUID()
        func handoff(_ id: String, age: TimeInterval, tab: UUID?) -> Handoff {
            Handoff(id: id, reason: "R", created: now.addingTimeInterval(-age),
                    steps: [.init(id: id + ".1", number: 1, instruction: "Do", tab: tab)])
        }
        let shown: (UUID) -> Bool = { $0 == shownTab }
        // Nothing waiting, or waiting only on a tab nobody can see, or with no tab: no polling.
        #expect(!Handoff.needsPolling([], now: now, isShown: shown))
        #expect(!Handoff.needsPolling([handoff("h1", age: 60, tab: hiddenTab)], now: now, isShown: shown))
        #expect(!Handoff.needsPolling([handoff("h1", age: 60, tab: nil)], now: now, isShown: shown))
        // A fresh step on the shown tab polls; the same step past the watch limit doesn't.
        #expect(Handoff.needsPolling([handoff("h1", age: 60, tab: shownTab)], now: now, isShown: shown))
        #expect(!Handoff.needsPolling([handoff("h1", age: UserHandoff.watchLimit + 1, tab: shownTab)], now: now, isShown: shown))
        // A finished step on the shown tab doesn't.
        var done = handoff("h2", age: 60, tab: shownTab)
        done.finishAll(.done, how: "the user pressed Done")
        #expect(!Handoff.needsPolling([done, handoff("h3", age: 60, tab: hiddenTab)], now: now, isShown: shown))
    }

    // MARK: Taking the user to the step (Gabe, 5 Nov 2026: steps on other tabs, and nothing ringed where he was)

    // Finishing a step never moves the user (Gabe, 5 Nov 2026: "keep me in the same tab"): only a handoff starting does.
    @Test func onlyAStartingHandoffBringsATabForward() {
        #expect(HandoffLead.bringsTabForward(at: .handoffStarted))
        #expect(!HandoffLead.bringsTabForward(at: .stepEnded))
    }

    // Every step finishes by itself: no Done button (Gabe, 5 Nov 2026: "dont even offer a done button").
    @Test func stepsSayWhatDoneLooksLike() throws {
        func parse(_ step: [String: JSONValue]) throws -> UserHandoff.StepRequest {
            guard case .handoff(let request) = try AutomationCommand(tool: "handoff", arguments: ["reason": "r", "steps": [.object(step)]])
            else { throw AutomationCommand.InvalidArguments("not a handoff") }
            return request.steps[0]
        }
        #expect(try parse(["instruction": "Pay", "text": "Pay"]).doneWhen == nil)
        #expect(try parse(["instruction": "ZIP", "selector": "#zip", "done_when": "value"]).doneWhen == .value)
        let appears = try parse(["instruction": "Confirm", "text": "Confirm", "done_when": "appears", "appears": "Order confirmed"])
        #expect(appears.doneWhen == .appears && appears.appears == "Order confirmed")
        // Words alone mean appears; appears without words, or a kind Kite can't see, is refused.
        #expect(try parse(["instruction": "Confirm", "text": "Confirm", "appears": "Thanks"]).doneWhen == .appears)
        #expect(throws: AutomationCommand.InvalidArguments.self) { try parse(["instruction": "x", "text": "x", "done_when": "appears"]) }
        #expect(throws: AutomationCommand.InvalidArguments.self) { try parse(["instruction": "x", "text": "x", "done_when": "whenever"]) }
        #expect(!UserHandoff.ringFunction.contains("class=\"done\""))
        // What the page reports reads back to Claude, and a step keeps its done_when across launches.
        #expect(UserHandoff.describe("value") == "the user filled in the highlighted field and moved on")
        #expect(UserHandoff.state("gone") == .done && UserHandoff.onControl("later") && !UserHandoff.onControl("navigated"))
        #expect(UserHandoff.RingEvent(json: #"{"step":"h1.1","how":"later","later":"h1.2"}"#)?.later == "h1.2")
        var step = Handoff.Step(id: "h1.1", number: 1, instruction: "Confirm", tab: UUID(), locator: .text("Confirm"))
        step.doneWhen = .appears
        step.appears = "Order confirmed"
        let back = try JSONDecoder().decode(Handoff.Step.self, from: JSONEncoder().encode(step))
        #expect(back.doneWhen == .appears && back.appears == "Order confirmed")
        // The ring hears a click on a later step's control on the same tab.
        let pay = Handoff.Step(id: "h1.2", number: 2, instruction: "Pay", tab: step.tab, locator: .selector("#pay"))
        let config = UserHandoff.RingConfig(step: step, scroll: false, later: [pay])
        #expect(config.doneWhen == "appears" && config.later == [.init(step: "h1.2", selector: "#pay")])
        // Navigation: only another address, not a fragment.
        let page = URL(string: "https://shop.example/cart?x=1#top")!
        #expect(UserHandoff.samePage(page, URL(string: "https://shop.example/cart?x=1#pay")!))
        #expect(!UserHandoff.samePage(page, URL(string: "https://shop.example/checkout")!))
    }

    // Gabe's Muji checkout (5 Nov 2026): billing address, card, Pay now on one tab, then /thank-you, and the handoff
    // still said 0 of 3 done, step 1 "not on the step's page".
    @Test func aPageThatMovesOnAfterItsPayStepEndsEveryStepThere() {
        let checkout = UUID(), other = UUID()
        let handoff = Handoff(id: "h1", reason: "Only you pay", steps: [
            .init(id: "h1.1", number: 1, instruction: "Pick the billing address", tab: checkout, locator: .text("Same as shipping address")),
            .init(id: "h1.2", number: 2, instruction: "Card number", tab: checkout, locator: .selector("#card")),
            .init(id: "h1.3", number: 3, instruction: "Pay now", tab: checkout, locator: .text("Pay now")),
            .init(id: "h1.4", number: 4, instruction: "Approve", tab: other, locator: .text("Approve")),
        ])
        #expect(handoff.stepsEndedByNavigation(on: checkout) == ["h1.1", "h1.2", "h1.3"])
        // A tab whose last step isn't a submit: only the step it showed (the next may be on the page it went to).
        #expect(handoff.stepsEndedByNavigation(on: other) == ["h1.4"])
        let signUp = Handoff(id: "h2", reason: "r", steps: [
            .init(id: "h2.1", number: 1, instruction: "Create account", tab: checkout, locator: .text("Create account")),
            .init(id: "h2.2", number: 2, instruction: "Tick the terms", tab: checkout, locator: .text("I agree")),
        ])
        #expect(signUp.stepsEndedByNavigation(on: checkout) == ["h2.1"])
        #expect(Handoff.Step(id: "x", number: 1, instruction: "Click it", locator: .text("Place order")).isSubmit)
        #expect(!Handoff.Step(id: "x", number: 1, instruction: "Type your ZIP", locator: .selector("#zip")).isSubmit)
        // "Payment" isn't "Pay": whole words only.
        #expect(!Handoff.Step(id: "x", number: 1, instruction: "Payment method", locator: .text("Payment method")).isSubmit)
        #expect(UserHandoff.movedOn(to: URL(string: "https://muji.us/checkouts/c/1/thank-you"), title: "Thank you")
            == "the page moved on to “Thank you” (muji.us/checkouts/c/1/thank-you); check it")
        #expect(UserHandoff.movedOn(to: URL(string: "https://muji.us/thank-you"), title: nil) == "the page moved on to muji.us/thank-you; check it")
    }

    @Test func leadsToTheFirstStepOnABackgroundTab() {
        let mouser = UUID(), amazon = UUID(), tools = UUID(), mcmaster = UUID()
        var handoff = Handoff(id: "h1", reason: "Only you can solve a CAPTCHA or enter a card", steps: [
            .init(id: "h1.1", number: 1, instruction: "Tick \"I am human\"", tab: amazon, locator: .text("I am human")),
            .init(id: "h1.2", number: 2, instruction: "Place order", tab: tools, locator: .text("Place order")),
            .init(id: "h1.3", number: 3, instruction: "Card number", tab: mcmaster, locator: .selector("#card")),
            .init(id: "h1.4", number: 4, instruction: "Pay", tab: mcmaster, locator: .text("Pay")),
        ])
        let open: (UUID) -> Bool = { _ in true }
        // The user is on a tab with no step: Kite takes them to step 1's tab.
        #expect(HandoffLead.target(handoff, front: mouser, isOpen: open)?.id == "h1.1")
        #expect(HandoffLead.target(handoff, front: nil, isOpen: open)?.id == "h1.1")
        // Already on a step's tab: they stay.
        #expect(HandoffLead.target(handoff, front: tools, isOpen: open) == nil)
        // The first waiting step, in Claude's order, once step 1 is done (where a handoff that starts now would lead).
        handoff.finish("h1.1", .done, how: "the user clicked the highlighted control")
        #expect(HandoffLead.target(handoff, front: amazon, isOpen: open)?.id == "h1.2")
        // A step whose tab is closed can't be gone to: the next one that's open.
        #expect(HandoffLead.target(handoff, front: amazon, isOpen: { $0 != tools })?.id == "h1.3")
        handoff.finish("h1.2", .skipped, how: "the user skipped it")
        handoff.finish("h1.3", .done, how: "the user changed the highlighted control")
        // Step 4 is on the tab in front (the same page as step 3): no switch.
        #expect(HandoffLead.target(handoff, front: mcmaster, isOpen: open) == nil)
        handoff.finish("h1.4", .done, how: "the user pressed Done")
        #expect(HandoffLead.target(handoff, front: mouser, isOpen: open) == nil)
    }

    @Test func waitsWhileTheUserTypesInKite() {
        // Kite in the background: switching its tab interrupts nothing.
        #expect(!HandoffLead.userIsBusy(appActive: false, sinceKey: 0, sincePointer: 0))
        // In Kite, typing or clicking: not under their hands.
        #expect(HandoffLead.userIsBusy(appActive: true, sinceKey: 1, sincePointer: 60))
        #expect(HandoffLead.userIsBusy(appActive: true, sinceKey: 60, sincePointer: 0.5))
        #expect(HandoffLead.userIsBusy(appActive: true, sinceKey: 60, sincePointer: 60, commandBarOpen: true))
        // Paused: now.
        #expect(!HandoffLead.userIsBusy(appActive: true, sinceKey: HandoffLead.afterTyping, sincePointer: HandoffLead.afterPointer))
    }

    @Test func tellsClaudeWhereTheUserWasTaken() {
        let step = Handoff.Step(id: "h1.1", number: 1, instruction: "Tick", tab: UUID(), locator: .text("I am human"))
        #expect(HandoffLead.note(step, title: "Amazon.com", led: true)
            == "Kite brought step 1's tab (“Amazon.com”) to the front for the user, with its control ringed.")
        #expect(HandoffLead.note(step, title: nil, led: false).contains("once the user stops typing"))
    }

    @Test func ringConfigJumpsAndOffersThePasswordManager() {
        let step = Handoff.Step(id: "h1.1", number: 1, instruction: "Choose a password", tab: UUID(), locator: .selector("#newpw"))
        let script = UserHandoff.ringScript(.init(step: step, scroll: true, jump: true, manager: "1Password", managerReady: true))
        #expect(script.contains(#""jump":true"#) && script.contains(#""manager":"1Password""#) && script.contains(#""managerReady":true"#))
        // The ring scrolls again on a jump, never draws the tag without its control, and only offers the manager on a
        // new password's field.
        #expect(UserHandoff.ringFunction.contains("if (cfg.jump)") && !UserHandoff.ringFunction.contains("float"))
        #expect(UserHandoff.ringFunction.contains("new-password") && UserHandoff.ringFunction.contains("current-password"))
        // Kite's own click on the field to open the manager doesn't end the step.
        #expect(UserHandoff.ringFunction.contains("K.quietUntil && Date.now() < K.quietUntil"))
        #expect(UserHandoff.RingState(json: #"{"found":false,"hidden":true}"#)?.hidden == true)
        #expect(UserHandoff.noteScript("1Password didn't open here").contains(#"["1Password didn't open here"]"#))
    }

    // MARK: Waits that MCP clients don't time out (Gabe, 5 Nov 2026: waits of 600 and 300 s both timed out)

    @Test func waitsAreCutBelowClientTimeouts() throws {
        #expect(UserHandoff.maxWait <= 50)
        let status = try AutomationCommand(tool: "handoff_status", arguments: ["wait": 600])
        #expect(status == .handoffStatus(id: nil, wait: UserHandoff.maxWait, cancel: false))
        let handoff = try AutomationCommand(tool: "handoff", arguments: ["reason": "r", "wait": 300, "steps": [["instruction": "Go", "text": "Go"]]])
        if case .handoff(let request) = handoff { #expect(request.wait == UserHandoff.maxWait) } else { Issue.record("not a handoff") }
        #expect(throws: AutomationCommand.InvalidArguments.self) { try AutomationCommand(tool: "handoff_status", arguments: ["wait": -1]) }
        // Done: Claude carries on at once and fills the next page's ordinary fields.
        var h = Handoff(id: "h9", reason: "r", steps: [.init(id: "h9.1", number: 1, instruction: "Create login", tab: UUID(), locator: .text("Create"))])
        h.finish("h9.1", .done, how: "the user clicked the highlighted control")
        let report = h.report { _ in nil }
        #expect(report.contains("carry on at once") && report.contains("fill its ordinary fields"))
        #expect(Handoff.endedNews(h).contains("handoff h9 has ended (1 of 1 done)"))
    }
}
