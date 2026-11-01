import Foundation
import KiteCore

/// Tidy Tabs' one question to Kite's built-in Claude: a headless `claude -p` on the user's
/// own Claude login, with no tools (TidyTabs.claudeArguments). Not a Claude Task: nothing
/// shows in the ⌘J panel.
enum TidyTabsClient {
    enum Failure: Error {
        case noClaude
        case failed(String)
    }

    /// Claude's reply text. Gives up after `timeout` seconds.
    static func ask(_ prompt: String, timeout: TimeInterval = 90) async throws -> String {
        try await Task.detached(priority: .userInitiated) { try run(prompt, timeout: timeout) }.value
    }

    /// Blocks until Claude Code exits, so it runs off the main thread.
    private static func run(_ prompt: String, timeout: TimeInterval) throws -> String {
        guard let claude = ClaudeConnect.findClaude() else { throw Failure.noClaude }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = TidyTabs.claudeArguments
        process.environment = ClaudeTasksController.environment()
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { throw Failure.failed(error.localizedDescription) }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        try? input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
        try? input.fileHandleForWriting.close()
        // Read stderr alongside so a chatty Claude Code can't fill its pipe and stall.
        final class Box: @unchecked Sendable { var data = Data() }
        let stderrBox = Box(), group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            stderrBox.data = errors.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()
        killer.cancel()
        let stderrData = stderrBox.data
        guard process.terminationStatus == 0 else {
            let message = String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.failed(message.isEmpty ? "Claude Code exited with \(process.terminationStatus)" : message)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
