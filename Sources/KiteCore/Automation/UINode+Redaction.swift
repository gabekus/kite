import Foundation

extension UINode {
    /// Attributes that describe structure, never what the user has open.
    static let structuralAttributes: Set<String> = ["subrole", "selected", "enabled"]

    /// The tree with everything but roles, frames and structural attributes hidden, for
    /// reading another app's interface (`kite probe`) without its user's data. Apps put
    /// tab titles and URLs in identifiers too (Arc does), so identifiers go; labels become
    /// their length.
    public func redactingText() -> UINode {
        UINode(
            kind: kind,
            identifier: nil,
            label: label.map { "‹\($0.count) chars›" },
            frame: frame,
            attributes: attributes.filter { Self.structuralAttributes.contains($0.name) },
            children: children.map { $0.redactingText() }
        )
    }
}
