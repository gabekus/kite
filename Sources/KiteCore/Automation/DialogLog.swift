import Foundation

/// The JavaScript dialogs (alert, confirm, prompt, "Leave site?") pages showed on tabs Claude touched or handed the
/// user a step on, kept after they close, so Claude hears about one even when it wasn't looking (Gabe, 5 Nov 2026: a
/// checkout's alert, "Double check your credit card information", came up after his handoff step and Claude never
/// heard; "kite should be able to capture alerts and route that to the agent context").
///
/// Kite hears each dialog from the engine (Chromium's JS dialog handler, WebKit's UI delegate) as it shows, and how it
/// closed. Claude hears each one once (`told`): in a waiting `handoff_status` (which a dialog on the handoff's tabs
/// wakes), on its next tool result, or in the `dialogs` tool's list. A dialog still open is news only after
/// `openGrace`, so a user who answers it at once is reported with their answer.
public struct DialogLog: Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case alert, confirm, prompt, beforeunload

        /// "an alert", for Claude's sentences.
        public var phrase: String {
            switch self {
            case .alert: "an alert"
            case .confirm: "a confirm dialog"
            case .prompt: "a prompt"
            case .beforeunload: "a “Leave site?” dialog"
            }
        }

        /// "alert", for the step's tag on the page: "Claude saw the page's alert…".
        public var noun: String {
            switch self {
            case .alert: "alert"
            case .confirm, .prompt: "question"
            case .beforeunload: "“Leave site?”"
            }
        }
    }

    /// Who answered a dialog.
    public enum Answerer: String, Hashable, Sendable {
        /// In Kite's dialog sheet.
        case user
        /// With handle_dialog.
        case claude
        /// Kite itself, without showing it: its tab wasn't in a window (a background tab).
        case kite
    }

    public enum Outcome: Hashable, Sendable {
        /// OK (or Leave).
        case accepted(by: Answerer)
        /// Cancel (or Stay).
        case dismissed(by: Answerer)
        /// It went away unanswered: the page navigated, or another dialog took its place.
        case unanswered
    }

    /// The handoff step a dialog came up on: the one waiting on its tab, or the one the user just ended there.
    public struct Step: Hashable, Sendable {
        public var handoff: String
        public var id: String
        public var number: Int
        public var instruction: String
        /// Still waiting when the dialog showed (it came up during the step rather than after it).
        public var waiting: Bool

        public init(handoff: String, id: String, number: Int, instruction: String, waiting: Bool) {
            self.handoff = handoff
            self.id = id
            self.number = number
            self.instruction = instruction
            self.waiting = waiting
        }
    }

    public struct Entry: Identifiable, Hashable, Sendable {
        public let id: Int
        public let tab: UUID
        public var kind: Kind
        /// The page's words: untrusted, always wrapped before Claude reads them.
        public var message: String
        /// The page that showed it ("https://shop.example").
        public var origin: String?
        public var opened: Date
        public var closed: Date?
        /// Nil while it's open.
        public var outcome: Outcome?
        public var step: Step?
        /// The Claude connection it's news for: the step's handoff's, or the one last acting on the tab.
        public var connection: Int?
        /// Claude has heard about it.
        public var told = false

        public var isOpen: Bool { outcome == nil }
    }

    /// Most dialogs kept per tab; the oldest go first.
    public static let perTab = 20
    /// An open dialog is news once it has been open this long: the user, who sees it, usually answers it first.
    public static let openGrace: TimeInterval = 3

    public private(set) var entries: [Entry] = []
    private var nextID = 1
    /// Claude's handle_dialog answer while it's on its way, so the engine's "it went away" is put down to Claude.
    private var claudeAnswering: [UUID: Bool] = [:]

    public init() {}

    // MARK: Recording

    /// A dialog showed on `tab`. One still open there is gone now (a page shows one at a time). Returns its id.
    @discardableResult
    public mutating func opened(tab: UUID, kind: Kind, message: String, origin: String?, step: Step?, connection: Int?,
                                at now: Date = Date()) -> Int {
        close(tab: tab, outcome: .unanswered, at: now)
        let id = nextID
        nextID += 1
        entries.append(Entry(id: id, tab: tab, kind: kind, message: message, origin: origin, opened: now, step: step,
                             connection: connection))
        let mine = entries.indices.filter { entries[$0].tab == tab }
        if mine.count > Self.perTab { entries.remove(at: mine[0]) }
        return id
    }

    /// The engine took the tab's open dialog down. `by` nil: nobody answered it in Kite (the page navigated, or the
    /// dialog was reset), unless Claude's handle_dialog is what took it down.
    public mutating func closed(tab: UUID, accepted: Bool, by: Answerer?, at now: Date = Date()) {
        let outcome: Outcome
        if let by {
            outcome = accepted ? .accepted(by: by) : .dismissed(by: by)
        } else if let claude = claudeAnswering[tab] {
            outcome = claude ? .accepted(by: .claude) : .dismissed(by: .claude)
        } else {
            outcome = .unanswered
        }
        close(tab: tab, outcome: outcome, at: now)
    }

    /// Claude is answering the tab's dialog with handle_dialog. `done` once the engine has done it (or nil if it failed).
    public mutating func claudeAnswers(tab: UUID, accept: Bool) { claudeAnswering[tab] = accept }

    public mutating func claudeAnswered(tab: UUID, accept: Bool?, at now: Date = Date()) {
        claudeAnswering[tab] = nil
        guard let accept else { return }
        if let i = entries.lastIndex(where: { $0.tab == tab }) {
            // The engine may have reported the dialog gone before Claude's call returned: it was Claude's answer.
            if entries[i].isOpen || entries[i].outcome == .unanswered {
                entries[i].outcome = accept ? .accepted(by: .claude) : .dismissed(by: .claude)
                entries[i].closed = entries[i].closed ?? now
            }
            entries[i].told = true
        }
    }

    private mutating func close(tab: UUID, outcome: Outcome, at now: Date) {
        for i in entries.indices where entries[i].tab == tab && entries[i].isOpen {
            entries[i].outcome = outcome
            entries[i].closed = now
        }
    }

    /// The dialog open on `tab`, if any.
    public func open(on tab: UUID) -> Entry? { entries.last { $0.tab == tab && $0.isOpen } }

    public func entries(on tab: UUID) -> [Entry] { entries.filter { $0.tab == tab } }

    /// Claude has heard about these (they were in a result).
    public mutating func markTold(_ ids: some Sequence<Int>) {
        let ids = Set(ids)
        for i in entries.indices where ids.contains(entries[i].id) { entries[i].told = true }
    }

    /// Claude was just told about the tab's open dialog some other way (an action's result, a refused tool).
    public mutating func markOpenTold(on tab: UUID) {
        if let i = entries.lastIndex(where: { $0.tab == tab && $0.isOpen }) { entries[i].told = true }
    }

    /// Closed tabs take their dialogs with them.
    public mutating func retain(live: Set<UUID>) {
        entries.removeAll { !live.contains($0.tab) }
        claudeAnswering = claudeAnswering.filter { live.contains($0.key) }
    }

    public mutating func clear() {
        entries.removeAll()
        claudeAnswering.removeAll()
    }

    // MARK: What Claude hears

    /// Whether an entry is news yet: closed, or open longer than `openGrace`.
    public static func isReady(_ entry: Entry, now: Date = Date()) -> Bool {
        !entry.isOpen || now.timeIntervalSince(entry.opened) >= openGrace
    }

    /// Entries Claude hasn't heard about that are news now, for `connection`'s next tool result.
    public func news(for connection: Int, now: Date = Date()) -> [Entry] {
        entries.filter { !$0.told && $0.connection == connection && Self.isReady($0, now: now) }
    }

    /// What wakes a waiting handoff_status: news on one of the handoff's tabs (its steps', and those its steps' clicks
    /// opened), whoever's it is, or news for the connection that's waiting.
    public func wakes(_ handoff: Handoff, connection: Int, now: Date = Date()) -> [Entry] {
        let tabs = Set(handoff.steps.compactMap(\.tab)).union(handoff.opened.map(\.tab))
        return entries.filter { entry in
            !entry.told && Self.isReady(entry, now: now) && (tabs.contains(entry.tab) || entry.connection == connection)
        }
    }

    /// What Claude reads about one dialog. `title` is the tab's title now, if it's open.
    public static func describe(_ entry: Entry, title: String?, tabInfo: Bool = true) -> String {
        var text = ""
        if tabInfo {
            text += "the page in tab \(entry.tab.uuidString)" + (title.map { " (“\(UntrustedContent.defuse($0))”)" } ?? "") + " "
        }
        text += "showed \(entry.kind.phrase)"
        if let step = entry.step {
            text += (step.waiting ? " during" : " after") + " the user's step \(step.number) of handoff \(step.handoff) "
                + "(“\(step.instruction)”)"
        }
        text += ":\n" + UntrustedContent.wrap(entry.message.isEmpty ? "(no message)" : entry.message, source: "dialog")
        text += "\n" + outcomeSentence(entry) + " " + nextSentence(entry)
        return text
    }

    /// How it ended, or that it's still open.
    static func outcomeSentence(_ entry: Entry) -> String {
        switch entry.outcome {
        case nil:
            entry.kind == .alert
                ? "It's still open, and the page is frozen until it's answered."
                : "It's still open, waiting for an answer: the page is frozen until then."
        case .accepted(.user)?:
            switch entry.kind {
            case .alert: "The user dismissed it."
            case .confirm: "The user pressed OK."
            case .prompt: "The user answered it and pressed OK."
            case .beforeunload: "The user chose to leave the page."
            }
        case .dismissed(.user)?:
            entry.kind == .beforeunload ? "The user chose to stay on the page." : "The user pressed Cancel."
        case .accepted(.claude)?: "You accepted it with handle_dialog."
        case .dismissed(.claude)?: "You dismissed it with handle_dialog."
        case .accepted(.kite)?, .dismissed(.kite)?:
            "Kite closed it without showing it (" + (entry.kind == .alert ? "OK" : "Cancel")
                + "), as its tab wasn't on screen: the user never saw it."
        case .unanswered?: "It closed unanswered (the page moved on)."
        }
    }

    /// What Claude should do about it.
    static func nextSentence(_ entry: Entry) -> String {
        let read = entry.step != nil
            ? "read the page now (read_page on that tab) and work out what's wrong, then fix it yourself or hand the user a new step."
            : "read the page now and see what it means for your work."
        guard entry.isOpen else { return read.prefix(1).uppercased() + read.dropFirst() }
        if entry.kind == .alert {
            return "Dismiss it with handle_dialog (accept false; an alert only has OK), then " + read
        }
        return "If it's the user's to answer, leave it to them (it reaches you again here once it closes); otherwise answer it "
            + "with handle_dialog (accepting asks the user first). Then " + read
    }

    /// The `dialogs` tool's list for some tabs, oldest first. `title` gives a tab's title now.
    public static func report(_ entries: [Entry], tab: UUID?, now: Date = Date(), title: (UUID) -> String?) -> String {
        guard !entries.isEmpty else {
            return tab == nil
                ? "No JavaScript dialogs on the tabs you touched or handed steps on."
                : "No JavaScript dialogs on this tab since you touched it."
        }
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        let lines = entries.map { entry in
            "#\(entry.id) at \(time.string(from: entry.opened))" + (entry.origin.map { " from \($0)" } ?? "") + ": "
                + describe(entry, title: title(entry.tab), tabInfo: true)
        }
        return "\(entries.count) dialog\(entries.count == 1 ? "" : "s"), oldest first:\n\n" + lines.joined(separator: "\n\n")
    }

    /// The words on a step's tag while Claude looks at what the page's dialog said.
    public static func stepAside(_ kind: Kind) -> String { "Claude saw the page's \(kind.noun) and is looking at it" }

    /// The sidebar note for the tab meanwhile.
    public static func tabNote(_ kind: Kind) -> String { "Looking at the page's \(kind.noun)" }

    /// A page's dialog, from the engine's names (Chromium's DevTools types, Kite's own kinds).
    public static func kind(_ name: String) -> Kind {
        switch name {
        case "confirm": .confirm
        case "prompt": .prompt
        case "beforeunload", "leave", "reload": .beforeunload
        default: .alert
        }
    }
}
