import Foundation
import Testing
@testable import KiteCore

@Suite struct VPNSignInTests {
    let hosts = ["vpn.example.com"]
    let start = URL(string: "https://vpn.example.com/saml/login?session=1")!

    @Test func normalizesHosts() {
        #expect(VPNSignIn.normalize("https://VPN.example.com/saml?x=1") == "vpn.example.com")
        #expect(VPNSignIn.normalize(" vpn.example.com. ") == "vpn.example.com")
        #expect(VPNSignIn.normalize("*.example.com") == "example.com")
        #expect(VPNSignIn.normalize("vpn.example.com:943/x") == "vpn.example.com")
        #expect(VPNSignIn.normalize("") == nil)
        #expect(VPNSignIn.normalize("not a host") == nil)
    }

    @Test func matchesWatchedHostsAndSubdomains() {
        #expect(VPNSignIn.matches(start, hosts: hosts))
        #expect(VPNSignIn.matches(URL(string: "https://eu.vpn.example.com/")!, hosts: hosts))
        #expect(!VPNSignIn.matches(URL(string: "https://evilvpn.example.com/")!, hosts: hosts))
        #expect(!VPNSignIn.matches(URL(string: "https://example.com/")!, hosts: hosts))
        #expect(!VPNSignIn.matches(URL(string: "file:///vpn.example.com")!, hosts: hosts))
        #expect(!VPNSignIn.matches(start, hosts: []))
    }

    @Test func storesHostsWithoutRepeats() {
        let defaults = UserDefaults(suiteName: "VPNSignInTests-\(UUID().uuidString)")!
        VPNSignIn.setHosts(["vpn.example.com", "https://VPN.example.com/x", "junk host"], in: defaults)
        #expect(VPNSignIn.hosts(in: defaults) == ["vpn.example.com"])
        VPNSignIn.setHosts([], in: defaults)
        #expect(defaults.object(forKey: VPNSignIn.hostsKey) == nil)
    }

    func look(_ url: String, loading: Bool = false, passwords: Int = 0, codes: Int = 0, identities: Int = 0) -> VPNSignIn.Look {
        .init(url: URL(string: url), isLoading: loading, probe: .init(passwords: passwords, codes: codes, identities: identities))
    }

    @Test func finishesOnceBackOnTheVPNSiteAfterTheCompanyLogin() {
        let t0 = Date()
        var run = VPNSignIn.Run(start: start, hosts: hosts, now: t0)
        #expect(run.step(look("https://login.company.com/sso/saml", loading: true), now: t0 + 1) == .wait)
        #expect(run.step(look("https://vpn.example.com/saml/acs"), now: t0 + 2) == .wait)
        // Settled on the VPN's page for 1.5 s.
        #expect(run.step(look("https://vpn.example.com/saml/acs"), now: t0 + 3.6) == .done)
    }

    @Test func finishesOnALocalClientPage() {
        let t0 = Date()
        var run = VPNSignIn.Run(start: start, hosts: hosts, now: t0)
        _ = run.step(look("http://127.0.0.1:4567/done"), now: t0 + 1)
        #expect(run.step(look("http://127.0.0.1:4567/done"), now: t0 + 3) == .done)
    }

    @Test func doesntFinishOnThePageItOpenedOn() {
        let t0 = Date()
        var run = VPNSignIn.Run(start: start, hosts: hosts, now: t0)
        #expect(run.step(look(start.absoluteString), now: t0 + 5) == .wait)
    }

    @Test func showsThePageWhenItNeedsTheUser() {
        let t0 = Date()
        var run = VPNSignIn.Run(start: start, hosts: hosts, now: t0)
        #expect(run.step(look("https://login.company.com/", passwords: 1), now: t0 + 1) == .needsUser(.asksForInput))
        run = VPNSignIn.Run(start: start, hosts: hosts, now: t0)
        #expect(run.step(look("https://login.company.com/", codes: 1), now: t0 + 1) == .needsUser(.asksForInput))
        // Still loading: fields may be about to go away.
        run = VPNSignIn.Run(start: start, hosts: hosts, now: t0)
        #expect(run.step(look("https://login.company.com/", loading: true, passwords: 1), now: t0 + 1) == .wait)
        // An MFA push: nothing to type, stuck on the company login.
        run = VPNSignIn.Run(start: start, hosts: hosts, now: t0)
        #expect(run.step(look("https://login.company.com/verify"), now: t0 + 1) == .wait)
        #expect(run.step(look("https://login.company.com/verify"), now: t0 + 11.5) == .needsUser(.waitingOnOtherSite))
        run = VPNSignIn.Run(start: start, hosts: hosts, now: t0)
        #expect(run.step(look("https://login.company.com/", loading: true), now: t0 + VPNSignIn.timeout) == .needsUser(.tookTooLong))
    }

    @Test func readsTheProbe() {
        let value = #"{"href":"https://vpn.example.com/a","title":"Okta","fields":{"passwords":1,"codes":0,"identities":0}}"#
        let look = VPNSignIn.look(fromProbe: value, isLoading: false)
        #expect(look.url?.host() == "vpn.example.com" && look.probe == .init(passwords: 1, codes: 0) && look.title == "Okta")
        #expect(VPNSignIn.look(fromProbe: nil, isLoading: true).probe == nil)
        #expect(VPNSignIn.probeScript.contains(SignInHandoff.probeScript))
    }

    @Test func parsesTheTool() throws {
        #expect(try AutomationCommand(tool: "vpn", arguments: nil) == .vpn(.status))
        #expect(try AutomationCommand(tool: "vpn", arguments: ["action": "watch", "host": "https://VPN.example.com/x"])
            == .vpn(.watch(host: "vpn.example.com")))
        #expect(try AutomationCommand(tool: "vpn", arguments: ["action": "reconnect", "profile": "Work", "timeout": 30])
            == .vpn(.reconnect(profile: "Work", timeout: 30)))
        #expect(try AutomationCommand(tool: "vpn", arguments: ["action": "wait"]) == .vpn(.wait(timeout: 60)))
        #expect(throws: AutomationCommand.InvalidArguments.self) { try AutomationCommand(tool: "vpn", arguments: ["action": "watch"]) }
        #expect(throws: AutomationCommand.InvalidArguments.self) { try AutomationCommand(tool: "vpn", arguments: ["action": "nope"]) }
        #expect(throws: AutomationCommand.InvalidArguments.self) { try AutomationCommand(tool: "vpn", arguments: ["action": "wait", "timeout": 999]) }
        #expect(MCPServer.instructions.contains("vpn tool"))
    }

    @Test func reportsStatus() {
        let empty = VPNSignIn.statusReport(hosts: [], recent: ["vpn.example.com"], last: nil, isOn: true)
        #expect(empty.contains("isn't watching") && empty.contains("vpn.example.com"))
        let last = VPNSignIn.Outcome(host: "vpn.example.com", startedAt: Date(), finishedAt: Date() + 2, result: .signedIn)
        let report = VPNSignIn.statusReport(hosts: hosts, recent: ["eu.vpn.example.com", "github.com"], last: last, isOn: true)
        #expect(report.contains("Signed in quietly") && report.contains("github.com") && !report.contains("eu.vpn"))
        #expect(VPNSignIn.remember("a.com", in: ["b.com", "a.com"]) == ["a.com", "b.com"])
    }
}
