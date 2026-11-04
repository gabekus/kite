import AppKit
import KiteCore

// handoff: Claude hands the user steps it can't do, and Kite shows each one where it happens: a ring on the
// control in the page, a mark on the tab in the sidebar, and a card with why Claude stopped. See `UserHandoff`.

extension AutomationController {
    func handOff(_ request: UserHandoff.Request, connection: Int) async throws -> ToolOutput {
        guard host?.window != nil else { throw AutomationError(.failed, "Kite has no window open.") }
        handoffCount += 1
        let id = "h\(handoffCount)"
        var steps: [Handoff.Step] = []
        for (index, spec) in request.steps.enumerated() {
            var step = Handoff.Step(id: "\(id).\(index + 1)", number: index + 1, instruction: spec.instruction, why: spec.why,
                                    command: spec.command)
            if spec.command == nil, spec.tab != nil || request.tab != nil || spec.target != nil {
                let tab = try resolveTab(spec.tab ?? request.tab)
                step.tab = tab.id
                step.locator = try await locator(for: spec.target, step: step.id, tab: tab)
            }
            steps.append(step)
        }
        let handoff = Handoff(id: id, reason: request.reason, session: sessionFolders[connection], steps: steps)
        handoffs = Handoff.pruned(handoffs + [handoff])
        saveHandoffs()
        handoffCardCollapsed = false
        handback = nil
        // The tab in front may be one of them: show its step at once rather than on the next look.
        pollHandoffsSoon()
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        await lookAtSteps(id, attempts: UserHandoff.probeAttempts)
        // A step Claude handed over blocked is news now, not after the wait. One that turns off later, during the
        // wait, may only be the page checking what the user just did: it waits out the usual delay.
        let blocked = handoffs.first { $0.id == id }.map { !$0.blockedSteps.isEmpty } ?? false
        return try await handoffReport(id, wait: blocked ? 0 : request.wait, reportBlockedAfter: UserHandoff.blockedReportDelay)
    }

    func handoffStatus(_ id: String?, wait: Double, cancel: Bool, connection: Int) async throws -> ToolOutput {
        let mine = sessionFolders[connection]
        guard let handoff = id.flatMap({ id in handoffs.last { $0.id == id.lowercased() } })
            ?? handoffs.last(where: { mine != nil && $0.session == mine }) ?? handoffs.last else {
            throw AutomationError(.notFound, id.map { "There's no handoff \($0) (Kite keeps them for a week)." }
                ?? "There's no handoff. Call handoff first.")
        }
        if cancel {
            update(handoff.id, byUser: false) { $0.finishAll(.skipped, how: "Claude withdrew it") }
            pollHandoffsSoon()
        } else {
            // A fresh look first, so a step Claude just unblocked (or the page did) isn't reported from an old one.
            await lookAtSteps(handoff.id, attempts: 1)
        }
        return try await handoffReport(handoff.id, wait: cancel ? 0 : wait, reportBlockedAfter: UserHandoff.blockedReportDelay)
    }

    /// Waits up to `wait` seconds for the user to end every step, then reports. A step that has been blocked for
    /// `reportBlockedAfter` ends the wait early (once per step), so Claude can fix what's in the way instead of
    /// waiting on a user who can't go on; so does a click that opens a new tab, for Claude to carry on there.
    private func handoffReport(_ id: String, wait: Double, reportBlockedAfter delay: TimeInterval) async throws -> ToolOutput {
        let deadline = Date().addingTimeInterval(wait)
        var watch = HandoffBlockWatch(reported: reportedBlockedSteps)
        let openedBefore = handoffs.first { $0.id == id }?.opened.count ?? 0
        if wait > 0 { handoffWaiters[id, default: 0] += 1 }
        defer { if wait > 0 { handoffWaiters[id, default: 1] -= 1 } }
        while Date() < deadline, let handoff = handoffs.first(where: { $0.id == id }), !handoff.isFinished,
              handoff.opened.count == openedBefore, !watch.shouldReport(handoff, delay: delay) {
            try await Task.sleep(for: .milliseconds(250))
        }
        // A click that just ended a step may also be opening a tab: give it a moment to arrive, so the report has it.
        if wait > 0, let click = handoffClicks.values.filter({ handoffID(of: $0.step) == id }).map(\.at).max() {
            let left = UserHandoff.clickSettle - Date().timeIntervalSince(click)
            if left > 0 { try await Task.sleep(for: .seconds(left)) }
        }
        guard let handoff = handoffs.first(where: { $0.id == id }) else { throw AutomationError(.notFound, "Handoff \(id) is gone.") }
        reportedBlockedSteps.formUnion(handoff.blockedSteps.map(\.id))
        // Claude is back: the card no longer needs to ask the user to tell it.
        if handback?.handoff == id, handback?.claudeWaiting == false { handback = nil }
        var text = handoff.report(waitedOut: wait > 0 && !handoff.isFinished) { [store] tab in
            store.state.tab(tab).map { (url: $0.url?.absoluteString, title: $0.displayTitle) }
        }
        // What the user's steps opened (a popup from a button they pressed), so Claude carries on there.
        for tab in Set(handoff.steps.compactMap(\.tab)) {
            if let opened = openedReport(by: tab, since: handoff.created) { text += "\n\n" + opened }
        }
        return .text(text)
    }

    /// How the ring finds a step's control. A ref is marked on the page now, while it's fresh; its label finds it
    /// again if the page redraws it.
    private func locator(for target: UserHandoff.Target?, step: String, tab: BrowserTab) async throws -> Handoff.Step.Locator? {
        switch target {
        case nil: return nil
        case .selector(let selector)?: return .selector(selector)
        case .text(let text)?: return .text(text)
        case .ref(let ref)?:
            guard let host, let actions = host.automationPage(for: tab).automation as? PageActions else {
                throw AutomationError(.unsupported, "This tab's engine can't point at a control: pass text instead of ref.")
            }
            let found = try await actions.mark(ref: ref, attribute: UserHandoff.markerAttribute, value: step)
            return .marker(step, label: found.label, path: found.path)
        }
    }

    /// A look at the controls of a handoff's steps now, so Claude hears what's in the way from what the pages show
    /// now: right after handing them over (`attempts` looks half a second apart while a page is still drawing a
    /// control) and before each handoff_status. Pages on screen get the poller's own look; a live page in the
    /// background gets a look that draws nothing. Only the step a tab shows is looked at.
    private func lookAtSteps(_ id: String, attempts: Int) async {
        guard let host else { return }
        for attempt in 0..<attempts {
            // A look already under way may have started before what Claude just did: let it finish, then look.
            while handoffPolling, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
            await pollHandoffs()
            guard let handoff = handoffs.first(where: { $0.id == id }) else { return }
            var missing = false
            for step in handoff.waiting where step.locator != nil {
                guard let tab = step.tab, waitingStep(on: tab)?.id == step.id, let page = host.livePages[tab] else { continue }
                if !isOnScreen(page), let actions = page.automation as? PageActions {
                    let script = UserHandoff.ringScript(.init(step: step, scroll: false, probe: true))
                    let at = store.state.tab(tab)?.url
                    guard let json = try? await actions.runIsolated(script, world: UserHandoff.worldName, binding: UserHandoff.bindingName),
                          let state = UserHandoff.RingState(json: json) else { continue }
                    setLook(step.id, state, tab: tab, at: at)
                }
                if handoffs.first(where: { $0.id == id })?.steps.first(where: { $0.id == step.id })?.found == false { missing = true }
            }
            guard missing, attempt < attempts - 1 else { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func isOnScreen(_ page: WebPage) -> Bool {
        page.view.window != nil && !page.view.isHiddenOrHasHiddenAncestor
    }

    /// What a look at a step's control saw. Where the control is found becomes the step's page (so a step that
    /// happens after a redirect, or on the page an earlier step leads to, gets that page). A control missing for a
    /// while, on a tab at another address than its page, means the tab has left it. `at` is the tab's address when
    /// the look began: a look a navigation overtook teaches nothing about where the control is.
    private func setLook(_ stepID: String, _ state: UserHandoff.RingState, tab: UUID, at: URL?) {
        let current = store.state.tab(tab)?.url
        let now = Date()
        if state.found { controlMissingSince[stepID] = nil } else if controlMissingSince[stepID] == nil { controlMissingSince[stepID] = now }
        let missing = controlMissingSince[stepID].map { now.timeIntervalSince($0) >= UserHandoff.offPageDelay } ?? false
        // Missing, but not for long enough yet to tell: make sure a second look comes.
        if !state.found, !missing { scheduleHandoffFollowUp() }
        update(handoffID(of: stepID)) { h in
            guard let i = h.steps.firstIndex(where: { $0.id == stepID }), h.steps[i].isWaiting else { return }
            if state.found, let current, current == at, Handoff.canReturn(to: current), h.steps[i].url != current.absoluteString {
                h.steps[i].url = current.absoluteString
            }
            let off = missing && Handoff.isOffPage(stepURL: h.steps[i].url, current: current)
            let blocker = state.blocker ?? (off ? .offPage : nil)
            if h.steps[i].found != state.found { h.steps[i].found = state.found }
            if h.steps[i].blocker != blocker { h.steps[i].blocker = blocker }
        }
    }

    /// Changes a handoff. `byUser` false is Claude's doing: the user ending the last step hands back to Claude, Claude
    /// withdrawing it doesn't.
    private func update(_ id: String, byUser: Bool = true, _ change: (inout Handoff) -> Void) {
        guard let index = handoffs.firstIndex(where: { $0.id == id }) else { return }
        let before = handoffs[index]
        change(&handoffs[index])
        if byUser, !before.isFinished, handoffs[index].isFinished { handBack(id, .finished) }
        // Saved: what the user or Claude did, and the steps' pages and tabs; not what the ring found.
        if handoffs[index].steps.map({ [$0.state.rawValue, $0.url, $0.tab?.uuidString] }) != before.steps.map({ [$0.state.rawValue, $0.url, $0.tab?.uuidString] }) {
            saveHandoffs()
        }
        if handoffs[index].isFinished, let focused = focusedHandoffStep, focused.hasPrefix(id + ".") { focusedHandoffStep = nil }
    }

    private func handoffID(of step: String) -> String { String(step.prefix { $0 != "." }) }

    // MARK: Across launches

    func saveHandoffs() {
        do {
            try Handoff.save(handoffs, to: Handoff.fileURL(supportDirectory: supportDirectory))
        } catch {
            NSLog("Kite: couldn't save Claude's handoffs: \(error)")
        }
    }

    // MARK: What the card and the sidebar ask

    /// Every step still waiting on the user, newest handoff first (the order tabs show them in: waitingStep).
    var waitingHandoffSteps: [(handoff: Handoff, step: Handoff.Step)] {
        handoffs.reversed().flatMap { handoff in handoff.waiting.map { (handoff, $0) } }
    }

    /// The step the card shows: the tab in front's (the first one waiting on it), or the one brought up with Next.
    func cardStep(front: UUID?) -> (handoff: Handoff, step: Handoff.Step)? {
        let waiting = waitingHandoffSteps
        // A step brought up with Next stays up over the front tab's own until another tab comes forward.
        let focused = focusedHandoffStep.flatMap { id in waiting.first { $0.step.id == id } }
        if let focused, focusedHandoffFront == front { return focused }
        // The front tab's step is the one its ring shows (waitingStep: the newest handoff's).
        if let front, let step = waitingStep(on: front), let found = waiting.first(where: { $0.step.id == step.id }) { return found }
        return focused
    }

    /// The step a tab shows: the newest handoff's first waiting one there (Claude's latest word for that page, such as
    /// the step that turns on an older step's control).
    func waitingStep(on tab: UUID) -> Handoff.Step? {
        for handoff in handoffs.reversed() { if let step = handoff.current(on: tab) { return step } }
        return nil
    }

    /// Tabs with a step waiting on them, for the sidebar's folders.
    var handoffTabs: Set<UUID> { Set(waitingHandoffSteps.compactMap(\.step.tab)) }

    /// The card's Done and Skip.
    func answerHandoff(_ stepID: String, _ state: Handoff.Step.State) {
        update(handoffID(of: stepID)) { $0.finish(stepID, state, how: state == .done ? "the user pressed Done" : "the user skipped it") }
        if focusedHandoffStep == stepID { focusedHandoffStep = nil }
        pollHandoffsSoon()
        // On to the next step of the same tab (the ring moves there), or the next one anywhere.
        let front = store.state.selectedTab?.id
        if cardStep(front: front) == nil, !waitingHandoffSteps.isEmpty { showNextHandoffStep(after: stepID) }
    }

    /// Back on the card: the step before this one comes up again, waiting on the user even if it was done or skipped
    /// (Claude hears so from handoff_status), on its own tab when it has one.
    func showPreviousHandoffStep(before stepID: String) {
        let id = handoffID(of: stepID)
        guard let previous = handoffs.first(where: { $0.id == id })?.previous(before: stepID) else { return }
        update(id) { $0.reopen(previous.id) }
        handoffCardCollapsed = false
        if let tab = previous.tab, store.state.tab(tab) != nil, tab != store.state.selectedTab?.id {
            store.mutateWithoutUndo { $0.select(tab: tab) }
        }
        // Held up over the tab's own step: one left waiting before it (passed with Next) would come up instead.
        focusedHandoffStep = previous.id
        focusedHandoffFront = store.state.selectedTab?.id
        pollHandoffsSoon()
    }

    /// The card says the user handed back to Claude: for a few seconds while Claude waits on the handoff and takes
    /// over, or until closed when it doesn't (Claude can't be woken: the user tells it in the chat).
    private func handBack(_ id: String, _ kind: HandoffHandback.Kind) {
        let note = HandoffHandback(handoff: id, kind: kind, claudeWaiting: (handoffWaiters[id] ?? 0) > 0)
        handback = note
        handoffCardCollapsed = false
        guard note.claudeWaiting else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + HandoffHandback.shownFor) { [weak self] in
            MainActor.assumeIsolated { if self?.handback == note { self?.handback = nil } }
        }
    }

    /// The handback's close button.
    func closeHandback() { handback = nil }

    /// A step on `tab` ended with a click on its control: a tab that page opens (or just opened) is the click's doing.
    private func stepClicked(_ stepID: String, on tab: UUID) {
        let now = Date()
        handoffClicks[tab] = (stepID, now)
        if let open = handoffOpens[tab], now.timeIntervalSince(open.at) < UserHandoff.openedTabWindow { stepOpened(open.tab, by: stepID) }
    }

    /// The page in `opener` opened `tab` (a link to a new tab, or a popup: `tabOpened`). Right after a click on a step's
    /// control, it's where the user went next: a wait ends for it, and the card hands back to Claude.
    func handoffTabOpened(_ tab: UUID, by opener: UUID) {
        let now = Date()
        handoffOpens[opener] = (tab, now)
        if let click = handoffClicks[opener], now.timeIntervalSince(click.at) < UserHandoff.openedTabWindow {
            stepOpened(tab, by: click.step)
        }
    }

    private func stepOpened(_ tab: UUID, by stepID: String) {
        let id = handoffID(of: stepID)
        guard let number = handoffs.first(where: { $0.id == id })?.steps.first(where: { $0.id == stepID })?.number,
              handoffs.first(where: { $0.id == id })?.opened.contains(where: { $0.tab == tab }) == false else { return }
        update(id) { $0.opened.append(.init(step: number, tab: tab)) }
        handBack(id, .openedTab(tab))
    }

    /// Dismiss on the card's menu: the user won't do the rest.
    func dismissHandoff(_ id: String) {
        update(id) { $0.finishAll(.skipped, how: "the user dismissed the handoff") }
        pollHandoffsSoon()
    }

    /// Next on the card, and the pill: brings up the next waiting step, switching to its tab when it has one.
    func showNextHandoffStep(after current: String? = nil) {
        let waiting = waitingHandoffSteps
        guard !waiting.isEmpty else { return }
        let start = current.flatMap { id in waiting.firstIndex { $0.step.id == id } }.map { $0 + 1 } ?? 0
        // After the current one, then wrapping round; a step on the same tab as the current one comes up by itself.
        let currentTab = current.flatMap { id in handoffs.lazy.flatMap(\.steps).first { $0.id == id }?.tab }
        let order = Array(waiting[min(start, waiting.count)...]) + Array(waiting[..<min(start, waiting.count)])
        guard let next = order.first(where: { currentTab == nil || $0.step.tab != currentTab }) ?? order.first else { return }
        handoffCardCollapsed = false
        if let tab = next.step.tab, store.state.tab(tab) != nil {
            focusedHandoffStep = nil
            store.mutateWithoutUndo { $0.select(tab: tab) }
            pollHandoffsSoon()
        } else {
            focusedHandoffStep = next.step.id
            focusedHandoffFront = store.state.selectedTab?.id
        }
    }

    /// The step's tab was closed (and isn't back).
    func stepTabIsClosed(_ step: Handoff.Step) -> Bool {
        step.tab.map { !store.state.allTabIDs.contains($0) } ?? false
    }

    /// Reopen Tab can bring the tab back, or at least open the step's page.
    func canReopenStepTab(_ step: Handoff.Step) -> Bool {
        guard let id = step.tab else { return false }
        return store.state.recentlyClosed.contains { $0.tab.id == id } || step.url.flatMap(URL.init(string:)).map(Handoff.canReturn) == true
    }

    /// Take Me Back on the card, for the tab in front: loads the step's page in it again.
    func returnToStepPage(_ stepID: String) {
        guard let host, let step = waitingHandoffSteps.first(where: { $0.step.id == stepID })?.step,
              let id = step.tab, id == store.state.selectedTab?.id, let tab = store.state.tab(id),
              let url = step.url.flatMap(URL.init(string:)), Handoff.canReturn(to: url) else { return }
        controlMissingSince[stepID] = nil
        host.automationPage(for: tab).load(url)
        pollHandoffsSoon()
    }

    /// Reopen Tab on the card, for a step whose tab was closed: the tab itself comes back where it was (its space,
    /// place and history), as Undo Close does. Pushed out of the recently closed, a new tab opens at the step's page,
    /// and this handoff's steps on the old tab move to it.
    func reopenStepTab(_ stepID: String) {
        guard let step = waitingHandoffSteps.first(where: { $0.step.id == stepID })?.step, let id = step.tab,
              stepTabIsClosed(step) else { return }
        if store.mutateWithoutUndo({ $0.reopenClosed(tab: id) }) == nil {
            guard let url = step.url.flatMap(URL.init(string:)), Handoff.canReturn(to: url) else { return }
            let opened = store.mutateWithoutUndo { $0.openTab(url: url) }
            update(handoffID(of: stepID)) { h in
                for i in h.steps.indices where h.steps[i].isWaiting && h.steps[i].tab == id {
                    h.steps[i].tab = opened
                    h.steps[i].blocker = nil
                    h.steps[i].found = nil
                }
            }
        }
        focusedHandoffStep = nil
        pollHandoffsSoon()
    }

    /// Show Tab on the card, for a step whose tab isn't in front.
    func showTab(of stepID: String) {
        guard let tab = waitingHandoffSteps.first(where: { $0.step.id == stepID })?.step.tab, store.state.tab(tab) != nil else { return }
        store.mutateWithoutUndo { $0.select(tab: tab) }
        pollHandoffsSoon()
    }

    // MARK: Watching the pages

    /// Kite looks at the pages when something the user sees could have changed: a tab comes forward or closes, a
    /// page finishes loading, a window becomes key or visible, Kite comes to the front, or the ring hears a click.
    /// It puts the ring up for the step a page shows, follows it through reloads, and notes what's in the way.
    /// Between those, it looks twice a second only while a step's page is on screen in a visible window (to follow
    /// a page that redraws without loading, and hear a click the binding missed), and only for handoffs under
    /// `UserHandoff.watchLimit` old: older steps keep their card, sidebar dot and ring, but wait for one of those
    /// events. An idle Kite with steps left waiting doesn't wake for them.
    func watchHandoffEvents() {
        guard handoffObservers.isEmpty else { return }
        let center = NotificationCenter.default
        // Browser windows only: popovers, tooltips and panels come and go without changing what a page shows.
        let windowNames = [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification,
                           NSWindow.didDeminiaturizeNotification, .kitePagesShown]
        handoffObservers = windowNames.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard (note.object as? NSWindow)?.windowController is BrowserWindowController else { return }
                    self?.handoffEvent()
                }
            }
        }
        handoffObservers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.handoffEvent() }
        })
        // A reload (or a slept tab waking) took the ring with the old page, in whichever window: put it back now.
        handoffObservers.append(center.addObserver(forName: .kitePageFinishedLoading, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let tab = note.userInfo?["tab"] as? UUID, self.waitingStep(on: tab) != nil else { return }
                self.pollHandoffsSoon()
            }
        })
        watchHandoffTabs()
    }

    func stopWatchingHandoffEvents() {
        handoffObservers.forEach(NotificationCenter.default.removeObserver)
        handoffObservers = []
        handoffPoller?.cancel()
        handoffFollowUp?.cancel()
    }

    /// A page of a step's tab moved within the document (a single-page app's route): look again.
    func handoffPageNavigated(_ tab: UUID) {
        if waitingStep(on: tab) != nil { pollHandoffsSoon() }
    }

    /// One more look once `UserHandoff.offPageDelay` has passed, after a look found a waiting step's control missing:
    /// it takes two looks that far apart to call the page left (`setLook`), and an old step, or a page on screen in a
    /// covered window, gets no twice-a-second looks to make the second.
    func scheduleHandoffFollowUp() {
        guard handoffFollowUp == nil else { return }
        handoffFollowUp = Task { [weak self] in
            try? await Task.sleep(for: .seconds(UserHandoff.offPageDelay + 0.1))
            guard let self, !Task.isCancelled else { return }
            self.handoffFollowUp = nil
            await self.pollHandoffs()
        }
    }

    /// The tab in front, and which steps' tabs are open: a switch or a close changes what the ring and card show.
    private func watchHandoffTabs() {
        let key = withObservationTracking { handoffTabsKey } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.watchHandoffTabs() } }
        }
        if key != lastHandoffTabsKey {
            lastHandoffTabsKey = key
            handoffEvent()
        }
    }

    /// The front tab, and each open step tab with its address (a step's page can change without a load finishing).
    /// Linked windows' own front tabs come through `kitePagesShown`.
    private var handoffTabsKey: [String] {
        guard !handoffs.allSatisfy(\.isFinished) else { return [] }
        let state = store.state
        let live = state.allTabIDs
        let tabs = handoffTabs.filter(live.contains).sorted { $0.uuidString < $1.uuidString }
        return [state.selectedTab?.id.uuidString ?? ""] + tabs.map { "\($0.uuidString) \(state.tab($0)?.url?.absoluteString ?? "")" }
    }

    private func handoffEvent() {
        guard !handoffs.allSatisfy(\.isFinished) || !ringShown.isEmpty else { return }
        pollHandoffsSoon()
    }

    /// A look now, for a change the user made (a tab switch, Done), then the twice-a-second looks if a step's page
    /// is on screen.
    func pollHandoffsSoon() {
        Task { [weak self] in
            await self?.pollHandoffs()
            self?.startHandoffPoller()
        }
    }

    private func startHandoffPoller() {
        guard handoffPoller == nil, needsHandoffPolling else { return }
        handoffPoller = Task { [weak self] in
            while let self, !Task.isCancelled, self.needsHandoffPolling {
                try? await Task.sleep(for: .seconds(UserHandoff.pollInterval))
                await self.pollHandoffs()
            }
            self?.handoffPoller = nil
        }
    }

    /// Whether a step under `UserHandoff.watchLimit` old has its page on screen in a visible window.
    var needsHandoffPolling: Bool {
        guard let host else { return false }
        let pages = host.livePages
        return Handoff.needsPolling(handoffs) { tab in pages[tab].map(isShown) ?? false }
    }

    /// On screen in a window the user can see: not covered, minimised or on another space.
    private func isShown(_ page: WebPage) -> Bool {
        guard isOnScreen(page), let window = page.view.window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    private func pollHandoffs() async {
        // One look at a time: two at once would both move the ring and race to report the same click.
        // (runIsolated keeps the page's world single.)
        guard !handoffPolling else { handoffPollAgain = true; return }
        handoffPolling = true
        defer { handoffPolling = false }
        repeat {
            handoffPollAgain = false
            await pollHandoffsOnce()
        } while handoffPollAgain
    }

    private func pollHandoffsOnce() async {
        guard let host else { return }
        let live = store.state.allTabIDs
        // A closed tab keeps its steps, for the card to offer the tab back; one that's back (Undo Close, the archive)
        // is open again.
        for handoff in handoffs where !handoff.isFinished {
            for step in handoff.waiting {
                guard let tab = step.tab else { continue }
                let closed = !live.contains(tab)
                guard closed != (step.blocker == .tabClosed) else { continue }
                update(handoff.id) { h in
                    if let i = h.steps.firstIndex(where: { $0.id == step.id }) { h.steps[i].found = nil; h.steps[i].blocker = closed ? .tabClosed : nil }
                }
            }
        }
        // Steps that ended, and pages off screen, start the missing-control clock afresh when next looked at.
        let watched = Set(handoffs.flatMap(\.waiting).compactMap { step in
            step.tab.flatMap { host.livePages[$0] }.map(isOnScreen) == true ? step.id : nil
        })
        controlMissingSince = controlMissingSince.filter { watched.contains($0.key) }
        // What a page that isn't live any more (Kite slept it) showed is old news: forget it until Kite can look again.
        for handoff in handoffs where !handoff.isFinished {
            for step in handoff.waiting where step.tab.map({ live.contains($0) && host.livePages[$0] == nil }) == true
                && (step.found != nil || step.blocker != nil) {
                update(handoff.id) { h in
                    if let i = h.steps.firstIndex(where: { $0.id == step.id }) { h.steps[i].found = nil; h.steps[i].blocker = nil }
                }
            }
        }
        for (id, page) in host.livePages {
            let onScreen = isOnScreen(page)
            let step = waitingStep(on: id)
            // A page off screen keeps its ring for when it's back; one whose steps ended loses it.
            guard (step != nil && onScreen) || (step == nil && ringShown[id] != nil),
                  let actions = page.automation as? PageActions else { continue }
            if let step {
                try? await track(id, page: page, actions: actions)
                let first = ringShown[id] != step.id
                let script = UserHandoff.ringScript(.init(step: step, scroll: first))
                let at = store.state.tab(id)?.url
                guard let json = try? await actions.runIsolated(script, world: UserHandoff.worldName, binding: UserHandoff.bindingName),
                      let state = UserHandoff.RingState(json: json) else { continue }
                ringShown[id] = step.id
                let handoff = handoffID(of: step.id)
                if let done = state.done {
                    update(handoff) { $0.finish(step.id, .done, how: UserHandoff.describe(done)) }
                    stepClicked(step.id, on: id)
                    // Again at once: the tab's next step gets the ring, or the ring goes.
                    handoffPollAgain = true
                } else {
                    setLook(step.id, state, tab: id, at: at)
                }
            } else {
                _ = try? await actions.runIsolated(UserHandoff.clearScript, world: UserHandoff.worldName, binding: UserHandoff.bindingName)
                ringShown[id] = nil
            }
        }
        // Pages that went away (hibernated or closed) took their ring along.
        for id in Array(ringShown.keys) where host.livePages[id] == nil { ringShown[id] = nil }
    }

    /// The ring's click listener, through the binding: ends the step at once, even if the click navigates away.
    func handoffBindingCalled(_ params: JSONValue, tab: UUID) {
        guard params["name"]?.stringValue == UserHandoff.bindingName,
              let payload = params["payload"]?.stringValue, let event = UserHandoff.RingEvent(json: payload),
              let step = waitingStep(on: tab), step.id == event.step else { return }
        update(handoffID(of: step.id)) { $0.finish(step.id, .done, how: UserHandoff.describe(event.how)) }
        stepClicked(step.id, on: tab)
        pollHandoffsSoon()
    }
}
