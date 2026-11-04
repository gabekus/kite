import Foundation
import Testing
@testable import KiteCore

struct ClaudeProcessEnvironmentTests {
    let user = URL(fileURLWithPath: "/Users/me", isDirectory: true)

    @Test func aRealProfileKeepsTheUsersHome() {
        let base = ["HOME": "/Users/me", "PATH": "/usr/bin", "KITE_DIAGNOSTICS": "1"]
        let environment = ClaudeProcessEnvironment.make(base, loginPath: "/opt/homebrew/bin:/usr/bin\n", userHome: user)
        #expect(environment == ["HOME": "/Users/me", "PATH": "/opt/homebrew/bin:/usr/bin"])
        #expect(environment["CLAUDE_CONFIG_DIR"] == nil)
        #expect(!ClaudeProcessEnvironment.isTestProfile(base))
    }

    @Test func aMissingLoginPathKeepsKitesOwn() {
        let base = ["HOME": "/Users/me", "PATH": "/usr/bin"]
        #expect(ClaudeProcessEnvironment.make(base, loginPath: nil, userHome: user)["PATH"] == "/usr/bin")
        #expect(ClaudeProcessEnvironment.make(base, loginPath: "  ", userHome: user)["PATH"] == "/usr/bin")
    }

    @Test func aTestProfileRunsClaudeInTheFixtureHome() {
        let base = ["HOME": "/Users/me", "PATH": "/usr/bin", "KITE_SUPPORT_PATH": "/tmp/k.1",
                    "KITE_TEST_CLAUDE_HOME": "/tmp/fixture"]
        let environment = ClaudeProcessEnvironment.make(base, loginPath: "/bin", userHome: user)
        #expect(environment["HOME"] == "/tmp/fixture")
        #expect(environment["CLAUDE_CONFIG_DIR"] == "/tmp/fixture/.claude")
        #expect(environment["PATH"] == "/bin")
    }

    @Test func anEmptySupportPathIsATestProfileToo() {
        // As in main.swift and AppDelegate.supportDirectory: set, even empty, is a test profile.
        let base = ["HOME": "/Users/me", "KITE_SUPPORT_PATH": ""]
        #expect(ClaudeProcessEnvironment.isTestProfile(base))
        let environment = ClaudeProcessEnvironment.make(base, loginPath: nil, userHome: user)
        let home = environment["HOME"] ?? ""
        #expect(home.hasSuffix("/Kite Test Claude Home"))
        #expect(!home.hasPrefix("/Users/me"))
        #expect(environment["CLAUDE_CONFIG_DIR"] == home + "/.claude")
    }

    @Test func aTestProfileWithoutAFixtureUsesTheProfileFolder() {
        let base = ["HOME": "/Users/me", "KITE_SUPPORT_PATH": "/tmp/k.1"]
        let environment = ClaudeProcessEnvironment.make(base, loginPath: nil, userHome: user)
        #expect(environment["HOME"] == "/tmp/k.1")
        #expect(environment["CLAUDE_CONFIG_DIR"] == "/tmp/k.1/.claude")
        #expect(!environment.values.contains { $0.hasPrefix("/Users/me") })
    }

    @Test func keysFollowTheTestProfile() {
        let real = ClaudeProcessEnvironment.Key(environment: [:], userHome: user)
        let empty = ClaudeProcessEnvironment.Key(environment: ["KITE_SUPPORT_PATH": ""], userHome: user)
        let test = ClaudeProcessEnvironment.Key(environment: ["KITE_SUPPORT_PATH": "/tmp/k.1"], userHome: user)
        let fixture = ClaudeProcessEnvironment.Key(environment: ["KITE_SUPPORT_PATH": "/tmp/k.1",
                                                                 "KITE_TEST_CLAUDE_HOME": "/tmp/fixture"], userHome: user)
        #expect(!real.isTestProfile)
        #expect(empty.isTestProfile && empty != real)
        #expect(test.isTestProfile && test != real && test != empty)
        #expect(fixture != test)
        #expect(fixture.home == "/tmp/fixture")
    }

    @Test func theCacheWorksOutEachProfileOnce() {
        let cache = ClaudeProcessEnvironment.Cache()
        let real = ClaudeProcessEnvironment.Key(environment: [:], userHome: user)
        let test = ClaudeProcessEnvironment.Key(environment: ["KITE_SUPPORT_PATH": "/tmp/k.1"], userHome: user)
        var made = 0
        let first = cache.environment(for: real) { made += 1; return ["HOME": "/Users/me"] }
        let again = cache.environment(for: real) { made += 1; return ["HOME": "wrong"] }
        let other = cache.environment(for: test) { made += 1; return ["HOME": "/tmp/k.1"] }
        #expect(first == again)
        #expect(other["HOME"] == "/tmp/k.1")
        #expect(made == 2)
    }

    @Test func theSignInScriptExportsOnlyWhatDiffers() {
        let base = ["HOME": "/Users/me", "PATH": "/usr/bin"]
        #expect(ClaudeProcessEnvironment.exports(base, base: base) == "")
        #expect(ClaudeProcessEnvironment.exports(ClaudeProcessEnvironment.make(base, loginPath: nil, userHome: user), base: base) == "")
        let test = ["HOME": "/tmp/k.1", "CLAUDE_CONFIG_DIR": "/tmp/k.1/.claude", "PATH": "/opt/bin"]
        #expect(ClaudeProcessEnvironment.exports(test, base: base)
                == "export HOME=/tmp/k.1\nexport CLAUDE_CONFIG_DIR=/tmp/k.1/.claude\n")
        let spaced = ["HOME": "/tmp/it's here", "CLAUDE_CONFIG_DIR": "/Users/me/.claude"]
        #expect(ClaudeProcessEnvironment.exports(spaced, base: base + ["CLAUDE_CONFIG_DIR": "/Users/me/.claude"])
                == "export HOME='/tmp/it'\\''s here'\n")
    }

    @Test func shellQuoting() {
        #expect(ClaudeProcessEnvironment.shellQuote("/usr/local/bin/claude") == "/usr/local/bin/claude")
        #expect(ClaudeProcessEnvironment.shellQuote("/Applications/My App") == "'/Applications/My App'")
        #expect(ClaudeProcessEnvironment.shellQuote("") == "''")
    }
}

private func + (lhs: [String: String], rhs: [String: String]) -> [String: String] {
    lhs.merging(rhs) { _, new in new }
}
