import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One line of Kite's action trace (`<support>/Traces/YYYY-MM-DD.jsonl`): a tool call, an event, or a resource
/// sample, all on the same two clocks. The schema is in docs/action-trace.md; `v` changes only when a field is
/// renamed, retyped or removed (adding one doesn't).
///
/// Nothing here holds what a person typed, a field's value, page text, a secret or a picture: callers pass
/// only what `TraceRedaction` has cleaned (hosts and paths, field roles, lengths, counts and times).
public struct TraceRecord: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// An automation tool call (MCP or `kite call`), or a step of a batch (`parent` set).
        case call
        /// Something that happened: a handoff step, a tab, a page load, a click, the app sleeping.
        case event
        /// Resource numbers: a process, the totals, or the Mac (`name` says which).
        case sample
    }

    /// The schema version.
    public var v: Int
    public var kind: Kind
    /// What: the tool for a call ("click"), the event's dotted name ("handoff.step_done"), or the sample's
    /// ("proc", "totals", "system").
    public var name: String
    /// Unique across launches: `<launch>-<n>`. Calls always have one; events and samples only when something
    /// refers to them.
    public var id: String?
    /// The batch a step belongs to, or the call an event happened inside.
    public var parent: String?
    /// Who did it: `user`, `agent:<client>` (Claude Code, Claude Desktop, `cli`), or `kite` (Kite's own housekeeping).
    public var actor: String?

    /// Wall clock at the start, Unix milliseconds.
    public var t: Double
    /// Monotonic clock at the start, milliseconds since boot (counts while the Mac sleeps; the same in every process).
    public var m: Double
    /// Duration in milliseconds, when it lasted (a call, a load, a hang, a scroll).
    public var dur: Double?

    /// Socket connection (one `kite mcp` or `kite call` process).
    public var conn: Int?
    /// The agent's client from MCP initialize ("claude-code"), or "cli".
    public var client: String?
    /// The Claude › session folder the agent named.
    public var session: String?
    /// A Claude task Kite started itself.
    public var task: String?
    public var tab: String?
    /// URL host and path at the start, query values stripped (`TraceRedaction.place`).
    public var host: String?
    public var path: String?
    /// The same at the end of a call, when it changed.
    public var hostEnd: String?
    public var pathEnd: String?

    /// Calls: whether it worked, and the error (redacted, short) when it didn't.
    public var ok: Bool?
    public var error: String?
    /// Calls: the result's size in bytes as sent, and how many images it held.
    public var bytes: Int?
    public var images: Int?
    /// Calls: where the time went, in milliseconds (queue, wait, js, input, screenshot, encode, confirm, …).
    public var phases: [String: Double]?

    /// Everything else, per name (docs/action-trace.md). Only numbers, booleans, and short words Kite chose.
    public var attrs: [String: JSONValue]?

    public init(kind: Kind, name: String, t: Double, m: Double, dur: Double? = nil, actor: String? = nil, id: String? = nil,
                parent: String? = nil, attrs: [String: JSONValue]? = nil) {
        v = Trace.schemaVersion
        self.kind = kind
        self.name = name
        self.t = t
        self.m = m
        // A tenth of a millisecond is as fine as anything here is measured.
        self.dur = dur.map { ($0 * 10).rounded() / 10 }
        self.actor = actor
        self.id = id
        self.parent = parent
        self.attrs = attrs
    }

    private enum CodingKeys: String, CodingKey {
        case v, kind, name, id, parent, actor, t, m, dur, conn, client, session, task, tab, host, path
        case hostEnd = "host_end", pathEnd = "path_end"
        case ok, error, bytes, images, phases, attrs
    }

    /// The wall-clock start.
    public var date: Date { Date(timeIntervalSince1970: t / 1000) }
    /// The monotonic end (start plus duration).
    public var mEnd: Double { m + (dur ?? 0) }

    /// One JSONL line (no newline).
    public func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public static func decode(_ line: Data) -> TraceRecord? {
        try? JSONDecoder().decode(TraceRecord.self, from: line)
    }
}

/// The trace's two clocks. Monotonic time is what durations and ordering use; wall time is for people and for
/// lining a trace up with other logs.
public enum TraceClock {
    /// Milliseconds since boot on a clock that keeps counting while the Mac sleeps and never jumps with the wall
    /// clock. The same in every process, so the CLI and the app agree.
    public static func monotonic() -> Double {
        #if canImport(Darwin)
        return Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000
        #else
        return ProcessInfo.processInfo.systemUptime * 1000
        #endif
    }

    /// Unix milliseconds.
    public static func wall() -> Double { Date().timeIntervalSince1970 * 1000 }

    /// Both, read together.
    public static func now() -> (t: Double, m: Double) { (wall(), monotonic()) }
}

/// Who did something.
public enum TraceActor: Hashable, Sendable {
    case user
    case agent(client: String)
    case kite

    public var name: String {
        switch self {
        case .user: "user"
        case .agent(let client): "agent:\(client)"
        case .kite: "kite"
        }
    }

    /// Reads `name` back.
    public static func named(_ name: String) -> TraceActor {
        if name == "kite" { return .kite }
        if name.hasPrefix("agent:") { return .agent(client: String(name.dropFirst(6))) }
        return .user
    }

    /// `--actor user|agent|kite` matches the actor's first word.
    public static func matches(_ actor: String?, filter: String) -> Bool {
        let actor = actor ?? "user"
        let filter = filter.lowercased()
        return actor == filter || actor.hasPrefix(filter + ":")
    }
}
