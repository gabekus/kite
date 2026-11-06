import Foundation

/// Reading the trace back: `kite trace` and the `trace` tool. Filters, the timeline, the summary (where the time
/// went, for the agent and the user), and the resources report.
public enum TraceReport {
    public struct Query: Equatable, Sendable {
        public var since: Date?
        public var session: String?
        public var tab: String?
        /// user, agent or kite (`TraceActor.matches`).
        public var actor: String?
        /// Only this connection's records (the `trace` tool's default: an agent reads its own timings).
        public var connection: Int?

        public init(since: Date? = nil, session: String? = nil, tab: String? = nil, actor: String? = nil, connection: Int? = nil) {
            self.since = since
            self.session = session
            self.tab = tab
            self.actor = actor
            self.connection = connection
        }
    }

    /// "90s", "15m", "1h", "2d" (or a bare number of minutes) as seconds.
    public static func duration(_ text: String) -> TimeInterval? {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let unit = text.last else { return nil }
        if let minutes = Double(text) { return minutes * 60 }
        guard let value = Double(text.dropLast()), value >= 0 else { return nil }
        switch unit {
        case "s": return value
        case "m": return value * 60
        case "h": return value * 3600
        case "d": return value * 86400
        default: return nil
        }
    }

    /// The records a query asks for. A session takes in its tabs' events too (their page loads and samples), and
    /// a batch takes its steps.
    public static func filter(_ records: [TraceRecord], _ query: Query) -> [TraceRecord] {
        var sessionTabs: Set<String> = []
        if let session = query.session {
            for record in records where record.session == session { if let tab = record.tab { sessionTabs.insert(tab) } }
        }
        var connectionCalls: Set<String> = []
        if let connection = query.connection {
            for record in records where record.conn == connection { if let id = record.id { connectionCalls.insert(id) } }
        }
        return records.filter { record in
            if let since = query.since, record.date < since { return false }
            if let session = query.session {
                let tabs = (record.attrs?["tabs"]?.arrayValue ?? []).compactMap(\.stringValue)
                guard record.session == session || record.tab.map(sessionTabs.contains) == true
                    || tabs.contains(where: sessionTabs.contains) else { return false }
            }
            if let tab = query.tab?.lowercased() {
                let tabs = (record.attrs?["tabs"]?.arrayValue ?? []).compactMap { $0.stringValue?.lowercased() }
                guard record.tab?.lowercased().hasPrefix(tab) == true || tabs.contains(where: { $0.hasPrefix(tab) }) else { return false }
            }
            if let actor = query.actor, !TraceActor.matches(record.actor, filter: actor) { return false }
            if let connection = query.connection {
                guard record.conn == connection || record.parent.map(connectionCalls.contains) == true else { return false }
            }
            return true
        }
    }

    // MARK: Timeline

    /// One line per call and event (samples are in `resources`): time, the gap since the line before, the duration,
    /// who, and what. Batch steps are indented under their batch.
    public static func timeline(_ records: [TraceRecord], timeZone: TimeZone = .current) -> String {
        let shown = records.filter { $0.kind != .sample }
        guard !shown.isEmpty else { return "No trace records match." }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss.SSS"
        var lines: [String] = []
        var previous: TraceRecord?
        for record in shown {
            let delta = previous.map { gap(record, after: $0) } ?? 0
            previous = record
            let time = formatter.string(from: record.date)
            let indent = record.kind == .call && record.parent != nil ? "  └ " : ""
            let duration = record.dur.map(ms) ?? ""
            let what = describe(record)
            lines.append("\(time)  \(pad("+" + seconds(delta), 9))  \(pad(duration, 8))  \(pad(record.actor ?? "user", 18))  \(indent)\(what)")
        }
        return lines.joined(separator: "\n")
    }

    /// The time between two records: monotonic within a launch, wall clock across a reboot.
    static func gap(_ record: TraceRecord, after previous: TraceRecord) -> Double {
        let mono = record.m - previous.m
        let wall = record.t - previous.t
        return abs(mono - wall) < 60_000 ? max(0, mono) : max(0, wall)
    }

    static func describe(_ record: TraceRecord) -> String {
        var parts: [String] = []
        parts.append(record.kind == .call ? record.name : record.name)
        if let tab = record.tab { parts.append("tab " + String(tab.prefix(8))) }
        if let host = record.host { parts.append(host + (record.path ?? "")) }
        if let host = record.hostEnd, host != record.host || record.pathEnd != record.path { parts.append("→ " + host + (record.pathEnd ?? "")) }
        if let session = record.session, record.kind == .call { parts.append("[\(session)]") }
        if record.kind == .call {
            parts.append(record.ok == false ? "ERROR: " + (record.error ?? "") : "ok")
            if let bytes = record.bytes { parts.append(size(bytes) + (record.images.map { $0 > 0 ? " \($0) img" : "" } ?? "")) }
        }
        if let attrs = record.attrs, !attrs.isEmpty {
            parts.append(attrs.sorted { $0.key < $1.key }.prefix(8).map { "\($0.key)=\(short($0.value))" }.joined(separator: " "))
        }
        if let phases = record.phases, !phases.isEmpty {
            parts.append("{" + phases.sorted { $0.value > $1.value }.map { "\($0.key) \(ms($0.value))" }.joined(separator: ", ") + "}")
        }
        return parts.joined(separator: "  ")
    }

    static func short(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n ? String(Int(n)) : String(format: "%.1f", n)
        case .bool(let b): return b ? "yes" : "no"
        case .array(let list): return list.map(short).joined(separator: ",")
        case .null: return "null"
        case .object: return "{…}"
        }
    }

    // MARK: Summary

    public struct Stat: Equatable, Sendable {
        public var name: String
        public var count: Int
        public var errors: Int
        public var p50: Double
        public var p95: Double
        public var max: Double
        public var total: Double
    }

    public struct Summary: Equatable, Sendable {
        /// Per tool, most total time first.
        public var tools: [Stat] = []
        /// The slowest calls (id, tool, ms).
        public var slowest: [(id: String, name: String, ms: Double)] = []
        /// Top-level call time spent waiting on the user (handoff_status, sign_in, confirmation sheets).
        public var waitingOnUser: Double = 0
        /// The rest of top-level call time.
        public var working: Double = 0
        /// Gaps between one call ending and the same connection's next call starting: the agent thinking.
        public var betweenCalls: Double = 0
        /// A handoff step done to the agent's next call.
        public var reaction: Stat?
        /// Page loads by host, slowest first.
        public var loads: [Stat] = []
        /// Command bar opened to the page loaded.
        public var intentToReady: Stat?
        /// Millijoules by host and by Claude session, most first.
        public var energyByHost: [(String, Double)] = []
        public var energyBySession: [(String, Double)] = []

        public static func == (a: Summary, b: Summary) -> Bool {
            a.tools == b.tools && a.slowest.map(\.id) == b.slowest.map(\.id) && a.waitingOnUser == b.waitingOnUser
                && a.working == b.working && a.betweenCalls == b.betweenCalls && a.reaction == b.reaction && a.loads == b.loads
                && a.intentToReady == b.intentToReady && a.energyByHost.map(\.0) == b.energyByHost.map(\.0)
                && a.energyBySession.map(\.0) == b.energyBySession.map(\.0)
        }
    }

    /// The nearest-rank percentile of `values` (p from 0 to 100); 0 for none.
    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    static func stat(_ name: String, _ values: [Double], errors: Int = 0) -> Stat {
        Stat(name: name, count: values.count, errors: errors, p50: percentile(values, 50), p95: percentile(values, 95),
             max: values.max() ?? 0, total: values.reduce(0, +))
    }

    /// Tools whose time is the user's: the agent is waiting on a person.
    public static let userWaitTools: Set<String> = ["handoff_status", "sign_in"]

    public static func summary(_ records: [TraceRecord]) -> Summary {
        var summary = Summary()
        let calls = records.filter { $0.kind == .call && $0.dur != nil }
        let byTool = Dictionary(grouping: calls, by: \.name)
        summary.tools = byTool.map { name, list in
            stat(name, list.compactMap(\.dur), errors: list.filter { $0.ok == false }.count)
        }.sorted { $0.total == $1.total ? $0.name < $1.name : $0.total > $1.total }
        summary.slowest = calls.sorted { ($0.dur ?? 0) > ($1.dur ?? 0) }.prefix(5).map { ($0.id ?? "", $0.name, $0.dur ?? 0) }

        let top = calls.filter { $0.parent == nil }
        for call in top {
            let confirm = call.phases?["confirm"] ?? 0
            if userWaitTools.contains(call.name) {
                summary.waitingOnUser += call.dur ?? 0
            } else {
                summary.waitingOnUser += confirm
                summary.working += (call.dur ?? 0) - confirm
            }
        }
        for (_, list) in Dictionary(grouping: top.filter { $0.conn != nil }, by: { $0.conn! }) {
            let ordered = list.sorted { $0.m < $1.m }
            for (a, b) in zip(ordered, ordered.dropFirst()) { summary.betweenCalls += max(0, b.m - a.mEnd) }
        }

        let reactions = records.filter { $0.name == "agent.reaction" }.compactMap(\.dur)
        if !reactions.isEmpty { summary.reaction = stat("reaction", reactions) }

        let loads = records.filter { $0.name == "page.load" && $0.dur != nil }
        summary.loads = Dictionary(grouping: loads, by: { $0.host ?? "?" }).map { stat($0.key, $0.value.compactMap(\.dur)) }
            .sorted { $0.p95 == $1.p95 ? $0.name < $1.name : $0.p95 > $1.p95 }
        let intents = loads.compactMap { $0.attrs?["intent_ms"]?.doubleValue }
        if !intents.isEmpty { summary.intentToReady = stat("intent", intents) }

        var hosts: [String: Double] = [:]
        var sessions: [String: Double] = [:]
        for sample in records where sample.kind == .sample && sample.name == "proc" {
            guard let energy = sample.attrs?["energy_mj"]?.doubleValue, energy > 0 else { continue }
            let hostList = (sample.attrs?["hosts"]?.arrayValue ?? []).compactMap(\.stringValue)
            let sessionList = (sample.attrs?["sessions"]?.arrayValue ?? []).compactMap(\.stringValue)
            let kind = sample.attrs?["proc"]?.stringValue ?? "other"
            if hostList.isEmpty {
                hosts["(\(kind))", default: 0] += energy
            } else {
                for host in hostList { hosts[host, default: 0] += energy / Double(hostList.count) }
            }
            for session in sessionList { sessions[session, default: 0] += energy / Double(sessionList.count) }
        }
        summary.energyByHost = hosts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { ($0.key, $0.value) }
        summary.energyBySession = sessions.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { ($0.key, $0.value) }
        return summary
    }

    public static func summaryText(_ summary: Summary) -> String {
        var lines: [String] = []
        if !summary.tools.isEmpty {
            lines.append("Calls by tool (ms):")
            lines.append("  " + pad("tool", 24) + pad("n", 6) + pad("err", 5) + pad("p50", 9) + pad("p95", 9) + pad("max", 9) + "total")
            for tool in summary.tools {
                lines.append("  " + pad(tool.name, 24) + pad("\(tool.count)", 6) + pad("\(tool.errors)", 5) + pad(ms(tool.p50), 9)
                    + pad(ms(tool.p95), 9) + pad(ms(tool.max), 9) + ms(tool.total))
            }
            lines.append("Slowest calls: " + summary.slowest.map { "\($0.name) \(ms($0.ms)) (\($0.id))" }.joined(separator: ", "))
            lines.append("Agent time: working \(seconds(summary.working)), waiting on the user \(seconds(summary.waitingOnUser)), "
                + "between calls \(seconds(summary.betweenCalls))")
        }
        if let reaction = summary.reaction {
            lines.append("Step done → agent's next call: n \(reaction.count), p50 \(ms(reaction.p50)), p95 \(ms(reaction.p95)), max \(ms(reaction.max))")
        }
        if !summary.loads.isEmpty {
            lines.append("Slowest page loads by host (p95): " + summary.loads.prefix(5).map {
                "\($0.name) \(ms($0.p95)) (n \($0.count), max \(ms($0.max)))"
            }.joined(separator: ", "))
        }
        if let intent = summary.intentToReady {
            lines.append("Command bar → page ready: n \(intent.count), p50 \(ms(intent.p50)), p95 \(ms(intent.p95)), max \(ms(intent.max))")
        }
        if !summary.energyByHost.isEmpty {
            lines.append("Energy by host: " + summary.energyByHost.prefix(5).map { "\($0.0) \(joules($0.1))" }.joined(separator: ", "))
        }
        if !summary.energyBySession.isEmpty {
            lines.append("Energy by Claude session: " + summary.energyBySession.prefix(5).map { "\($0.0) \(joules($0.1))" }.joined(separator: ", "))
        }
        return lines.isEmpty ? "Nothing to summarize." : lines.joined(separator: "\n")
    }

    // MARK: Resources

    public struct TabUse: Equatable, Sendable {
        public var tab: String
        public var hosts: [String]
        public var peakMB: Double
        public var averageMB: Double
        public var energyMJ: Double
        public var averageCPU: Double
    }

    /// Each tab's memory, CPU and energy over the records (from its renderer's samples, shared evenly).
    public static func tabUse(_ records: [TraceRecord]) -> [TabUse] {
        var use: [String: (hosts: Set<String>, mb: [Double], energy: Double, cpu: [Double])] = [:]
        for sample in records where sample.kind == .sample && sample.name == "proc" {
            let tabs = (sample.attrs?["tabs"]?.arrayValue ?? []).compactMap(\.stringValue)
            guard !tabs.isEmpty, let mb = sample.attrs?["footprint_mb"]?.doubleValue else { continue }
            let share = Double(tabs.count)
            let hosts = (sample.attrs?["hosts"]?.arrayValue ?? []).compactMap(\.stringValue)
            for tab in tabs {
                var entry = use[tab] ?? ([], [], 0, [])
                entry.hosts.formUnion(hosts)
                entry.mb.append(mb / share)
                entry.energy += (sample.attrs?["energy_mj"]?.doubleValue ?? 0) / share
                if let cpu = sample.attrs?["cpu_pct"]?.doubleValue { entry.cpu.append(cpu / share) }
                use[tab] = entry
            }
        }
        return use.map { tab, entry in
            TabUse(tab: tab, hosts: entry.hosts.sorted(), peakMB: entry.mb.max() ?? 0,
                   averageMB: entry.mb.reduce(0, +) / Double(max(entry.mb.count, 1)), energyMJ: entry.energy,
                   averageCPU: entry.cpu.reduce(0, +) / Double(max(entry.cpu.count, 1)))
        }
    }

    /// `kite trace resources`: the top tabs by memory and by energy, Kite's totals, and the Mac.
    public static func resources(_ records: [TraceRecord], limit: Int = 10) -> String {
        let use = tabUse(records)
        let totals = records.filter { $0.kind == .sample && $0.name == "totals" }
        let system = records.filter { $0.kind == .sample && $0.name == "system" }
        guard !use.isEmpty || !totals.isEmpty else { return "No resource samples in this window." }
        var lines: [String] = []
        func row(_ entry: TabUse) -> String {
            "  " + pad(String(entry.tab.prefix(8)), 10) + pad(entry.hosts.joined(separator: ",").prefix(32).description, 34)
                + pad(String(format: "%.0f", entry.peakMB), 9) + pad(String(format: "%.0f", entry.averageMB), 9)
                + pad(String(format: "%.1f", entry.averageCPU), 8) + joules(entry.energyMJ)
        }
        let header = "  " + pad("tab", 10) + pad("hosts", 34) + pad("peak MB", 9) + pad("avg MB", 9) + pad("cpu %", 8) + "energy"
        lines.append("Top tabs by memory:")
        lines.append(header)
        lines += use.sorted { $0.peakMB > $1.peakMB }.prefix(limit).map(row)
        lines.append("Top tabs by energy:")
        lines.append(header)
        lines += use.sorted { $0.energyMJ > $1.energyMJ }.prefix(limit).map(row)
        if !totals.isEmpty {
            let footprint = totals.compactMap { $0.attrs?["footprint_mb"]?.doubleValue }
            let energy = totals.compactMap { $0.attrs?["energy_mj"]?.doubleValue }.reduce(0, +)
            let power = totals.compactMap { $0.attrs?["power_mw"]?.doubleValue }
            lines.append(String(format: "Kite in all: peak %.0f MB, average %.0f MB, ", footprint.max() ?? 0,
                                footprint.reduce(0, +) / Double(max(footprint.count, 1)))
                + "energy \(joules(energy)), "
                + String(format: "average power %.0f mW (%d samples)", power.reduce(0, +) / Double(max(power.count, 1)), totals.count))
        }
        if let first = system.first, let last = system.last {
            var mac: [String] = []
            if let a = first.attrs?["battery_pct"]?.doubleValue, let b = last.attrs?["battery_pct"]?.doubleValue {
                mac.append(String(format: "battery %.0f%% → %.0f%%", a, b))
            }
            let drains = system.compactMap { $0.attrs?["drain_pct_h"]?.doubleValue }
            if !drains.isEmpty { mac.append(String(format: "drain %.1f%%/h", drains.reduce(0, +) / Double(drains.count))) }
            let thermal = Set(system.compactMap { $0.attrs?["thermal"]?.stringValue })
            mac.append("thermal " + thermal.sorted().joined(separator: "/"))
            let pressure = records.filter { $0.name == "system.memory_pressure" }.count
            if pressure > 0 { mac.append("\(pressure) memory pressure warnings") }
            if system.contains(where: { $0.attrs?["low_power"]?.boolValue == true }) { mac.append("Low Power Mode on") }
            lines.append("Mac: " + mac.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Formatting

    static func ms(_ value: Double) -> String {
        value >= 10_000 ? String(format: "%.1fs", value / 1000) : value >= 100 ? String(format: "%.0fms", value)
            : String(format: "%.1fms", value)
    }

    static func seconds(_ milliseconds: Double) -> String {
        let s = milliseconds / 1000
        return s >= 3600 ? String(format: "%.1fh", s / 3600) : s >= 120 ? String(format: "%.1fm", s / 60) : String(format: "%.3fs", s)
    }

    static func joules(_ millijoules: Double) -> String {
        millijoules >= 1000 ? String(format: "%.1f J", millijoules / 1000) : String(format: "%.0f mJ", millijoules)
    }

    static func size(_ bytes: Int) -> String {
        bytes >= 1_048_576 ? String(format: "%.1f MB", Double(bytes) / 1_048_576)
            : bytes >= 1024 ? String(format: "%.1f KB", Double(bytes) / 1024) : "\(bytes) B"
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }
}
