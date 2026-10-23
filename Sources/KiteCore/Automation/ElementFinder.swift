import Foundation

/// `find`: matches a plain description ("search box", "Add to cart button")
/// against the accessibility tree and returns the best elements with refs.
///
/// Claude in Chrome asks a model to do this; Kite scores words instead, which
/// is instant and free, and the caller can always fall back to read_page.
public enum ElementFinder {
    public struct Match: Hashable, Sendable {
        public var ref: String
        /// The element as an outline line, e.g. `button "Add to cart"`.
        public var line: String
        public var score: Double
    }

    /// Words in a query that name a kind of element, and the roles they mean.
    static let roleWords: [String: Set<String>] = [
        "button": ["button", "togglebutton", "popupbutton", "menuitem"],
        "btn": ["button", "togglebutton", "popupbutton"],
        "link": ["link"],
        "field": ["textbox", "searchbox", "combobox", "spinbutton", "textfield"],
        "input": ["textbox", "searchbox", "combobox", "spinbutton", "textfield", "checkbox", "radio"],
        "box": ["textbox", "searchbox", "combobox", "checkbox"],
        "textbox": ["textbox", "searchbox"],
        "search": ["searchbox"],
        "checkbox": ["checkbox", "switch"],
        "check": ["checkbox"],
        "toggle": ["switch", "checkbox", "togglebutton"],
        "switch": ["switch"],
        "radio": ["radio"],
        "dropdown": ["combobox", "listbox", "popupbutton"],
        "select": ["combobox", "listbox"],
        "menu": ["menu", "menuitem", "menubar", "popupbutton"],
        "tab": ["tab"],
        "heading": ["heading"],
        "title": ["heading"],
        "image": ["img", "image"],
        "picture": ["img", "image"],
        "slider": ["slider"],
        "option": ["option"],
    ]

    static let stopWords: Set<String> = ["the", "a", "an", "to", "of", "for", "on", "in", "that", "with", "and", "or", "this", "element"]

    public static func find(_ nodes: [AXNode], query: String, limit: Int = 20) -> [Match] {
        let queryWords = words(query).filter { !stopWords.contains($0) }
        guard !queryWords.isEmpty else { return [] }
        let wantedRoles = queryWords.compactMap { roleWords[$0] }.reduce(into: Set<String>()) { $0.formUnion($1) }
        let phrase = queryWords.joined(separator: " ")

        var matches: [(Match, Int)] = []
        for (order, node) in nodes.enumerated() where !node.ignored {
            guard let id = node.backendDOMNodeId, let role = node.role?.value?.stringValue?.lowercased() else { continue }
            let name = node.name?.value?.stringValue ?? ""
            let value = node.value?.value?.stringValue ?? ""
            let interactive = AccessibilityOutline.interactiveRoles.contains(role)
            guard interactive || role == "heading" || role == "statictext" || role == "img" || role == "image" else { continue }
            if name.isEmpty && value.isEmpty && !interactive { continue }

            let nameWords = Set(words(name + " " + value))
            var score = 0.0
            for word in queryWords where nameWords.contains(word) { score += 2 }
            // Prefix matches ("subscri" → "subscribe") count a little.
            for word in queryWords where word.count >= 3 && !nameWords.contains(word)
                && nameWords.contains(where: { $0.hasPrefix(word) }) { score += 1 }
            if !phrase.isEmpty, words(name).joined(separator: " ").contains(phrase) { score += 3 }
            let roleMatches = wantedRoles.contains(role)
            if roleMatches { score += 1.5 }
            // A role word alone ("search box") finds every element of that role.
            guard score > (roleMatches ? 0 : 0.5) else { continue }
            if interactive { score += 0.5 }
            if node.property("disabled")?.boolValue == true { score -= 1 }

            var line = role
            if !name.isEmpty { line += " " + AccessibilityOutline.quote(AccessibilityOutline.clean(name)) }
            matches.append((Match(ref: AccessibilityOutline.ref(forBackendNodeID: id), line: line, score: score), order))
        }
        return matches
            .sorted { $0.0.score != $1.0.score ? $0.0.score > $1.0.score : $0.1 < $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}
