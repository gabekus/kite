import Foundation

/// Text forms of a link for the clipboard (Copy URL, Copy URL as Markdown).
public enum LinkFormat {
    /// `[title](url)`. Falls back to the URL as the text when the title is empty,
    /// and escapes characters that would end the text or the destination early.
    public static func markdown(title: String, url: URL) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.isEmpty ? url.absoluteString : trimmed
        var escapedText = ""
        for character in text {
            if "\\[]".contains(character) { escapedText.append("\\") }
            // A newline inside the link text breaks most renderers.
            escapedText.append(character.isNewline ? " " : character)
        }
        let destination = url.absoluteString
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: " ", with: "%20")
        return "[\(escapedText)](\(destination))"
    }

    /// The selection as a Markdown block quote followed by its source link.
    /// With nothing selected it's just the Markdown link.
    public static func quote(selection: String, title: String, url: URL) -> String {
        let link = markdown(title: title, url: url)
        let lines = selection
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
        guard lines != [""] else { return link }
        return lines.map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n") + "\n>\n> — \(link)"
    }
}
