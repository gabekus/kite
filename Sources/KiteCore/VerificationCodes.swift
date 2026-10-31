import Foundation

/// One-time codes sent by email ("Your FedEx verification code is 482913"), found in
/// recent mail so Kite can offer them in the code field that asked for them.
public enum VerificationCodes {
    /// Codes older than this are stale (most expire within 10 minutes).
    public static let maxAge: TimeInterval = 15 * 60

    public struct Message: Equatable, Sendable {
        public var subject: String
        public var snippet: String
        public var senderName: String
        public var senderEmail: String
        public var date: Date

        public init(subject: String, snippet: String, senderName: String, senderEmail: String, date: Date) {
            self.subject = subject
            self.snippet = snippet
            self.senderName = senderName
            self.senderEmail = senderEmail
            self.date = date
        }
    }

    public struct Code: Equatable, Sendable {
        public var code: String
        /// Who sent it, as the mail names them ("FedEx").
        public var sender: String
        public var date: Date
    }

    // MARK: Finding the code in a message

    private static let keywords = try! NSRegularExpression(
        pattern: #"\b(code|verification|verify|one[- ]?time|passcode|pass code|otp|security|sign[- ]?in|log[- ]?in|login|2fa|mfa|authenticat\w*|confirm\w*|pin)\b"#,
        options: [.caseInsensitive]
    )
    /// 4–8 digits (optionally split once by a space or dash, "482 913"), or 5–8 capitals
    /// and digits with at least one digit ("K7P2QX").
    private static let candidates = try! NSRegularExpression(
        pattern: #"(?<![\w-])(\d{3,4}[ -]\d{3,4}|\d{4,8}|(?=[A-Z0-9]*\d)(?=[A-Z0-9]*[A-Z])[A-Z0-9]{5,8})(?![\w-])"#
    )

    /// The code in a message, when it reads like a code message: its subject or text
    /// talks about a code, and a code-shaped token sits near those words.
    public static func code(in message: Message) -> String? {
        for text in [message.subject, message.snippet] {
            if let code = code(inText: text) { return code }
        }
        return nil
    }

    static func code(inText text: String) -> String? {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let keywordRanges = keywords.matches(in: text, range: full).map(\.range)
        guard !keywordRanges.isEmpty else { return nil }
        var best: (code: String, distance: Int)?
        for match in candidates.matches(in: text, range: full) {
            let token = ns.substring(with: match.range)
            let code = token.filter { $0 != " " && $0 != "-" }
            guard (4...8).contains(code.count), !looksLikeNoise(code, in: ns, at: match.range) else { continue }
            let distance = keywordRanges.map { k in
                k.location > match.range.location ? k.location - NSMaxRange(match.range) : match.range.location - NSMaxRange(k)
            }.map(abs).min() ?? .max
            guard distance <= 80 else { continue }
            // Six digits is by far the usual shape.
            let score = distance - (code.count == 6 && code.allSatisfy(\.isNumber) ? 40 : 0)
            if best == nil || score < best!.distance { best = (code, score) }
        }
        return best?.code
    }

    /// Years, times, prices, phone-number pieces and the like.
    private static func looksLikeNoise(_ code: String, in text: NSString, at range: NSRange) -> Bool {
        if code.count == 4, let year = Int(code), (1990...2099).contains(year) { return true }
        let before = range.location > 0 ? text.substring(with: NSRange(location: range.location - 1, length: 1)) : ""
        let after = NSMaxRange(range) < text.length ? text.substring(with: NSRange(location: NSMaxRange(range), length: 1)) : ""
        return ["$", "€", "£", "#", "+", ":", ".", ","].contains(before) || [":", "%"].contains(after)
            || (after == "." && NSMaxRange(range) + 1 < text.length
                && CharacterSet.decimalDigits.contains(text.substring(with: NSRange(location: NSMaxRange(range) + 1, length: 1)).unicodeScalars.first!))
    }

    // MARK: Choosing one for a site

    /// The code to offer on `host`: recent codes only, from a sender on the site's own
    /// domain first, else one whose name matches the site, else the newest.
    public static func best(in messages: [Message], forHost host: String?, now: Date = Date()) -> Code? {
        let recent = messages.filter { now.timeIntervalSince($0.date) <= maxAge && $0.date <= now.addingTimeInterval(60) }
        let found = recent.compactMap { m in code(in: m).map { (m, Code(code: $0, sender: m.senderName.isEmpty ? m.senderEmail : m.senderName, date: m.date)) } }
            .sorted { $0.1.date > $1.1.date }
        guard let first = found.first else { return nil }
        guard let site = host.map(siteName) else { return first.1 }
        if let match = found.first(where: { siteName($0.0.senderEmail.split(separator: "@").last.map(String.init) ?? "") == site }) {
            return match.1
        }
        if let match = found.first(where: { ($0.0.senderName + " " + $0.0.subject).lowercased().contains(site) }) {
            return match.1
        }
        return first.1
    }

    /// "fedex" for www.fedex.com, mail.fedex.co.uk or fedex.com.
    static func siteName(_ host: String) -> String {
        var labels = host.lowercased().split(separator: ".").map(String.init)
        if labels.count >= 3, ["co", "com", "org", "net", "ac", "gov"].contains(labels[labels.count - 2]), labels.last!.count == 2 {
            labels.removeLast()
        }
        return labels.count >= 2 ? labels[labels.count - 2] : labels.first ?? ""
    }

    // MARK: Gmail's feed

    /// Messages in a Gmail Atom feed (`/mail/u/N/feed/atom`: unread mail in the inbox).
    public static func parseGmailFeed(_ data: Data) -> [Message] {
        let parser = FeedParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return parser.messages
    }

    private final class FeedParser: NSObject, XMLParserDelegate {
        var messages: [Message] = []
        private var current: [String: String]?
        private var path: [String] = []
        private var text = ""
        private let dates: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }()

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            path.append(name)
            text = ""
            if name == "entry" { current = [:] }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { path.removeLast() }
            guard current != nil else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch (path.dropLast().last, name) {
            case ("entry", "title"): current?["subject"] = value
            case ("entry", "summary"): current?["snippet"] = value
            case ("entry", "issued"), ("entry", "modified"):
                if current?["date"] == nil { current?["date"] = value }
            case ("author", "name"): current?["name"] = value
            case ("author", "email"): current?["email"] = value
            case (_, "entry"):
                if let entry = current, let date = entry["date"].flatMap(dates.date(from:)) {
                    messages.append(Message(subject: entry["subject"] ?? "", snippet: entry["snippet"] ?? "",
                                            senderName: entry["name"] ?? "", senderEmail: entry["email"] ?? "", date: date))
                }
                current = nil
            default: break
            }
            text = ""
        }
    }
}
