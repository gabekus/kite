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
        // The tab in front may be one of them: show its step at once rather than on the next look.
        startHandoffPoller()
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        return try await handoffReport(id, wait: request.wait)
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
        }
        return try await handoffReport(handoff.id, wait: cancel ? 0 : wait)
    }

    /// Waits up to `wait` seconds for the user to end every step, then reports.
    private func handoffReport(_ id: String, wait: Double) async throws -> ToolOutput {
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline, handoffs.first(where: { $0.id == id })?.isFinished == false {
            try await Task.sleep(for: .milliseconds(250))
        }
        guard let handoff = handoffs.first(where: { $0.id == id }) else { throw AutomationError(.notFound, "Handoff \(id) is gone.") }
        let text = handoff.report(waitedOut: wait > 0 && !handoff.isFinished) { [store] tab in
            store.state.tab(tab).map { (url: $0.url?.absoluteString, title: $0.displayTitle) }
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
            let label = try await actions.mark(ref: ref, attribute: UserHandoff.markerAttribute, value: step)
            return .marker(step, label: label)
        }
    }

    private func update(_ id: String, _ change: (inout Handoff) -> Void) {
        guard let index = handoffs.firstIndex(where: { $0.id == id }) else { return }
        let before = handoffs[index]
        change(&handoffs[index])
        // Only what the user or Claude did is saved; the ring finding its control or not isn't.
        if handoffs[index].steps.map(\.state) != before.steps.map(\.state) { saveHandoffs() }
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

    /// Every step still waiting on the user, oldest handoff first.
    var waitingHandoffSteps: [(handoff: Handoff, step: Handoff.Step)] {
        handoffs.flatMap { handoff in handoff.waiting.map { (handoff, $0) } }
    }

    /// The step the card shows: the tab in front's (the first one waiting on it), or the one brought up with Next.
    func cardStep(front: UUID?) -> (handoff: Handoff, step: Handoff.Step)? {
        let waiting = waitingHandoffSteps
        // A step brought up with Next stays up over the front tab's own until another tab comes forward.
        let focused = focusedHandoffStep.flatMap { id in waiting.first { $0.step.id == id } }
        if let focused, focusedHandoffFront == front { return focused }
        if let front, let found = waiting.first(where: { $0.step.tab == front }) { return found }
        return focused
    }

    /// The first step waiting on a tab, for its sidebar row.
    func waitingStep(on tab: UUID) -> Handoff.Step? {
        for handoff in handoffs { if let step = handoff.current(on: tab) { return step } }
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
            store.mutate { $0.select(tab: tab) }
            pollHandoffsSoon()
        } else {
            focusedHandoffStep = next.step.id
            focusedHandoffFront = store.state.selectedTab?.id
        }
    }

    /// Show Tab on the card, for a step whose tab isn't in front.
    func showTab(of stepID: String) {
        guard let tab = waitingHandoffSteps.first(where: { $0.step.id == stepID })?.step.tab, store.state.tab(tab) != nil else { return }
        store.mutate { $0.select(tab: tab) }
        pollHandoffsSoon()
    }

    // MARK: Watching the pages

    /// While any step waits on a tab, Kite looks at the pages on screen twice a second: it puts the ring up for
    /// their step, follows it through navigations, and hears a click the binding missed.
    func startHandoffPoller() {
        guard handoffPoller == nil else { return pollHandoffsSoon() }
        handoffPoller = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.pollHandoffs()
                if self.handoffs.allSatisfy(\.isFinished) && self.ringShown.isEmpty { break }
                try? await Task.sleep(for: .seconds(UserHandoff.pollInterval))
            }
            self?.handoffPoller = nil
        }
    }

    /// A look now, for a change the user made (a tab switch, Done), instead of on the next tick.
    func pollHandoffsSoon() {
        guard handoffPoller != nil else { return startHandoffPoller() }
        Task { [weak self] in await self?.pollHandoffs() }
    }

    private func pollHandoffs() async {
        // One look at a time: two at once would race to make the page's world and draw two rings.
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
        // A closed tab takes its steps with it (not while the window's tabs haven't loaded yet).
        for handoff in handoffs where !handoff.isFinished && !live.isEmpty {
            update(handoff.id) { $0.finishAll(.skipped, how: "the user closed the tab") { $0.tab.map { !live.contains($0) } ?? false } }
        }
        for (id, page) in host.livePages {
            let onScreen = page.view.window != nil && !page.view.isHiddenOrHasHiddenAncestor
            let step = waitingStep(on: id)
            // A page off screen keeps its ring for when it's back; one whose steps ended loses it.
            guard (step != nil && onScreen) || (step == nil && ringShown[id] != nil),
                  let actions = page.automation as? PageActions else { continue }
            if let step {
                try? await track(id, page: page, actions: actions)
                let first = ringShown[id] != step.id
                let script = UserHandoff.ringScript(.init(step: step, scroll: first))
                guard let json = try? await actions.runIsolated(script, world: UserHandoff.worldName, binding: UserHandoff.bindingName),
                      let state = UserHandoff.RingState(json: json) else { continue }
                ringShown[id] = step.id
                let handoff = handoffID(of: step.id)
                if let done = state.done {
                    update(handoff) { $0.finish(step.id, .done, how: UserHandoff.describe(done)) }
                } else if waitingStep(on: id)?.found != state.found {
                    update(handoff) { h in
                        if let i = h.steps.firstIndex(where: { $0.id == step.id }) { h.steps[i].found = state.found }
                    }
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
        pollHandoffsSoon()
    }
}
