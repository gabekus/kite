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

    /// Claude Code with its environment, once found. Not found is never kept: it's looked for again
    /// `LoginShellCache.retryInterval` later (the login shell may just have been slow).
    private static var claude: ClaudeCommand?
    private static var missingSince: Date?

    /// False while Claude Code was just found missing: cards then show no summary at all.
    static var mayBeAvailable: Bool { claude != nil || !recentlyMissing }

    private static var recentlyMissing: Bool {
        missingSince.map { Date().timeIntervalSince($0) < LoginShellCache.retryInterval } ?? false
    }

    static func cached(_ url: URL) -> LinkPreviewSummary?? {
        cache.object(forKey: url as NSURL).map(\.summary)
    }

    /// The summary, or nil when Claude failed, timed out or found nothing to say. Cancelling the
    /// task stops Claude Code.
    static func summary(for url: URL, metadata: LinkPreviewMetadata?, pageText: String) async -> LinkPreviewSummary? {
        if let cached = cached(url) { return cached }
        if claude == nil, !recentlyMissing {
            claude = await ClaudeCommand.find()
            missingSince = claude == nil ? Date() : nil
        }
        guard let claude else { return nil }
        let prompt = LinkPreviewSummary.prompt(url: url, metadata: metadata, pageText: pageText,
                                               language: LinkPreviewSummary.languageName())
        guard !Task.isCancelled else { return nil }
        // Its own process group, ended whole at the timeout or when this task is cancelled: a child left
        // holding stdout can't hang the read.
        let process = claude.oneShot(arguments: LinkPreviewSummary.claudeArguments(),
                                     directory: FileManager.default.temporaryDirectory)
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
