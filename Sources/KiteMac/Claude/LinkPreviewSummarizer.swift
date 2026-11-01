import Foundation
import KiteCore

/// Writes a link preview card's AI summary with Kite's built-in Claude: one headless
/// `claude -p` per link, no tools, the page's text on stdin. Summaries are kept per link for
/// the session, as Arc caches its own (`HoverCardViewModel.CacheKey`).
@MainActor
enum LinkPreviewSummarizer {
    /// Arc gives up on a summary after a timeout (`SummaryTimeout`); its length wasn't found. Inferred.
    nonisolated static let timeout: TimeInterval = 30

    private static let cache = NSCache<NSURL, Box>()

    private final class Box {
        let summary: LinkPreviewSummary?
        init(_ summary: LinkPreviewSummary?) { self.summary = summary }
    }

    /// Where Claude Code is, looked up once, off the main thread (nil inside: not installed).
    private static var claude: String??

    /// False once Claude Code is known to be missing: cards then show no summary at all.
    static var mayBeAvailable: Bool { claude.map { $0 != nil } ?? true }

    static func cached(_ url: URL) -> LinkPreviewSummary?? {
        cache.object(forKey: url as NSURL).map(\.summary)
    }

    /// The summary, or nil when Claude failed, timed out or found nothing to say. Cancelling the
    /// task stops Claude Code.
    static func summary(for url: URL, metadata: LinkPreviewMetadata?, pageText: String) async -> LinkPreviewSummary? {
        if let cached = cached(url) { return cached }
        if claude == nil {
            claude = await Task.detached { ClaudeConnect.findClaude() }.value
        }
        guard let claude = claude ?? nil else { return nil }
        let prompt = LinkPreviewSummary.prompt(url: url, metadata: metadata, pageText: pageText,
                                               language: LinkPreviewSummary.languageName())
        let process = Process()
        let reply: String? = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) { run(process, claude: claude, prompt: prompt) }.value
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        guard !Task.isCancelled else { return nil }
        let summary = reply.flatMap(LinkPreviewSummary.parse(reply:))
        // A failed run isn't kept, so the next hover asks again.
        if reply != nil { cache.setObject(Box(summary), forKey: url as NSURL) }
        return summary
    }

    /// Blocks until Claude Code exits, so it runs off the main thread.
    nonisolated private static func run(_ process: Process, claude: String, prompt: String) -> String? {
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = LinkPreviewSummary.claudeArguments()
        process.environment = ClaudeTasksController.environment()
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let writer = input.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            try? writer.write(contentsOf: Data(prompt.utf8))
            try? writer.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && !text.isEmpty ? text : nil
    }
}
