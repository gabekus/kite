import Foundation

/// The AI summary on a link preview card (Arc's `HoverCardSummaryView`): a few words worth
/// knowing about the page, then two to four detail rows, each an SF Symbol, a short label and
/// a short line. Arc asks its model for JSON with `blocked`, `quickSummary` and `details`
/// (label, icon, info); Kite asks its built-in Claude for the same shape, in its own words.
/// Sources are in docs/arc-visual-spec.md.
public struct LinkPreviewSummary: Equatable, Sendable, Codable {
    public struct Detail: Equatable, Sendable, Codable {
        public var label: String
        public var icon: String
        public var info: String

        public init(label: String, icon: String, info: String) {
            self.label = label
            self.icon = icon
            self.info = info
        }
    }

    public var blocked: Bool
    public var quickSummary: String?
    public var details: [Detail]

    public init(blocked: Bool = false, quickSummary: String? = nil, details: [Detail] = []) {
        self.blocked = blocked
        self.quickSummary = quickSummary
        self.details = details
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blocked = (try? container.decodeIfPresent(Bool.self, forKey: .blocked)) ?? false
        quickSummary = try? container.decodeIfPresent(String.self, forKey: .quickSummary)
        details = (try? container.decodeIfPresent([LossyDetail].self, forKey: .details))?.compactMap(\.detail) ?? []
    }

    /// A detail row that's missing a field is dropped rather than failing the whole summary.
    private struct LossyDetail: Decodable {
        var detail: Detail?

        init(from decoder: Decoder) throws {
            detail = try? Detail(from: decoder)
        }
    }

    /// Arc's schema asks for 2–4 details.
    public static let maxDetails = 4

    /// Nothing worth a row: an empty summary, or a page behind a JavaScript or security check.
    public var isEmpty: Bool { blocked || (quickSummary == nil && details.isEmpty) }

    // MARK: Asking Claude

    /// Kite's instructions, written from the fields of Arc's schema (a glanceable answer card in the
    /// writer's tone; a 3–8 word fact or opinion beyond the title; 2–4 details of 5–10 words).
    public static let systemPrompt = """
        You write the summary on a link preview card in Kite, a web browser: someone is holding Shift over a \
        link and wants to know, at a glance, what's on the other side. Keep the writer's tone and point of view.

        Reply with one JSON object and nothing else (no code fence):
        {"blocked": boolean, "quickSummary": string or null, "details": [{"label": string, "icon": string, "info": string}]}

        - blocked: true when the page only asks the reader to turn on JavaScript or pass a security check, \
        so its real content isn't there.
        - quickSummary: 3 to 8 words the reader most likely wants to know beyond the page's title: a fact or \
        an opinion, never just the title again.
        - details: 2 to 4 key points, solutions or items. label is short and ends with a colon, like "Price:", \
        "Story:", "Solution 1:", "Highlights:" or "Criticism:". icon is the name of a fitting SF Symbol, like \
        "fork.knife". info is 5 to 10 words, as tight as possible.

        Write the text (not the keys) in the language asked for. Markdown bold and italics are fine inside \
        the strings.

        \(UntrustedContent.notice)
        """

    /// Claude Code's arguments: the fast model, no tools, no MCP servers, nothing saved. The
    /// message goes on stdin.
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

    /// The linked page's text sent along is cut to this many characters.
    public static let maxPageCharacters = 20_000

    /// The message for one card: the page's address, title, description and text.
    public static func prompt(url: URL, metadata: LinkPreviewMetadata?, pageText: String, language: String) -> String {
        var parts = ["Write the card's text in \(language)."]
        parts.append("Page address: \(url.absoluteString)")
        if let title = metadata?.title { parts.append("Page title: \(UntrustedContent.defuse(title))") }
        if let summary = metadata?.summary { parts.append("Page description: \(UntrustedContent.defuse(summary))") }
        let text = String(pageText.prefix(maxPageCharacters))
        parts.append(text.isEmpty ? "The page has no readable text." : UntrustedContent.wrap(text, source: url.absoluteString))
        return parts.joined(separator: "\n\n")
    }

    /// The user's language by name ("English"), for the prompt.
    public static func languageName(for identifier: String? = Locale.preferredLanguages.first) -> String {
        let code = identifier?.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? "en"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }

    /// Reads Claude's reply: the JSON object in it (code fences and stray text around it are
    /// ignored), trimmed, at most four details. Nil when there's nothing to show.
    public static func parse(reply: String) -> LinkPreviewSummary? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              var summary = try? JSONDecoder().decode(LinkPreviewSummary.self, from: Data(reply[start...end].utf8))
        else { return nil }
        summary.quickSummary = summary.quickSummary.map(clean).flatMap { $0.isEmpty ? nil : $0 }
        summary.details = summary.details.compactMap { detail in
            let row = Detail(label: clean(detail.label), icon: detail.icon.trimmingCharacters(in: .whitespaces), info: clean(detail.info))
            return row.label.isEmpty && row.info.isEmpty ? nil : row
        }
        summary.details = Array(summary.details.prefix(maxDetails))
        return summary.isEmpty ? nil : summary
    }

    private static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Page text

    /// The readable text of an HTML page, for the summary: scripts, styles and markup removed,
    /// entities decoded, whitespace collapsed.
    public static func pageText(html: String) -> String {
        var body = Substring(html)
        if let open = body.range(of: "<body", options: .caseInsensitive) { body = body[open.lowerBound...] }
        var text = String(body)
        for element in ["script", "style", "noscript", "svg", "template", "head"] {
            text = text.replacingOccurrences(of: "<\(element)\\b[\\s\\S]*?</\(element)\\s*>", with: " ",
                                             options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        return LinkPreviewMetadata.clean(text)
    }
}
