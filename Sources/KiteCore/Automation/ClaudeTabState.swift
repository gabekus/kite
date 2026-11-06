import Foundation

/// What a tab Claude opened or drove shows the user: always exactly one of three states, never nothing (Gabe, 5 Nov
/// 2026: "either its done and we need a done indicator, or its not done and its in progress and its not showing a
/// progress indicator, or im needed and youre not calling me to do it with highlights").
///
/// - working: Claude's tools act on it (or Claude said it's working there): its title shimmers in the sidebar;
/// - needs you: a handoff step waits on it (orange title and dot, the ring on the page, the jump to it), or Claude
///   touched it and went quiet without saying it's done: "Claude stopped here", so a stalled agent never looks
///   finished;
/// - done: Claude said so with `tab_status`, with what it did ("Order placed"): a green dot.
public enum ClaudeTabState: Hashable, Sendable {
    case working(note: String?)
    /// `stalled`: no handoff step, but Claude stopped here without saying it's done.
    case needsYou(step: String, stalled: Bool)
    case done(note: String?)

    public static let maxNoteLength = 120
    public static let stoppedHere = "Claude stopped here"

    /// What Claude said with `tab_status`.
    public struct Declared: Hashable, Sendable {
        public enum Kind: String, Hashable, Sendable, CaseIterable { case working, done }
        public var kind: Kind
        public var note: String?
        public var at: Date

        public init(kind: Kind, note: String?, at: Date = Date()) {
            self.kind = kind
            self.note = note
            self.at = at
        }
    }

    /// The one state a tab shows. `step`: a waiting handoff step's words on it. `active`: Claude's tools are acting on
    /// it now (Kite's control indicator, which lapses after two minutes without a tool call). `lastTouched`: Claude's
    /// last tool call on it that did something (opened it, clicked, typed: reading alone doesn't count). Nil for a tab
    /// Claude never touched.
    public static func of(step: String?, declared: Declared?, active: Bool, lastTouched: Date?) -> ClaudeTabState? {
        if let step { return .needsYou(step: step, stalled: false) }
        let actedSince = { (d: Declared) in lastTouched.map { $0 > d.at } ?? false }
        // Tools at work count, unless all Claude did since saying it's done is read the tab.
        if active, declared?.kind != .done || actedSince(declared!) {
            return .working(note: declared?.kind == .working ? declared?.note : nil)
        }
        if let declared, declared.kind == .done, !actedSince(declared) { return .done(note: declared.note) }
        // Touched, quiet, and not done: the user needs to know.
        return lastTouched != nil || declared != nil ? .needsYou(step: stoppedHere, stalled: true) : nil
    }

    /// The sidebar's tooltip for it.
    public var help: String {
        switch self {
        case .working(let note): "Claude is working here" + (note.map { ": \($0)" } ?? "")
        case .needsYou(_, true): "\(Self.stoppedHere) without saying it's done. Ask Claude what's left, or clear this mark."
        case .needsYou(let step, false): "Claude needs you: \(step)"
        case .done(let note): "Claude is done here" + (note.map { ": \($0)" } ?? "")
        }
    }

    public var isNeedsYou: Bool { if case .needsYou = self { true } else { false } }
}
