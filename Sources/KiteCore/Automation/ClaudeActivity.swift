import Foundation

/// What Claude is doing on a tab while it works there, for a quiet second line under the tab's title in the sidebar
/// and the row's tooltip (Gabe, 5 Nov 2026: "when an agent is cranking (shiny text) i should be able to see somewhere
/// non intrusive what the agent is doing/thinking"). The line is Claude's `tab_status` working note when it set one,
/// otherwise Kite's own words for its last tool call there: "Typing in Zip Code", "Clicking Proceed to checkout",
/// "Reading the page". Only what Claude does, never what it types: a field's name, not its value.
public enum ClaudeActivity {
    public struct Entry: Hashable, Sendable {
        public var text: String
        public var at: Date

        public init(_ text: String, at: Date = Date()) {
            self.text = text
            self.at = at
        }
    }

    /// The last few things Claude did on one tab, newest last.
    public struct Log: Hashable, Sendable {
        public static let capacity = 5
        public private(set) var entries: [Entry] = []

        public init(_ entries: [Entry] = []) {
            self.entries = Array(entries.suffix(Self.capacity))
        }

        public var latest: Entry? { entries.last }

        public mutating func append(_ text: String, at date: Date = Date()) {
            entries.append(Entry(text, at: date))
            if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        }

        /// The same tool call, now that its element is known: "Clicking" becomes "Clicking Proceed to checkout".
        public mutating func refineLatest(_ text: String) {
            guard !entries.isEmpty else { return append(text) }
            entries[entries.count - 1].text = text
        }
    }

    /// Longest a label from the page gets before it's cut, so the line reads at a glance.
    public static let maxLabelLength = 40

    // MARK: Words for each tool

    /// Before Kite knows the element: what the tool call is, in a few words.
    public static func describe(_ command: AutomationCommand) -> String? {
        switch command {
        case .readPage, .getPageText: "Reading the page"
        case .find(_, let query): "Looking for \(quoted(query))"
        case .screenshot: "Looking at the page"
        case .click: "Clicking"
        case .type: "Typing"
        case .formInput: "Filling in a field"
        case .computer(_, let action): describe(action, element: nil)
        case .javascript: "Running a script on the page"
        case let .waitFor(_, condition, _):
            switch condition {
            case .load, .navigation: "Waiting for the page to load"
            case .networkIdle: "Waiting for the page to settle"
            case .selector, .text: "Waiting for the page"
            }
        case .handleDialog(_, let accept, _): accept ? "Accepting a dialog" : "Dismissing a dialog"
        case .uploadFile: "Attaching a file"
        case let .navigate(_, url, _):
            switch url.lowercased() {
            case "back": "Going back"
            case "forward": "Going forward"
            default: opening(url)
            }
        case .readConsole: "Reading the console"
        case .readNetwork: "Reading network requests"
        case .signIn: "Waiting for you to sign in"
        default: nil
        }
    }

    public static func clicking(_ element: ElementDescription?) -> String { "Clicking" + named(element) }
    public static func typing(into element: ElementDescription?) -> String { "Typing" + named(element, in: true) }
    public static func filling(_ element: ElementDescription) -> String {
        let name = named(element)
        return name.isEmpty ? "Filling in a field" : "Filling in" + name
    }

    public static func describe(_ action: ComputerAction, element: ElementDescription?) -> String {
        switch action {
        case .screenshot, .zoom: "Looking at the page"
        case .click(_, let button, _, _): button == .right ? "Right-clicking" + named(element) : clicking(element)
        case .hover: "Pointing at" + (named(element).isEmpty ? " the page" : named(element))
        case .scroll: "Scrolling the page"
        case .drag: "Dragging on the page"
        case .key: "Pressing keys"
        case .type: typing(into: element)
        case .wait: "Waiting"
        }
    }

    /// "Opening example.com" for a URL Claude loads.
    public static func opening(_ string: String?) -> String {
        guard let string, !string.isEmpty else { return "Opening a new tab" }
        let url = URL(string: string.contains("://") ? string : "https://" + string)
        guard var host = url?.host, !host.isEmpty else { return "Opening a page" }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return "Opening \(host)"
    }

    // MARK: The tooltip

    /// The row's tooltip while Claude works: the line's note, then the last few actions with their times.
    public static func tooltip(help: String, log: Log?, timeZone: TimeZone = .current) -> String {
        guard let log, !log.entries.isEmpty else { return help }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "h:mm:ss a"
        let lines = log.entries.reversed().map { "\(formatter.string(from: $0.at))  \($0.text)" }
        return ([help, ""] + lines).joined(separator: "\n")
    }

    // MARK: Private

    /// " Zip Code" for an element with a name, "" for one without. A rich text box's label can be its own text (the
    /// page falls back to it), so for one Claude types into only its placeholder counts.
    private static func named(_ element: ElementDescription?, in into: Bool = false) -> String {
        guard let element else { return "" }
        let candidates = element.isContentEditable ? [element.placeholder] : [element.label, element.placeholder]
        guard let raw = candidates.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { !$0.isEmpty })
        else { return "" }
        let label = cut(raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " "))
        return (into ? " in " : " ") + label
    }

    private static func quoted(_ text: String) -> String { "“\(cut(text))”" }

    private static func cut(_ text: String) -> String {
        text.count > maxLabelLength ? text.prefix(maxLabelLength - 1).trimmingCharacters(in: .whitespaces) + "…" : text
    }
}
