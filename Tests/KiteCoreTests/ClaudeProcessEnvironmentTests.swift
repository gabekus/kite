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
        #expect(ClaudeProcessEnvironment.isolated(base, userHome: user) == base)
    }

    @Test func aMissingLoginPathKeepsKitesOwn() {
        let base = ["HOME": "/Users/me", "PATH": "/usr/bin"]
        #expect(ClaudeProcessEnvironment.make(base, loginPath: nil, userHome: user)["PATH"] == "/usr/bin")
        #expect(ClaudeProcessEnvironment.make(base, loginPath: "  ", userHome: user)["PATH"] == "/usr/bin")
    }

    @Test func aTestProfileRunsClaudeInTheFixtureHome() {
        let base = ["HOME": "/Users/me", "PATH": "/usr/bin", "KITE_SUPPORT_PATH": "/tmp/k.1",
                    "KITE_TEST_CLAUDE_HOME": "/tmp/fixture"]
        for environment in [ClaudeProcessEnvironment.make(base, loginPath: "/bin", userHome: user),
                            ClaudeProcessEnvironment.isolated(base, userHome: user)] {
            #expect(environment["HOME"] == "/tmp/fixture")
            #expect(environment["CLAUDE_CONFIG_DIR"] == "/tmp/fixture/.claude")
        }
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
        #expect(!real.isTestProfile && real == empty)
        #expect(test.isTestProfile && test != real)
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
}
