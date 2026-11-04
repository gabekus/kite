import Foundation
import Testing
@testable import KiteCore

/// Gabe's standing rule for forms of an account he opens: Claude fills the ordinary details, he keeps the clicks that
/// make the account and every secret or ID number. Every Claude that uses Kite hears it.
@Suite struct AccountFormsRuleTests {
    @Test func everyClaudeHearsIt() {
        for text in [MCPServer.instructions, ClaudeInvocation.systemPrompt] {
            #expect(text.contains(MCPServer.accountForms))
        }
        let rule = MCPServer.accountForms
        for words in ["ordinary details they approve", "don't guess them", "creates the account", "agrees to terms",
                      "authorizes a credit check", "verifies identity", "SSN, EIN or other ID number", "a card or bank number",
                      "a password or a one-time code", "hand the account-making click over with handoff and wait on it"] {
            #expect(rule.contains(words), "missing: \(words)")
        }
    }

    @Test func theSafetyLinesStay() {
        #expect(MCPServer.instructions.contains("Only submit forms, send, post, pay, buy or delete what the user asked for."))
        #expect(MCPServer.instructions.contains("Never ask for a password or type one yourself."))
        #expect(ClaudeInvocation.systemPrompt.contains("Only submit forms, send, post, pay, buy or delete what the user asked for."))
        #expect(ClaudeInvocation.systemPrompt.contains("Never enter credentials or payment details yourself"))
    }

    @Test func theSetupGuideCarriesIt() throws {
        // Onboarding's Set Up Claude hands Claude this guide, and its CLAUDE.md block keeps the rule without Kite loaded.
        let guide = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("../../Resources/SETUP.md"), encoding: .utf8)
        #expect(guide.contains("Forms for an account the person opens"))
        let block = try #require(guide.components(separatedBy: "## Kite (my browser)").last?.components(separatedBy: "```").first)
        #expect(block.contains("Account forms: fill in the ordinary details I approve"))
        #expect(block.contains("Hand that click over with handoff, wait, then fill on."))
    }
}
