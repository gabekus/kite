import AppKit
import KiteCore

// Page dialogs reach Claude. Every JavaScript dialog (alert, confirm, prompt, "Leave site?") on a tab Claude works in is
// kept, open or answered (`DialogLog`), and Claude hears of each once: a waiting handoff_status wakes for one on its
// tabs, the next tool result carries any other, and `dialogs` lists them. When one comes up on a step's page, Claude has
// the next move: the step's tag says Claude is looking at it and the tab shows working, until Claude waits on the user
// again (Gabe, 5 Nov 2026: a checkout's alert after his step left him stuck, and the agent never heard).

extension AutomationController {
    /// The engine showed a dialog on `tab`'s page, or took it down. Kept for the tabs Claude works in: ones it opened,
    /// touched or drives, and ones it handed the user a step on. Nothing is kept while Claude's control is off.
    func pageDialog(_ tab: UUID, _ event: PageDialogEvent) {
        guard isEnabled else { return }
        switch event {
        case let .opened(kind, message, origin):
            let step = dialogStep(on: tab)
            guard step != nil || touchedTabs[tab] != nil || controlledTabIDs.contains(tab) || claudeOpened.contains(tab)
                || activities[tab] != nil, !isRevoked(tab) else { return }
            let owner = step.flatMap { handoffConnections[$0.handoff] } ?? connection(lastActingOn: tab)
            dialogLog.opened(tab: tab, kind: kind, message: message, origin: origin.flatMap(Self.origin), step: step,
                             connection: owner)
        case let .closed(accepted, by):
            guard dialogLog.open(on: tab) != nil else { return }
            dialogLog.closed(tab: tab, accepted: accepted, by: by)
        }
    }

    /// "https://shop.example": where a dialog came from, without its path and query.
    private static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host() else { return nil }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    /// The handoff step a dialog on `tab` came up on: the step waiting there; else the step the user just ended there
    /// with a click on its control (the click that sent a form, say); else the last step there the user did (not one
    /// skipped or withdrawn) of a handoff made in the last hour. Nil when no step was on the tab.
    func dialogStep(on tab: UUID, now: Date = Date()) -> DialogLog.Step? {
        func ref(_ step: Handoff.Step, waiting: Bool) -> DialogLog.Step {
            DialogLog.Step(handoff: String(step.id.prefix { $0 != "." }), id: step.id, number: step.number,
                           instruction: step.instruction, waiting: waiting)
        }
        if let step = waitingStep(on: tab) { return ref(step, waiting: true) }
        if let click = handoffClicks[tab], now.timeIntervalSince(click.at) < 600,
           let step = handoffs.lazy.flatMap(\.steps).first(where: { $0.id == click.step }) {
            return ref(step, waiting: false)
        }
        for handoff in handoffs.reversed() where now.timeIntervalSince(handoff.created) < 3600 {
            if let step = handoff.steps.last(where: { $0.tab == tab && $0.state == .done }) { return ref(step, waiting: false) }
        }
        return nil
    }

    /// Dialogs `connection` hasn't heard about yet, for its next tool result. Nil when there are none.
    func dialogNews(for connection: Int) -> String? {
        let entries = dialogLog.news(for: connection)
        guard !entries.isEmpty else { return nil }
        return tellDialogs(entries, connection: connection)
    }

    /// Claude hears of these dialogs now: each is marked told, and one on a step's page hands the next move to Claude.
    func tellDialogs(_ entries: [DialogLog.Entry], connection: Int) -> String {
        dialogLog.markTold(entries.map(\.id))
        for entry in entries { dialogInterruptedStep(entry, connection: connection) }
        let state = store.state
        return entries.map { "Kite: " + DialogLog.describe($0, title: state.tab($0.tab)?.displayTitle) }.joined(separator: "\n\n")
    }

    /// A dialog came up on a step's page and Claude has heard of it: the user isn't left stuck behind it. The step
    /// waiting on that tab keeps its ring, Skip and Done, and its tag says Claude saw the dialog and is looking at it;
    /// the tab shows working, not needs you. That lasts until Claude waits on the user again (handoff_status with a
    /// wait, or a new handoff on the tab), or the step ends.
    private func dialogInterruptedStep(_ entry: DialogLog.Entry, connection: Int) {
        guard entry.step != nil, store.state.tab(entry.tab) != nil, !isRevoked(entry.tab) else { return }
        if let waiting = waitingStep(on: entry.tab) {
            dialogAsides[waiting.id] = DialogLog.stepAside(entry.kind)
            pollHandoffsSoon()
        }
        setTabStatus(entry.tab, .working, note: DialogLog.tabNote(entry.kind), connection: connection)
    }

    /// The step a tab shows that waits on the user (`waitingStep`), unless a page's dialog interrupted it and Claude
    /// is looking at that (`dialogAsides`): then the tab shows Claude at work. The tab state's one hook for dialogs.
    func stepNeedingUser(on tab: UUID) -> Handoff.Step? {
        guard let step = waitingStep(on: tab), dialogAsides[step.id] == nil else { return nil }
        return step
    }

    /// Claude is waiting on the user again (or handed over new steps on these tabs): their steps need the user again.
    func endDialogAsides(handoff id: String? = nil, tabs: Set<UUID> = []) {
        guard !dialogAsides.isEmpty else { return }
        let waiting = Set(handoffs.flatMap(\.waiting).map(\.id))
        let steps = handoffs.flatMap(\.steps)
        let ended = dialogAsides.keys.filter { stepID in
            guard waiting.contains(stepID) else { return true }
            if let id, stepID.hasPrefix(id + ".") { return true }
            return steps.first { $0.id == stepID }?.tab.map(tabs.contains) ?? false
        }
        guard !ended.isEmpty else { return }
        for stepID in ended { dialogAsides[stepID] = nil }
        pollHandoffsSoon()
    }

    /// The `dialogs` tool: a tab's dialogs (every tab's, without one), oldest first. Claude has heard of them all now.
    func dialogsReport(_ string: String?, connection: Int) throws -> ToolOutput {
        let tab = try string.map { try resolveTab($0).id }
        let entries = tab.map { dialogLog.entries(on: $0) } ?? dialogLog.entries
        let fresh = entries.filter { !$0.told }
        if !fresh.isEmpty { _ = tellDialogs(fresh, connection: connection) }
        let state = store.state
        let shown = tab.map { dialogLog.entries(on: $0) } ?? dialogLog.entries
        return .text(DialogLog.report(shown, tab: tab) { state.tab($0)?.displayTitle })
    }
}
