import Foundation

/// Settings › Advanced › "Export Data" (g96): Arc's "exports Arc Spaces and tabs as Markdown".
///
/// Arc 1.171 (binary, see docs/arc-visual-spec.md) builds one block per space and joins them with
/// a newline; each block ends with a newline, so spaces are a blank line apart. A block is
/// `# ` + the space's name, then its items: a tab is `- ` + its URL (no title), a folder is a
/// heading one level deeper than its parent (`## ` at the top of a space) followed by its own
/// items. Names have their whitespace runs folded to single spaces. The save panel offers
/// "Arc Data Export.md"; Kite's is "Kite Data Export.md".
public enum DataExport {
    public static let fileName = "Kite Data Export.md"

    public static func markdown(spaces: [Space]) -> String {
        spaces.map(block).joined(separator: "\n")
    }

    static func block(_ space: Space) -> String {
        var lines = ["# " + flattened(space.name)]
        lines += items(space.pinnedItems, depth: 2)
        let unpinned = space.tabs.map(line)
        if !unpinned.isEmpty {
            if lines.count > 1 { lines.append("") }
            lines += unpinned
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func items(_ items: [PinnedItem], depth: Int) -> [String] {
        items.flatMap { item -> [String] in
            switch item {
            case .tab(let tab):
                return [line(tab)]
            case .folder(let folder):
                return [String(repeating: "#", count: depth) + " " + flattened(folder.name)]
                    + self.items(folder.items, depth: depth + 1)
            }
        }
    }

    private static func line(_ tab: BrowserTab) -> String { "- " + (tab.url?.absoluteString ?? "") }

    private static func flattened(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
