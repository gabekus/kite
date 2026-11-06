import Foundation

/// What may go in a trace, and in what shape. A trace has to be safe to hand to an eval pipeline: it never holds
/// typed text, a field's value, page text, a secret or a screenshot. Everything that comes from a page or a person
/// passes through here first.
public enum TraceRedaction {
    // MARK: URLs

    /// A URL as host and path, query values stripped (`?q=&page=`: the names stay, so a search is told from a page),
    /// the fragment and any user or password dropped, and path segments that look like ids, tokens or emails masked.
    /// Non-web URLs keep only their scheme: a file path or data URL says too much.
    public static func place(_ url: URL?) -> (host: String?, path: String?) {
        guard let url, let scheme = url.scheme?.lowercased() else { return (nil, nil) }
        guard ["http", "https", "kite"].contains(scheme) else { return (scheme + ":", nil) }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let host = (components?.host ?? url.host())?.lowercased()
        var path = (components?.percentEncodedPath ?? url.path())
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { maskSegment(String($0)) }
            .joined(separator: "/")
        if path.isEmpty { path = "/" }
        if path.count > maxPath { path = String(path.prefix(maxPath)) + "…" }
        if let names = components?.queryItems?.map(\.name), !names.isEmpty {
            let kept = names.prefix(12).map { maskSegment($0) }
            path += "?" + kept.map { "\($0)=" }.joined(separator: "&")
        }
        return (host, path)
    }

    public static let maxPath = 160

    /// A path segment that is an id, a token or an email becomes a placeholder; words stay.
    static func maskSegment(_ segment: String) -> String {
        guard !segment.isEmpty else { return segment }
        let decoded = segment.removingPercentEncoding ?? segment
        if decoded.contains("@") { return ":email" }
        let digits = decoded.filter(\.isNumber).count
        if digits == decoded.count, digits >= 4 { return ":n" }
        // Long runs of letters and digits mixed (a session id, a reset token, a UUID, a hash).
        if decoded.count >= 16, digits >= 2,
           decoded.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." || $0 == "=" || $0 == "~" }) {
            return ":id"
        }
        if decoded.count >= 32 { return ":id" }
        return segment
    }

    // MARK: Fields

    /// The kind of field something was typed into, never what: name, address, card, password, code, email, phone,
    /// search, username, date, number, text or other.
    public static func fieldRole(_ element: ElementDescription?) -> String {
        guard let element else { return "focused" }
        let type = element.type ?? ""
        let auto = element.autocomplete ?? ""
        let raw = [element.name, element.id, element.placeholder, element.label, element.role].compactMap { $0 }.joined(separator: " ")
        let words = raw.lowercased()
        // Short needles match whole words only ("pin" isn't in "shipping"; "zip" is in "shippingZip"); longer ones
        // anywhere ("cardNumber").
        var tokens = Set<String>()
        var current = ""
        var previousLower = false
        for character in raw + " " + auto {
            if !character.isLetter && !character.isNumber {
                if !current.isEmpty { tokens.insert(current.lowercased()) }
                current = ""
            } else {
                if character.isUppercase, previousLower, !current.isEmpty {
                    tokens.insert(current.lowercased())
                    current = ""
                }
                current.append(character)
            }
            previousLower = character.isLowercase
        }
        if !current.isEmpty { tokens.insert(current.lowercased()) }
        func has(_ needles: String...) -> Bool {
            needles.contains { $0.count <= 3 ? tokens.contains($0) : auto.contains($0) || words.contains($0) }
        }
        if type == "password" || auto.contains("password") || has("password", "passcode", "passwd") { return "password" }
        if auto.hasPrefix("cc-") || has("card", "cvc", "cvv", "ccnum", "expir") { return "card" }
        if auto == "one-time-code" || has("otp", "one-time", "verification", "2fa", "mfa", "pin", "security code") { return "code" }
        if has("ssn", "social security", "tax id", "ein", "passport", "routing", "iban", "account number") { return "id_number" }
        if type == "email" || auto.contains("email") || has("email", "e-mail") { return "email" }
        if type == "tel" || auto.hasPrefix("tel") || has("phone", "mobile") { return "phone" }
        if type == "search" || element.role == "searchbox" || has("search", "query") { return "search" }
        if auto == "username" || has("username", "user name", "login") { return "username" }
        if auto.contains("address") || auto.contains("postal") || auto.hasPrefix("country") || auto.hasSuffix("level1")
            || auto.hasSuffix("level2") || has("address", "street", "city", "zip", "postal", "state", "country") { return "address" }
        if auto.contains("name") || has("name") { return "name" }
        if ["date", "datetime-local", "month", "week", "time"].contains(type) || has("date", "birthday") { return "date" }
        if ["number", "range"].contains(type) { return "number" }
        if ["checkbox", "radio"].contains(type) { return type }
        if element.tag == "select" { return "select" }
        if element.tag == "textarea" || element.isContentEditable || ["text", ""].contains(type) { return "text" }
        return "other"
    }

    // MARK: Text Kite shows

    /// An error message, short, with anything from a page or the arguments taken out: page content blocks, and
    /// anything in quotes (Kite quotes what it echoes back, like a bad key name or a dialog's message).
    public static func error(_ message: String) -> String {
        var text = message
        let tag = UntrustedContent.tag
        while let open = text.range(of: "<\(tag)") {
            let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
            text.replaceSubrange(open.lowerBound..<(close?.upperBound ?? text.endIndex), with: "[page content]")
        }
        text = maskQuoted(text, open: "“", close: "”")
        text = maskQuoted(text, open: "\"", close: "\"")
        text = text.replacingOccurrences(of: "\n", with: " ")
        if text.count > maxError { text = String(text.prefix(maxError)) + "…" }
        return text
    }

    public static let maxError = 240

    static func maskQuoted(_ text: String, open: Character, close: Character) -> String {
        var out = ""
        var inside = false
        for character in text {
            if !inside, character == open {
                inside = true
                out.append(open)
                out.append("…")
            } else if inside, character == close {
                inside = false
                out.append(close)
            } else if !inside {
                out.append(character)
            }
        }
        return out
    }

    /// A control's accessible name, for a click: short, digits and emails masked, nothing for fields (their names
    /// can be what was typed: a combobox shows its value).
    public static func accessibleName(_ name: String?, role: String?) -> String? {
        guard let name else { return nil }
        let fieldRoles: Set<String> = ["textbox", "searchbox", "combobox", "spinbutton", "textarea", "input", "slider"]
        if let role, fieldRoles.contains(role.lowercased()) { return nil }
        var words = name.split(whereSeparator: \.isWhitespace).map { word -> String in
            if word.contains("@") { return ":email" }
            return word.count(where: \.isNumber) >= 3 ? String(word.map { $0.isNumber ? "#" : $0 }) : String(word)
        }.joined(separator: " ")
        guard !words.isEmpty else { return nil }
        if words.count > maxName { words = String(words.prefix(maxName)) + "…" }
        return words
    }

    public static let maxName = 40

    /// A word Kite chose (a tool, a cause, a command name): letters, digits and `._:-`, at most 64 characters.
    public static func word(_ text: String) -> String {
        let kept = text.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || "._:-".unicodeScalars.contains($0)
        }
        return String(String.UnicodeScalarView(kept).prefix(64))
    }
}
