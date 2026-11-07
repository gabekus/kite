import Foundation

/// Kite's action trace: every automation tool call, and every event around it (the user's browsing too), on one
/// timeline with one pair of clocks, written locally for timings and evals (docs/action-trace.md). Never uploaded.
///
/// Emitting is cheap on any thread: it fills in a record and hands it to `TraceStore`, which encodes and writes in
/// the background. While tracing is off (Settings › Advanced › Record Action Trace, or no store yet) every call
/// returns at once.
public enum Trace {
    public static let schemaVersion = 1
    /// UserDefaults: set to turn tracing off. Unset (the default) traces.
    public static let disabledKey = "actionTraceDisabled"

    // MARK: Setup

    /// Starts tracing into `directory` (`TraceStore.directory(supportDirectory:)`).
    public static func configure(_ store: TraceStore?, enabled: Bool = true) {
        hub.configure(store, enabled: enabled)
    }

    public static func setEnabled(_ enabled: Bool) { hub.setEnabled(enabled) }
    public static var isEnabled: Bool { hub.enabled }
    public static var store: TraceStore? { hub.currentStore }

    /// Writes what's queued (before reading the trace back, and on quit).
    public static func flush() { hub.currentStore?.flush() }

    // MARK: Context

    /// The call running in this task: its phases and child records attach to it.
    @TaskLocal public static var span: TraceSpan?
    /// Who's acting in this task. Unset is the user (AppKit's event handlers have no task-local context).
    @TaskLocal public static var actor: TraceActor?

    // MARK: Emitting

    /// Records an event. `url` is reduced to host and path here; `attrs` must already be safe (numbers, booleans,
    /// and words Kite chose).
    public static func event(_ name: String, tab: UUID? = nil, url: URL? = nil, actor: TraceActor? = nil, duration: Double? = nil,
                             start: (t: Double, m: Double)? = nil, connection: Int? = nil, session: String? = nil,
                             _ attrs: [String: JSONValue] = [:]) {
        guard hub.enabled else { return }
        let clock = start ?? TraceClock.now()
        var record = TraceRecord(kind: .event, name: name, t: clock.t, m: clock.m, dur: duration,
                                 actor: (actor ?? Self.actor ?? .user).name, parent: span?.id, attrs: attrs.isEmpty ? nil : attrs)
        record.tab = tab?.uuidString
        if let url { (record.host, record.path) = TraceRedaction.place(url) }
        record.conn = connection ?? span?.connection
        record.session = session ?? span?.session
        emit(record)
    }

    /// Records a finished record as built (calls and samples).
    public static func emit(_ record: TraceRecord) {
        guard hub.enabled, let store = hub.currentStore else { return }
        store.append(record)
    }

    /// Adds `ms` to a phase of the call running in this task, if any. Inside a `measure` the outer phase already
    /// counts the time, so phases never overlap and add up to at most the call's duration.
    public static func phase(_ name: String, _ ms: Double) {
        guard measuring == nil else { return }
        span?.add(phase: name, ms)
    }

    /// Runs `body` and adds its time to a phase of the running call (what runs inside counts only here).
    public static func measure<T>(_ phase: String, _ body: () async throws -> T) async rethrows -> T {
        guard let span, measuring == nil else { return try await body() }
        let start = TraceClock.monotonic()
        defer { span.add(phase: phase, TraceClock.monotonic() - start) }
        return try await $measuring.withValue(phase) { try await body() }
    }

    /// The phase an enclosing `measure` is timing.
    @TaskLocal static var measuring: String?

    /// A fresh id, unique across launches: `<launch>-<n>`.
    public static func nextID() -> String { hub.nextID() }

    // MARK: The agent's reaction time

    /// The user finished a step a connection's handoff asked for: its next call measures how long the agent took to
    /// notice (`agent.reaction`).
    public static func stepFinished(connection: Int?, at m: Double = TraceClock.monotonic()) {
        guard let connection, hub.enabled else { return }
        hub.setStepFinished(connection, m)
    }

    /// The time since the last step `connection` hasn't reacted to yet finished, in ms, and forgets it.
    public static func takeReaction(connection: Int, now m: Double) -> Double? {
        hub.takeStepFinished(connection).map { m - $0 }
    }

    // MARK: Navigation intents

    /// What the next navigation in `tab` comes from (`typed`, `command_bar`, `back`, `reload`, `link`…), and when
    /// the person started asking for it (the command bar opening), so the page load can say how long intent took
    /// to become a ready page.
    public static func intend(_ cause: String, tab: UUID, since intentStart: Double? = nil) {
        guard hub.enabled else { return }
        hub.setIntent(tab, Intent(cause: cause, at: TraceClock.monotonic(), since: intentStart, actor: (actor ?? .user).name))
    }

    /// The intent for a navigation starting now in `tab`: the last one set within `window` ms, once.
    public static func takeIntent(tab: UUID, window: Double = 5_000) -> Intent? {
        guard let intent = hub.takeIntent(tab), TraceClock.monotonic() - intent.at <= window else { return nil }
        return intent
    }

    public struct Intent: Sendable, Equatable {
        public var cause: String
        public var at: Double
        public var since: Double?
        public var actor: String
    }

    static let hub = TraceHub()
}

/// The state behind `Trace`, behind one lock.
final class TraceHub: @unchecked Sendable {
    private let lock = NSLock()
    private var store: TraceStore?
    private var isOn = false
    private var counter = 0
    private var stepFinished: [Int: Double] = [:]
    private var intents: [UUID: Trace.Intent] = [:]
    /// Four random hex digits per launch, so ids stay unique across launches in one day's file.
    let launch = String(UInt16.random(in: .min ... .max), radix: 16)

    func configure(_ store: TraceStore?, enabled: Bool) {
        lock.withLock {
            self.store = store
            isOn = enabled && store != nil
        }
    }

    func setEnabled(_ enabled: Bool) { lock.withLock { isOn = enabled && store != nil } }
    var enabled: Bool { lock.withLock { isOn } }
    var currentStore: TraceStore? { lock.withLock { isOn ? store : nil } }

    func nextID() -> String {
        lock.withLock {
            counter += 1
            return "\(launch)-\(counter)"
        }
    }

    func setStepFinished(_ connection: Int, _ m: Double) { lock.withLock { stepFinished[connection] = m } }
    func takeStepFinished(_ connection: Int) -> Double? { lock.withLock { stepFinished.removeValue(forKey: connection) } }

    func setIntent(_ tab: UUID, _ intent: Trace.Intent) {
        lock.withLock {
            intents[tab] = intent
            // Intents that never became a navigation (a reload of a page that was already gone) don't pile up.
            if intents.count > 64 { intents = intents.filter { intent.at - $0.value.at < 10_000 } }
        }
    }

    func takeIntent(_ tab: UUID) -> Trace.Intent? { lock.withLock { intents.removeValue(forKey: tab) } }
}

/// A tool call being traced: its id, and the phases and details that code deeper down adds while it runs.
public final class TraceSpan: @unchecked Sendable {
    public let id: String
    public let connection: Int?
    public let session: String?
    private let lock = NSLock()
    private var phases: [String: Double] = [:]
    private var attrs: [String: JSONValue] = [:]

    public init(id: String = Trace.nextID(), connection: Int? = nil, session: String? = nil) {
        self.id = id
        self.connection = connection
        self.session = session
    }

    public func add(phase: String, _ ms: Double) {
        guard ms.isFinite, ms >= 0 else { return }
        lock.withLock { phases[phase, default: 0] += ms }
    }

    /// A detail of the call found while running it (the field's role, the tab it ended on).
    public func set(_ key: String, _ value: JSONValue) {
        lock.withLock { attrs[key] = value }
    }

    public var recordedPhases: [String: Double] { lock.withLock { phases } }
    public var recordedAttrs: [String: JSONValue] { lock.withLock { attrs } }
}
