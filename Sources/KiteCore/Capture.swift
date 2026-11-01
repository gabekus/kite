import Foundation

/// Arc's File › Capture… and Capture Full Page, without the AppKit parts: file names and
/// selection geometry. Evidence for every number is in docs/arc-visual-spec.md ("Capture").
/// Plain Doubles rather than CGRect: KiteCore stays Foundation-only.
public enum Capture {
    /// A rectangle in points from the page's top-left corner.
    public struct Rect: Equatable, Sendable {
        public var x, y, width, height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var isEmpty: Bool { width <= 0 || height <= 0 }
    }

    /// A drag shorter than this on either side is a click, not a selection.
    public static let minimumSelection: Double = 4

    /// The rectangle between a drag's start and end, kept inside a page of `width` × `height`.
    public static func selection(
        from start: (x: Double, y: Double),
        to end: (x: Double, y: Double),
        within width: Double,
        _ height: Double
    ) -> Rect {
        func clamp(_ v: Double, _ limit: Double) -> Double { min(max(v, 0), limit) }
        let x0 = clamp(min(start.x, end.x), width), x1 = clamp(max(start.x, end.x), width)
        let y0 = clamp(min(start.y, end.y), height), y1 = clamp(max(start.y, end.y), height)
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Whether a selection is big enough to capture.
    public static func isCapturable(_ rect: Rect) -> Bool {
        rect.width >= minimumSelection && rect.height >= minimumSelection
    }

    /// The scale for a full-page image: device pixels, unless the page is taller than
    /// `maxPixels`, which GPUs and image formats refuse past; then as many as fit.
    public static func fullPageScale(contentHeight: Double, deviceScale: Double, maxPixels: Double = 16_384) -> Double {
        guard contentHeight > 0, deviceScale > 0 else { return 1 }
        return min(1, maxPixels / (contentHeight * deviceScale))
    }

    // MARK: File names

    /// Area capture's Save: "Capture-2026-11-01-153045.png", like Arc's save panel.
    public static func areaFilename(date: Date, timeZone: TimeZone = .current) -> String {
        "Capture-" + format(date, "yyyy-MM-dd-HHmmss", timeZone) + ".png"
    }

    /// Full page: the page's title with Arc's characters removed, then the time and day,
    /// "Example Domain · 3.45PM · 11-01.png". Falls back to "Capture" for an empty title.
    public static func fullPageFilename(title: String, date: Date, timeZone: TimeZone = .current) -> String {
        let name = sanitizedTitle(title)
        return (name.isEmpty ? "Capture" : name) + " " + format(date, "'·' h.mma '·' MM-dd", timeZone) + ".png"
    }

    /// Arc keeps only `[a-zA-Z0-9\-_ ]` of the title.
    public static func sanitizedTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "[^a-zA-Z0-9\\-_ ]", with: "", options: .regularExpression)
            .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func format(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        // POSIX so "a" is always AM/PM and digits are ASCII, whatever the user's locale.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
