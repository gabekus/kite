import AppKit
import KiteCore

/// A tab handed to the user to sign in. The banner shows it; Done and Cancel answer it.
struct SignInRequest: Equatable {
    var host: String
    var reason: String?
    /// Set by the banner's buttons (or Stop); the waiting tool call picks it up.
    var answer: SignInHandoff.Outcome?
}

// sign_in: Claude hands a login page to the user and waits. The password goes from
// the password manager into the page; Claude only hears whether the user signed in.

extension AutomationController {
    func signIn(tab string: String?, reason: String?, connection: Int) async throws -> ToolOutput {
        let tab = try resolveTab(string)
        guard let maker = host, maker.window != nil else { throw AutomationError(.failed, "Kite has no window open.") }
        if Self.inBatch {
            throw NeedsConfirmation(request: ConfirmationRequest(action: "hand the tab over to sign in", detail: ""))
        }
        let page = maker.automationPage(for: tab)
        guard let actions = page.automation as? PageActions else {
            throw AutomationError(.unsupported, "This tab's engine can't hand a sign-in over.")
        }
        markControlled(tab.id, connection: connection)
        try await track(tab.id, page: page, actions: actions)
        // Read again after the wait: the window may have closed, and the tools moved on.
        guard let host, host.window != nil else { throw AutomationError(.failed, "Kite has no window open.") }
        let start = store.state.tab(tab.id)?.url
        signIns[tab.id] = SignInRequest(host: start?.host() ?? "this site", reason: reason)
        defer { signIns[tab.id] = nil }

        // Show the tab, and the password manager over it once the tab is in front (it fills the active tab).
        store.mutateWithoutUndo { $0.select(tab: tab.id) }
        if UIDiagnostics.enabledByEnvironment {
            // A test profile's run stays in the background and opens no other app; the log says what it skipped.
            NSLog("Kite: diagnostics: sign_in would bring Kite forward%@",
                  host.canOpenPasswordManager ? " and open the password manager" : "")
        } else {
            WindowPresenter.show(host.window, activate: true)
            if host.canOpenPasswordManager {
                try? await Task.sleep(for: .milliseconds(300))
                _ = host.openPasswordManager()
            }
        }

        let began = TraceClock.now()
        Trace.event("sign_in.started", tab: tab.id, url: start, connection: connection)
        // The user's time, not the page's: its polls don't count as the call's JavaScript.
        let outcome = await Trace.measure("user") { await waitForSignIn(tab.id, start: start, actions: actions) }
        Trace.event("sign_in.finished", tab: tab.id, url: store.state.tab(tab.id)?.url, actor: .user,
                    duration: TraceClock.monotonic() - began.m, start: began, connection: connection,
                    ["outcome": .string(TraceRedaction.word("\(outcome)"))])
        if isRevoked(tab.id) { throw AutomationError.stopped }
        if outcome != .signedIn {
            // Whatever the password manager (or the user) put in the form stays out of Claude's reach.
            _ = try? await actions.run(SignInHandoff.clearScript)
        }
        markControlled(tab.id, connection: connection)
        let current = store.state.tab(tab.id) ?? tab
        snapshots[tab.id] = nil
        return .text(SignInHandoff.report(outcome, tab: tab.id, url: current.url, title: current.displayTitle))
    }

    /// Polls the page until it leaves the login form, the user answers in the banner, or time runs out.
    private func waitForSignIn(_ id: UUID, start: URL?, actions: PageActions) async -> SignInHandoff.Outcome {
        let deadline = Date().addingTimeInterval(SignInHandoff.timeout)
        var agreeing = 0
        while Date() < deadline {
            if isRevoked(id) || store.state.tab(id) == nil { return .cancelled }
            if let answer = signIns[id]?.answer { return answer }
            // Keep the tab counted as Claude's, so the banner stays while the user signs in.
            touchControlled(id)
            if store.pages[id]?.isLoading != true,
               let json = try? await actions.run(SignInHandoff.probeScript),
               let probe = SignInHandoff.Probe(json: json),
               SignInHandoff.isFinished(start: start, now: store.state.tab(id)?.url, probe: probe) {
                agreeing += 1
                if agreeing >= SignInHandoff.settledProbes { return .signedIn }
            } else {
                agreeing = 0
            }
            try? await Task.sleep(for: .seconds(SignInHandoff.pollInterval))
        }
        return .timedOut
    }

    /// The banner's Done (signed in) and Cancel.
    func answerSignIn(_ id: UUID, _ outcome: SignInHandoff.Outcome) {
        signIns[id]?.answer = outcome
    }

    var canOpenPasswordManager: Bool { host?.canOpenPasswordManager ?? false }
    var passwordManagerName: String { host?.passwordManagerName ?? "Password manager" }

    func openPasswordManager() {
        if host?.openPasswordManager() != true { NSSound.beep() }
    }
}
