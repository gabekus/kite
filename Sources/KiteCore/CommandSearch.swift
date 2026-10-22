import Foundation

/// Scores menu commands for the command bar, so "cop url" finds Copy URL.
public enum CommandSearch {
    /// Higher is better; nil when the title doesn't match.
    public static func score(_ query: String, title: String) -> Int? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let t = title.lowercased()
        guard !q.isEmpty else { return nil }
        if t.hasPrefix(q) { return 100 }
        let words = t.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let parts = q.split(separator: " ")
        // Every typed word starts some word of the title, in any order.
        if parts.allSatisfy({ part in words.contains { $0.hasPrefix(part) } }) { return 80 }
        if t.contains(q) { return 50 }
        return nil
    }
}
