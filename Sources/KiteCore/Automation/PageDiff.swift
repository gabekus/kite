import Foundation

/// What changed on a page between two reads: lines of the outline and of the
/// text that appeared or went away. After an action this replaces a whole new
/// read_page, which keeps Claude's context small on long tasks.
public enum PageDiff {
    /// A read of a page, kept as the baseline for the next diff.
    public struct Snapshot: Hashable, Sendable {
        public var url: String
        public var outline: [String]
        public var text: [String]

        public init(url: String, outline: String, text: String) {
            self.url = url
            // Outline lines lose their "- " bullet and indent; the diff adds its own +/- marks.
            self.outline = Self.lines(outline).map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }
            self.text = Self.lines(text)
        }

        static func lines(_ text: String) -> [String] {
            text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }

    public struct Change: Hashable, Sendable {
        public var added: [String]
        public var removed: [String]
        public var isEmpty: Bool { added.isEmpty && removed.isEmpty }
        public var count: Int { added.count + removed.count }
    }

    /// Added and removed lines, in page order. Lines that only moved count as unchanged.
    public static func change(from old: [String], to new: [String]) -> Change {
        // Longest common subsequence over lines; outlines are capped at 1,500 lines, so n·m stays small.
        // Trim the shared start and end first, which is most of a page after a small change.
        var start = 0
        while start < old.count, start < new.count, old[start] == new[start] { start += 1 }
        var endOld = old.count, endNew = new.count
        while endOld > start, endNew > start, old[endOld - 1] == new[endNew - 1] {
            endOld -= 1
            endNew -= 1
        }
        let a = Array(old[start..<endOld]), b = Array(new[start..<endNew])
        guard !a.isEmpty || !b.isEmpty else { return Change(added: [], removed: []) }
        guard a.count * b.count <= 4_000_000 else { return Change(added: b, removed: a) }

        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var added: [String] = [], removed: [String] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                i += 1
                j += 1
            } else if j < b.count, i == a.count || table[i][j + 1] >= table[i + 1][j] {
                added.append(b[j])
                j += 1
            } else {
                removed.append(a[i])
                i += 1
            }
        }
        return Change(added: added, removed: removed)
    }

    /// The change from one read to the next, written for the model. Nil when the
    /// difference is too big to be useful (a new page): read the page instead.
    public static func report(from old: Snapshot, to new: Snapshot, maxLines: Int = 60) -> String? {
        if old.url != new.url { return nil }
        let outline = change(from: old.outline, to: new.outline)
        let text = change(from: old.text, to: new.text)
        if outline.isEmpty && text.isEmpty { return "Nothing on the page changed." }
        guard outline.count + text.count <= maxLines else { return nil }
        var lines: [String] = []
        if !outline.isEmpty {
            lines.append("Outline:")
            lines += outline.removed.map { "- " + $0 } + outline.added.map { "+ " + $0 }
        }
        if !text.isEmpty {
            lines.append("Text:")
            lines += text.removed.map { "- " + $0 } + text.added.map { "+ " + $0 }
        }
        return lines.joined(separator: "\n")
    }
}

/// Screenshots wider than `maxWidth` are scaled down: Claude's image cost grows with
/// pixels, not bytes. Coordinates Claude reads off a screenshot are mapped back.
public struct ScreenshotScale: Hashable, Sendable {
    public static let maxWidth: Double = 1280

    /// Image pixels per CSS pixel (1 or less).
    public let factor: Double

    public init(viewportWidth: Double, maxWidth: Double = ScreenshotScale.maxWidth) {
        factor = viewportWidth > maxWidth && viewportWidth > 0 ? maxWidth / viewportWidth : 1
    }

    /// A point in screenshot pixels, in the page's CSS pixels.
    public func toPage(_ point: ViewportPoint) -> ViewportPoint {
        ViewportPoint(x: point.x / factor, y: point.y / factor)
    }
}
