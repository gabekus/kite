import AppKit
import KiteCore

// The action trace at the dispatcher: one record per tool call and per batch step (`Trace`, docs/action-trace.md).
// Code deeper down adds phases (`Trace.measure`, `Trace.phase`) and details (`Trace.span?.set`) to the running call.

extension AutomationController {
    /// The raw arguments of the running batch's steps, for their records (the parsed steps don't keep them).
    @TaskLocal static var batchStepArguments: [JSONValue] = []

    /// Runs one tool call, or a step of a batch (`parent` set), and records it: both clocks at the start and the
    /// end, who called, the tab and where it was at the start and the end, how it ended, the result's size, and
    /// where the time went. With tracing off it just runs.
    func traceCall(_ name: String, arguments: JSONValue, connection: Int, actor: TraceActor, task: String?, parent: String?,
                   received: Double?, run: () async throws -> ToolOutput) async throws -> ToolOutput {
        guard Trace.isEnabled else { return try await run() }
        let start = TraceClock.now()
        let named = arguments["session"]?.stringValue.flatMap(BrowserState.cleanSessionFolderName)
        let span = TraceSpan(connection: connection, session: named ?? sessionFolders[connection])
        if let received { span.add(phase: "queue", max(0, start.m - received)) }
        let first = traceTab(name, arguments)
        // How long the agent took to come back after the user finished a step it handed over.
        if parent == nil, let reaction = Trace.takeReaction(connection: connection, now: start.m) {
            Trace.event("agent.reaction", actor: actor, duration: reaction, start: (start.t - reaction, start.m - reaction),
                        connection: connection, session: span.session, ["next": .string(TraceRedaction.word(name))])
        }
        if let tab = first.id { ActionTrace.agentActing(on: tab, actor: actor) }
        var output: ToolOutput?
        var thrown: Error?
        do {
            output = try await Trace.$span.withValue(span) { try await Trace.$actor.withValue(actor) { try await run() } }
        } catch {
            thrown = error
        }
        let end = TraceClock.monotonic()
        let found = span.recordedAttrs
        let tab = found["tab"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? first.id
        if let tab { ActionTrace.agentDone(on: tab) }

        var record = TraceRecord(kind: .call, name: TraceRedaction.word(name), t: start.t, m: start.m, dur: end - start.m,
                                 actor: actor.name, id: span.id, parent: parent)
        var attrs = TraceCall.attributes(tool: name, arguments: arguments)
        attrs.merge(found.filter { $0.key != "tab" }) { _, new in new }
        record.attrs = attrs.isEmpty ? nil : attrs
        record.conn = connection
        if case .agent(let client) = actor { record.client = client }
        record.session = span.session ?? sessionFolders[connection]
        record.task = task
        record.tab = tab?.uuidString
        (record.host, record.path) = TraceRedaction.place(first.url)
        if let tab, let url = store.state.tab(tab)?.url {
            let last = TraceRedaction.place(url)
            if last.host != record.host || last.path != record.path { (record.hostEnd, record.pathEnd) = last }
        }
        if let output {
            record.ok = !output.isError
            record.error = TraceCall.error(of: output)
            (record.bytes, record.images) = TraceCall.size(of: output)
        } else if let thrown {
            record.ok = false
            record.error = TraceRedaction.error(Self.traceMessage(thrown))
        }
        let phases = span.recordedPhases
        record.phases = phases.isEmpty ? nil : phases.mapValues { ($0 * 10).rounded() / 10 }
        Trace.emit(record)
        if let thrown { throw thrown }
        return output ?? .failure(AutomationError(.failed, "No result."))
    }

    /// The tab a call acts on at its start, and its address: the one it names, or the one in front for a tool that
    /// takes a tab.
    private func traceTab(_ name: String, _ arguments: JSONValue) -> (id: UUID?, url: URL?) {
        if let string = arguments["tab"]?.stringValue, let id = UUID(uuidString: string.trimmingCharacters(in: .whitespaces)) {
            return (id, store.state.tab(id)?.url)
        }
        guard AutomationCommand.Tool(name: name)?.takesTab == true, name != "trace", let tab = store.state.selectedTab else { return (nil, nil) }
        return (tab.id, tab.url)
    }

    static func traceMessage(_ error: Error) -> String {
        switch error {
        case let error as AutomationError: error.message
        case let error as AutomationCommand.InvalidArguments: error.description
        case is NeedsConfirmation: "needs the user's OK; not run in the batch"
        default: "\(error)"
        }
    }

    /// The `trace` tool: the caller's own calls (or a session's, a tab's, everyone's) with the events around them.
    func traceReport(_ request: TraceRequest, connection: Int) -> ToolOutput {
        Trace.flush()
        let directory = TraceStore.directory(supportDirectory: supportDirectory)
        let query = TraceReport.Query(since: Date().addingTimeInterval(-request.since), session: request.session, tab: request.tab,
                                      actor: request.actor, connection: request.all || request.session != nil || request.tab != nil ? nil : connection)
        let records = TraceReport.filter(TraceStore.read(directory: directory, since: query.since), query)
        guard Trace.isEnabled || !records.isEmpty else {
            return .text("Kite's action trace is off (Settings › Advanced › Record Action Trace).")
        }
        var text = ""
        if !request.summaryOnly {
            let shown = records.filter { $0.kind != .sample }.suffix(request.limit)
            // Hosts and paths come from pages.
            text += UntrustedContent.wrap(TraceReport.timeline(Array(shown)), source: "action trace") + "\n\n"
        }
        text += TraceReport.summaryText(TraceReport.summary(records))
        return .text(text)
    }
}
