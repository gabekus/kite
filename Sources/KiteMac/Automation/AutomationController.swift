import AppKit
import KiteCore
import Observation

/// What the automation controller needs from the browser window.
@MainActor
protocol AutomationHost: AnyObject {
    var window: NSWindow? { get }
    /// The tab's page, created in the background if it isn't live.
    func automationPage(for tab: BrowserTab) -> WebPage
}

/// "Claude in the browser", the local half: runs Claude's tool calls against
/// real tabs, asks the user before anything that commits on their behalf, and
/// tracks which tabs Claude is driving so the window can say so.
///
/// Off by default. While off there's no socket at all.
@MainActor
@Observable
final class AutomationController {
    struct ControlledTab: Equatable {
        var lastActive: Date
        /// Socket connections that touched the tab. A tab whose client went away fades sooner.
        var connections: Set<Int>
    }

    private(set) var isEnabled: Bool
    /// Tabs Claude is driving right now, for the "Claude is controlling this tab" banner.
    private(set) var controlledTabs: [UUID: ControlledTab] = [:]

    @ObservationIgnored weak var host: AutomationHost?
    @ObservationIgnored private let store: BrowserStore
    @ObservationIgnored private let supportDirectory: URL
    @ObservationIgnored private var server: AutomationServer?
    /// Tabs the user pressed Stop on. Cleared when the setting is turned off and on again.
    @ObservationIgnored private var revoked: Set<UUID> = []
    @ObservationIgnored private var pendingConfirmations: [UUID: [NSAlert]] = [:]
    @ObservationIgnored private var expiryTimer: Timer?

    private enum Timing {
        static let idleWhileConnected: TimeInterval = 120
        static let idleAfterDisconnect: TimeInterval = 15
        static let loadWait: TimeInterval = 10
        static let confirmationWait: TimeInterval = 120
    }

    init(store: BrowserStore, supportDirectory: URL) {
        self.store = store
        self.supportDirectory = supportDirectory
        isEnabled = AutomationSettings.load(from: AutomationSettings.fileURL(supportDirectory: supportDirectory)).allowClaudeControl
    }

    var socketURL: URL { AutomationWire.socketURL(supportDirectory: supportDirectory) }

    /// Opens the socket if the setting is on. Call once the window exists.
    func start() {
        if isEnabled && !openSocket() { isEnabled = false }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            guard openSocket() else { return }
        } else {
            server?.stop()
            server = nil
            stop(tabs: Set(controlledTabs.keys).union(pendingConfirmations.keys))
            revoked.removeAll()
        }
        isEnabled = enabled
        do {
            try AutomationSettings(allowClaudeControl: enabled).save(to: AutomationSettings.fileURL(supportDirectory: supportDirectory))
        } catch {
            NSLog("Kite: couldn't save the automation setting: \(error)")
        }
    }

    func shutdown() {
        server?.stop()
        server = nil
    }

    /// The Stop button: Claude loses these tabs until the setting is turned off and on.
    func stop(tabs: Set<UUID>) {
        revoked.formUnion(tabs)
        for id in tabs {
            controlledTabs[id] = nil
            for alert in pendingConfirmations.removeValue(forKey: id) ?? [] {
                host?.window?.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
            }
        }
    }

    private func openSocket() -> Bool {
        let server = AutomationServer(
            socketURL: socketURL,
            handler: { [weak self] request, connection in
                await self?.perform(request, connection: connection) ?? .failure(.disabled)
            },
            onDisconnect: { [weak self] connection in
                Task { @MainActor in self?.disconnected(connection) }
            }
        )
        do {
            try server.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Kite couldn't start Claude's connection"
            alert.informativeText = "\(error)"
            alert.runModal()
            return false
        }
        self.server = server
        expiryTimer?.invalidate()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireIdleTabs() }
        }
        return true
    }

    // MARK: Control indicator

    private func markControlled(_ id: UUID, connection: Int) {
        var entry = controlledTabs[id] ?? ControlledTab(lastActive: Date(), connections: [])
        entry.lastActive = Date()
        entry.connections.insert(connection)
        controlledTabs[id] = entry
    }

    private func disconnected(_ connection: Int) {
        for (id, var entry) in controlledTabs where entry.connections.contains(connection) {
            entry.connections.remove(connection)
            controlledTabs[id] = entry
        }
        expireIdleTabs()
    }

    private func expireIdleTabs(now: Date = Date()) {
        let live = store.state.allTabIDs
        for (id, entry) in controlledTabs {
            let idle = entry.connections.isEmpty ? Timing.idleAfterDisconnect : Timing.idleWhileConnected
            if now.timeIntervalSince(entry.lastActive) > idle || !live.contains(id) { controlledTabs[id] = nil }
        }
        if !isEnabled { expiryTimer?.invalidate() }
    }

    // MARK: Running tool calls

    func perform(_ request: AutomationWire.Request, connection: Int) async -> ToolOutput {
        guard isEnabled else { return .failure(.disabled) }
        do {
            let command = try AutomationCommand(tool: request.tool, arguments: request.arguments)
            return try await run(command, connection: connection)
        } catch let error as AutomationError {
            return .failure(error)
        } catch let error as AutomationCommand.InvalidArguments {
            return .failure(AutomationError(.invalidArguments, error.description))
        } catch {
            return .failure(AutomationError(.failed, "\(error)"))
        }
    }

    private func run(_ command: AutomationCommand, connection: Int) async throws -> ToolOutput {
        if case .listTabs = command { return .text(AutomationReport.tabs(tabList())) }
        if case let .navigate(nil, url, true) = command { return try await openNewTab(url, connection: connection) }

        let tab = try resolveTab(command.tab)
        markControlled(tab.id, connection: connection)
        guard let host else { throw AutomationError(.failed, "Kite has no window open.") }
        let page = host.automationPage(for: tab)
        guard let driver = page.automation else { throw AutomationError(.unsupported, "This tab's engine can't be automated.") }

        switch command {
        case .listTabs:
            fatalError("handled above")

        case .readPage(_, let limit):
            let (outline, text) = try await driver.read()
            let current = store.state.tab(tab.id) ?? tab
            return .text(AutomationReport.page(tab: tab.id, url: current.url, title: current.displayTitle,
                                               outline: outline, text: text, textLimit: limit))

        case .click(_, let target):
            let element = try await driver.locate(target)
            try await authorize(.click(element.description), tab: tab)
            try await driver.click(element)
            await settle(tab.id)
            return report("Clicked \(Self.name(target)).", tab.id)

        case let .type(_, target, text, submit):
            let element: LocatedElement
            if let target {
                element = try await driver.locate(target)
            } else if let focused = try await driver.focusedElement() {
                element = focused
            } else {
                throw AutomationError(.notFound, "Nothing on the page has keyboard focus. Pass a ref or selector.")
            }
            try await authorize(.type(element.description, text: text, submit: submit), tab: tab)
            try await driver.type(text, into: element, submit: submit)
            if submit { await settle(tab.id) }
            let into = target.map { " into \(Self.name($0))" } ?? ""
            return report("Typed \(text.count) characters\(into)\(submit ? " and pressed Return" : "").", tab.id)

        case let .navigate(_, string, _):
            let url = try authorizeURL(string)
            try await authorize(.navigate(url), tab: tab)
            page.load(url)
            await settle(tab.id, startDelay: 0.3)
            return report("Loaded.", tab.id)

        case .screenshot:
            let png = try await driver.screenshot()
            return ToolOutput(content: [
                .image(base64: png.base64EncodedString(), mimeType: "image/png"),
                .text("Screenshot of tab \(tab.id.uuidString)."),
            ])
        }
    }

    private func openNewTab(_ string: String, connection: Int) async throws -> ToolOutput {
        let url = try authorizeURL(string)
        guard let host else { throw AutomationError(.failed, "Kite has no window open.") }
        let id = store.mutate { $0.openTab(url: url, select: false) }
        guard let tab = store.state.tab(id) else { throw AutomationError(.failed, "Couldn't open a tab.") }
        markControlled(id, connection: connection)
        do {
            try await authorize(.navigate(url), tab: tab)
        } catch {
            store.mutate { _ = $0.close(tab: id) }
            throw error
        }
        _ = host.automationPage(for: tab)
        await settle(id, startDelay: 0.3)
        return report("Opened a new background tab.", id)
    }

    private func authorizeURL(_ string: String) throws -> URL {
        guard let url = URLInput.resolve(string, engine: store.state.searchEngine) else {
            throw AutomationError(.invalidArguments, "\"\(string)\" isn't a URL.")
        }
        return url
    }

    private func report(_ action: String, _ id: UUID) -> ToolOutput {
        let tab = store.state.tab(id)
        return .text(AutomationReport.afterAction(action, tab: id, url: tab?.url, title: tab?.displayTitle ?? ""))
    }

    private static func name(_ target: AutomationTarget) -> String {
        switch target {
        case .ref(let ref): ref
        case .selector(let selector): "the element matching \(selector)"
        }
    }

    private func tabList() -> [AutomationReport.Tab] {
        let state = store.state
        let front = state.selectedTab?.id
        var tabs = state.favorites.map {
            AutomationReport.Tab(id: $0.id, title: $0.displayTitle, url: $0.url, space: "Favorites", section: "favorite", isFront: $0.id == front)
        }
        for space in state.spaces {
            tabs += space.pinned.map {
                AutomationReport.Tab(id: $0.id, title: $0.displayTitle, url: $0.url, space: space.name, section: "pinned", isFront: $0.id == front)
            }
            tabs += space.tabs.map {
                AutomationReport.Tab(id: $0.id, title: $0.displayTitle, url: $0.url, space: space.name, section: "tab", isFront: $0.id == front)
            }
        }
        return tabs
    }

    private func resolveTab(_ string: String?) throws -> BrowserTab {
        let tab: BrowserTab?
        if let string {
            guard let id = UUID(uuidString: string.trimmingCharacters(in: .whitespaces)) else {
                throw AutomationError(.invalidArguments, "\"\(string)\" isn't a tab id. Call list_tabs for ids.")
            }
            tab = store.state.tab(id)
        } else {
            tab = store.state.selectedTab
        }
        guard let tab else { throw AutomationError(.notFound, "That tab isn't open. Call list_tabs for the open tabs.") }
        if revoked.contains(tab.id) { throw AutomationError.stopped }
        return tab
    }

    /// Lets a click or Return start its navigation, then waits (briefly) for the load to finish.
    private func settle(_ id: UUID, startDelay: TimeInterval = 0.25) async {
        try? await Task.sleep(for: .seconds(startDelay))
        let deadline = Date().addingTimeInterval(Timing.loadWait)
        while store.pages[id]?.isLoading == true, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: Confirmation

    private func authorize(_ action: AutomationAction, tab: BrowserTab) async throws {
        switch AutomationPolicy.evaluate(action, host: store.state.tab(tab.id)?.url?.host()) {
        case .allow:
            break
        case .deny(let reason):
            throw AutomationError(.denied, reason)
        case .confirm(let request):
            guard await confirm(request, tab: tab.id) else {
                if revoked.contains(tab.id) { throw AutomationError.stopped }
                throw AutomationError.denied(request.action)
            }
        }
        if revoked.contains(tab.id) { throw AutomationError.stopped }
    }

    /// Shows the tab and asks. Deny is the default button; no answer within two minutes is a no.
    private func confirm(_ request: ConfirmationRequest, tab id: UUID) async -> Bool {
        guard let window = host?.window else { return false }
        store.mutate { $0.select(tab: id) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = request.title
        alert.informativeText = request.detail + "\n\nOnly allow this if you asked Claude to do it."
        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Allow")
        pendingConfirmations[id, default: []].append(alert)
        defer { pendingConfirmations[id]?.removeAll { $0 === alert } }

        let timeout = DispatchWorkItem { [weak window] in
            window?.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.confirmationWait, execute: timeout)
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        timeout.cancel()
        return response == .alertSecondButtonReturn
    }

    // MARK: Setup help

    /// The CLI inside the app bundle, or next to the executable in a `swift build`.
    var cliPath: String {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let bundled = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers/kite")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled.path }
        return executable.deletingLastPathComponent().appendingPathComponent("kite-cli").path
    }

    var claudeCodeCommand: String {
        var command = "claude mcp add kite"
        if let profile = ProcessInfo.processInfo.environment["KITE_SUPPORT_PATH"] {
            command += " -e KITE_SUPPORT_PATH=\(Self.shellQuote(profile))"
        }
        return command + " -- \(Self.shellQuote(cliPath)) mcp"
    }

    private static func shellQuote(_ string: String) -> String {
        string.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) }
            ? string : "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
