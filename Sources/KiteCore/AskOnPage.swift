import Foundation

/// Arc Max's "Ask on Page" (its `AskInPage` module): with it on, ⌘F's find bar reads "Find or ask…",
/// and a query the page doesn't contain becomes a question for an AI, answered under the bar with
/// quotes from the page you can click to find. Kite asks its built-in Claude. Evidence and what is
/// inferred are in docs/arc-visual-spec.md ("Ask on Page").
public enum AskOnPage {
    /// Settings key. Arc's is `askOnPageEnabled` (an Arc Max feature, off in Gabe's Arc), so
    /// Kite's is off too until turned on from the Kite menu.
    public static let enabledKey = "askOnPageEnabled"

    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    /// The find field's placeholder, as Arc picks it: plain find with the feature off,
    /// "Find or ask…" with it on, "Ask a question…" once a conversation has started.
    public static func placeholder(enabled: Bool, inConversation: Bool) -> String {
        if !enabled { return "Find in page…" }
        return inConversation ? "Ask a question…" : "Find or ask…"
    }

    /// Whether Return asks instead of finding. Arc: with the feature on, a non-blank query the
    /// page has no match for (a finished search, `numMatches == 0`) is a question; otherwise
    /// it's a question only once the bar is in a conversation. `matches` is nil until a search
    /// for the current query has come back.
    public static func isAskMode(enabled: Bool, query: String, matches: Int?, inConversation: Bool) -> Bool {
        guard enabled else { return false }
        let blank = query.trimmingCharacters(in: .whitespaces).isEmpty
        if !blank, matches == 0 { return true }
        return inConversation
    }

    /// Arc's label when a finished search found nothing, Ask on Page on (its SwiftUI `AskInPageView`,
    /// disassembly `0x10215ae18`).
    public static let noMatchesLabel = "No matches"

    /// The same with Ask on Page off: Arc's AppKit `FindInPageView` shows its `noResultsView`,
    /// "Not Found" (`0x1003292e0`) in the `FindInPageError` red, in the counter's place.
    public static let notFoundLabel = "Not Found"

    /// The text right of the query, as Arc's find views pick it: nothing for an empty query or
    /// before the search comes back, "No matches" / "Not Found" for none (Ask on Page on / off),
    /// else "active/total". `matches` is nil when the engine only says found or not (WebKit),
    /// which shows nothing when found.
    public static func matchLabel(query: String, found: Bool, matches: Int?, activeMatch: Int?,
                                  askEnabled: Bool) -> String {
        guard !query.isEmpty else { return "" }
        guard let total = matches ?? (found ? nil : 0) else { return "" }
        guard total >= 1 else { return askEnabled ? noMatchesLabel : notFoundLabel }
        return "\(activeMatch ?? 0)/\(total)"
    }

    /// Each tab's conversation while the tab isn't shown, so it's still there when you come back
    /// (Arc keeps its `askInPageState` with each window content). Esc, or ⌘F in the field, still
    /// ends a conversation; closing the tab drops it.
    public struct Conversations<Value> {
        private var stored: [UUID: Value] = [:]

        public init() {}

        public var tabs: Set<UUID> { Set(stored.keys) }

        public mutating func keep(_ value: Value, for tab: UUID) { stored[tab] = value }

        /// The tab's conversation, taken out to be shown again.
        public mutating func take(for tab: UUID) -> Value? { stored.removeValue(forKey: tab) }

        /// Drops the conversations of tabs that are gone and returns them (to stop their answers).
        public mutating func prune(keeping live: Set<UUID>) -> [Value] {
            let gone = stored.keys.filter { !live.contains($0) }
            return gone.compactMap { stored.removeValue(forKey: $0) }
        }
    }

    /// How much of the page's text goes to Claude. Arc counts tokens; Kite counts characters
    /// (about 15k tokens), which is plenty for an article and keeps the answer quick.
    public static let maxPageCharacters = 60_000

    public struct PageText: Equatable, Sendable {
        public var text: String
        /// Below 1 when the page was cut to fit; Arc then says "This page was long, so I read the first …".
        public var fractionRead: Double

        public var wasTruncated: Bool { fractionRead < 1 }
    }

    public static func pageText(_ raw: String, limit: Int = maxPageCharacters) -> PageText {
        // innerText keeps every blank line; runs of them only cost characters.
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var collapsed: [String] = []
        for line in lines where !(line.isEmpty && (collapsed.last?.isEmpty ?? true)) { collapsed.append(line) }
        let text = collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return PageText(text: text, fractionRead: 1) }
        return PageText(text: String(text.prefix(limit)), fractionRead: Double(limit) / Double(text.count))
    }

    /// Shown above an answer to a page that was cut.
    public static func longPageNote(fractionRead: Double) -> String {
        let percent = max(1, min(99, Int((fractionRead * 100).rounded(.down))))
        return "This page was long, so I read the first \(percent)%."
    }

    /// One question and its answer in the bar's conversation.
    public struct Exchange: Equatable, Sendable {
        public var question: String
        public var answer: String?
        public var failed = false

        public init(question: String, answer: String? = nil, failed: Bool = false) {
            self.question = question
            self.answer = answer
            self.failed = failed
        }
    }

    /// Earlier exchanges sent along with a question; older ones are dropped (Arc: "[Older messages hidden]").
    public static let maxHistory = 6

    /// Kite's own instructions for Claude, written from what Arc's answers do (quote the page,
    /// then a short answer with the key term in bold; say when it's a guess).
    public static let systemPrompt = """
        You answer questions about the web page the user is reading in Kite, their browser. The page's text \
        is in the user's message. Be as brief as possible: one sentence is best.

        When the page answers the question, first copy the sentence from the page that supports the answer, \
        word for word, between <excerpt> and </excerpt> on a line of its own (the user can click it to find it \
        on the page, so don't change a word). On the next line give the answer in ten words or fewer, with the \
        words that answer the question in **bold**. If the page doesn't answer it, answer from what you know \
        and say plainly that it isn't from the page. You may also summarise, translate or rewrite the page's \
        text when asked. Use Markdown, never HTML. Reply in the language of the question.

        \(UntrustedContent.notice)
        """

    /// The message sent to Claude: the page, the conversation so far, and the question.
    public static func prompt(question: String, history: [Exchange], url: URL?, title: String?, page: PageText) -> String {
        var parts: [String] = []
        let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        parts.append("Today is \(date).")
        if let title, !title.isEmpty { parts.append("Page title: \(UntrustedContent.defuse(title))") }
        if let url { parts.append("Page address: \(url.absoluteString)") }
        parts.append(page.text.isEmpty
            ? "The page has no readable text."
            : UntrustedContent.wrap(page.text, source: url?.absoluteString))
        let earlier = history.filter { $0.answer != nil }.suffix(maxHistory)
        if !earlier.isEmpty {
            var lines = ["Earlier in this conversation:"]
            if history.filter({ $0.answer != nil }).count > maxHistory { lines.append("[Older messages hidden]") }
            for exchange in earlier {
                lines.append("Q: \(exchange.question)")
                lines.append("A: \(exchange.answer ?? "")")
            }
            parts.append(lines.joined(separator: "\n"))
        }
        parts.append("Question: \(question)")
        return parts.joined(separator: "\n\n")
    }

    /// A piece of an answer: plain Markdown text, or a quote from the page (Arc's `QuoteView`).
    public enum Part: Equatable, Sendable {
        case text(String)
        case quote(String)
    }

    /// Splits an answer at its `<excerpt>` tags.
    public static func parts(of answer: String) -> [Part] {
        var parts: [Part] = []
        var rest = answer[...]
        func appendText(_ text: Substring) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(.text(trimmed)) }
        }
        while let open = rest.range(of: "<excerpt>", options: .caseInsensitive) {
            appendText(rest[..<open.lowerBound])
            let body = rest[open.upperBound...]
            let close = body.range(of: "</excerpt>", options: .caseInsensitive)
            let quote = body[..<(close?.lowerBound ?? body.endIndex)]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
            if !quote.isEmpty { parts.append(.quote(quote)) }
            rest = close.map { body[$0.upperBound...] } ?? body[body.endIndex...]
        }
        appendText(rest)
        return parts
    }

    /// What to search the page for when a quote is clicked: the quote without Markdown, and a
    /// shorter fallback for pages whose text breaks a long sentence across elements.
    public static func searchTerms(forQuote quote: String) -> [String] {
        let plain = quote.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return [] }
        var terms = [plain]
        let words = plain.split(separator: " ")
        if words.count > 8 { terms.append(words.prefix(6).joined(separator: " ")) }
        return terms
    }

    /// Claude Code's arguments for one answer: no tools, no MCP servers, nothing saved, the fast model.
    /// The message goes on stdin.
    public static func claudeArguments() -> [String] {
        [
            "-p",
            "--output-format", "text",
            "--model", "haiku",
            "--tools", "",
            "--strict-mcp-config",
            "--no-session-persistence",
            "--system-prompt", systemPrompt,
        ]
    }

    /// Arc's errors, word for word.
    public static let errorMessage = "Sorry, I encountered an error"
    public static let unreadablePageMessage = "Sorry, I can’t read this type of page."
    public static let quoteNotFoundMessage = "Quote not found. Make sure it’s accurate!"
}
