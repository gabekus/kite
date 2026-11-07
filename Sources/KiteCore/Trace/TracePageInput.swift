import Foundation

/// What a page's trace script reports (clicks, fields focused and left, scrolls, load timings), turned into trace
/// events. The script sends only kinds, lengths and times, and a click's role and accessible name; this keeps only
/// the keys it knows and redacts again, so nothing a page put in a report reaches the trace unchecked.
public enum TracePageInput {
    public struct Event: Equatable, Sendable {
        public var name: String
        public var attrs: [String: JSONValue]
        public var duration: Double?
        /// A link the click followed, for the navigation it starts (its cause is "link").
        public var link: URL?
    }

    public static func parse(_ payload: String) -> Event? {
        guard let value = try? JSONValue.decode(Data(payload.utf8)), let object = value.objectValue,
              let type = object["t"]?.stringValue else { return nil }
        func number(_ key: String) -> Double? {
            guard let n = object[key]?.doubleValue, n.isFinite, n >= -1e9, n <= 1e9 else { return nil }
            return (n * 10).rounded() / 10
        }
        func word(_ key: String) -> String? {
            object[key]?.stringValue.map(TraceRedaction.word).flatMap { $0.isEmpty ? nil : String($0.prefix(24)) }
        }
        switch type {
        case "click":
            let role = word("role") ?? "generic"
            var attrs: [String: JSONValue] = ["role": .string(role)]
            if let name = TraceRedaction.accessibleName(object["name"]?.stringValue, role: role) { attrs["name"] = .string(name) }
            if let button = number("button"), button != 0 { attrs["button"] = .number(button) }
            var link: URL?
            if let href = object["href"]?.stringValue, let url = URL(string: href), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                link = url
                let (host, path) = TraceRedaction.place(url)
                if let host { attrs["link_host"] = .string(host) }
                if let path { attrs["link_path"] = .string(path) }
                if object["newTab"]?.boolValue == true { attrs["new_tab"] = true }
            }
            return Event(name: "input.click", attrs: attrs, link: link)
        case "focus", "blur":
            let element = ElementDescription(
                tag: object["tag"]?.stringValue ?? "input", type: object["type"]?.stringValue, role: object["role"]?.stringValue,
                label: object["label"]?.stringValue, name: object["name"]?.stringValue, id: object["id"]?.stringValue,
                autocomplete: object["autocomplete"]?.stringValue, placeholder: object["placeholder"]?.stringValue,
                isContentEditable: object["editable"]?.boolValue == true)
            var attrs: [String: JSONValue] = ["field": .string(TraceRedaction.fieldRole(element))]
            if type == "blur" {
                if let length = number("len") { attrs["len"] = .number(max(0, length.rounded())) }
                if object["changed"]?.boolValue == true { attrs["changed"] = true }
            }
            return Event(name: type == "focus" ? "input.field_focus" : "input.field_blur", attrs: attrs,
                         duration: type == "blur" ? number("ms") : nil)
        case "scroll":
            var attrs: [String: JSONValue] = [:]
            for key in ["dx", "dy", "n"] { if let n = number(key) { attrs[key] = .number(n.rounded()) } }
            return Event(name: "input.scroll", attrs: attrs, duration: number("ms"))
        case "timing":
            var attrs: [String: JSONValue] = [:]
            for key in ["ttfb", "dcl", "load", "fcp", "lcp"] { if let n = number(key), n >= 0 { attrs["\(key)_ms"] = .number(n) } }
            if let kind = word("nav") { attrs["nav"] = .string(kind) }
            return Event(name: "page.timing", attrs: attrs)
        default:
            return nil
        }
    }
}
