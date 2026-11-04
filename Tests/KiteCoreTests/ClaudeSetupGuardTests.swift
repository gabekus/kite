import Testing
@testable import KiteCore

@Suite struct ClaudeSetupGuardTests {
    let installed = "/Applications/Kite.app/Contents/Helpers/kite"
    let worktree = "/Users/gabe/dev/kite/.claude/worktrees/agent-a56f/build/Kite.app/Contents/Helpers/kite"

    @Test func theInstalledKiteWritesEverything() {
        for target in [ClaudeSetupGuard.Target.claudeCode, .desktop, .commandLink] {
            #expect(ClaudeSetupGuard.refusal(target, cli: installed, environment: [:]) == nil)
        }
        // A plain dev build in the repo stays put, so it may link itself.
        #expect(ClaudeSetupGuard.refusal(.claudeCode, cli: "/Users/gabe/dev/kite/build/Kite.app/Contents/Helpers/kite",
                                         environment: [:]) == nil)
    }

    @Test func testBuildsLeaveTheRealSetupAlone() {
        // How Claude Code ended up on a deleted worktree build with a /tmp profile.
        let profile = ["KITE_SUPPORT_PATH": "/tmp/k.hpx7"]
        for target in [ClaudeSetupGuard.Target.claudeCode, .desktop, .commandLink] {
            #expect(ClaudeSetupGuard.refusal(target, cli: worktree, environment: profile) != nil)
            #expect(ClaudeSetupGuard.refusal(target, cli: installed, environment: profile) != nil)
            #expect(ClaudeSetupGuard.refusal(target, cli: worktree, environment: [:]) != nil)
        }
        #expect(ClaudeSetupGuard.refusal(.desktop, cli: installed, environment: profile)?.contains("KITE_CLAUDE_DESKTOP_CONFIG") == true)
    }

    @Test func aRedirectedStepRunsOnlyItself() {
        let environment = ["KITE_SUPPORT_PATH": "/tmp/k.1", "KITE_CLAUDE_BIN": "/tmp/k.1/claude"]
        #expect(ClaudeSetupGuard.refusal(.claudeCode, cli: worktree, environment: environment) == nil)
        #expect(ClaudeSetupGuard.refusal(.desktop, cli: worktree, environment: environment) != nil)
        #expect(ClaudeSetupGuard.refusal(.commandLink, cli: worktree, environment: environment) != nil)
    }
}
