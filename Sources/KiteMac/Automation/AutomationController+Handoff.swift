import AppKit
import KiteCore

// handoff: Claude hands the user steps it can't do, and Kite shows each one where it happens: a ring on the
// control in the page with the step and Skip beside it, and a mark on the tab in the sidebar. Nothing else: there's
// no card over the page. Kite takes the user to the first step's tab when the handoff starts (`HandoffLead`), and
// never moves them after; every step finishes by itself (`UserHandoff.DoneWhen`). See `UserHandoff`.

extension AutomationController {
    func handOff(_ request: UserHandoff.Request, connection: Int) async throws -> ToolOutput {
        guard host?.window != nil else { throw AutomationError(.failed, "Kite has no window open.") }
        handoffCount += 1
        let id = "h\(handoffCount)"
        var steps: [Handoff.Step] = []
        for (index, spec) in request.steps.enumerated() {
            var step = Handoff.Step(id: "\(id).\(index + 1)", number: index + 1, instruction: spec.instruction, why: spec.why)
            step.doneWhen = spec.doneWhen
            step.appears = spec.appears
            let tab = try resolveTab(spec.tab ?? request.tab)
            step.tab = tab.id
            step.locator = try await locator(for: spec.target, step: step.id, tab: tab)
            steps.append(step)
        }
        let handoff = Handoff(id: id, reason: request.reason, session: sessionFolders[connection], steps: steps)
        handoffConnections[id] = connection
        handoffs = Handoff.pruned(handoffs + [handoff])
        saveHandoffs()
        // Take the user to the first step's tab (now, or once they stop typing in Kite): a step on a tab that isn't in
        // front shows them nothing.
        let lead = leadToStep(of: id)
        // The tab in front may be one of them: show its step at once rather than on the next look.
        pollHandoffsSoon()
        if !NSApp.isActive { WindowPresenter.requestAttention() }
        await lookAtSteps(id, attempts: UserHandoff.probeAttempts)
        // A step Claude handed over blocked, or that the page can't show (its control isn't there), is news now, not
        // after the wait. One that turns off or goes missing later, during the wait, may only be the page checking or
        // following what the user just did: it waits out the usual delay.
        let blocked = handoffs.first { $0.id == id }.map { !$0.blockedSteps.isEmpty } ?? false
        let note = lead.map { HandoffLead.note($0.step, title: store.state.tab($0.tab)?.displayTitle, led: $0.now) }
        return try await handoffReport(id, wait: blocked ? 0 : request.wait, reportBlockedAfter: UserHandoff.blockedReportDelay,
                                       note: note)
    }

    func handoffStatus(_ id: String?, wait: Double, cancel: Bool, connection: Int) async throws -> ToolOutput {
        let mine = sessionFolders[connection]
        guard let handoff = id.flatMap({ id in handoffs.last { $0.id == id.lowercased() } })
            ?? handoffs.last(where: { mine != nil && $0.session == mine }) ?? handoffs.last else {
            throw AutomationError(.notFound, id.map { "There's no handoff \($0) (Kite keeps them for a week)." }
                ?? "There's no handoff. Call handoff first.")
        }
        if cancel {
            update(handoff.id) { $0.finishAll(.skipped, how: "Claude withdrew it") }
            pollHandoffsSoon()
        } else {
            // A fresh look first, so a step Claude just unblocked (or the page did) isn't reported from an old one.
            await lookAtSteps(handoff.id, attempts: 1)
        }
        return try await handoffReport(handoff.id, wait: cancel ? 0 : wait, reportBlockedAfter: UserHandoff.blockedReportDelay)
    }

    /// Waits up to `wait` seconds for the user to end every step, then reports. A step that has been blocked for
    /// `reportBlockedAfter` (unshown for `UserHandoff.unshownReportDelay`) ends the wait early (once per step), so
    /// Claude can fix what's in the way instead of waiting on a user who can't go on; so does a click that opens a
    /// new tab, for Claude to carry on there.
    private func handoffReport(_ id: String, wait: Double, reportBlockedAfter delay: TimeInterval,
                               note: String? = nil) async throws -> ToolOutput {
        let deadline = Date().addingTimeInterval(wait)
        var watch = HandoffBlockWatch(reported: reportedBlockedSteps)
        let openedBefore = handoffs.first { $0.id == id }?.opened.count ?? 0
        let waitingBefore = handoffs.first { $0.id == id }?.waiting.count ?? 0
        // Any step ending wakes the wait, not only the last one, so Claude picks up on the page it led to at once.
        while Date() < deadline, let handoff = handoffs.first(where: { $0.id == id }), !handoff.isFinished,
              handoff.opened.count == openedBefore, handoff.waiting.count == waitingBefore,
              !watch.shouldReport(handoff, delay: delay, unshownDelay: max(delay, UserHandoff.unshownReportDelay)) {
            try await Task.sleep(for: .milliseconds(250))
        }
        // A click that just ended a step may also be opening a tab: give it a moment to arrive, so the report has it.
        if wait > 0, let click = handoffClicks.values.filter({ handoffID(of: $0.step) == id }).map(\.at).max() {
            let left = UserHandoff.clickSettle - Date().timeIntervalSince(click)
            if left > 0 { try await Task.sleep(for: .seconds(left)) }
        }
        guard let handoff = handoffs.first(where: { $0.id == id }) else { throw AutomationError(.notFound, "Handoff \(id) is gone.") }
        reportedBlockedSteps.formUnion(handoff.blockedSteps.map(\.id))
        if handoff.isFinished { handoffEndsTold.insert(id) }
        var text = handoff.report(waitedOut: wait > 0 && !handoff.isFinished) { [store] tab in
            store.state.tab(tab).map { (url: $0.url?.absoluteString, title: $0.displayTitle) }
        }
        if let note, !handoff.isFinished { text += "\n" + note }
        // What the user's steps opened (a popup from a button they pressed), so Claude carries on there.
        for tab in Set(handoff.steps.compactMap(\.tab)) {
            if let opened = openedReport(by: tab, since: handoff.created) { text += "\n\n" + opened }
        }
        return .text(text)
    }

    /// How the ring finds a step's control. A ref is marked on the page now, while it's fresh; its label finds it
    /// again if the page redraws it.
    private func locator(for target: UserHandoff.Target, step: String, tab: BrowserTab) async throws -> Handoff.Step.Locator {
        switch target {
        case .selector(let selector): return .selector(selector)
        case .text(let text): return .text(text)
        case .ref(let ref):
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
                    let at = store.state.tab(tab)?.url
                    guard let state = await ringLook(step, why: handoff.reason, scroll: false, probe: true, tab: tab, actions: actions)
                    else { continue }
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
        // A step the user saw ringed is done once its tab goes to another page (a navigation the events missed, or one
        // inside the page).
        if let shown = handoffShownAt[stepID], let current, Handoff.canReturn(to: current), !UserHandoff.samePage(shown, current),
           let step = waitingStep(on: tab), step.id == stepID {
            return finishFromPage(step, how: "navigated", later: nil, tab: tab)
        }
        if state.found, handoffShownAt[stepID] == nil, let current, current == at { handoffShownAt[stepID] = current }
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
            let hidden = state.found ? nil : state.hidden
            if h.steps[i].controlHidden != hidden { h.steps[i].controlHidden = hidden }
            if h.steps[i].blocker != blocker { h.steps[i].blocker = blocker }
        }
    }

    /// Changes a handoff.
    private func update(_ id: String, _ change: (inout Handoff) -> Void) {
        guard let index = handoffs.firstIndex(where: { $0.id == id }) else { return }
        let before = handoffs[index]
        change(&handoffs[index])
        // The user finished their step on a tab: it goes back to working at once, the handoff's connection's touch.
        for tab in handoffs[index].tabsPickedUp(since: before) { pickUp(tab, connection: handoffConnections[id]) }
        // Saved: what the user or Claude did, and the steps' pages and tabs; not what the ring found.
        if handoffs[index].steps.map({ [$0.state.rawValue, $0.url, $0.tab?.uuidString] }) != before.steps.map({ [$0.state.rawValue, $0.url, $0.tab?.uuidString] }) {
            saveHandoffs()
        }
    }

    private func handoffID(of step: String) -> String { String(step.prefix { $0 != "." }) }

    /// Handoffs `connection` made that ended since it last heard about them: the line its next tool result carries, so
    /// it picks up at once even if it wasn't waiting in handoff_status.
    func handoffNews(for connection: Int) -> String? {
        let ended = handoffs.filter { $0.isFinished && handoffConnections[$0.id] == connection && !handoffEndsTold.contains($0.id) }
        guard !ended.isEmpty else { return nil }
        handoffEndsTold.formUnion(ended.map(\.id))
        return ended.map(Handoff.endedNews).joined(separator: "\n")
    }

    // MARK: Taking the user to the step

    /// Takes the user to the step of handoff `id` they're needed for (`HandoffLead.target`): brings its tab (and space)
    /// forward now, or once they've paused typing or clicking in Kite. `from`: only if the tab in front is still that
    /// one then (after a step there ended: a user who has gone elsewhere since isn't pulled back). Nil when there's
    /// nowhere to take them; `now` says whether the tab came forward at once.
    @discardableResult
    func leadToStep(of id: String, from: UUID? = nil) -> (step: Handoff.Step, tab: UUID, now: Bool)? {
        handoffLead?.cancel()
        handoffLead = nil
        let state = store.state
        guard from == nil || state.selectedTab?.id == from, let handoff = handoffs.first(where: { $0.id == id }),
              let step = HandoffLead.target(handoff, front: state.selectedTab?.id, isOpen: { state.tab($0) != nil }),
              let tab = step.tab else { return nil }
        guard userIsBusy else {
            bringForward(tab)
            return (step, tab, true)
        }
        handoffLead = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(HandoffLead.recheck))
                guard let self, !Task.isCancelled else { return }
                if self.userIsBusy { continue }
                self.handoffLead = nil
                // Looked at again: the user may have gone to the step themselves, or finished it, meanwhile.
                self.leadToStep(of: id, from: from)
                return
            }
        }
        return (step, tab, false)
    }

    /// Brings a step's tab to the front of the tools' window (switching to its space), without activating Kite or
    /// raising its window over another app's: the user finds it there when they look. Its next look scrolls the
    /// control into view and pulses the ring.
    private func bringForward(_ tab: UUID) {
        ringJumps.insert(tab)
        store.mutateWithoutUndo { $0.select(tab: tab) }
        pollHandoffsSoon()
    }

    /// Whether the user is typing or clicking in Kite right now (`HandoffLead.userIsBusy`).
    private var userIsBusy: Bool {
        let since = { (type: CGEventType) in CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type) }
        let pointer = [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .mouseMoved, .leftMouseDragged]
            .map(since).min() ?? .infinity
        return HandoffLead.userIsBusy(appActive: NSApp.isActive, sinceKey: since(.keyDown), sincePointer: pointer,
                                      commandBarOpen: store.commandBar != nil)
    }

    /// The user ended a step on `tab`. They stay where they are (Gabe, 5 Nov 2026: "when i hit the final step of a claude
    /// action it seems to take me to another tab.. dont.. keep me in the same tab"): the next step's tab is orange in
    /// the sidebar with its control ringed, and a lead still waiting from the handoff's start is dropped, since they've
    /// found the steps.
    private func stepEnded(_ stepID: String, on tab: UUID) {
        handoffLead?.cancel()
        handoffLead = nil
        guard HandoffLead.bringsTabForward(at: .stepEnded) else { return }
        leadToStep(of: handoffID(of: stepID), from: tab)
    }

    /// Ends `step` from what the page saw (`how`, `UserHandoff.describe`). "later": the user clicked step `later`'s
    /// control on the same tab, so every waiting step there up to it is done.
    func finishFromPage(_ step: Handoff.Step, how: String, later: String?, tab: UUID) {
        let id = handoffID(of: step.id)
        update(id) { h in
            if let later, let target = h.steps.first(where: { $0.id == later }), target.tab == tab, target.isWaiting {
                for other in h.steps where other.isWaiting && other.tab == tab && other.number < target.number {
                    h.finish(other.id, .done, how: UserHandoff.describe("later"))
                }
                h.finish(later, .done, how: UserHandoff.describe("click"))
            } else {
                h.finish(step.id, UserHandoff.state(how), how: UserHandoff.describe(how))
            }
        }
        handoffShownAt[step.id] = nil
        if UserHandoff.onControl(how) { stepClicked(later ?? step.id, on: tab) }
        stepEnded(step.id, on: tab)
        pollHandoffsSoon()
    }

    /// The tab's main frame went to `url`: a step the user saw ringed there is done ("navigated").
    func handoffNavigated(_ tab: UUID, to url: String) {
        guard let step = waitingStep(on: tab), let shown = handoffShownAt[step.id], let to = URL(string: url),
              Handoff.canReturn(to: to), !UserHandoff.samePage(shown, to) else { return }
        finishFromPage(step, how: "navigated", later: nil, tab: tab)
    }

    /// The page opened a dialog while a step waits on its tab: the step is done, and Claude's wait wakes to it. The
    /// dialog itself reaches Claude with the dialog capture work (branch `claude/dialogs-to-agent`): this is its hook.
    func handoffDialogOpened(_ tab: UUID) {
        guard let step = waitingStep(on: tab) else { return }
        finishFromPage(step, how: "dialog", later: nil, tab: tab)
    }

    // MARK: Across launches

    func saveHandoffs() {
        do {
            try Handoff.save(handoffs, to: Handoff.fileURL(supportDirectory: supportDirectory))
        } catch {
            NSLog("Kite: couldn't save Claude's handoffs: \(error)")
        }
    }

    /// Steps saved before Kite showed steps only beside their control (a command, a note, a tab alone) have nowhere
    /// to show now: they're skipped, and Claude hears why if it asks.
    func skipUnshowableHandoffSteps() {
        for handoff in handoffs where handoff.waiting.contains(where: { $0.locator == nil }) {
            update(handoff.id) { $0.finishAll(.skipped, how: "Kite no longer shows steps without a control on a page") { $0.locator == nil } }
        }
    }

    // MARK: What the sidebar asks

    /// Every step still waiting on the user, newest handoff first (the order tabs show them in: waitingStep).
    var waitingHandoffSteps: [(handoff: Handoff, step: Handoff.Step)] {
        handoffs.reversed().flatMap { handoff in handoff.waiting.map { (handoff, $0) } }
    }

    /// The step a tab shows: the newest handoff's first waiting one there (Claude's latest word for that page, such as
    /// the step that turns on an older step's control).
    func waitingStep(on tab: UUID) -> Handoff.Step? {
        for handoff in handoffs.reversed() { if let step = handoff.current(on: tab) { return step } }
        return nil
    }

    /// Tabs with a step waiting on them, for the sidebar's folders.
    var handoffTabs: Set<UUID> { Set(waitingHandoffSteps.compactMap(\.step.tab)) }

    /// A step on `tab` ended with a click on its control: a tab that page opens (or just opened) is the click's doing.
    private func stepClicked(_ stepID: String, on tab: UUID) {
        let now = Date()
        handoffClicks[tab] = (stepID, now)
        if let open = handoffOpens[tab], now.timeIntervalSince(open.at) < UserHandoff.openedTabWindow { stepOpened(open.tab, by: stepID) }
    }

    /// The page in `opener` opened `tab` (a link to a new tab, or a popup: `tabOpened`). Right after a click on a step's
    /// control, it's where the user went next: a wait ends for it, so Claude carries on there.
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
    }

    // MARK: Watching the pages

    /// Kite looks at the pages when something the user sees could have changed: a tab comes forward or closes, a
    /// page finishes loading, a window becomes key or visible, Kite comes to the front, or the ring hears a click.
    /// It puts the ring up for the step a page shows, follows it through reloads, and notes what's in the way.
    /// Between those, it looks twice a second only while a step's page is on screen in a visible window (to follow
    /// a page that redraws without loading, and hear a click the binding missed), and only for handoffs under
    /// `UserHandoff.watchLimit` old: older steps keep their sidebar dot and ring, but wait for one of those
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
        handoffLead?.cancel()
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

    /// The tab in front, and which steps' tabs are open: a switch or a close changes what the ring shows.
    /// `generation` is the store watch's (`handoffTabsWatch`): when the tools move to another window's store
    /// (`attach`), the old store's observation is dropped and this runs again on the new one.
    func watchHandoffTabs(generation: Int? = nil) {
        let generation = generation ?? handoffTabsWatch.generation
        guard handoffTabsWatch.isCurrent(generation) else { return }
        let key = withObservationTracking { handoffTabsKey } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.watchHandoffTabs(generation: generation) } }
        }
        if handoffTabsWatch.saw(key, generation: generation) { handoffEvent() }
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
        // A closed tab keeps its steps (Claude hears so, to open the page again or withdraw them); one that's back
        // (Undo Close, the archive) is open again.
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
        let waitingIDs = Set(handoffs.flatMap(\.waiting).map(\.id))
        handoffShownAt = handoffShownAt.filter { waitingIDs.contains($0.key) }
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
                let reason = handoffs.first { $0.id == handoffID(of: step.id) }?.reason
                let at = store.state.tab(id)?.url
                guard let state = await ringLook(step, why: reason, scroll: first, probe: false, tab: id, actions: actions) else { continue }
                ringShown[id] = step.id
                if let done = state.done {
                    finishFromPage(step, how: done, later: state.later, tab: id)
                    // Again at once: the tab's next step gets the ring, or the ring goes.
                    handoffPollAgain = true
                } else {
                    setLook(step.id, state, tab: id, at: at)
                }
            } else {
                _ = try? await actions.runIsolated(UserHandoff.clearScript, world: UserHandoff.worldName, binding: UserHandoff.bindingName)
                if let frame = ringFrames.removeValue(forKey: id) {
                    _ = try? await actions.runIsolated(UserHandoff.clearScript, world: UserHandoff.worldName,
                                                       binding: UserHandoff.bindingName, in: frame)
                }
                ringShown[id] = nil
                ringFloating[id] = nil
            }
        }
        // Pages that went away (hibernated or closed) took their ring along.
        for id in Array(ringShown.keys) where host.livePages[id] == nil { ringShown[id] = nil }
        for id in Array(ringFloating.keys) where host.livePages[id] == nil { ringFloating[id] = nil }
        for id in Array(ringFrames.keys) where host.livePages[id] == nil { ringFrames[id] = nil }
    }

    /// Shows a step's ring where its control is, and says what the look saw. The top frame first: its look walks
    /// into same-origin frames itself. Then the frame of another origin that had the ring, then the others (a
    /// sign-in form in Apple's or another site's frame), probed without drawing until one has the control, which
    /// then gets the ring. One place shows it at a time: the frame that had it is cleared when it moves. When no frame
    /// has it for `floatDelay`, the tag shows on its own at the top of the page, so the user still reads the step.
    /// `probe` only looks, drawing nothing.
    private func ringLook(_ step: Handoff.Step, why: String?, scroll: Bool, probe: Bool, tab: UUID,
                          actions: PageActions) async -> UserHandoff.RingState? {
        func run(_ config: UserHandoff.RingConfig, in frame: PageFrame?) async -> UserHandoff.RingState? {
            let script = UserHandoff.ringScript(config)
            guard let json = try? await actions.runIsolated(script, world: UserHandoff.worldName, binding: UserHandoff.bindingName, in: frame)
            else { return nil }
            return UserHandoff.RingState(json: json)
        }
        func clear(_ frame: PageFrame) async {
            _ = try? await actions.runIsolated(UserHandoff.clearScript, world: UserHandoff.worldName, binding: UserHandoff.bindingName, in: frame)
        }
        let jump = !probe && ringJumps.remove(tab) != nil
        let later = handoffs.first { $0.id == handoffID(of: step.id) }?.steps
            .filter { $0.isWaiting && $0.tab == tab && $0.number > step.number } ?? []
        let config = UserHandoff.RingConfig(step: step, why: why, scroll: scroll || jump, probe: probe, jump: jump,
                                            manager: host?.passwordManagerName, managerReady: host?.canOpenPasswordManager ?? false,
                                            later: later)
        guard let top = await run(config, in: nil) else { return nil }
        let held = ringFrames[tab]
        if top.found || top.done != nil {
            if let held, !probe { await clear(held); ringFrames[tab] = nil }
            return top
        }
        let frames = (try? await actions.childFrames()) ?? []
        let same = { (a: PageFrame, b: PageFrame?) in a.id == b?.id && a.session == b?.session }
        if let held {
            if frames.contains(where: { same($0, held) }), let state = await run(config, in: held), state.found || state.done != nil {
                return state
            }
            if !probe { await clear(held); ringFrames[tab] = nil }
        }
        let look = UserHandoff.RingConfig(step: step, why: why, scroll: false, probe: true)
        var hidden = top.hidden == true
        for frame in frames.prefix(UserHandoff.maxFramesLooked) where !same(frame, held) {
            guard let seen = await run(look, in: frame) else { continue }
            if seen.hidden == true { hidden = true }
            guard seen.found else { continue }
            if probe { return seen }
            // Newly ringed there: scroll the frame to it.
            var ring = config
            ring.scroll = true
            guard let state = await run(ring, in: frame) else { continue }
            ringFrames[tab] = frame
            return state
        }
        var state = top
        state.hidden = hidden
        return state
    }

    // MARK: Suggest password

    /// The tag's "Suggest password" on a new password's field: Kite clicks the field (a real click, as the user's would
    /// be) so the password manager's own inline menu opens there with its suggestion, which the user picks. Kite never
    /// reads the field, and its click doesn't end the step. When the manager isn't added to this space's profile, or its
    /// menu doesn't come up (locked, or not on this page), the tag says so.
    private func suggestPassword(for step: Handoff.Step, on tab: UUID) async {
        guard let host, let page = host.livePages[tab], let actions = page.automation as? PageActions else { return }
        let frame = ringFrames[tab]
        func note(_ words: String?) async {
            _ = try? await actions.runIsolated(UserHandoff.noteScript(words), world: UserHandoff.worldName,
                                               binding: UserHandoff.bindingName, in: frame)
        }
        let name = host.passwordManagerName ?? "Your password manager"
        guard host.canOpenPasswordManager else {
            return await note("Add \(name): ⇧⌘X")
        }
        guard let json = try? await actions.runIsolated(UserHandoff.prepareManagerScript, world: UserHandoff.worldName,
                                                        binding: UserHandoff.bindingName, in: frame),
              let point = try? JSONDecoder().decode([String: Double].self, from: Data(json.utf8)),
              let x = point["x"], let y = point["y"] else { return }
        if frame == nil {
            try? await actions.click(at: ViewportPoint(x: x, y: y), button: .left, count: 1, modifiers: [])
        } else {
            // In a frame, the point is the frame's own: focus the field there and press ↓, the key the manager's menu
            // opens on.
            _ = try? await actions.runIsolated("(() => { const K = window.__kiteHandoff; if (K && K.el) K.el.focus(); return true; })()",
                                               world: UserHandoff.worldName, binding: UserHandoff.bindingName, in: frame)
            if let down = try? KeyChord.parse("ArrowDown") { try? await actions.press([down]) }
        }
        // Only 1Password's page elements are known (its own inline button and menu): another manager gets no check.
        guard name == PasswordManager.onePassword.name else { return await note(nil) }
        try? await Task.sleep(for: .milliseconds(900))
        let present = try? await actions.runIsolated(UserHandoff.onePasswordPresentScript, world: UserHandoff.worldName,
                                                     binding: UserHandoff.bindingName, in: frame)
        await note(present == "true" ? nil : "Unlock 1Password, then again")
    }

    /// The ring's listeners (a click, a field filled in, a later step's control, the control gone, and its tag's Skip),
    /// through the binding: ends the step at once, even if the click navigates away.
    func handoffBindingCalled(_ params: JSONValue, tab: UUID) {
        guard params["name"]?.stringValue == UserHandoff.bindingName,
              let payload = params["payload"]?.stringValue, let event = UserHandoff.RingEvent(json: payload),
              let step = waitingStep(on: tab), step.id == event.step else { return }
        if event.how == UserHandoff.managerEvent {
            Task { await suggestPassword(for: step, on: tab) }
            return
        }
        finishFromPage(step, how: event.how, later: event.later, tab: tab)
    }
}
