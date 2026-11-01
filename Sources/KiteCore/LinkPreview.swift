import Foundation

/// Arc's "5-Second Previews" (its `HoverCards` module): hold ⇧ while hovering a link and a card
/// about the linked page appears next to it. Kite's card shows the page's own title, description
/// and image; Arc's adds an AI summary. Numbers and sources are in docs/arc-visual-spec.md.
public enum LinkPreview {
    /// Settings key. Arc's is `hoverCardsEnabled` (an Arc Max feature, off until you opt in, and
    /// off in Gabe's Arc), so Kite's is off too until turned on from the Kite menu.
    public static let enabledKey = "linkPreviewsEnabled"

    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? false
    }

    /// Only web links get a card.
    public static func canPreview(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host() != nil
    }

    /// A status-bar string (Chromium reports the hovered link that way) as a link, or nil
    /// for anything that isn't a web URL.
    public static func link(fromStatus status: String?) -> URL? {
        guard let status = status?.trimmingCharacters(in: .whitespacesAndNewlines), !status.isEmpty,
              let url = URL(string: status) ?? status.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:)),
              canPreview(url) else { return nil }
        return url
    }

    /// Timing from Arc's binary (HoverCardsController).
    public enum Timing {
        /// Hover changes are debounced this long before a card is asked for (`.milliseconds(100)`).
        public static let showDelay: Double = 0.1
        /// After the pointer leaves the link, the card waits this long before closing (`asyncAfter` 0.2).
        public static let leaveDelay: Double = 0.2
        /// The card window fades in and out over this (`NSAnimationContext` duration 0.15).
        public static let fade: Double = 0.15
    }

    /// Geometry from Arc's binary (HoverCardView, HoverCardsController).
    public enum Metrics {
        /// `.frame(maxWidth: 300, maxHeight: 400)` on the card.
        public static let width: Double = 300
        public static let maxHeight: Double = 400
        /// Continuous corner radius of the card's rounded rectangle.
        public static let cornerRadius: Double = 12
        /// The card's window is the card's frame grown by this on every side, for the shadow
        /// (`CGRectInset(frame, -30, -30)`).
        public static let windowInset: Double = 30
        /// Gap between the link and the card. Inferred: not found in the binary.
        public static let gap: Double = 8
        /// Keeps the card this far inside the window's edges. Inferred.
        public static let edgeMargin: Double = 8
    }

    /// A rectangle in AppKit screen coordinates (origin bottom-left, y up).
    public struct Box: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        var top: Double { y + height }
        var right: Double { x + width }
    }

    /// Which side of the link the card opens on.
    public enum Placement: Equatable, Sendable {
        case below
        case above
    }

    /// Where the card goes: below the link, left edges aligned, flipped above when there's no
    /// room below, and kept inside `bounds` (the browser window).
    public static func cardFrame(link: Box, cardHeight: Double, in bounds: Box) -> (frame: Box, placement: Placement) {
        let width = Metrics.width
        let height = min(cardHeight, Metrics.maxHeight)
        let minX = bounds.x + Metrics.edgeMargin
        let maxX = bounds.right - Metrics.edgeMargin - width
        let x = max(minX, min(link.x, maxX))
        let below = link.y - Metrics.gap - height
        if below >= bounds.y + Metrics.edgeMargin {
            return (Box(x: x, y: below, width: width, height: height), .below)
        }
        let above = link.top + Metrics.gap
        if above + height <= bounds.top - Metrics.edgeMargin {
            return (Box(x: x, y: above, width: width, height: height), .above)
        }
        // No room either side: whichever has more, pinned inside the window.
        let roomBelow = link.y - bounds.y
        let roomAbove = bounds.top - link.top
        let y = roomBelow >= roomAbove ? bounds.y + Metrics.edgeMargin : bounds.top - Metrics.edgeMargin - height
        return (Box(x: x, y: y, width: width, height: height), roomBelow >= roomAbove ? .below : .above)
    }

    /// Whether `point` is still "on the way" between the link and the card, so the card stays
    /// open while the pointer travels to it. Arc builds the same kind of polygon from the card's
    /// corners and the pointer, 24pt past the card (HoverCardsController's mouse handler).
    public static func isInCorridor(x: Double, y: Double, link: Box, card: Box, slack: Double = 24) -> Bool {
        let minX = min(link.x, card.x) - slack
        let maxX = max(link.right, card.right) + slack
        let minY = min(link.y, card.y) - slack
        let maxY = max(link.top, card.top) + slack
        return x >= minX && x <= maxX && y >= minY && y <= maxY
    }
}

/// What a page says about itself in its `<head>`: enough for a preview card.
public struct LinkPreviewMetadata: Equatable, Sendable {
    public var title: String?
    public var summary: String?
    public var imageURL: URL?
    public var siteName: String?

    public init(title: String? = nil, summary: String? = nil, imageURL: URL? = nil, siteName: String? = nil) {
        self.title = title
        self.summary = summary
        self.imageURL = imageURL
        self.siteName = siteName
    }

    public var isEmpty: Bool { title == nil && summary == nil && imageURL == nil }

    /// Only the start of a page is read; the head is nearly always well inside this.
    public static let maxBytes = 512 * 1024

    /// Open Graph and Twitter tags first, then `<title>` and the description meta tag.
    public static func parse(html: String, baseURL: URL) -> LinkPreviewMetadata {
        let head: Substring
        if let end = html.range(of: "</head>", options: .caseInsensitive) {
            head = html[..<end.lowerBound]
        } else {
            head = html.prefix(200_000)
        }
        var meta: [String: String] = [:]
        for tag in matches(#"<meta\b[^>]*>"#, in: head) {
            let attributes = Self.attributes(of: tag)
            guard let key = (attributes["property"] ?? attributes["name"])?.lowercased(),
                  let content = attributes["content"], meta[key] == nil else { continue }
            let value = clean(content)
            if !value.isEmpty { meta[key] = value }
        }
        let titleTag = firstGroup(#"<title\b[^>]*>([\s\S]*?)</title>"#, in: head).map(clean)
        let title = meta["og:title"] ?? meta["twitter:title"] ?? titleTag.flatMap { $0.isEmpty ? nil : $0 }
        let summary = meta["og:description"] ?? meta["twitter:description"] ?? meta["description"]
        let image = (meta["og:image"] ?? meta["og:image:url"] ?? meta["twitter:image"] ?? meta["twitter:image:src"])
            .flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
            .flatMap { LinkPreview.canPreview($0) ? $0 : nil }
        return LinkPreviewMetadata(title: title, summary: summary, imageURL: image, siteName: meta["og:site_name"])
    }

    // MARK: Parsing

    private static func matches(_ pattern: String, in text: Substring) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let string = String(text)
        return regex.matches(in: string, range: NSRange(string.startIndex..., in: string)).compactMap {
            Range($0.range, in: string).map { String(string[$0]) }
        }
    }

    private static func firstGroup(_ pattern: String, in text: Substring) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let string = String(text)
        guard let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let range = Range(match.range(at: 1), in: string) else { return nil }
        return String(string[range])
    }

    /// `name="value"`, `name='value'` and `name=value` attributes of one tag, keys lowercased.
    static func attributes(of tag: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#
        ) else { return [:] }
        var result: [String: String] = [:]
        for match in regex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let name = Range(match.range(at: 1), in: tag).map({ tag[$0].lowercased() }) else { continue }
            let value = (2...4).lazy.compactMap { Range(match.range(at: $0), in: tag) }.first.map { String(tag[$0]) } ?? ""
            if result[name] == nil { result[name] = value }
        }
        return result
    }

    /// Entities decoded, whitespace collapsed.
    static func clean(_ text: String) -> String {
        decodeEntities(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "#39": "'", "nbsp": " ",
                     "mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“"]
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            guard let semi = after.prefix(10).firstIndex(of: ";") else {
                result += "&"
                rest = after
                continue
            }
            let name = String(after[..<semi])
            var decoded: String?
            if let value = named[name.lowercased()] {
                decoded = value
            } else if name.hasPrefix("#x") || name.hasPrefix("#X") {
                decoded = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if name.hasPrefix("#") {
                decoded = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            }
            if let decoded {
                result += decoded
                rest = after[after.index(after: semi)...]
            } else {
                result += "&"
                rest = after
            }
        }
        return result + rest
    }
}
