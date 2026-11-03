import Darwin
import Foundation
import KiteCore

/// `kite setup`: starts Claude Code with Kite's setup guide (Resources/SETUP.md, shipped in
/// Kite.app's Contents/Resources), so Claude walks the user through connecting it. The guide
/// is the one source: the share folder's install.sh and the README point here too.
enum Setup {
    static let usage = """
        kite setup: set Kite up with Claude Code, step by step.

        Usage:
          kite setup           Start Claude Code with Kite's setup guide
          kite setup --print   Print the guide (SETUP.md), e.g. to paste into the Claude app
          kite setup --path    Print where the guide is
        """

    static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"

    static func run(_ arguments: [String]) -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return 0
        }
        guard let guide = guidePath() else {
            fail("Couldn't find SETUP.md next to this kite (\(executablePath() ?? "?")). Is Kite.app complete?")
            return 1
        }
        if arguments.contains("--path") {
            print(guide)
            return 0
        }
        if arguments.contains("--print") {
            guard let text = try? String(contentsOfFile: guide, encoding: .utf8) else {
                fail("Couldn't read \(guide).")
                return 1
            }
            print(text)
            return 0
        }

        var claude = findClaude()
        if claude == nil {
            print("Claude Code isn't installed. Kite's setup runs in it, on your own Claude plan.")
            guard isatty(STDIN_FILENO) == 1, confirm("Install it now with Anthropic's installer (\(installCommand))?") else {
                print("\nInstall it, then run `kite setup` again:\n  \(installCommand)\n\nOr follow the guide yourself: \(guide)")
                return 1
            }
            let status = shell(installCommand)
            claude = findClaude()
            guard status == 0, claude != nil else {
                fail("Claude Code didn't install. Run `\(installCommand)` yourself, then `kite setup`.")
                return 1
            }
        }
        guard let claude else { return 1 }

        let kite = executablePath() ?? "kite"
        let prompt = ClaudeSetupPrompt.pointingAt(guidePath: guide, kite: kite)
        print("Starting Claude Code with Kite's setup guide…")
        let argv = [claude, prompt]
        var cArgs = argv.map { strdup($0) } + [nil]
        execv(claude, &cArgs)
        fail("Couldn't start \(claude): \(String(cString: strerror(errno)))")
        return 1
    }

    /// Contents/Helpers/kite → Contents/Resources/SETUP.md. A dev build (.build/…/debug/kite-cli)
    /// finds the repo's Resources/SETUP.md a few levels up.
    static func guidePath() -> String? {
        guard let exe = executablePath() else { return nil }
        var dir = URL(fileURLWithPath: exe).deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = dir.appendingPathComponent("Resources/SETUP.md").path
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// The real path of this binary, through the ~/.local/bin/kite symlink.
    static func executablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0, let real = realpath(buffer, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    /// The shell's PATH first, then where Claude Code's installer puts it.
    static func findClaude() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
        for candidate in path + ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    static func confirm(_ question: String) -> Bool {
        print("\(question) [y/N] ", terminator: "")
        fflush(stdout)
        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return answer == "y" || answer == "yes"
    }

    static func shell(_ command: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func fail(_ message: String) {
        FileHandle.standardError.write(Data("kite: \(message)\n".utf8))
    }
}
