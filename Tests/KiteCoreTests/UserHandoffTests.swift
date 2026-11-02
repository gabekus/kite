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

    @Test func buildsTheRingScript() throws {
        let step = Handoff.Step(id: "h1.2", number: 2, instruction: "Tick “Super Administrator”", tab: UUID(),
                                locator: .marker("h1.2", label: "Super Administrator"))
        let config = UserHandoff.RingConfig(step: step, scroll: true)
        #expect(config.marker == "h1.2" && config.text == "Super Administrator" && config.selector == nil)
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
}
