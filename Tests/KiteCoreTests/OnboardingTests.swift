import Foundation
import Testing
@testable import KiteCore

@Suite struct OnboardingTests {
    @Test func showsOnlyOnANewProfile() {
        // A new install: no session yet, no onboarding.json.
        #expect(Onboarding.shouldShow(sessionExisted: false, state: nil, testProfile: false, forced: false))
        // An existing install from before onboarding (Gabe's): it has a session and no onboarding.json.
        #expect(!Onboarding.shouldShow(sessionExisted: true, state: nil, testProfile: false, forced: false))
        // Quit halfway through: back next launch, even though the session is there now.
        #expect(Onboarding.shouldShow(sessionExisted: true, state: Onboarding.State(completed: false), testProfile: false, forced: false))
        #expect(!Onboarding.shouldShow(sessionExisted: true, state: Onboarding.State(completed: true), testProfile: false, forced: false))
        #expect(!Onboarding.shouldShow(sessionExisted: false, state: Onboarding.State(completed: true), testProfile: false, forced: false))
    }

    @Test func testProfilesOnlyWhenAsked() {
        #expect(!Onboarding.shouldShow(sessionExisted: false, state: nil, testProfile: true, forced: false))
        #expect(!Onboarding.shouldShow(sessionExisted: false, state: Onboarding.State(completed: false), testProfile: true, forced: false))
        #expect(Onboarding.shouldShow(sessionExisted: false, state: nil, testProfile: true, forced: true))
        #expect(Onboarding.shouldShow(sessionExisted: true, state: Onboarding.State(completed: false), testProfile: true, forced: true))
        #expect(!Onboarding.shouldShow(sessionExisted: false, state: Onboarding.State(completed: true), testProfile: true, forced: true))
    }

    @Test func stateRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("onboarding.json")
        #expect(Onboarding.load(from: file) == nil)
        Onboarding.save(.init(completed: false), to: file)
        #expect(Onboarding.load(from: file) == .init(completed: false))
        Onboarding.save(.init(completed: true), to: file)
        #expect(Onboarding.load(from: file) == .init(completed: true))
        try Data("not json".utf8).write(to: file)
        #expect(Onboarding.load(from: file) == nil)
    }

    @Test func promptCarriesTheGuide() {
        let guide = "# Setting up Kite with Claude\n\n## 1. Find Kite\n"
        let prompt = ClaudeSetupPrompt.withGuide(guide, kite: "/Applications/Kite.app/Contents/Helpers/kite")
        #expect(prompt.hasPrefix("Help me set up Kite, my web browser, on this Mac."))
        #expect(prompt.contains("/Applications/Kite.app/Contents/Helpers/kite"))
        #expect(prompt.hasSuffix("## 1. Find Kite"))
        #expect(prompt.contains("ask me before you change anything"))

        let code = ClaudeSetupPrompt.pointingAt(guidePath: "/x/SETUP.md", kite: "/x/kite")
        #expect(code.contains("Kite's setup guide is at /x/SETUP.md"))
        #expect(code.contains("command line tool is /x/kite"))
    }
}
