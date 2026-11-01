import Foundation

/// Copy Link to Highlight: a link to the page that scrolls to and highlights the selected text,
/// with a text fragment directive (`#:~:text=`, the URL Fragment Text Directives spec, which
/// Chromium's LinkToTextMenuObserver writes).
///
/// Chromium asks the renderer for a selector that is unique on the page (adding a prefix or
/// suffix when it has to). Kite writes the selection itself: the whole text when it's short, or
/// its first and last words as a range, so a phrase that appears earlier on the page highlights
/// that first match.
public enum TextFragment {
    /// Above this many characters, or across lines, the link uses a start,end range.
    static let maxExactLength = 300
    /// Words on each end of a range.
    static let rangeWords = 3

    public static func link(to page: URL, selection: String) -> URL? {
        let words = selection.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, var components = URLComponents(url: page, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let directive: String
        let multiline = selection.trimmingCharacters(in: .whitespacesAndNewlines).contains(where: \.isNewline)
        if words.joined(separator: " ").count <= maxExactLength && !multiline || words.count <= rangeWords * 2 {
            directive = encode(words.joined(separator: " "))
        } else {
            let start = words.prefix(rangeWords).joined(separator: " ")
            let end = words.suffix(rangeWords).joined(separator: " ")
            directive = encode(start) + "," + encode(end)
        }
        // Keep the page's own fragment, minus any directive it already has.
        let ownFragment = components.percentEncodedFragment.map { fragment in
            fragment.range(of: ":~:").map { String(fragment[..<$0.lowerBound]) } ?? fragment
        } ?? ""
        components.percentEncodedFragment = ownFragment + ":~:text=" + directive
        return components.url
    }

    /// Percent-encodes everything but letters, digits and `._~`: the spec reserves `-`, `,` and `&`.
    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private static let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~")
}
