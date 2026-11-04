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
        // The login shell's PATH comes from running zsh: off the main thread, as the run itself is.
        let environment = await Task.detached { ClaudeTasksController.environment() }.value
        guard !Task.isCancelled else { return nil }
        // Its own process group, ended whole at the timeout or when this task is cancelled: a child left
        // holding stdout can't hang the read.
        let process = OneShotProcess(executable: claude, arguments: LinkPreviewSummary.claudeArguments(),
                                     environment: environment, directory: FileManager.default.temporaryDirectory)
        let reply = await process.run(input: Data(prompt.utf8), timeout: timeout).flatMap { result -> String? in
            let text = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return result.status == 0 && !text.isEmpty ? text : nil
        }
        guard !Task.isCancelled else { return nil }
        let summary = reply.flatMap(LinkPreviewSummary.parse(reply:))
        // A failed run isn't kept, so the next hover asks again.
        if reply != nil { cache.setObject(Box(summary), forKey: url as NSURL) }
        return summary
    }
}
