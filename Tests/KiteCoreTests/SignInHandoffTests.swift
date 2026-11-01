import Foundation
import Testing
@testable import KiteCore

@Suite struct SignInHandoffTests {
    @Test func parsesTheTool() throws {
        #expect(try AutomationCommand(tool: "sign_in", arguments: nil) == .signIn(tab: nil, reason: nil))
        #expect(try AutomationCommand(tool: "sign_in", arguments: ["tab": "T", "reason": "to see your orders"])
            == .signIn(tab: "T", reason: "to see your orders"))
        #expect(try AutomationCommand(tool: "sign_in", arguments: ["reason": ""]) == .signIn(tab: nil, reason: nil))
        // A batch passes its tab down to it, and the controller pauses the batch there.
        let batch = try AutomationCommand(tool: "batch", arguments: ["tab": "T", "steps": [["tool": "sign_in"]]])
        #expect(batch == .batch(steps: [.signIn(tab: "T", reason: nil)]))
    }

    @Test func isListedForClaude() async throws {
        let tool = try #require(MCPServer(version: "1").tools.arrayValue?.first { $0["name"]?.stringValue == "sign_in" })
        #expect(tool["description"]?.stringValue?.contains("1Password") == true)
        #expect(tool["inputSchema"]?["properties"]?["reason"] != nil)
        #expect(AutomationCommand.Tool.signIn.takesTab)
        #expect(!AutomationCommand.Tool.signIn.isReadOnly)
        #expect(MCPServer.instructions.contains("sign_in"))
        #expect(ClaudeInvocation.systemPrompt.contains("sign_in"))
    }

    @Test func readsTheProbe() {
        #expect(SignInHandoff.Probe(json: #"{"passwords":1,"codes":0}"#) == .init(passwords: 1, codes: 0))
        #expect(SignInHandoff.Probe(json: "undefined") == nil)
        #expect(SignInHandoff.Probe(passwords: 0, codes: 1).asksForSecret)
        #expect(!SignInHandoff.Probe(passwords: 0, codes: 0).asksForSecret)
    }

    @Test func finishesOnlyOnceThePageMovesOnAndStopsAskingForSecrets() {
        let login = URL(string: "https://shop.example/login?next=/orders")!
        let none = SignInHandoff.Probe(passwords: 0, codes: 0)
        // Still on the form.
        #expect(!SignInHandoff.isFinished(start: login, now: login, probe: .init(passwords: 1, codes: 0)))
        // Email-first step: no password field yet, but the page hasn't moved on.
        #expect(!SignInHandoff.isFinished(start: login, now: login, probe: none))
        // Same page with a new query or fragment is still the login page.
        #expect(!SignInHandoff.isFinished(start: login, now: URL(string: "https://shop.example/login?step=2#pw")!, probe: none))
        // On to the password step, or a two-factor code.
        let password = URL(string: "https://accounts.example/signin/password")!
        #expect(!SignInHandoff.isFinished(start: login, now: password, probe: .init(passwords: 1, codes: 0)))
        #expect(!SignInHandoff.isFinished(start: login, now: password, probe: .init(passwords: 0, codes: 1)))
        // Signed in.
        #expect(SignInHandoff.isFinished(start: login, now: URL(string: "https://shop.example/orders")!, probe: none))
    }

    @Test func waitsThroughAnotherSitesLogin() {
        let login = URL(string: "https://github.com/login")!
        let none = SignInHandoff.Probe(passwords: 0, codes: 0)
        // "Continue with Google": an account picker or passkey page asks for no password, but it's not done.
        #expect(!SignInHandoff.isFinished(start: login, now: URL(string: "https://accounts.google.com/v3/signin/accountchooser")!, probe: none))
        // Back on the starting site afterwards, it is.
        #expect(SignInHandoff.isFinished(start: login, now: URL(string: "https://github.com/")!, probe: none))
        // The same site's other hosts count as the site.
        #expect(SignInHandoff.site("login.shop.example.co.uk") == "example.co.uk")
        #expect(SignInHandoff.site("www.example.co.uk") == "example.co.uk")
        #expect(SignInHandoff.site("accounts.example.com") == "example.com")
        #expect(SignInHandoff.isFinished(start: URL(string: "https://accounts.example.com/signin")!,
                                         now: URL(string: "https://www.example.com/home")!, probe: none))
    }

    @Test func waitsThroughEmailFirstSteps() {
        let login = URL(string: "https://accounts.example.com/signin")!
        // The next step asks for an email or username: still signing in.
        #expect(!SignInHandoff.isFinished(start: login, now: URL(string: "https://accounts.example.com/signin/identifier")!,
                                          probe: .init(passwords: 0, codes: 0, identities: 1)))
        #expect(SignInHandoff.Probe(json: #"{"passwords":0,"codes":0,"identities":1}"#)?.looksLikeLogin == true)
        #expect(SignInHandoff.Probe(json: #"{"passwords":0,"codes":0}"#)?.identities == 0)
    }

    @Test func reportsNoSecrets() {
        let id = UUID()
        let url = URL(string: "https://shop.example/orders")!
        let signedIn = SignInHandoff.report(.signedIn, tab: id, url: url, title: "Orders")
        #expect(signedIn.hasPrefix("The user signed in."))
        #expect(signedIn.contains(id.uuidString) && signedIn.contains(url.absoluteString))
        #expect(SignInHandoff.report(.cancelled, tab: id, url: url, title: "Orders").contains("Don't try to sign in yourself"))
        #expect(SignInHandoff.report(.timedOut, tab: id, url: url, title: "Orders").contains("5 minutes"))
    }

    @Test func pageScriptsNeverReadValuesBack() {
        // The probe counts fields; only the cleanup touches values, and only to empty them.
        #expect(!SignInHandoff.probeScript.contains(".value"))
        #expect(SignInHandoff.clearScript.contains("setter.call(el, '')"))
        #expect(!SignInHandoff.clearScript.contains("return el.value"))
    }
}
