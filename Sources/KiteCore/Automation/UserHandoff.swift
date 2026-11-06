import Foundation

/// `handoff`: Claude hands steps it can't (or mustn't) do to the user, and Kite shows them where they happen.
///
/// Claude stops for things only the user can do: its safety check won't let it approve a DNS change, a page
/// wants a click on Super Administrator. Instead of a list in the chat, Claude calls `handoff` with why it stopped
/// and the steps, each with its tab and its control. Kite then:
/// - rings the control on the page itself, with a tag beside it: the step and Skip (and Claude's reason when the
///   pointer rests on it);
/// - marks those tabs, and the Claude folders holding them, in the sidebar;
/// - tells Claude which steps the user did when it asks (`handoff_status`), or when its wait ends.
///
/// Nothing else shows the steps: there's no card over the page (Gabe, 5 Nov 2026: "only inline with highlighted
/// elements"). So every step needs a control on a page, and a step whose control Kite can't find there (or whose
/// tab left its page or closed) is reported to Claude at once, to point it at one that's there or withdraw it.
///
/// The user is taken to the first step when a handoff starts (`HandoffLead`): a step on a tab that isn't in front
/// would show nobody anything (Gabe, 5 Nov 2026: "if the job is not done, then clearly im needed for something, and
/// its not highlighted"). Kite brings its tab forward, scrolls its control into view and pulses the ring, once the
/// user isn't in the middle of typing or clicking in Kite. Only then: finishing a step, or the whole handoff, never
/// changes the tab or space in front (Gabe, 5 Nov 2026: "when i hit the final step of a claude action it seems to
/// take me to another tab.. dont.. keep me in the same tab"). The next step's tab turns orange in the sidebar, its
/// control ringed for when they go there.
///
/// Every step finishes by itself, the moment it's done: there's no Done button (Gabe, 5 Nov 2026: "dont even offer a
/// done button, kite / claude should be smart enough and setup to auto detect this instantly"). What done looks like
/// is the step's `DoneWhen`: a click on the ringed control (buttons, links, boxes), a value in the ringed field and
/// focus leaving it or Enter or Tab (fields; a payment field in another site's frame, whose value Kite can't read,
/// once focus has been in the frame and moves on), the page navigating, the control going away, or words appearing.
/// Whatever it says, a step is also done when its page navigates or its ringed control goes away (the form was
/// sent or replaced), when the page opens a dialog, and when the user clicks a later step's control on the same tab
/// (every step before it there is done too). Skip stays, to leave a step undone. Only the user's own clicks and
/// keys count: the page's own scripts can't fake one, since the ring and its listeners live in an isolated world
/// the page can't reach.
public enum UserHandoff {
    public static let maxSteps = 12
    public static let maxReasonLength = 400
    public static let maxInstructionLength = 240
    /// The longest one call waits for the user, in seconds; a longer wait is cut to it. MCP clients give up on a call
    /// after about 60 s ("Request timed out"), and a wait that times out there never hears the user finish (Gabe, 5 Nov
    /// 2026: Claude asked for 600 and 300, both timed out, and nobody filled McMaster's next page). Claude calls
    /// handoff_status again, and again, to wait longer.
    public static let maxWait: Double = 50
    /// How often Kite looks at the page in front while a step waits on it and the page is on screen.
    public static let pollInterval: TimeInterval = 0.5
    /// How close together a click on a step's control and a tab its page opens must be to count as the click's doing.
    public static let openedTabWindow: TimeInterval = 5
    /// How long after such a click a report waits for the tab it may be opening.
    public static let clickSettle: TimeInterval = 1
    /// How long after a handoff Kite keeps looking at its steps' pages twice a second. Older steps stay (card,
    /// sidebar, ring), but Kite only looks when the user switches to the tab, the page loads or the ring hears a
    /// click, so steps left waiting for days cost nothing while Kite sits idle.
    public static let watchLimit: TimeInterval = 24 * 3600
    /// How many looks, half a second apart, Kite takes at a new step's control before telling Claude it's missing.
    public static let probeAttempts = 3
    /// How long a step's control must be missing, on a tab at another address, before Kite calls the page left.
    public static let offPageDelay: TimeInterval = 1.5
    /// How long a step's control stays turned off before a waiting handoff_status returns to tell Claude.
    public static let blockedReportDelay: TimeInterval = 2
    /// How long a step stays unshown (its control missing, its page left, its tab closed) before a waiting
    /// handoff_status returns to tell Claude. Longer than `blockedReportDelay`: the page a click leads to may still
    /// be loading the next step's control.
    public static let unshownReportDelay: TimeInterval = 5
    /// How many frames of another origin a look searches for a step's control, when the top frame doesn't have it.
    public static let maxFramesLooked = 24
    /// The isolated world the ring lives in, and the binding it reports clicks through.
    public static let worldName = "kite-handoff"
    public static let bindingName = "kiteHandoffEvent"
    /// The attribute that marks an element Claude named by ref, so the ring finds it again.
    public static let markerAttribute = "data-kite-handoff"

    /// What Claude points a step at.
    public enum Target: Hashable, Sendable {
        /// A ref from read_page or find.
        case ref(String)
        case selector(String)
        /// The visible text of a button, link, checkbox or label: "Save", "Super Administrator".
        case text(String)
    }

    /// What says a step is done (`done_when`), so it finishes by itself. Nil: by its control, `click` for a button,
    /// link or box, `value` for a field (or a frame holding one).
    public enum DoneWhen: String, Hashable, Codable, Sendable, CaseIterable {
        /// The user clicks the ringed control.
        case click
        /// The ringed field holds a value and focus leaves it, or the user presses Enter or Tab in it. A payment field
        /// in another site's frame: focus has been in the frame and moves on.
        case value
        /// The tab goes to another page.
        case navigation
        /// The ringed control goes away (a form sent, a dialog closed).
        case gone
        /// Words (`appears`) show up on the page that weren't there when the step began: "Order confirmed".
        case appears
    }

    /// One step as Claude asks for it.
    public struct StepRequest: Hashable, Sendable {
        /// What to do, in a few words: "Approve Apple", "Tick Super Administrator".
        public var instruction: String
        /// The tab it happens in. Nil: the call's tab, or the front tab.
        public var tab: String?
        /// The control the step is about: Kite shows the step beside it, and nowhere else.
        public var target: Target
        /// Why this step is the user's, when it differs from the call's reason.
        public var why: String?
        /// What says it's done; nil goes by the control.
        public var doneWhen: DoneWhen?
        /// With `doneWhen` `.appears`: the words that show up.
        public var appears: String?

        public init(instruction: String, tab: String? = nil, target: Target, why: String? = nil, doneWhen: DoneWhen? = nil,
                    appears: String? = nil) {
            self.instruction = instruction
            self.tab = tab
            self.target = target
            self.why = why
            self.doneWhen = doneWhen
            self.appears = appears
        }
    }

    /// A handoff as Claude asks for it.
    public struct Request: Hashable, Sendable {
        /// Why Claude stopped and needs the user: "My safety check won't let me change nameservers."
        public var reason: String
        public var steps: [StepRequest]
        /// The tab for steps that don't name one.
        public var tab: String?
        /// Seconds to wait for the user before returning (0 returns at once).
        public var wait: Double

        public init(reason: String, steps: [StepRequest], tab: String? = nil, wait: Double = 0) {
            self.reason = reason
            self.steps = steps
            self.tab = tab
            self.wait = wait
        }
    }

    // MARK: Parsing

    static func parse(_ values: [String: JSONValue], tab: String?) throws -> Request {
        typealias Invalid = AutomationCommand.InvalidArguments
        func text(_ value: JSONValue?, _ key: String, limit: Int) throws -> String? {
            guard let value, !value.isNull else { return nil }
            guard let string = value.stringValue else { throw Invalid("\"\(key)\" must be a string.") }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard trimmed.count <= limit else { throw Invalid("\"\(key)\" is at most \(limit) characters.") }
            return trimmed
        }
        guard let reason = try text(values["reason"], "reason", limit: maxReasonLength) else {
            throw Invalid("\"reason\" is required: say why you stopped and need the user, e.g. \"My safety check won't let me change nameservers\".")
        }
        guard let list = values["steps"]?.arrayValue, !list.isEmpty else {
            throw Invalid("\"steps\" must be a list of {\"instruction\": …, \"tab\"?, \"ref\" | \"selector\" | \"text\"}.")
        }
        guard list.count <= maxSteps else { throw Invalid("A handoff has at most \(maxSteps) steps.") }
        let steps: [StepRequest] = try list.enumerated().map { index, item in
            guard let step = item.objectValue else { throw Invalid("Step \(index + 1) must be an object.") }
            func field(_ key: String, limit: Int = UserHandoff.maxInstructionLength) throws -> String? {
                do { return try text(step[key], key, limit: limit) } catch let error as Invalid {
                    throw Invalid("Step \(index + 1): \(error.description)")
                }
            }
            guard let instruction = try field("instruction") else {
                throw Invalid("Step \(index + 1) needs an \"instruction\": what the user does, like \"Approve Apple\".")
            }
            if step["command"].map({ !$0.isNull }) == true {
                throw Invalid("Step \(index + 1): Kite shows a step only beside its control on a page, so it can't show a command. "
                    + "Ask the user to run it in your chat instead, and hand over only steps on pages.")
            }
            let targets: [Target] = [
                try field("ref").map(Target.ref), try field("selector", limit: 1_000).map(Target.selector), try field("text").map(Target.text),
            ].compactMap { $0 }
            guard targets.count <= 1 else { throw Invalid("Step \(index + 1): pass one of \"ref\", \"selector\" or \"text\", not several.") }
            if targets.isEmpty {
                throw Invalid("Step \(index + 1) needs its control: a \"ref\" (from find or read_page), a \"selector\" or its visible "
                    + "\"text\". Kite shows a step only beside its control on the page; for anything else (a question, a note, "
                    + "something outside the browser), ask the user in your chat.")
            }
            if case .selector(let selector) = targets[0], selector.contains("\u{0}") {
                throw Invalid("Step \(index + 1): that selector isn't valid.")
            }
            let appears = try field("appears")
            var doneWhen: DoneWhen?
            if let raw = try field("done_when") {
                guard let value = DoneWhen(rawValue: raw.lowercased()) else {
                    throw Invalid("Step \(index + 1): \"done_when\" is one of " + DoneWhen.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
                        + ", or leave it out to go by the control (click for a button or link, value for a field).")
                }
                doneWhen = value
            }
            if appears != nil, doneWhen == nil { doneWhen = .appears }
            if doneWhen == .appears, appears == nil {
                throw Invalid("Step \(index + 1): done_when \"appears\" needs \"appears\": the words that show up on the page once the "
                    + "step is done (\"Order confirmed\").")
            }
            return StepRequest(instruction: instruction, tab: try field("tab"), target: targets[0], why: try field("why"),
                               doneWhen: doneWhen, appears: doneWhen == .appears ? appears : nil)
        }
        let wait = try values["wait"].flatMap { value -> Double? in
            guard !value.isNull else { return nil }
            guard let number = value.doubleValue, number.isFinite, number >= 0 else {
                throw Invalid("\"wait\" is 0 to \(Int(maxWait)) seconds.")
            }
            return min(number, maxWait)
        } ?? 0
        return Request(reason: reason, steps: steps, tab: tab, wait: wait)
    }
}

/// A handoff while it's live in Kite: its steps and how far the user got.
public struct Handoff: Identifiable, Hashable, Codable, Sendable {
    public struct Step: Identifiable, Hashable, Codable, Sendable {
        public enum State: String, Hashable, Codable, Sendable { case waiting, done, skipped }

        /// How Kite finds the step's control on the page.
        public enum Locator: Hashable, Codable, Sendable {
            case selector(String)
            case text(String)
            /// An element Claude named by ref, marked with `UserHandoff.markerAttribute`. The mark is gone once the
            /// page reloads (or Kite slept the tab), so `path` (its place in the page, checked against `label`) and
            /// then `label` find it again.
            /// the page redraws it.
            case marker(String, label: String?, path: String? = nil)
        }

        /// Why the user can't do the step on the page right now, from the last look.
        public enum Blocker: Hashable, Sendable {
            /// The control is on the page but turned off (disabled or aria-disabled), with the page's own
            /// words about it when it gives some ("Only Super Administrators can invite members").
            case disabled(why: String?)
            /// The tab is at another address than the step's page, and the control has been missing for a while.
            case offPage
            /// The step's tab is closed.
            case tabClosed
        }

        /// "h1.2": the handoff and the step's number.
        public let id: String
        /// From 1, in the order Claude gave.
        public let number: Int
        public var instruction: String
        public var why: String?
        /// A command for the user's terminal: only in handoffs saved before Kite stopped showing steps off the page
        /// (they're skipped when loaded).
        public var command: String?
        public var tab: UUID?
        public var locator: Locator?
        /// The step's page: where Kite last found its control (http or https only), to take the user back there when
        /// they lose it.
        public var url: String?
        public var state: State = .waiting
        /// What says it's done (`UserHandoff.DoneWhen`); nil goes by the control.
        public var doneWhen: UserHandoff.DoneWhen?
        /// With `doneWhen` `.appears`: the words that show up.
        public var appears: String?
        /// What finished it, in words for Claude: "the user clicked the highlighted control".
        public var how: String?
        /// Whether the ring found the control on the page the last time Kite looked.
        public var found: Bool?
        /// The last look found no shown control but one that matches, hidden (zero size, display none, visibility hidden).
        public var controlHidden: Bool?
        /// Why the step can't be done right now, from the last look; nil when nothing is in the way. Only the step a
        /// tab shows is looked at, so a step waiting behind another on its tab (whose control the first one turns on)
        /// isn't called blocked.
        public var blocker: Blocker?

        public init(id: String, number: Int, instruction: String, why: String? = nil, command: String? = nil, tab: UUID? = nil,
                    locator: Locator? = nil, url: String? = nil) {
            self.id = id
            self.number = number
            self.instruction = instruction
            self.why = why
            self.command = command
            self.tab = tab
            self.locator = locator
            self.url = url
        }

        public var isWaiting: Bool { state == .waiting }

        /// The words on the step's control, for "“Invite members” can't be clicked yet".
        public var targetName: String? {
            switch locator {
            case .text(let text)?: text
            case .marker(_, let label?, _)?: label
            default: nil
            }
        }

        /// Its control is on the page but turned off.
        public var isTurnedOff: Bool {
            if case .disabled? = blocker { true } else { false }
        }

        /// The page can't show the step to the user: Kite shows it only beside its control.
        public var isUnshown: Bool {
            switch blocker {
            case .offPage?, .tabClosed?: true
            case .disabled?: false
            case nil: found == false
            }
        }

        /// What's in the way, in words for Claude. `blocked` is false while an earlier step of the handoff waits: that
        /// step may be what turns the control on, or brings it up.
        public func blockerNote(blocked: Bool) -> String? {
            switch blocker {
            case .disabled? where !blocked: "its control is turned off for now, probably until the steps before it are done"
            case .disabled(let why)?:
                "BLOCKED: its control is on the page but turned off (disabled), so the user can't click it"
                    // The page's own words, which it controls: marked as page content, like everything else read off a page.
                    + (why.map { ". The page says: " + UntrustedContent.wrap($0, source: "the step's control") }
                        ?? ". Something it needs (a field, a choice, a permission) is probably missing")
            case .offPage?: (blocked ? "NOT SHOWN: " : "") + "the tab is no longer on the step's page (\(url ?? "unknown")), so the "
                + "user can't see the step there. Navigate the tab back to it, or withdraw the handoff"
            case .tabClosed?: (blocked ? "NOT SHOWN: " : "") + "its tab is closed, so the user can't see the step. Open the page "
                + "again and hand the step over on the new tab, or withdraw the handoff if it's no longer needed"
            case nil where found == false && !blocked: "Kite can't find its control on the page yet (a step before it may bring it up)"
            case nil where found == false && controlHidden == true: "NOT SHOWN: its control is on the page but hidden (no "
                + "size, display none or visibility hidden: often a field the site draws its own box over), so Kite can't ring "
                + "it and the user sees nothing for this step. Point it at what the user sees and clicks or types in (a ref "
                + "from find or read_page, or the box's visible text), or withdraw the handoff"
            case nil where found == false: "NOT SHOWN: Kite can't find its control on the page, so the user sees nothing for this "
                + "step but a dot on its tab in the sidebar. Point it at a control that's on the page now (a ref from find or "
                + "read_page; a control in another site's frame, such as a CAPTCHA or a card field, by its visible text or a "
                + "selector), or withdraw the handoff"
            case nil: nil
            }
        }

        /// `found` and `blocker` are only what the last look saw, so they aren't saved.
        enum CodingKeys: String, CodingKey { case id, number, instruction, why, command, tab, locator, url, state, how, doneWhen, appears }
    }

    /// A tab a step's click opened (a link to a new tab, a popup): a wait ends for it, and Claude carries on there
    /// (the report's list of opened tabs, `AutomationController.openedReport`, names it).
    public struct Opened: Hashable, Sendable {
        /// The number of the step whose click opened it.
        public var step: Int
        public var tab: UUID

        public init(step: Int, tab: UUID) {
            self.step = step
            self.tab = tab
        }
    }

    /// "h1", "h2": short enough for Claude to pass back.
    public let id: String
    public var reason: String
    /// The Claude session folder of the session that asked, when it named one.
    public var session: String?
    public var created: Date
    public var steps: [Step]
    /// Tabs the user's clicks opened, oldest first. News for the next report only, so not saved.
    public var opened: [Opened] = []

    enum CodingKeys: String, CodingKey { case id, reason, session, created, steps }

    public init(id: String, reason: String, session: String? = nil, created: Date = Date(), steps: [Step]) {
        self.id = id
        self.reason = reason
        self.session = session
        self.created = created
        self.steps = steps
    }

    public var waiting: [Step] { steps.filter(\.isWaiting) }

    /// Whether Kite still looks at the steps' pages twice a second while they're on screen (`UserHandoff.watchLimit`).
    public func isWatched(now: Date = Date()) -> Bool {
        !isFinished && now.timeIntervalSince(created) < UserHandoff.watchLimit
    }

    /// Whether Kite should look at the pages twice a second: a watched handoff has a waiting step whose tab
    /// `isShown` (its page on screen in a window the user can see). Otherwise Kite only looks on events.
    public static func needsPolling(_ handoffs: [Handoff], now: Date = Date(), isShown: (UUID) -> Bool) -> Bool {
        handoffs.contains { handoff in
            handoff.isWatched(now: now) && handoff.waiting.contains { step in step.tab.map(isShown) ?? false }
        }
    }

    /// A waiting step the user is stuck on, while no earlier step of the handoff waits: its control is turned off, or
    /// the page can't show the step at all (`Step.isUnshown`: its control missing, its page left, its tab closed).
    /// (While an earlier one waits, that step may be what turns the control on or brings it up.)
    public func isBlocked(_ step: Step) -> Bool {
        guard step.isWaiting, step.isUnshown || step.isTurnedOff else { return false }
        return !steps.contains { $0.isWaiting && $0.number < step.number }
    }

    public var blockedSteps: [Step] { steps.filter(isBlocked) }
    public var isFinished: Bool { !steps.contains(where: \.isWaiting) }

    /// The step a tab shows: its first waiting one, so "Approve, then Save" on one tab goes in order.
    public func current(on tab: UUID) -> Step? {
        steps.first { $0.isWaiting && $0.tab == tab }
    }

    /// Ends a waiting step. Steps already ended stay as they are, so a late click can't undo a Skip.
    @discardableResult
    public mutating func finish(_ stepID: String, _ state: Step.State, how: String) -> Bool {
        guard let index = steps.firstIndex(where: { $0.id == stepID }), steps[index].isWaiting, state != .waiting else { return false }
        steps[index].state = state
        steps[index].how = how
        return true
    }

    /// Tabs whose step just ended (done or skipped) between `before` and now, with no step left waiting on them: the
    /// user's turn there is over, so they go straight back to working, "Claude is picking up", without waiting for
    /// Claude's next tool call (Gabe, 5 Nov 2026: "as soon as i do what claude tells me from the highlight, it should go
    /// back to the cranking state with shiny text, rn it takes a while to kick in").
    public func tabsPickedUp(since before: Handoff) -> [UUID] {
        let ended = steps.filter { step in !step.isWaiting && before.steps.first { $0.id == step.id }?.isWaiting == true }
        var tabs: [UUID] = []
        for tab in ended.compactMap(\.tab) where current(on: tab) == nil && !tabs.contains(tab) { tabs.append(tab) }
        return tabs
    }

    /// Ends every waiting step (the user dismissed the handoff, or Claude withdrew it).
    public mutating func finishAll(_ state: Step.State, how: String, where include: (Step) -> Bool = { _ in true }) {
        for index in steps.indices where steps[index].isWaiting && include(steps[index]) {
            steps[index].state = state
            steps[index].how = how
        }
    }

    /// What `handoff` and `handoff_status` tell Claude. `place` gives a tab's URL and title for steps on tabs.
    public func report(waitedOut: Bool = false, place: (UUID) -> (url: String?, title: String)?) -> String {
        let done = steps.filter { $0.state == .done }.count
        let skipped = steps.filter { $0.state == .skipped }.count
        let left = steps.count - done - skipped
        var lines = ["Handoff \(id): \(done) of \(steps.count) done" + (skipped > 0 ? ", \(skipped) skipped" : "")
            + (left > 0 ? ", \(left) waiting for the user." : ".")]
        for step in steps {
            var line = "\(step.number). [\(step.state.rawValue)] \(step.instruction)"
            if let how = step.how { line += " (\(how))" }
            if step.isWaiting, let note = step.blockerNote(blocked: isBlocked(step)) { line += " — \(note)" }
            if let tab = step.tab {
                if let place = place(tab) {
                    line += " · tab \(tab.uuidString) at \(place.url ?? "an unknown URL") (“\(place.title)”)"
                } else {
                    line += " · tab \(tab.uuidString), now closed"
                }
            }
            lines.append(line)
        }
        if left == 0 {
            lines.append((skipped == 0
                ? "The user did every step. Read the pages now to check they took"
                : "Skipped steps weren't done: don't do them yourself. Say what's left and why")
                + ", then carry on at once: " + Self.carryOn)
        } else if !blockedSteps.isEmpty {
            lines.append("The user can't do a blocked or unshown step as it is. Fix what's in the way yourself if you may (bring "
                + "the step's page back, or what turns its control on), or withdraw this handoff (handoff_status cancel) and "
                + "hand over the steps again in order, each with a control that's on its page now. Then call handoff_status "
                + "with id \"\(id)\" and wait.")
        } else if waitedOut {
            lines.append("The steps stay in Kite for the user. Call handoff_status with id \"\(id)\" and wait "
                + "\(Int(UserHandoff.maxWait)) again, or carry on with work that doesn't need them. "
                + Self.dontStop)
        } else {
            lines.append("Kite is showing these to the user. Now call handoff_status with id \"\(id)\" and wait "
                + "\(Int(UserHandoff.maxWait)) to hear when they're done. " + Self.dontStop)
        }
        return lines.joined(separator: "\n")
    }

    /// What Claude does the moment a handoff ends: the page after the user's click is usually the next part of the job
    /// (Gabe, 5 Nov 2026: McMaster's order form sat unfilled after he made the login).
    static let carryOn = "a step often leads to a new page (an order form after a sign-up), so read_page each step's tab, fill "
        + "its ordinary fields (names, addresses, phone, email, plain choices) yourself, and hand over only what's the "
        + "user's (secrets, account-making, terms and pay clicks) with a new handoff."

    /// A handoff that ended while Claude did something else, for its next tool result.
    public static func endedNews(_ handoff: Handoff) -> String {
        let done = handoff.steps.filter { $0.state == .done }.count, skipped = handoff.steps.filter { $0.state == .skipped }.count
        return "Kite: handoff \(handoff.id) has ended (\(done) of \(handoff.steps.count) done"
            + (skipped > 0 ? ", \(skipped) skipped" : "") + "). Carry on now: " + carryOn
            + " handoff_status with id \"\(handoff.id)\" has the details."
    }

    /// Why Claude keeps waiting: once its turn ends, nothing reaches it when the user is done.
    static let dontStop = "Don't end your turn while steps wait: Kite can't tell you when the user is done once you've "
        + "stopped, and they're left waiting on you. Each wait returns the moment the user finishes (or a step's click "
        + "opens a new tab), so keep calling it; a longer wait is cut to \(Int(UserHandoff.maxWait)) s, as clients time out."
}

/// When a waiting handoff_status (or handoff) ends early to tell Claude a step is blocked: once a step has stayed
/// blocked for `delay` (unshown for `unshownDelay`), and only once per step, so a control the page redraws can't end
/// every wait.
public struct HandoffBlockWatch: Sendable {
    /// Steps Claude has already been told are blocked.
    public var reported: Set<String>
    private var since: [String: Date] = [:]

    public init(reported: Set<String> = []) {
        self.reported = reported
    }

    /// One look at the handoff: true when a step not yet reported has been blocked for `delay`, or unshown (its
    /// control missing, its page left, its tab closed) for `unshownDelay` (default `delay`).
    public mutating func shouldReport(_ handoff: Handoff, now: Date = Date(), delay: TimeInterval,
                                      unshownDelay: TimeInterval? = nil) -> Bool {
        let blocked = handoff.blockedSteps.filter { !reported.contains($0.id) }
        let ids = Set(blocked.map(\.id))
        since = since.filter { ids.contains($0.key) }
        for id in ids where since[id] == nil { since[id] = now }
        return blocked.contains { step in
            since[step.id].map { now.timeIntervalSince($0) >= (step.isUnshown ? unshownDelay ?? delay : delay) } ?? false
        }
    }
}

/// Taking the user to the step Claude needs them for. A step on a tab that isn't in front shows nobody anything, so
/// Kite brings that tab forward (its space too), scrolls the control into view and pulses the ring when a handoff
/// starts. Only then: finishing a step, or the handoff, never moves the user (Gabe, 5 Nov 2026: "keep me in the same
/// tab"); the next step's tab is orange in the sidebar with its control ringed. Only once (a user who goes elsewhere
/// afterwards isn't pulled back), and never while they're typing or clicking in Kite, which would switch the page
/// under their hands: Kite waits until they've paused.
public enum HandoffLead {
    /// When Kite might move the user to a step's tab.
    public enum Moment: Sendable { case handoffStarted, stepEnded }

    /// Whether Kite brings a step's tab to the front at `moment`: only when a handoff starts.
    public static func bringsTabForward(at moment: Moment) -> Bool { moment == .handoffStarted }

    /// How long after a key press in Kite it waits before switching the tab, and after a click, scroll or pointer move.
    public static let afterTyping: TimeInterval = 4
    public static let afterPointer: TimeInterval = 1.5
    /// How often a waiting lead checks whether the user has paused.
    public static let recheck: TimeInterval = 0.5

    /// The step to take the user to: the first waiting one (in Claude's order) whose tab is open, unless the tab in
    /// front already has a step waiting (they're where they're needed). Nil when there's nowhere to take them.
    public static func target(_ handoff: Handoff, front: UUID?, isOpen: (UUID) -> Bool) -> Handoff.Step? {
        if let front, handoff.current(on: front) != nil { return nil }
        return handoff.steps.first { step in step.isWaiting && step.tab.map(isOpen) == true }
    }

    /// Whether the user is in the middle of something in Kite: Kite is the active app and they pressed a key within
    /// `afterTyping`, or clicked, scrolled or moved the pointer within `afterPointer` (seconds since each), or they're
    /// typing in Kite's own command bar. While Kite isn't the active app, switching its tab interrupts nothing.
    public static func userIsBusy(appActive: Bool, sinceKey: TimeInterval, sincePointer: TimeInterval,
                                  commandBarOpen: Bool = false) -> Bool {
        guard appActive else { return false }
        return commandBarOpen || sinceKey < afterTyping || sincePointer < afterPointer
    }

    /// The line for Claude about where Kite took the user. `title` is the step's tab's title.
    public static func note(_ step: Handoff.Step, title: String?, led: Bool) -> String {
        let place = title.map { "“\($0)”" } ?? "its tab"
        return led
            ? "Kite brought step \(step.number)'s tab (\(place)) to the front for the user, with its control ringed."
            : "Kite will bring step \(step.number)'s tab (\(place)) to the front once the user stops typing in Kite."
    }
}

extension Handoff {
    /// Whether a tab at `current` is at another address than a step's page (`stepURL`, where its control was last
    /// found). Kite only calls it a page left once the control has been missing for `UserHandoff.offPageDelay`.
    public static func isOffPage(stepURL: String?, current: URL?) -> Bool {
        guard let stepURL, let page = URL(string: stepURL), let current, canReturn(to: page) else { return false }
        return address(page) != address(current)
    }

    /// A page Kite may load again for the user: a web page, not a file, data or internal one.
    public static func canReturn(to url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }

    /// An address to compare: the host's case, a default port and a trailing slash don't count.
    private static func address(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.host = parts.host?.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        if parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.string ?? url.absoluteString
    }
}

// MARK: Keeping handoffs across launches

extension Handoff {
    /// Where a profile keeps its handoffs, so steps still waiting come back when Kite does.
    public static func fileURL(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("Claude Handoffs.json")
    }

    /// How long a handoff lasts across launches, waiting or not.
    public static let lifetime: TimeInterval = 7 * 24 * 3600
    /// Finished handoffs kept for handoff_status.
    public static let keptFinished = 20

    /// The saved handoffs still worth keeping: under a week old, and the newest finished ones.
    /// A handoff that doesn't decode (a step from a newer build, say) is left out and the file copied
    /// aside; a file that won't decode at all is moved aside, or never saved over when it can't be (`StoreFile`).
    public static func load(from url: URL, now: Date = Date()) -> [Handoff] {
        guard let lossy = StoreFile.load([Lossy<Handoff>].self, from: url, makeDecoder: { .handoffs }, now: now).value
        else { return [] }
        let saved = lossy.compactMap(\.value)
        return pruned(saved.filter { now.timeIntervalSince($0.created) < lifetime })
    }

    public static func save(_ handoffs: [Handoff], to url: URL) throws {
        try StoreFile.checkWritable(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.handoffs.encode(handoffs).write(to: url, options: .atomic)
    }

    /// Drops the oldest finished handoffs past `keptFinished`; waiting ones always stay.
    public static func pruned(_ handoffs: [Handoff]) -> [Handoff] {
        let finished = handoffs.filter(\.isFinished)
        guard finished.count > keptFinished else { return handoffs }
        let drop = Set(finished.prefix(finished.count - keptFinished).map(\.id))
        return handoffs.filter { !drop.contains($0.id) }
    }

    /// The number after "h" in the newest id, so new handoffs don't reuse a saved one's.
    public static func lastNumber(in handoffs: [Handoff]) -> Int {
        handoffs.compactMap { Int($0.id.dropFirst()) }.max() ?? 0
    }
}

private extension JSONEncoder {
    static var handoffs: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var handoffs: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: The ring on the page

extension UserHandoff {
    /// What the page script needs for the step a tab shows.
    public struct RingConfig: Encodable, Equatable, Sendable {
        public var step: String
        public var number: Int
        public var label: String
        /// Why Claude stopped, shown when the pointer rests on the tag.
        public var why: String?
        public var selector: String?
        public var text: String?
        public var marker: String?
        public var path: String?
        /// Scroll the control into view the first time it's found.
        public var scroll: Bool
        /// Only look: report whether the control is there and can be used, without drawing the ring.
        public var probe: Bool
        /// Kite just brought the tab forward for this step (`HandoffLead`): scroll the control into view again and
        /// pulse the ring, even if the page showed the step before.
        public var jump: Bool
        /// The password manager to offer on the tag when the control is a new password's field ("1Password"), so the
        /// user has it suggest one; nil for none. `manager` false: it isn't added to this tab's profile, and the tag says so.
        public var manager: String?
        public var managerReady: Bool
        /// What says the step is done (`DoneWhen`'s raw value); nil goes by the control.
        public var doneWhen: String?
        public var appears: String?
        /// The steps after it on the same tab, still waiting: a click on one of their controls ends this step (and every
        /// step before that one) too.
        public var later: [Later]

        /// A later step's control, found the same way as the step's own.
        public struct Later: Encodable, Equatable, Sendable {
            public var step: String
            public var selector: String?
            public var text: String?
            public var marker: String?
            public var path: String?
        }

        public init(step: Handoff.Step, why: String? = nil, scroll: Bool, probe: Bool = false, jump: Bool = false,
                    manager: String? = nil, managerReady: Bool = false, later: [Handoff.Step] = []) {
            doneWhen = step.doneWhen?.rawValue
            appears = step.appears
            self.later = later.map { other in
                var found = Later(step: other.id)
                switch other.locator {
                case .selector(let selector)?: found.selector = selector
                case .text(let text)?: found.text = text
                case .marker(let marker, let label, let path)?:
                    found.marker = marker
                    found.text = label
                    found.path = path
                case nil: break
                }
                return found
            }
            self.step = step.id
            number = step.number
            label = step.instruction
            self.why = step.why ?? why
            self.scroll = scroll
            self.probe = probe
            self.jump = jump
            self.manager = manager
            self.managerReady = managerReady
            switch step.locator {
            case .selector(let selector)?: self.selector = selector
            case .text(let text)?: self.text = text
            case .marker(let marker, let label, let path)?:
                self.marker = marker
                text = label
                self.path = path
            case nil: break
            }
        }
    }

    /// What the page script reports back.
    public struct RingState: Decodable, Equatable, Sendable {
        /// The control is on the page (and shown).
        public var found: Bool
        /// How the step ended, if it did since the last look ("click", "change", "value", "gone", "appeared", "later",
        /// or the tag's "skip").
        public var done: String?
        /// With `done` "later": the later step whose control the user clicked.
        public var later: String?
        /// The control is there but turned off, and the page's words about why when it gives some.
        public var disabled: Bool?
        public var why: String?
        /// Not found, but something matches its selector (or Claude's ref) that doesn't show.
        public var hidden: Bool?

        public init(found: Bool, done: String? = nil, disabled: Bool? = nil, why: String? = nil, hidden: Bool? = nil) {
            self.found = found
            self.done = done
            self.disabled = disabled
            self.why = why
            self.hidden = hidden
        }

        /// What blocks the step, as far as this look saw.
        public var blocker: Handoff.Step.Blocker? { found && disabled == true ? .disabled(why: why) : nil }

        public init?(json: String) {
            guard let state = try? JSONDecoder().decode(RingState.self, from: Data(json.utf8)) else { return nil }
            self = state
        }
    }

    /// A click the ring's listener reported through the binding.
    public struct RingEvent: Decodable, Equatable, Sendable {
        public var step: String
        public var how: String
        /// With `how` "later": the later step whose control the user clicked.
        public var later: String?

        public init?(json: String) {
            guard let event = try? JSONDecoder().decode(RingEvent.self, from: Data(json.utf8)) else { return nil }
            self = event
        }
    }

    /// Words for Claude about how the page saw the user end the step.
    public static func describe(_ how: String) -> String {
        switch how {
        case "change": "the user changed the highlighted control"
        case "value": "the user filled in the highlighted field and moved on"
        case "navigated": "the page moved on to another address"
        case "gone": "the highlighted control went away (the form was sent or replaced)"
        case "appeared": "what the step waited for appeared on the page"
        case "dialog": "the page opened a dialog"
        case "later": "the user went on to a later step's control"
        // Handoffs from before Kite dropped its Done button.
        case "done": "the user pressed Done"
        case "skip": "the user skipped it"
        default: "the user clicked the highlighted control"
        }
    }

    /// The tag's "Suggest password": not an end to the step, but a request to open the password manager on its field.
    public static let managerEvent = "manager"
    /// Asks the ring for the field's point, quieting its own click listener for Kite's click (`K.prepareManager`).
    public static let prepareManagerScript = "(() => { const K = window.__kiteHandoff; return K && K.prepareManager ? K.prepareManager() : 'null'; })()"
    /// Puts a few words on the tag's Suggest password button in its place, or takes them off (nil).
    public static func noteScript(_ note: String?) -> String {
        let json = (try? JSONEncoder().encode([note])).map { String(decoding: $0, as: UTF8.self) } ?? "[null]"
        return "(() => { const K = window.__kiteHandoff; return K && K.setNote ? K.setNote(\(json)[0]) : false; })()"
    }
    /// Whether 1Password's own inline button or menu is on the page (its elements only, never what they hold).
    public static let onePasswordPresentScript = "String(!!document.querySelector('com-1password-button, com-1password-menu'))"

    /// What the page's report makes of the step: the tag's Skip skips it, anything else does it.
    public static func state(_ how: String) -> Handoff.Step.State { how == "skip" ? .skipped : .done }

    /// Whether the user ended the step on the control itself (a click or a change), rather than on the tag: only such
    /// a click can be what opens a tab.
    public static func onControl(_ how: String) -> Bool { ["click", "change", "value", "later"].contains(how) }

    /// The same page, as far as a step is concerned: only the fragment may differ.
    public static func samePage(_ a: URL, _ b: URL) -> Bool {
        func strip(_ url: URL) -> String {
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
            parts.fragment = nil
            return parts.string ?? url.absoluteString
        }
        return strip(a) == strip(b)
    }

    /// Shows (or moves) the ring for one step, in the isolated world. Returns `RingState` as JSON.
    public static func ringScript(_ config: RingConfig) -> String {
        let json = (try? JSONEncoder().encode(config)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
        return "(\(ringFunction))(\(json))"
    }

    /// Takes the ring off the page.
    public static let clearScript = "(() => { const K = window.__kiteHandoff; if (K) K.clear(); return true; })()"

    /// The ring itself, and the tag beside it: the step's words and Skip (the only place Kite shows a step). They
    /// live in a closed shadow root on a host element that takes no clicks (only the tag does), in an isolated world, so
    /// the page can neither style them nor read or fake their state. Every frame they follow the control's box.
    ///
    /// Single-page apps (Cloudflare, Squarespace, Gmail) draw a page several times before it settles: a skeleton,
    /// then the controls, then the same controls again. So the ring looks the control up again whenever the page
    /// changes, moves only to a candidate that has stayed put for `settle` ms, and prefers a real control that says
    /// exactly the words over a block of text that merely mentions them. It looks in same-origin frames too. A
    /// control that's disabled is still ringed (dashed, grey) and reported, with the page's own reason when it
    /// gives one, so Claude and the user hear why the step can't be done yet.
    static let ringFunction = #"""
        (cfg) => {
          const settle = 300;
          const K = window.__kiteHandoff || (window.__kiteHandoff = { step: null, el: null, cand: null, candAt: 0, done: null,
            scrolled: false, raf: 0, timer: 0, retry: 0 });
          if (!K.docs) K.docs = new WeakSet();
          const norm = (s) => (s || '').replace(/\s+/g, ' ').trim().toLowerCase();
          const style = (el) => (el.ownerDocument.defaultView || window).getComputedStyle(el);
          const shown = (el) => {
            const r = el.getBoundingClientRect(), s = style(el);
            return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
          };
          // The page and its same-origin frames, which Squarespace and Gmail draw parts of the page in.
          const docs = () => {
            const out = [];
            const walk = (d, depth) => {
              out.push(d);
              if (depth >= 3) return;
              for (const f of d.querySelectorAll('iframe,frame')) {
                let inner = null;
                try { inner = f.contentDocument; } catch (e) {}
                if (inner && inner.documentElement) walk(inner, depth + 1);
              }
            };
            walk(document, 0);
            return out;
          };
          // Where a frame's element sits in the top page, and the part of the top page its frames show (an element
          // scrolled out of its frame isn't on screen).
          const offset = (el) => {
            let x = 0, y = 0, clip = null, w = el.ownerDocument.defaultView;
            while (w && w !== window) {
              let fe = null;
              try { fe = w.frameElement; } catch (e) {}
              if (!fe) break;
              const r = fe.getBoundingClientRect();
              const view = { left: r.left + fe.clientLeft, top: r.top + fe.clientTop, width: fe.clientWidth, height: fe.clientHeight };
              // Earlier (inner) clips were in this frame's coordinates: move them out with the rest.
              if (clip) clip = { left: clip.left + view.left, top: clip.top + view.top, right: clip.right + view.left, bottom: clip.bottom + view.top };
              const own = { left: view.left, top: view.top, right: view.left + view.width, bottom: view.top + view.height };
              clip = clip ? { left: Math.max(clip.left, own.left), top: Math.max(clip.top, own.top),
                right: Math.min(clip.right, own.right), bottom: Math.min(clip.bottom, own.bottom) } : own;
              x += view.left; y += view.top;
              w = fe.ownerDocument.defaultView;
            }
            return { x, y, clip };
          };
          const real = 'button,a[href],input:not([type=hidden]),select,textarea,summary,[role=button],[role=link],[role=checkbox],'
            + '[role=switch],[role=radio],[role=tab],[role=menuitem],[role=menuitemcheckbox],[role=menuitemradio],[role=option]';
          const controls = real + ',label,[tabindex]';
          // A focusable block that's no control: a dialog, a panel, a help line.
          const loose = '[tabindex]:not(' + real + ',label)';
          const words = (el) => norm(el.getAttribute('aria-label') || el.innerText || el.value || el.title
            || (el.labels && el.labels[0] && el.labels[0].innerText) || '');
          // An element's text, read only up to `max` characters: null past that.
          const textUpTo = (el, max) => {
            const walk = el.ownerDocument.createTreeWalker(el, NodeFilter.SHOW_TEXT);
            let text = '';
            for (let n = walk.nextNode(); n; n = walk.nextNode()) {
              text += n.data;
              if (text.length > max) return null;
            }
            return text;
          };
          // Cheap first look, before layout: could this element say the words at all? A big block can't be a match
          // (see byText), so its text is read only so far.
          const mentions = (el, want) => {
            const named = norm([el.getAttribute('aria-label'), el.value, el.title,
              el.labels && el.labels[0] && el.labels[0].textContent].join(' '));
            if (named.includes(want)) return true;
            const text = textUpTo(el, (want.length + 40) * 4);
            // Block children's words run together in text nodes ("Continue" "with Google"): compare without spaces.
            return text !== null && norm(text).replace(/ /g, '').includes(want.replace(/ /g, ''));
          };
          // Why a control can't be used, or null when it can: disabled or aria-disabled, with the page's own
          // words about it when it gives some (a title, a description, a tooltip attribute).
          const blocked = (el) => {
            // Not inert: that's usually a dialog in front of the page, not a control that's off.
            const off = el.disabled === true || el.matches(':disabled') || !!el.closest('[aria-disabled="true"]');
            if (!off) return null;
            const own = words(el), said = [];
            const desc = (el.getAttribute('aria-describedby') || '').split(/\s+/).filter(Boolean)
              .map((id) => el.ownerDocument.getElementById(id)).filter(Boolean).map((n) => n.textContent).join(' ');
            said.push(el.getAttribute('aria-description'), desc);
            for (let n = el, i = 0; n && n.getAttribute && i < 4; n = n.parentElement, i++) {
              said.push(n.getAttribute('title'), n.getAttribute('data-tooltip'), n.getAttribute('data-tip'), n.getAttribute('data-title'));
            }
            const why = said.map((s) => (s || '').replace(/\s+/g, ' ').trim()).find((s) => s && norm(s) !== own) || '';
            return { why: why.slice(0, 200) };
          };
          const byText = (want) => {
            want = norm(want);
            if (!want) return null;
            let best = null, score = 0;
            for (const d of docs()) {
              for (const el of d.querySelectorAll(controls)) {
                if (el === K.host) continue;
                // A focusable block only counts when it says exactly the words: skip big ones before reading their
                // text or any layout.
                if (el.matches(loose) && !el.getAttribute('aria-label')
                  && (el.childElementCount > 8 || textUpTo(el, want.length * 2 + 10) === null)) continue;
                if (!mentions(el, want)) continue;
                if (!shown(el)) continue;
                const t = words(el);
                if (!t) continue;
                // Exact words first. A partial match only counts on a control or label that says little else (a
                // panel or a help line that mentions "Invite members" isn't the button), or a control whose words
                // start with them ("Delete" for "Delete this repository…").
                const control = el.matches(real), partial = t.length <= want.length + 40 && !el.matches(loose);
                let s = t === want ? 30 : t.startsWith(want) && (partial || control) ? 20 : partial && t.includes(want) ? 10 : 0;
                if (!s) continue;
                if (control) s += 4;
                if (!blocked(el)) s += 1;
                // At a tie, the smaller element (a button inside a matching row).
                if (s > score || (s === score && best && best.contains(el))) { best = el; score = s; }
              }
            }
            return best;
          };
          const firstShown = (selector) => {
            for (const d of docs()) {
              let all = [];
              try { all = d.querySelectorAll(selector); } catch (e) { return null; }
              for (const el of all) if (shown(el)) return el;
            }
            return null;
          };
          // The control's own box, in the top page. A label or other block that holds a short control
          // ("☐ Super Administrator" across a whole row) is ringed around what it shows, not its full width.
          const box = (el, clipped = true) => {
            const o = offset(el), move = (r) => {
              const m = { left: r.left + o.x, top: r.top + o.y, right: r.right + o.x, bottom: r.bottom + o.y, width: r.width, height: r.height };
              return clipped && o.clip && (m.right <= o.clip.left || m.left >= o.clip.right || m.bottom <= o.clip.top || m.top >= o.clip.bottom) ? null : m;
            };
            const r = el.getBoundingClientRect();
            if (style(el).display === 'inline' || el.matches('input,select,textarea,button')) return move(r);
            const range = el.ownerDocument.createRange();
            range.selectNodeContents(el);
            const c = range.getBoundingClientRect();
            if (c.width <= 0 || c.height <= 0 || c.width >= r.width - 1) return move(r);
            return move({ left: c.left, top: Math.min(c.top, r.top), right: c.right, bottom: Math.max(c.bottom, r.bottom),
              width: c.width, height: Math.max(c.bottom, r.bottom) - Math.min(c.top, r.top) });
          };
          const find = (c) => {
            if (c.marker) {
              // The element Claude named, while it's on the page at all: hidden (a closed menu), it's nothing,
              // never another control with the same words.
              const mark = '[data-kite-handoff="' + CSS.escape(c.marker) + '"]';
              const marked = firstShown(mark);
              if (marked) return marked;
              if (docs().some((d) => d.querySelector(mark))) return null;
            }
            if (c.selector) return firstShown(c.selector);
            // After a reload: the same place in the page, if it still says the same; otherwise its words.
            if (c.path) {
              let placed = null;
              try { placed = document.querySelector(c.path); } catch (e) {}
              if (placed && shown(placed) && (!c.text || words(placed) === norm(c.text))) return placed;
            }
            return c.text ? byText(c.text) : null;
          };
          // Something matches but none of it shows (zero size, display none, visibility hidden): a field a site draws
          // its own box over, say. Claude hears so, to point the step at what the user sees.
          const hiddenMatch = (c) => {
            const sel = c.marker ? '[data-kite-handoff="' + CSS.escape(c.marker) + '"]' : c.selector;
            if (!sel) return false;
            return docs().some((d) => { try { return !!d.querySelector(sel); } catch (e) { return false; } });
          };
          const state = (el) => {
            const b = el ? blocked(el) : null;
            return JSON.stringify({ found: !!el, done: cfg && !cfg.probe ? K.done : null, later: cfg && !cfg.probe ? K.doneLater || null : null,
              disabled: !!b, why: b && b.why || null, hidden: !el && cfg ? hiddenMatch(cfg) : null });
          };
          // What the user types in: the field itself (a label's field; the one frame a box holds, for a payment field in
          // another site's frame), or null for a button, link or box.
          const textual = (f) => f.matches('textarea,select,[contenteditable=""],[contenteditable=true]')
            || (f.matches('input') && !/^(button|submit|reset|checkbox|radio|image|file|color|range|hidden)$/.test(f.type));
          const field = (el) => {
            if (!el) return null;
            if (el.matches('label') && el.control) el = el.control;
            if (el.matches('iframe') || textual(el)) return el;
            const frames = el.querySelectorAll('iframe');
            return frames.length === 1 ? frames[0] : null;
          };
          // What says the step is done: Claude's done_when, else the control's kind.
          const mode = () => (K.cfg && K.cfg.doneWhen) || (field(K.el || K.cand) ? 'value' : 'click');
          const filled = (f) => f.isContentEditable ? !!norm(f.innerText) : !!(f.value && String(f.value).trim());
          // Ends the step: once, through the binding at once (the page may be about to go), and in the next look's state.
          const finish = (how, later) => {
            if (!K.step || K.done) return;
            K.done = how; K.doneLater = later || null;
            stopFrameWatch();
            try { window.kiteHandoffEvent(JSON.stringify(later ? { step: K.step, how, later } : { step: K.step, how })); } catch (err) {}
          };
          // A later step's control on this page at `target`: the user went on to it, so this step is done too.
          const laterAt = (target, path) => {
            if (!target || !target.nodeType) return null;
            for (const l of (K.cfg && K.cfg.later) || []) {
              const el = find(l);
              if (el && ((path || []).includes(el) || el === target || el.contains(target)) && !blocked(el)) return l;
            }
            return null;
          };
          // A payment field in another site's frame: Kite can't read its value, so focus having been in the frame and
          // moving on (another field, another frame, a click elsewhere) is the user done typing there.
          function stopFrameWatch() {
            if (K.frameTimer) clearInterval(K.frameTimer);
            K.frameTimer = 0; K.inFrame = null;
          }
          const frameLeft = (target, path) => {
            if (!K.inFrame || K.done) return;
            const l = laterAt(target, path);
            stopFrameWatch();
            if (l) finish('later', l.step); else finish('value');
          };
          const frameWatch = () => {
            const f = K.inFrame;
            if (!f || K.done || !K.step) return stopFrameWatch();
            const a = f.ownerDocument.activeElement;
            // Still in the frame (the page's focus stays there when the whole window goes to another app): not yet.
            if (a === f) return;
            frameLeft(a, [a]);
          };
          const frameFocus = () => {
            if (!K.step || K.done || mode() !== 'value') return;
            const f = field(K.el);
            if (!f || !f.matches('iframe') || f.ownerDocument.activeElement !== f || K.inFrame) return;
            K.inFrame = f;
            K.frameTimer = setInterval(frameWatch, 150);
          };
          // A field for a new password (sign-up, create a login): the tag offers the password manager's suggestion.
          const newPassword = (el) => {
            if (!el || !el.matches('input[type=password]')) return false;
            const ac = (el.getAttribute('autocomplete') || '').toLowerCase();
            if (ac.includes('new-password')) return true;
            if (ac.includes('current-password')) return false;
            const scope = el.form || el.ownerDocument;
            if (scope.querySelectorAll('input[type=password]').length > 1) return true;
            return /sign ?up|create|register|join|new password|choose a password/i.test(
              (el.form ? el.form.innerText : '') + ' ' + (el.getAttribute('placeholder') || '') + ' ' + (el.getAttribute('aria-label') || ''));
          };
          // A look without the ring: is the control there, and can it be used?
          if (cfg && cfg.probe) return state(find(cfg));
          if (!K.clear) {
            K.clear = () => {
              K.step = null; K.el = null; K.cand = null; K.cfg = null; K.done = null; K.retry = 0; K.idle = 0; K.note = null;
              K.doneLater = null; K.seen = 0; K.goneAt = 0; K.appearsBefore = undefined; K.fieldFocused = false;
              if (K.frameTimer) clearInterval(K.frameTimer);
              K.frameTimer = 0; K.inFrame = null;
              if (K.raf) cancelAnimationFrame(K.raf);
              if (K.checkRaf) cancelAnimationFrame(K.checkRaf);
              K.checkRaf = 0;
              if (K.timer) clearTimeout(K.timer);
              K.raf = 0; K.timer = 0;
              // Stop watching the pages: nothing is looked for until the next step.
              for (const stop of K.watching || []) stop();
              K.watching = []; K.docs = new WeakSet();
              if (K.host) K.host.remove();
              K.host = null;
            };
          }
          // For "Suggest password": Kite's click on the field must not count as the step, and needs the field's middle on
          // screen. Returns its point in this frame's viewport, or null.
          K.prepareManager = () => {
            const el = K.el && K.el.isConnected && shown(K.el) ? K.el : null;
            if (!el) return 'null';
            K.quietUntil = Date.now() + 2500;
            let r = box(el, false);
            if (r.top < 0 || r.bottom > innerHeight) { el.scrollIntoView({ block: 'center', behavior: 'instant' }); r = box(el, false); }
            return JSON.stringify({ x: r.left + Math.min(r.width / 2, 24), y: r.top + r.height / 2 });
          };
          // A few words on the Suggest password button (the password manager didn't open, say), until the step changes.
          K.setNote = (note) => { K.note = note || null; K.tagSize = null; if (K.cfg) { look(); follow(); } return true; };
          const report = (how) => (e) => {
            if (!e.isTrusted || !K.step || K.done) return;
            // Kite's own click on the field, to open the password manager's menu there, isn't the user doing the step.
            if (K.quietUntil && Date.now() < K.quietUntil) return;
            // The ringed control, or the live one about to take its place (a page that redrew it under the pointer, or
            // a control the user clicked before the ring settled on it).
            const path = e.composedPath ? e.composedPath() : [];
            const hit = [K.el, !K.el || !K.el.isConnected ? K.cand : null]
              .find((el) => el && el.isConnected && (path.includes(el) || el.contains(e.target)));
            if (!hit) {
              // A later step's control: the user went on, so this step (and any between) is done.
              const l = how === 'click' ? laterAt(e.target, path) : null;
              if (l) finish('later', l.step);
              return;
            }
            if (blocked(hit)) return;
            const m = mode();
            // A field is done once it holds a value and the user moves on, not on the click into it.
            if (m === 'value') { if (how === 'change' && !field(hit).matches('iframe')) finish('value'); return; }
            if (m === 'click') finish(how);
          };
          // A field: done once it holds a value and focus leaves it for somewhere else on the page. (Another app taking
          // the window's focus leaves the page's focus on the field.)
          const left = (e) => {
            if (!e.isTrusted || !K.step || K.done || mode() !== 'value') return;
            const f = field(K.el);
            if (!f || f.matches('iframe') || !(e.target === f || f.contains(e.target))) return;
            const next = e.relatedTarget, l = next ? laterAt(next, [next]) : null;
            if (l) return finish('later', l.step);
            setTimeout(() => {
              const a = f.ownerDocument.activeElement;
              if (!K.done && K.step && a !== f && !f.contains(a) && filled(f)) finish('value');
            }, 0);
          };
          // Enter in the field, or Tab out of it with a value.
          const key = (e) => {
            if (!e.isTrusted || !K.step || K.done || mode() !== 'value' || (e.key !== 'Enter' && e.key !== 'Tab')) return;
            const f = field(K.el);
            if (!f || f.matches('iframe') || !(e.target === f || f.contains(e.target))) return;
            if (e.key === 'Enter' || filled(f)) finish('value');
          };
          // A press anywhere on this page while the user was typing in the ringed frame: they've moved on.
          const pressed = (e) => {
            if (!e.isTrusted || !K.inFrame) return;
            frameLeft(e.target, e.composedPath ? e.composedPath() : []);
          };
          const windowBlurred = () => setTimeout(frameFocus, 0);
          // Each document once, until K.clear(): hear the user's click, and look again soon after the page redraws.
          const watch = () => {
            if (!K.watching) K.watching = [];
            for (const d of docs()) {
              if (K.docs.has(d)) continue;
              K.docs.add(d);
              const click = report('click'), change = report('change');
              d.addEventListener('click', click, true);
              d.addEventListener('change', change, true);
              d.addEventListener('focusout', left, true);
              d.addEventListener('keydown', key, true);
              d.addEventListener('pointerdown', pressed, true);
              // The ring follows the control's box only while something may move it (see place): a scroll, a resize,
              // the end of a transition or animation, and any change to the page (classes and styles too), which costs
              // one frame to see whether the box moved.
              const moved = () => follow();
              const view = d.defaultView;
              d.addEventListener('scroll', moved, { capture: true, passive: true });
              for (const name of ['transitionend', 'animationend']) d.addEventListener(name, moved, true);
              if (view) view.addEventListener('resize', moved);
              // Focus going into a frame shows here only as this window losing it.
              if (view) view.addEventListener('blur', windowBlurred);
              const mover = new MutationObserver(() => checkMoved());
              mover.observe(d, { subtree: true, childList: true, attributes: true, attributeFilter: ['class', 'style'] });
              // While the control is missing, a page that never stops changing (Gmail) still gets the idle backoff.
              const observer = new MutationObserver(() => soon(K.el ? 1000 : Math.max(150, K.idle || 150)));
              observer.observe(d, { subtree: true, childList: true, characterData: true,
                attributes: true, attributeFilter: ['disabled', 'aria-disabled', 'inert', 'hidden', 'aria-hidden', 'aria-label'] });
              K.watching.push(() => {
                observer.disconnect();
                mover.disconnect();
                for (const name of ['transitionend', 'animationend']) d.removeEventListener(name, moved, true);
                d.removeEventListener('click', click, true);
                d.removeEventListener('change', change, true);
                d.removeEventListener('focusout', left, true);
                d.removeEventListener('keydown', key, true);
                d.removeEventListener('pointerdown', pressed, true);
                if (view) view.removeEventListener('blur', windowBlurred);
                d.removeEventListener('scroll', moved, { capture: true });
                if (view) view.removeEventListener('resize', moved);
              });
            }
          };
          if (!cfg) return JSON.stringify({ found: false });
          // Kite asks for a scroll on its first look at a step only; the control may settle after a later one.
          if (K.step !== cfg.step) {
            K.step = cfg.step; K.el = null; K.cand = null; K.done = null; K.scrolled = false; K.retry = 0; K.idle = 0;
            K.wantScroll = cfg.scroll; K.pulse = true; K.note = null;
            K.doneLater = null; K.seen = 0; K.goneAt = 0; K.appearsBefore = undefined; K.fieldFocused = false; stopFrameWatch();
          }
          // Kite brought the tab forward for this step: into view again, and pulse.
          if (cfg.jump) { K.wantScroll = true; K.scrolled = false; K.pulse = true; }
          K.cfg = cfg;
          watch();
          if (!K.host || !K.host.isConnected) {
            const host = document.createElement('kite-handoff');
            host.style.cssText = 'all:initial;position:fixed;inset:0;pointer-events:none;z-index:2147483647;display:block;';
            const root = host.attachShadow({ mode: 'closed' });
            root.innerHTML = '<style>'
              + ':host{all:initial}'
              + '.ring{position:fixed;display:none;box-sizing:border-box;border:2px solid #D97757;border-radius:8px;'
              + 'box-shadow:0 0 0 4px rgba(217,119,87,.25);animation:kh 1.6s ease-in-out 4;pointer-events:none}'
              + '.ring.off{border:2px dashed #8E8E93;box-shadow:none;animation:none}'
              + '@keyframes kh{50%{box-shadow:0 0 0 8px rgba(217,119,87,.12)}}'
              + '.tag{position:fixed;display:none;align-items:center;gap:4px;max-width:440px;padding:3px 3px 3px 9px;'
              + 'border-radius:7px;background:#D97757;color:#fff;font:600 12px/16px -apple-system,BlinkMacSystemFont,system-ui,'
              + 'sans-serif;box-shadow:0 2px 8px rgba(0,0,0,.18);pointer-events:auto;cursor:default;user-select:none}'
              + '.tag.off{background:#636366}'
              + '.words{flex:0 1 auto;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-right:4px}'
              + 'button{all:unset;flex:none;font:600 11px/16px -apple-system,BlinkMacSystemFont,system-ui,sans-serif;'
              + 'padding:1px 7px;border-radius:5px;cursor:pointer}'
              + '.skip{color:rgba(255,255,255,.85)}.skip:hover{background:rgba(255,255,255,.18);color:#fff}'
              // No white fill: Kite's dark pages (Chromium's auto dark mode) would turn it black. A deeper orange stays.
              + '.pm{background:rgba(255,255,255,.22);color:#fff}.pm:hover{background:rgba(255,255,255,.32)}.pm[hidden]{display:none}'
              + 'button:focus-visible{outline:2px solid #fff;outline-offset:1px}'
              + '@media (prefers-reduced-motion:reduce){.ring{animation:none}}'
              + '</style><div class="ring"></div><div class="tag" role="group"><span class="words"></span>'
              + '<button class="pm" hidden></button>'
              + '<button class="skip" title="Leave this step undone: Claude hears you skipped it">Skip</button></div>';
            (document.documentElement || document.body).appendChild(host);
            K.host = host; K.ring = root.querySelector('.ring'); K.tag = root.querySelector('.tag');
            K.words = root.querySelector('.words');
            // Skip ends the step the tag shows now, undone. Only the user's own presses count, as with the control. There's
            // no Done: every step finishes by itself (see `mode`).
            const press = (how) => (e) => {
              e.preventDefault(); e.stopPropagation();
              if (!e.isTrusted || !K.step || K.done) return;
              K.done = how;
              try { window.kiteHandoffEvent(JSON.stringify({ step: K.step, how })); } catch (err) {}
            };
            root.querySelector('.skip').addEventListener('click', press('skip'));
            // The password manager's suggestion: Kite clicks the field so the manager's own menu opens there. It doesn't end
            // the step, and Kite never reads what the manager fills in.
            K.pm = root.querySelector('.pm');
            K.pm.addEventListener('click', (e) => {
              e.preventDefault(); e.stopPropagation();
              if (!e.isTrusted || !K.step || K.done) return;
              try { window.kiteHandoffEvent(JSON.stringify({ step: K.step, how: 'manager' })); } catch (err) {}
            });
            // A press on the tag isn't a press on the page: a menu or dialog that closes on a press outside it stays open.
            for (const name of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click', 'dblclick'])
              K.tag.addEventListener(name, (e) => e.stopPropagation());
            K.pulse = false;
          }
          // The ring pulses a few times for each new step, then holds still: an endless pulse repaints the page every
          // frame for as long as the step waits (hours, days), which kept the renderer and GPU busy.
          if (K.pulse && K.ring) {
            K.pulse = false;
            for (const a of K.ring.getAnimations ? K.ring.getAnimations() : []) { a.cancel(); a.play(); }
          }
          // Looks the control up again (it walks the page, so on a timer, never in a frame), and keeps the tag's words
          // and the ring's style in step with it.
          const look = () => {
            const now = Date.now();
            if (now - K.retry >= 100) {
              K.retry = now;
              watch();
              const el = find(K.cfg);
              if (el !== K.cand) { K.cand = el; K.candAt = now; }
            }
            // Move only once the page has stopped redrawing that part, so the ring doesn't land on a skeleton. A ringed
            // control the page replaced (or hid) gives way to its live successor at once.
            const lost = K.el && !(K.el.isConnected && shown(K.el));
            if (K.cand !== K.el && (now - K.candAt >= settle || (lost && K.cand))) K.el = K.cand;
            const el = K.el && K.el.isConnected && shown(K.el) ? K.el : null;
            const b = el ? blocked(el) : null;
            K.off = !!b;
            if (!K.done) {
              // Gone: a control the user saw ringed went away and nothing took its place (a form sent, a dialog closed).
              if (el) K.seen = K.seen || now;
              if (K.seen && !el && !K.cand) {
                if (!K.goneAt) { K.goneAt = now; soon(settle + 20); } else if (now - K.goneAt >= settle) finish('gone');
              } else K.goneAt = 0;
              // Words that weren't on the page when the step began, there now.
              if (K.cfg.appears) {
                const want = norm(K.cfg.appears);
                const there = docs().some((d) => d.body && norm(d.body.innerText).includes(want));
                if (K.appearsBefore === undefined) K.appearsBefore = there;
                else if (there && !K.appearsBefore) finish('appeared');
                else if (!there) K.appearsBefore = false;
              }
              // Focus in the ringed frame, in case its window's blur came before the ring did.
              frameFocus();
              // A field the user was in, filled and left, for a page that sent no focus events (one behind other windows).
              const f = mode() === 'value' ? field(el || K.el) : null;
              if (f && !f.matches('iframe')) {
                const a = f.ownerDocument.activeElement;
                if (a === f || f.contains(a)) K.fieldFocused = true;
                else if (K.fieldFocused && filled(f)) finish('value');
              }
            }
            // A turned-off control says so first: the tag's end is cut off on a narrow page.
            const text = (K.off ? 'Not clickable yet · ' : 'Claude needs you · ') + K.cfg.number + '. ' + K.cfg.label;
            // A new password's field: "Suggest password", which opens the password manager's own menu on it.
            const pm = !!(el && K.cfg.manager && !K.off && newPassword(el));
            if (K.pm && K.pm.hidden === pm) { K.pm.hidden = !pm; K.tagSize = null; }
            if (pm) {
              // What went wrong last time, on the button itself, where the user's eyes are (the step's words may be cut off).
              const label = K.note || 'Suggest password', title = K.cfg.managerReady
                ? 'Have ' + K.cfg.manager + ' suggest a strong password here. Kite never sees it.'
                : K.cfg.manager + ' isn\'t added to Kite for this space yet (⇧⌘X adds it).';
              if (K.pm.textContent !== label) { K.pm.textContent = label; K.tagSize = null; }
              if (K.pm.title !== title) K.pm.title = title;
            }

            if (K.words && K.words.textContent !== text) { K.words.textContent = text; K.tagSize = null; }
            // Why Claude stopped, when the pointer rests on the tag.
            const why = K.cfg.why ? 'Claude: ' + K.cfg.why : text;
            if (K.tag && K.tag.title !== why) K.tag.title = why;
            if (K.ring) { K.ring.classList.toggle('off', K.off); K.tag.classList.toggle('off', K.off); }
            return el;
          };
          // The next look: soon while a control settles, backing off to 1s while it's missing and the page is still,
          // every 2s once found (for changes the observer can't see). A page change brings it forward (watch).
          const tick = () => {
            K.timer = 0;
            // A hidden page needs no looks; Kite's own look starts them again when it's back on screen.
            if (!K.cfg || document.hidden) return;
            const el = look();
            // Frames again only if the box moved (or the control came or went, or the tag changed its words).
            if (placedAt(el) !== K.placedAt || (el && !K.tagSize)) follow();
            K.idle = el || K.cand !== K.el ? 0 : Math.min(1000, Math.max(150, (K.idle || 75) * 2));
            soon(K.cand !== K.el ? settle / 2 : el ? 2000 : K.idle);
          };
          // Where the ring goes for el (its box, or nothing), to tell whether it moved.
          function placedAt(el) {
            const r = el && el.isConnected && shown(el) ? box(el) : null;
            return r ? r.left + ',' + r.top + ',' + r.width + ',' + r.height : '';
          }
          // On the next frame, follow again if the box moved since the ring last held still (once per frame at most).
          function checkMoved() {
            if (K.raf || K.checkRaf || !K.cfg || !K.host) return;
            K.checkRaf = requestAnimationFrame(() => {
              K.checkRaf = 0;
              if (K.cfg && placedAt(K.el) !== K.placedAt) follow();
            });
          }
          // Follow the control's box again, frame by frame, until it holds still (a scroll, a resize, a look).
          function follow() {
            K.still = 0;
            if (K.cfg && K.host && !K.raf) K.raf = requestAnimationFrame(place);
          }
          function soon(ms) {
            if (!K.cfg) return;
            const at = Date.now() + ms;
            if (K.timer && K.timerAt <= at) return;
            if (K.timer) clearTimeout(K.timer);
            K.timerAt = at;
            K.timer = setTimeout(tick, ms);
          }
          // Every frame while the control's box moves: it follows the box, and stops asking for frames once the box has
          // held still for half a second (a page with nothing moving then draws nothing). Scrolls, resizes and the
          // looks start it again (follow).
          const place = () => {
            K.raf = 0;
            if (!K.cfg || !K.host) return;
            const el = K.el && K.el.isConnected && shown(K.el) ? K.el : null;
            // The first look scrolls the control into view, its frame's too when it's below the frame's fold.
            if (el && K.wantScroll && !K.scrolled) {
              K.scrolled = true;
              const all = box(el, false), seen = box(el);
              if (!seen || all.top < 0 || all.bottom > innerHeight || all.left < 0 || all.right > innerWidth) {
                el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'smooth' });
              }
            }
            const r = el ? box(el) : null;
            if (el && r) {
              const pad = 4;
              Object.assign(K.ring.style, { display: 'block', left: (r.left - pad) + 'px', top: (r.top - pad) + 'px',
                width: (r.width + pad * 2) + 'px', height: (r.height + pad * 2) + 'px' });
              K.tag.style.display = 'flex';
              // Measured once per wording, not every frame.
              if (!K.tagSize) K.tagSize = { w: K.tag.offsetWidth || 200, h: K.tag.offsetHeight || 24 };
              const th = K.tagSize.h, tw = K.tagSize.w, gap = 8;
              // Beside the control on its own line when there's room (so it hides nothing the user reads),
              // then above, then below.
              let left, top;
              const middle = r.top + r.height / 2 - th / 2;
              if (r.right + pad + gap + tw <= innerWidth - 4) {
                left = r.right + pad + gap; top = middle;
              } else if (r.left - pad - gap - tw >= 4) {
                left = r.left - pad - gap - tw; top = middle;
              } else {
                const above = r.top - pad - th - 6;
                top = above >= 4 ? above : r.bottom + pad + 6;
                left = r.left - pad;
              }
              left = Math.max(4, Math.min(innerWidth - tw - 4, left));
              top = Math.max(4, Math.min(innerHeight - th - 4, top));
              Object.assign(K.tag.style, { left: left + 'px', top: top + 'px' });
            } else {
              K.ring.style.display = 'none'; K.tag.style.display = 'none';
            }
            const at = r ? r.left + ',' + r.top + ',' + r.width + ',' + r.height : '';
            K.still = at === K.placedAt ? (K.still || 0) + 1 : 0;
            K.placedAt = at;
            K.raf = K.still < 30 ? requestAnimationFrame(place) : 0;
          };
          // Kite's own looks (on tab switches and loads, and twice a second while a fresh step's page is shown) keep things
          // going in a page that gets no frames or timers. A control still settling counts as found.
          const el = look() || (K.cand && K.cand.isConnected ? K.cand : null);
          K.still = 0;
          if (!K.raf) place();
          soon(K.cand !== K.el ? settle / 2 : 150);
          return state(el);
        }
        """#
}
