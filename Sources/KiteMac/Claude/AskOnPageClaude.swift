import Foundation
import KiteCore

/// Answers Ask on Page questions with Kite's built-in Claude: one headless `claude -p` per
/// question, with no tools, the page's text and the conversation so far on stdin.
@MainActor
final class AskOnPageClaude {
    private var process: Process?
    private var generation = 0

    var isAsking: Bool { process != nil }

    /// Calls `completion` on the main thread with the answer, or nil when Claude Code failed.
    /// A newer question, or `cancel()`, drops the older one's answer.
    func ask(_ prompt: String, completion: @escaping (String?) -> Void) {
        cancel()
        generation += 1
        let mine = generation
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KiteAskOnPage", isDirectory: true)
        Task.detached { [weak self] in
            let claude = ClaudeConnect.findClaude()
            let environment = ClaudeTasksController.environment()
            await self?.run(claude: claude, environment: environment, directory: directory, prompt: prompt,
                            generation: mine, completion: completion)
        }
    }

    func cancel() {
        generation += 1
        process?.terminate()
        process = nil
    }

    private func run(claude: String?, environment: [String: String], directory: URL, prompt: String,
                     generation mine: Int, completion: @escaping (String?) -> Void) {
        guard mine == generation else { return }
        guard let claude else { return completion(nil) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = AskOnPage.claudeArguments()
        process.environment = environment
        process.currentDirectoryURL = directory
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return completion(nil)
        }
        self.process = process
        let writer = input.fileHandleForWriting
        let reader = output.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            try? writer.write(contentsOf: Data(prompt.utf8))
            try? writer.close()
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = reader.readDataToEndOfFile()
            process.waitUntilExit()
            let status = process.terminationStatus
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, mine == self.generation else { return }
                    self.process = nil
                    completion(status == 0 && !text.isEmpty ? text : nil)
                }
            }
        }
    }
}
