import Foundation

/// One node of Chromium's accessibility tree, as `Accessibility.getFullAXTree` returns it.
public struct AXNode: Codable, Hashable, Sendable {
    public struct Value: Codable, Hashable, Sendable {
        public var value: JSONValue?
        public init(_ value: JSONValue?) { self.value = value }
    }

    public struct Property: Codable, Hashable, Sendable {
        public var name: String
        public var value: Value
        public init(name: String, value: JSONValue) {
            self.name = name
            self.value = Value(value)
        }
    }

    public var nodeId: String
    public var ignored: Bool
    public var role: Value?
    public var name: Value?
    public var value: Value?
    public var properties: [Property]?
    public var childIds: [String]?
    public var parentId: String?
    public var backendDOMNodeId: Int?

    public init(
        nodeId: String, ignored: Bool = false, role: String? = nil, name: String? = nil, value: String? = nil,
        properties: [Property]? = nil, childIds: [String]? = nil, parentId: String? = nil, backendDOMNodeId: Int? = nil
    ) {
        self.nodeId = nodeId
        self.ignored = ignored
        self.role = role.map { Value(.string($0)) }
        self.name = name.map { Value(.string($0)) }
        self.value = value.map { Value(.string($0)) }
        self.properties = properties
        self.childIds = childIds
        self.parentId = parentId
        self.backendDOMNodeId = backendDOMNodeId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeId = try c.decode(String.self, forKey: .nodeId)
        ignored = try c.decodeIfPresent(Bool.self, forKey: .ignored) ?? false
        role = try c.decodeIfPresent(Value.self, forKey: .role)
        name = try c.decodeIfPresent(Value.self, forKey: .name)
        value = try c.decodeIfPresent(Value.self, forKey: .value)
        properties = try c.decodeIfPresent([Property].self, forKey: .properties)
        childIds = try c.decodeIfPresent([String].self, forKey: .childIds)
        parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
        backendDOMNodeId = try c.decodeIfPresent(Int.self, forKey: .backendDOMNodeId)
    }

    func property(_ name: String) -> JSONValue? {
        properties?.first(where: { $0.name == name })?.value.value
    }
}

/// Turns an accessibility tree into a short outline for the model: landmarks,
/// headings and every control, each control with a ref it can click or type into.
///
///     - heading "Example Domain" level=1
///     - link "Learn more" [ref=e12]
///     - textbox "Email" value="a@b.c" [ref=e15]
///
/// Refs are `e` plus Chromium's backend DOM node id, which stays valid for as
/// long as the element exists, so no marker is ever written into the page.
public enum AccessibilityOutline {
    static let interactiveRoles: Set<String> = [
        "button", "link", "textbox", "searchbox", "checkbox", "radio", "combobox", "listbox", "option",
        "menuitem", "menuitemcheckbox", "menuitemradio", "tab", "switch", "slider", "spinbutton",
        "treeitem", "textfield", "popupbutton", "togglebutton", "disclosuretriangle", "colorwell", "date", "time",
    ]
    static let structuralRoles: Set<String> = [
        "heading", "img", "image", "navigation", "main", "banner", "contentinfo", "complementary", "form",
        "search", "dialog", "alertdialog", "alert", "region", "table", "list", "article", "figure", "status",
    ]
    /// Named only when they have a name worth showing.
    static let needsName: Set<String> = ["region", "img", "image", "list", "table", "figure", "form", "article"]

    public static func ref(forBackendNodeID id: Int) -> String { "e\(id)" }

    public static func backendNodeID(fromRef ref: String) -> Int? {
        var body = Substring(ref.trimmingCharacters(in: .whitespaces))
        if body.hasPrefix("ref=") { body = body.dropFirst(4) }
        if body.first == "e" || body.first == "E" { body = body.dropFirst() }
        guard let id = Int(body), id > 0 else { return nil }
        return id
    }

    public struct Result: Hashable, Sendable {
        public var text: String
        public var lineCount: Int
        public var truncated: Bool
    }

    /// `interactiveOnly` keeps just the controls, unindented.
    public static func render(_ nodes: [AXNode], maxLines: Int = 1_500, interactiveOnly: Bool = false) -> Result {
        guard !nodes.isEmpty else { return Result(text: "", lineCount: 0, truncated: false) }
        let byID = Dictionary(nodes.map { ($0.nodeId, $0) }, uniquingKeysWith: { first, _ in first })
        let roots = nodes.filter { $0.parentId == nil || byID[$0.parentId!] == nil }

        var lines: [String] = []
        var truncated = false
        var visited = Set<String>()

        func visit(_ node: AXNode, depth: Int) {
            guard !truncated, visited.insert(node.nodeId).inserted else { return }
            var childDepth = depth
            let shown = !interactiveOnly || interactiveRoles.contains(node.role?.value?.stringValue?.lowercased() ?? "")
            if !node.ignored, shown, let line = line(for: node) {
                if lines.count >= maxLines {
                    truncated = true
                    return
                }
                lines.append(String(repeating: "  ", count: interactiveOnly ? 0 : depth) + "- " + line)
                childDepth += 1
            }
            for id in node.childIds ?? [] {
                if let child = byID[id] { visit(child, depth: childDepth) }
            }
        }
        for root in roots { visit(root, depth: 0) }
        if truncated { lines.append("… (outline cut off after \(maxLines) lines)") }
        return Result(text: lines.joined(separator: "\n"), lineCount: lines.count, truncated: truncated)
    }

    static func line(for node: AXNode) -> String? {
        guard let role = node.role?.value?.stringValue?.lowercased() else { return nil }
        let name = clean(node.name?.value?.stringValue ?? "")
        let interactive = interactiveRoles.contains(role)
        guard interactive || structuralRoles.contains(role) else { return nil }
        if needsName.contains(role) && name.isEmpty { return nil }

        var parts = [role]
        if !name.isEmpty { parts.append(quote(name)) }
        if role == "heading", let level = node.property("level")?.intValue { parts.append("level=\(level)") }
        if let value = node.value?.value, interactive {
            let text = value.stringValue ?? value.doubleValue.map { String(format: "%g", $0) } ?? ""
            if !text.isEmpty && clean(text) != name { parts.append("value=" + quote(clean(text))) }
        }
        for state in ["checked", "pressed", "selected", "expanded"] {
            guard let value = node.property(state) else { continue }
            if value.boolValue == true || value.stringValue == "true" { parts.append(state) }
            else if value.stringValue == "mixed" { parts.append("\(state)=mixed") }
        }
        for flag in ["disabled", "focused", "required"] where node.property(flag)?.boolValue == true {
            parts.append(flag)
        }
        if interactive, let id = node.backendDOMNodeId, node.property("disabled")?.boolValue != true {
            parts.append("[ref=\(ref(forBackendNodeID: id))]")
        }
        return parts.joined(separator: " ")
    }

    static func clean(_ text: String, limit: Int = 120) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return flat.count > limit ? flat.prefix(limit - 1) + "…" : flat
    }

    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
