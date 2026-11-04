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

    @Test func withoutALoginPathTheUsualFoldersGoFirst() {
        let base = ["HOME": "/Users/me", "PATH": "/usr/bin:/bin:/usr/local/bin"]
        let folders = ["/Users/me/.nvm/bin"] + ClaudeProcessEnvironment.fallbackDirectories(userHome: user)
        #expect(ClaudeProcessEnvironment.make(base, loginPath: nil, userHome: user, fallbackDirectories: folders)["PATH"]
                == "/Users/me/.nvm/bin:/Users/me/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/local/bin")
        // A login PATH wins over the fallback.
        #expect(ClaudeProcessEnvironment.make(base, loginPath: "/x/bin", userHome: user, fallbackDirectories: folders)["PATH"] == "/x/bin")
        #expect(ClaudeProcessEnvironment.prepending(["/a", "/a", ""], to: nil) == "/a")
    }

    @Test func theSignInScriptExportsTheTestHomeOnlyOnATestProfile() {
        let real = ["HOME": "/Users/me", "PATH": "/usr/bin"]
        #expect(ClaudeProcessEnvironment.exports(ClaudeProcessEnvironment.make(real, loginPath: nil, userHome: user), kite: real) == "")
        let kite = real.merging(["KITE_SUPPORT_PATH": "/tmp/k.1"]) { _, new in new }
        let test = ClaudeProcessEnvironment.make(kite, loginPath: nil, userHome: user)
        #expect(ClaudeProcessEnvironment.exports(test, kite: kite)
                == "export HOME=/tmp/k.1\nexport CLAUDE_CONFIG_DIR=/tmp/k.1/.claude\n")
        // Exported even when Kite's own HOME already matches: the script's login shell may set its own.
        #expect(ClaudeProcessEnvironment.exports(test, kite: kite.merging(["HOME": "/tmp/k.1"]) { _, new in new })
                .hasPrefix("export HOME=/tmp/k.1\n"))
        let quoted = ["HOME": "/tmp/it's here", "CLAUDE_CONFIG_DIR": "/tmp/it's here/.claude"]
        #expect(ClaudeProcessEnvironment.exports(quoted, kite: kite)
                == "export HOME='/tmp/it'\\''s here'\nexport CLAUDE_CONFIG_DIR='/tmp/it'\\''s here/.claude'\n")
    }

    @Test func shellQuoting() {
        #expect(Shell.quote("/usr/local/bin/claude") == "/usr/local/bin/claude")
        #expect(Shell.quote("/Applications/My App") == "'/Applications/My App'")
        #expect(Shell.quote("") == "''")
    }
}

struct LoginShellTests {
    /// A clock the test moves.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.withLock { time } }
        func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
    }

    /// A probe that answers from a list and counts its calls.
    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var outcomes: [LoginShellProbe.Outcome]
        private(set) var calls = 0
        init(_ outcomes: [LoginShellProbe.Outcome]) { self.outcomes = outcomes }
        func run() -> LoginShellProbe.Outcome {
            lock.withLock {
                calls += 1
                return outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
            }
        }
        var count: Int { lock.withLock { calls } }
    }

    @Test func readsThePathAndClaude() {
        #expect(LoginShellProbe.Answers("/opt/homebrew/bin:/usr/bin\n/opt/homebrew/bin/claude\n")
                == .init(path: "/opt/homebrew/bin:/usr/bin", claude: "/opt/homebrew/bin/claude"))
        #expect(LoginShellProbe.Answers("/usr/bin\n") == .init(path: "/usr/bin", claude: nil))
        #expect(LoginShellProbe.Answers("\nclaude not found") == .init())
    }

    @Test func aFailedProbeIsntKept() async {
        let clock = Clock()
        let probe = Probe([.timedOut, .answer("/usr/bin:/bin\n/usr/local/bin/claude\n")])
        let cache = LoginShellCache(probe: { probe.run() }, now: { clock.now })
        let first = await cache.snapshot()
        #expect(first.answers == .init() && first.timedOut)
        // Within the retry interval it doesn't ask again (no 30 s wait on every claude)...
        clock.advance(LoginShellCache.retryInterval - 1)
        #expect(await cache.snapshot().answers == .init())
        #expect(probe.count == 1)
        // ...but after it, it does, and keeps the answer for good.
        clock.advance(2)
        let second = await cache.snapshot()
        #expect(second.answers == .init(path: "/usr/bin:/bin", claude: "/usr/local/bin/claude") && !second.timedOut)
        clock.advance(LoginShellCache.retryInterval * 100)
        #expect(await cache.snapshot().answers.path == "/usr/bin:/bin")
        #expect(probe.count == 2)
    }

    @Test func aMissingClaudeIsAskedAgainAndAfterAnInstall() async {
        let clock = Clock()
        let probe = Probe([.answer("/usr/bin\n"), .answer("/usr/bin\n/Users/me/.local/bin/claude\n")])
        let cache = LoginShellCache(probe: { probe.run() }, now: { clock.now })
        #expect(await cache.snapshot().answers == .init(path: "/usr/bin", claude: nil))
        #expect(await cache.snapshot().answers.claude == nil)
        #expect(probe.count == 1)
        cache.invalidate()
        #expect(await cache.snapshot().answers.claude == "/Users/me/.local/bin/claude")
        #expect(probe.count == 2)
    }

    @Test func callersShareOneProbe() async {
        let probe = Probe([.answer("/usr/bin\n/usr/bin/claude\n")])
        let cache = LoginShellCache(probe: { Thread.sleep(forTimeInterval: 0.2); return probe.run() })
        await withTaskGroup(of: LoginShellCache.Snapshot.self) { group in
            for _ in 0..<8 { group.addTask { await cache.snapshot() } }
            for await snapshot in group { #expect(snapshot.answers.claude == "/usr/bin/claude") }
        }
        #expect(probe.count == 1)
    }

    #if !os(Windows)
    @Test func theProbeAnswersThroughAFileAndTimesOut() {
        #expect(LoginShellProbe.run(LoginShellProbe.script, shell: "/bin/sh", flags: ["-c"]) != .noAnswer)
        #expect(LoginShellProbe.run(#"printf hi > "$1""#, shell: "/bin/sh", flags: ["-c"]) == .answer("hi"))
        #expect(LoginShellProbe.run("exit 3", shell: "/bin/sh", flags: ["-c"]) == .noAnswer)
        let start = Date()
        #expect(LoginShellProbe.run("sleep 5", shell: "/bin/sh", flags: ["-c"], timeout: 0.3) == .timedOut)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func aBackgroundJobNeitherHoldsTheProbeNorDies() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("kite-probe-job-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let start = Date()
        // Like `nohup x &` in .zprofile: a job that outlives the shell.
        let script = "(sleep 1; touch \(Shell.quote(marker.path))) & printf ok > \"$1\""
        #expect(LoginShellProbe.run(script, shell: "/bin/sh", flags: ["-c"]) == .answer("ok"))
        #expect(Date().timeIntervalSince(start) < 0.9)
        Thread.sleep(forTimeInterval: 2)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }
    #endif
}
