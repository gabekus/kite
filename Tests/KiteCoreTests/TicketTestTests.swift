import Foundation
import Testing
@testable import KiteCore

@Suite struct TicketTestTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test func readsLinearIssueURLsAndKeys() {
        let ticket = LinearTicket(url: url("https://linear.app/carbonarc/issue/PRO-1234/fix-the-login-page"))
        #expect(ticket?.key == "PRO-1234" && ticket?.organization == "carbonarc")
        #expect(LinearTicket(url: url("https://linear.app/carbonarc/issue/pro-7"))?.key == "PRO-7")
        #expect(LinearTicket(url: url("https://linear.app/carbonarc/project/foo-123")) == nil)
        #expect(LinearTicket(url: url("https://linear.app/carbonarc/issue/not-a-key/x")) == nil)
        #expect(LinearTicket(url: url("https://evil.example/carbonarc/issue/PRO-1")) == nil)
        #expect(LinearTicket(url: nil) == nil)
        #expect(LinearTicket(argument: " PRO-42 ")?.key == "PRO-42")
        #expect(LinearTicket(argument: "PRO-42")?.url == nil)
        #expect(LinearTicket(argument: "https://linear.app/a/issue/ENG-9/slug")?.url != nil)
        #expect(LinearTicket(argument: "hello") == nil)
        #expect(LinearTicket(key: "PRO-1234").spoolURL.absoluteString == "spool://ticket/PRO-1234")
    }

    @Test func findsTheIssuePageForABareKey() {
        let open = [url("https://example.com"), url("https://linear.app/carbonarc/issue/PRO-1/a"),
                    url("https://linear.app/carbonarc/issue/PRO-2/b")]
        #expect(LinearTicket(key: "PRO-2").resolvedURL(openTabs: open)?.absoluteString == "https://linear.app/carbonarc/issue/PRO-2/b")
        #expect(LinearTicket(key: "PRO-9").resolvedURL(openTabs: open)?.absoluteString == "https://linear.app/carbonarc/issue/PRO-9")
        #expect(LinearTicket(key: "PRO-9").resolvedURL(openTabs: [url("https://linear.app/acme/inbox")])?.absoluteString
            == "https://linear.app/acme/issue/PRO-9")
        #expect(LinearTicket(key: "PRO-9").resolvedURL(openTabs: [url("https://example.com")]) == nil)
    }

    @Test func parsesTheCLIRequest() throws {
        let request = try TicketTest.Request(arguments: ["ticket": "PRO-5", "target": "https://staging.example.com/app"])
        #expect(request.ticket.key == "PRO-5" && request.target?.host() == "staging.example.com")
        #expect(try TicketTest.Request(arguments: request.arguments) == request)
        #expect(throws: AutomationError.self) { try TicketTest.Request(arguments: ["ticket": "nope"]) }
        #expect(throws: AutomationError.self) { try TicketTest.Request(arguments: ["ticket": "PRO-5", "target": "file:///etc/hosts"]) }
        #expect(TicketTest.goal(request) == "Test PRO-5\nTarget: https://staging.example.com/app")
        #expect(ClaudeTask(goal: TicketTest.goal(request)).title == "Test PRO-5")
    }

    @Test func promptsWithTheTicketTabTheTargetAndTheRules() {
        let tab = ClaudeInvocation.TabContext(id: UUID(), title: "PRO-5 Fix login", url: "https://linear.app/a/issue/PRO-5/fix")
        let withTab = TicketTest.prompt(TicketTest.Request(ticket: LinearTicket(key: "PRO-5")), ticketTab: tab, issueURL: nil)
        #expect(withTab.contains(tab.id.uuidString) && withTab.contains("<untrusted-page-content"))
        #expect(withTab.contains("find the preview or staging URL"))
        let withoutTab = TicketTest.prompt(TicketTest.Request(ticket: LinearTicket(key: "PRO-5"), target: url("https://pr-5.preview.app")),
                                           ticketTab: nil, issueURL: url("https://linear.app/a/issue/PRO-5"))
        #expect(withoutTab.contains("session \"PRO-5\"") && withoutTab.contains("https://pr-5.preview.app"))
        #expect(TicketTest.prompt(TicketTest.Request(ticket: LinearTicket(key: "PRO-5")), ticketTab: nil, issueURL: nil).contains("handoff"))

        #expect(ClaudeInvocation.systemPrompt(ticket: nil) == ClaudeInvocation.systemPrompt)
        let system = ClaudeInvocation.systemPrompt(ticket: "PRO-5")
        #expect(system.hasPrefix(ClaudeInvocation.systemPrompt) && system.contains("Review and post"))
        #expect(!system.contains("\u{2014}"))
        let arguments = ClaudeInvocation.arguments(kiteCLI: "/k", profile: nil, taskID: UUID(), resume: nil, systemPrompt: system)
        #expect(arguments.last == system)
    }

    @Test func neverPostsOnLinear() {
        let comment = ElementDescription(tag: "button", label: "Comment")
        let save = ElementDescription(tag: "button", label: "Save")
        let editor = ElementDescription(tag: "div", role: "textbox", label: "Leave a comment…", isContentEditable: true)
        let link = ElementDescription(tag: "a", label: "Pull request #42", href: "https://github.com/x/y/pull/42")
        let enter = try! KeyChord.parseSequence("Enter")
        let commandEnter = try! KeyChord.parseSequence("cmd+Enter")
        let space = try! KeyChord.parseSequence("space")

        for action: AutomationAction in [
            .click(comment), .click(save), .click(ElementDescription(tag: "button", label: "Submit", inForm: true)),
            // Status, assignee and label pickers save on click, with no posting word in sight.
            .click(ElementDescription(tag: "div", role: "option", label: "In Progress")),
            .click(ElementDescription(tag: "button", label: "Assign to me")),
            .formInput(ElementDescription(tag: "select", label: "Priority"), value: "Urgent"),
            .keys(enter, focused: editor), .keys(commandEnter, focused: editor),
            // Space presses a focused button, and with focus unknown Kite assumes it might.
            .keys(space, focused: comment), .keys(space, focused: nil),
            .type(editor, text: "report", submit: true), .javascript(code: "document.querySelector('button').click()"),
            .uploadFiles(["/tmp/a.png"], into: editor),
        ] {
            #expect(TicketTest.blocksPosting(action, host: "linear.app") == TicketTest.postingRefusal)
        }
        // Reading the ticket and drafting the comment stay open.
        for action: AutomationAction in [
            .click(editor), .click(link), .type(editor, text: "Kite ticket test: 2 of 3 passed\nPASS …", submit: false),
            .keys(try! KeyChord.parseSequence("cmd+a"), focused: editor), .keys(space, focused: editor),
            .navigate(url("https://linear.app/a/issue/PRO-5")),
        ] {
            #expect(TicketTest.blocksPosting(action, host: "linear.app") == nil)
        }
        // The app under test keeps Kite's usual rules.
        #expect(TicketTest.blocksPosting(.click(save), host: "staging.example.com") == nil)
        #expect(TicketTest.blocksPosting(.keys(enter, focused: editor), host: "app.linear.app.evil.example") == nil)
        #expect(TicketTest.isLinear("uploads.linear.app"))
    }
}
