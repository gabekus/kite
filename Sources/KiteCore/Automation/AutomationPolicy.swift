import Foundation

/// What Kite knows about the element an action targets, read from the page just
/// before acting. Field names match the object the page script returns.
public struct ElementDescription: Codable, Hashable, Sendable {
    /// Lowercased tag name, e.g. "button", "input", "a".
    public var tag: String
    /// The `type` attribute of inputs and buttons, lowercased.
    public var type: String?
    public var role: String?
    /// Accessible text: aria-label, label, value of a button, or text content.
    public var label: String?
    public var name: String?
    public var id: String?
    public var autocomplete: String?
    public var placeholder: String?
    public var href: String?
    /// Whether the element sits inside a <form> (or names one with form=).
    public var inForm: Bool
    public var isContentEditable: Bool

    public init(
        tag: String, type: String? = nil, role: String? = nil, label: String? = nil, name: String? = nil,
        id: String? = nil, autocomplete: String? = nil, placeholder: String? = nil, href: String? = nil,
        inForm: Bool = false, isContentEditable: Bool = false
    ) {
        self.tag = tag.lowercased()
        self.type = type?.lowercased()
        self.role = role?.lowercased()
        self.label = label
        self.name = name
        self.id = id
        self.autocomplete = autocomplete?.lowercased()
        self.placeholder = placeholder
        self.href = href
        self.inForm = inForm
        self.isContentEditable = isContentEditable
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            tag: try c.decode(String.self, forKey: .tag),
            type: try c.decodeIfPresent(String.self, forKey: .type),
            role: try c.decodeIfPresent(String.self, forKey: .role),
            label: try c.decodeIfPresent(String.self, forKey: .label),
            name: try c.decodeIfPresent(String.self, forKey: .name),
            id: try c.decodeIfPresent(String.self, forKey: .id),
            autocomplete: try c.decodeIfPresent(String.self, forKey: .autocomplete),
            placeholder: try c.decodeIfPresent(String.self, forKey: .placeholder),
            href: try c.decodeIfPresent(String.self, forKey: .href),
            inForm: try c.decodeIfPresent(Bool.self, forKey: .inForm) ?? false,
            isContentEditable: try c.decodeIfPresent(Bool.self, forKey: .isContentEditable) ?? false
        )
    }

    /// Short human description for the confirmation sheet, e.g. `button "Place order"`.
    public var summary: String {
        let kind = role ?? (tag == "input" ? "\(type ?? "text") field" : tag)
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return kind }
        return "\(kind) “\(label.count > 80 ? label.prefix(79) + "…" : Substring(label))”"
    }
}

/// An action Claude asks to take, as the policy sees it.
public enum AutomationAction: Hashable, Sendable {
    /// A click on an element, or on whatever is under a coordinate (hit-tested by the page).
    case click(ElementDescription)
    /// `element` nil means the focused element, described as well as the page allows.
    case type(ElementDescription?, text: String, submit: Bool)
    /// Keys pressed while `focused` has focus.
    case keys([KeyChord], focused: ElementDescription?)
    case formInput(ElementDescription, value: String)
    case navigate(URL)
    /// `allowedInSettings` is the profile's "run JavaScript without asking" switch.
    case javascript(code: String, allowedInSettings: Bool)
    case uploadFiles([String], into: ElementDescription)
    /// Answering a page's dialog. `kind` is CDP's: alert, confirm, prompt or beforeunload.
    case answerDialog(kind: String, message: String, accept: Bool)
}

/// What the user is asked before an action runs.
public struct ConfirmationRequest: Hashable, Sendable {
    /// What Claude wants to do, e.g. "submit a form on example.com".
    public var action: String
    public var detail: String
    public init(action: String, detail: String) {
        self.action = action
        self.detail = detail
    }

    public var title: String { "Allow Claude to \(action)?" }
}

/// Decides which of Claude's actions need the user's OK.
///
/// Reading, scrolling and ordinary clicks run straight away. Anything that
/// commits something on the user's behalf (submitting a form, sending,
/// posting, paying, buying, deleting) or hands over a secret (passwords,
/// card numbers) waits for the user to allow it in Kite. The checks are
/// deliberately broad: a needless prompt costs a click, a missed one can
/// cost money.
public enum AutomationPolicy {
    public enum Decision: Hashable, Sendable {
        case allow
        case confirm(ConfirmationRequest)
        case deny(String)
    }

    /// Words on a control that mean it commits something. Matched as whole words.
    static let committingWords: Set<String> = [
        "submit", "send", "post", "publish", "tweet", "reply",
        "pay", "buy", "purchase", "order", "checkout", "check out", "place order", "subscribe", "donate",
        "transfer", "withdraw", "deposit", "book", "reserve", "confirm", "agree", "accept",
        "delete", "remove", "erase", "destroy", "discard", "cancel subscription", "unsubscribe",
        "close account", "deactivate", "archive", "trash",
    ]

    /// Hints in a field's name, id, label or autocomplete that it holds payment or identity secrets.
    static let sensitiveFieldHints: [String] = [
        "password", "passwd", "passcode", "pin", "otp", "one-time-code", "2fa", "mfa", "verification code",
        "cc-", "card", "cardnumber", "card number", "credit", "cvv", "cvc", "csc", "security code",
        "expiry", "expiration", "iban", "routing", "account number", "acct", "swift", "bic",
        "ssn", "social security", "tax id", "passport",
    ]

    public static func evaluate(_ action: AutomationAction, host: String?) -> Decision {
        let site = host.map { " on \($0)" } ?? ""
        switch action {
        case .navigate(let url):
            switch url.scheme?.lowercased() {
            case "http", "https", "about": return .allow
            case "file":
                return .confirm(ConfirmationRequest(
                    action: "open a file from this Mac",
                    detail: url.path))
            default:
                return .deny("Kite only lets Claude open http, https and about: URLs, not \(url.scheme ?? "this kind of") URL.")
            }

        case .click(let element):
            if element.tag == "iframe" || element.tag == "frame" {
                // A cross-site frame Kite can't see into: payment widgets live there, so ask.
                let frameHost = element.href.flatMap { URL(string: $0)?.host() } ?? "another site"
                return .confirm(ConfirmationRequest(
                    action: "click inside an embedded page from \(frameHost)\(site)",
                    detail: "Kite can't see what's under the pointer in that frame (\(element.summary))."))
            }
            if submitsForm(element) {
                return .confirm(ConfirmationRequest(
                    action: "submit a form\(site)",
                    detail: "Claude wants to click \(element.summary)."))
            }
            if let word = committingWord(in: element) {
                return .confirm(ConfirmationRequest(
                    action: "\(word)\(site)",
                    detail: "Claude wants to click \(element.summary)."))
            }
            return .allow

        case let .type(element, text, submit):
            if let element, isSensitiveField(element) {
                let kind = element.type == "password" ? "a password" : "into a sensitive field"
                return .confirm(ConfirmationRequest(
                    action: "type \(kind)\(site)",
                    detail: "Field: \(element.summary). Claude wants to type \(text.count) characters (hidden)\(submit ? " and press Return" : "")."))
            }
            if submit, !isSearchField(element) {
                return .confirm(ConfirmationRequest(
                    action: "submit\(site)",
                    detail: "Claude wants to type “\(preview(text))” into \(element?.summary ?? "the focused field") and press Return, which can submit a form or send a message."))
            }
            return .allow

        case let .keys(chords, focused):
            guard let focused else { return .allow }
            for chord in chords {
                let isTextField = isTextEntry(focused)
                if chord.isEnter || (chord.key == " " && !isTextField) {
                    // Return or Space on a button or link is a click on it.
                    if !isTextField {
                        let decision = evaluate(.click(focused), host: host)
                        if decision != .allow { return decision }
                        continue
                    }
                    // Return in a field can submit or send (⌘/Ctrl-Return too). Search boxes are fine.
                    if !isSearchField(focused) {
                        return .confirm(ConfirmationRequest(
                            action: "press Return\(site)",
                            detail: "Focus is in \(focused.summary). Return there can submit a form or send a message."))
                    }
                }
            }
            return .allow

        case let .formInput(element, value):
            if isSensitiveField(element) {
                return .confirm(ConfirmationRequest(
                    action: "fill in a sensitive field\(site)",
                    detail: "Field: \(element.summary). Claude wants to enter \(value.count) characters (hidden)."))
            }
            return .allow

        case let .javascript(code, allowed):
            if allowed { return .allow }
            return .confirm(ConfirmationRequest(
                action: "run JavaScript\(site)",
                detail: "Code:\n\(code.count > 600 ? code.prefix(599) + "…" : Substring(code))\n\nScripts act as you on this site. Allow JavaScript without asking in Kite's menu."))

        case let .uploadFiles(paths, element):
            return .confirm(ConfirmationRequest(
                action: "upload \(paths.count == 1 ? "a file" : "\(paths.count) files")\(site)",
                detail: "Into \(element.summary):\n" + paths.map { "• \($0)" }.joined(separator: "\n")))

        case let .answerDialog(kind, message, accept):
            guard accept, kind != "alert" else { return .allow }
            let what = kind == "beforeunload" ? "leave the page (unsaved changes may be lost)" : "answer OK to the page's \(kind)"
            return .confirm(ConfirmationRequest(action: "\(what)\(site)", detail: "The page asks: “\(preview(message))”"))
        }
    }

    /// Where Return runs a search rather than sending something.
    static func isSearchField(_ element: ElementDescription?) -> Bool {
        guard let element else { return false }
        if element.type == "search" || element.role == "searchbox" { return true }
        let words = Set(normalizedWords([element.name, element.id, element.label, element.placeholder]
            .compactMap { $0 }.joined(separator: " ")))
        return !words.isDisjoint(with: ["search", "query", "q", "find", "lookup"])
    }

    /// Fields that take typed text, as opposed to buttons, links and checkboxes.
    static func isTextEntry(_ element: ElementDescription) -> Bool {
        if element.isContentEditable || element.tag == "textarea" { return true }
        guard element.tag == "input" else { return ["textbox", "searchbox", "combobox"].contains(element.role ?? "") }
        return !["button", "submit", "reset", "image", "checkbox", "radio", "file", "range", "color"].contains(element.type ?? "text")
    }

    /// Submit buttons and image inputs inside a form, including <button> without a type (it defaults to submit).
    static func submitsForm(_ element: ElementDescription) -> Bool {
        guard element.inForm else { return false }
        switch element.tag {
        case "button": return element.type == nil || element.type == "" || element.type == "submit"
        case "input": return element.type == "submit" || element.type == "image"
        default: return false
        }
    }

    static func committingWord(in element: ElementDescription) -> String? {
        let clickable = ["button", "a", "input", "summary"].contains(element.tag)
            || ["button", "link", "menuitem", "tab", "option"].contains(element.role ?? "")
        guard clickable || element.label != nil else { return nil }
        // A link with a sentence of text ("Read the blog post") is navigation, not a command.
        if element.tag == "a", let label = element.label, normalizedWords(label).count > 4 { return nil }
        let text = [element.label, element.name, element.id, element.type == "submit" ? "submit" : nil]
            .compactMap { $0 }.joined(separator: " ")
        let words = normalizedWords(text)
        let joined = " " + words.joined(separator: " ") + " "
        // Longest phrases first so "place order" wins over "order".
        for phrase in committingWords.sorted(by: { $0.count > $1.count }) where joined.contains(" \(phrase) ") {
            return phrase
        }
        return nil
    }

    public static func isSensitiveField(_ element: ElementDescription) -> Bool {
        if element.type == "password" { return true }
        if let autocomplete = element.autocomplete,
           autocomplete.contains("password") || autocomplete.hasPrefix("cc-") || autocomplete.contains(" cc-")
            || autocomplete.contains("one-time-code") {
            return true
        }
        let text = " " + normalizedWords(
            [element.name, element.id, element.label, element.placeholder, element.autocomplete]
                .compactMap { $0 }.joined(separator: " ")
        ).joined(separator: " ") + " "
        let squashed = text.replacingOccurrences(of: " ", with: "")
        for hint in sensitiveFieldHints {
            if hint.hasSuffix("-") {
                if text.contains(" \(hint)") { return true }
            } else if text.contains(" \(hint) ") || (hint.count >= 6 && squashed.contains(hint.replacingOccurrences(of: " ", with: ""))) {
                return true
            }
        }
        return false
    }

    /// Lowercased words; camelCase, snake_case and kebab-case are split apart ("cardNumber" → "card number").
    static func normalizedWords(_ text: String) -> [String] {
        var spaced = ""
        var previous: Character?
        for character in text {
            if character.isUppercase, let previous, previous.isLowercase { spaced.append(" ") }
            spaced.append(character)
            previous = character
        }
        return spaced.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" })
            .flatMap { word -> [Substring] in
                // Keep "cc-number" whole for the cc- prefix check, plus its parts.
                word.contains("-") ? [word] + word.split(separator: "-") : [word]
            }
            .map(String.init)
    }

    static func preview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 120 ? flat.prefix(119) + "…" : flat
    }
}
