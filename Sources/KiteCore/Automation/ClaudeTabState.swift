import Foundation

/// What a tab Claude opened or drove shows the user: always exactly one of three states, never nothing (Gabe, 5 Nov
/// 2026: "either its done and we need a done indicator, or its not done and its in progress and its not showing a
/// progress indicator, or im needed and youre not calling me to do it with highlights").
///
/// - working: Claude touched it (or said it's working there) and the connection that did is still live, whether or not
///   it's the tab being driven right now: its title shimmers in the sidebar, with a line under it of what Claude is
///   doing, or what it waits on;
/// - needs you: a handoff step waits on it (orange title and dot, the ring on the step's control, the jump to it), or
///   the connection that touched it is gone and it isn't done: "Claude stopped here", with the page outlined in
///   orange (the outline Kite draws while Claude drives a tab), so a stalled agent never looks finished;
/// - done: Claude said so with `tab_status`, with what it did ("Order placed"): a green dot.
///
/// Orange never shows without something ringed on the page (Gabe, 5 Nov 2026: "its orange with no highlight - this
/// should NEVER HAPPEN"; the Ocooch tab went orange while its agent was alive and busy on other tabs): a handoff step
/// rings its control, and a stalled tab gets the page outline (`ring`). Nothing floats over the page.
///
/// A tab Claude touched never shows no state, not even after Kite restarts (Gabe, 5 Nov 2026: five Claude-folder tabs
/// showed no dot and no shimmer after Kite restarted to install an update, "i literally said not to have this"). So
/// what Claude did on each tab is kept with the session (`Record`, `BrowserState.claudeTabs`); after a restart a
/// touched tab that isn't done shows needs you ("Claude stopped here"); any tool call counts as a touch, reads
/// included; and a tab in a Claude folder always has a state, even with no record. Only a tab outside the Claude
/// folders that Claude never touched shows nothing.
public enum ClaudeTabState: Hashable, Sendable {
    case working(note: String?)
    /// `stalled`: no handoff step, but Claude stopped here without saying it's done.
    case needsYou(step: String, stalled: Bool)
    case done(note: String?)

    public static let maxNoteLength = 120
    public static let stoppedHere = "Claude stopped here"
    /// A stalled tab's line under its title in the sidebar.
    public static let stoppedHereLine = "Claude stopped here, ask it to pick up"
    /// A working tab's line while its agent works on other tabs and set no note of what's next.
    public static let waitingLine = "Waiting on Claude"
    /// A tab's line the moment the user finishes the step Claude handed them there (`Handoff.tabsPickedUp`).
    public static let pickingUpLine = "Claude is picking up"

    /// What Kite rings on the page for an orange tab: never orange without one.
    public enum Ring: Hashable, Sendable {
        /// A handoff step's control, ringed where it is on the page.
        case handoffStep
        /// The page's edge, in Claude's orange (the outline Kite draws while Claude drives a tab).
        case pageOutline
    }

    /// What Kite rings for this state on the tab's page; nil for working and done.
    public var ring: Ring? {
        switch self {
        case .needsYou(_, false): .handoffStep
        case .needsYou(_, true): .pageOutline
        default: nil
        }
    }

    public var isStalled: Bool { if case .needsYou(_, true) = self { true } else { false } }

    /// What Claude said with `tab_status`.
    public struct Declared: Hashable, Codable, Sendable {
        public enum Kind: String, Hashable, Codable, Sendable, CaseIterable { case working, done }
        public var kind: Kind
        public var note: String?
        public var at: Date

        public init(kind: Kind, note: String?, at: Date = Date()) {
            self.kind = kind
            self.note = note
            self.at = at
        }
    }

    /// What Claude did on one tab, kept with the session so the tab's state outlives a restart.
    public struct Record: Hashable, Codable, Sendable {
        /// Claude's last tool call on the tab, reads included.
        public var touched: Date?
        /// Its last tool call that did something (opened it, clicked, typed): what ends a done.
        public var acted: Date?
        public var declared: Declared?
        /// The Claude session folder of the session that last worked here ("Shop purchase prep"), if it named one.
        public var session: String?
        /// When the user cleared Claude's mark (the row's Clear Claude's Mark): the tab shows nothing, even in a Claude
        /// folder, until Claude touches it again.
        public var cleared: Date?

        public init(touched: Date? = nil, acted: Date? = nil, declared: Declared? = nil, session: String? = nil,
                    cleared: Date? = nil) {
            self.touched = touched
            self.acted = acted
            self.declared = declared
            self.session = session
            self.cleared = cleared
        }
    }

    /// The one state a tab shows. `step`: a waiting handoff step's words on it. `active`: Claude's tools are acting on
    /// it now (Kite's control indicator: two minutes after the last tool call on it, fifteen seconds once its client
    /// disconnects; off after a restart). `connectionLive`: the connection that last touched it is still connected
    /// (false after a restart). `lastTouched`: Claude's last tool call on it that did something (opened it, clicked,
    /// typed). `lastRead`: its last tool call of any kind, reads included. `inClaudeFolder`: the tab sits in a Claude
    /// folder. Nil only for a tab outside the Claude folders that Claude never touched.
    public static func of(step: String?, declared: Declared?, active: Bool, connectionLive: Bool = false, lastTouched: Date?,
                          lastRead: Date? = nil, inClaudeFolder: Bool = false) -> ClaudeTabState? {
        if let step { return .needsYou(step: step, stalled: false) }
        let actedSince = { (d: Declared) in lastTouched.map { $0 > d.at } ?? false }
        // Done stands until Claude acts on the tab again: reading it doesn't undo it.
        let done = declared.flatMap { $0.kind == .done && !actedSince($0) ? $0 : nil }
        let touched = lastTouched != nil || lastRead != nil || declared != nil
        // Tools at work, or touched by a connection that's still live: working, whichever tab Claude is on now.
        if done == nil, active || (connectionLive && touched) {
            return .working(note: declared?.kind == .working ? declared?.note : nil)
        }
        if let done { return .done(note: done.note) }
        // Touched (even only read) by a connection that's gone, and not done, or in a Claude folder with no word: the
        // user needs to know, with the page outlined.
        return touched || inClaudeFolder ? .needsYou(step: stoppedHere, stalled: true) : nil
    }

    /// The same, from a tab's kept record. `inClaudeFolder` is only asked when there's no record to go on.
    public static func of(step: String?, record: Record?, active: Bool, connectionLive: Bool = false,
                          inClaudeFolder: () -> Bool) -> ClaudeTabState? {
        // A cleared mark shows nothing until Claude touches the tab again.
        let clearedSince = record?.cleared.map { cleared in (record?.touched ?? .distantPast) <= cleared } ?? false
        let touched = record?.touched != nil || record?.acted != nil || record?.declared != nil
        return of(step: step, declared: record?.declared, active: active, connectionLive: connectionLive, lastTouched: record?.acted,
                  lastRead: record?.touched, inClaudeFolder: !clearedSince && !touched && inClaudeFolder())
    }

    /// The sidebar's tooltip for it.
    public var help: String {
        switch self {
        case .working(let note): "Claude is working here" + (note.map { ": \($0)" } ?? "")
        case .needsYou(_, true): "\(Self.stoppedHere) without saying it's done, and its session has ended. Ask Claude to pick up, or clear this mark."
        case .needsYou(let step, false): "Claude needs you: \(step)"
        case .done(let note): "Claude is done here" + (note.map { ": \($0)" } ?? "")
        }
    }

    public var isNeedsYou: Bool { if case .needsYou = self { true } else { false } }
}
