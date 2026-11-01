import Foundation

/// Help › Troubleshooting › Open Task Manager.
///
/// Arc's item opens Chromium's own task manager (ArcCore 156 has TaskManagerView and the
/// IDS_TASK_MANAGER_* strings). Kite can't open Chromium's (CEF only runs Chrome commands for
/// Chrome-style browsers, and Kite's are Alloy style in its own views), so it draws a table
/// with Chromium's default columns and row titles. This is the part that doesn't need AppKit:
/// which rows to show and how each cell reads.
public enum TaskManager {
    /// Chromium's default visible columns, with its Mac titles (Arc's en.lproj/locale.pak).
    public static let columns = ["Task", "Memory Footprint", "CPU", "Network", "Process ID"]
    /// The footer button (locale.pak's "End Task", the refreshed task manager's wording).
    public static let endTaskTitle = "End Task"
    /// Chromium's text for a value it can't measure.
    public static let notAvailable = "N/A"
    /// How often Chromium's task manager refreshes.
    public static let refreshInterval: TimeInterval = 1

    /// In Chromium's order: the browser, its GPU and utility processes, then tabs.
    public enum Kind: Int, Comparable, Sendable {
        case browser, gpu, utility, tab

        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    /// One thing running: the browser, a tab, or a helper process.
    public struct Task: Equatable, Sendable {
        public var kind: Kind
        /// The page title, or a helper's service name; ignored for the browser.
        public var name: String
        public var pid: Int32?
        public var incognito: Bool
        public var tabID: UUID?

        public init(kind: Kind, name: String = "", pid: Int32?, incognito: Bool = false, tabID: UUID? = nil) {
            self.kind = kind
            self.name = name
            self.pid = pid
            self.incognito = incognito
            self.tabID = tabID
        }

        /// The Task column, in Chromium's words ("Tab: $1", "Incognito Tab: $1", "GPU Process", "Utility: $1").
        public var title: String {
            switch kind {
            case .browser: return "Browser"
            case .tab: return (incognito ? "Incognito Tab: " : "Tab: ") + (name.isEmpty ? "Untitled" : name)
            case .gpu: return "GPU Process"
            case .utility: return "Utility: " + name
            }
        }

        /// Chromium never lets you end the browser process.
        public var canEnd: Bool { kind != .browser && pid != nil }
    }

    /// One process's numbers, sampled now.
    public struct Sample: Equatable, Sendable {
        /// Physical footprint, Chromium's "Memory Footprint" on the Mac.
        public var footprintBytes: UInt64
        /// User + system CPU time so far.
        public var cpuSeconds: Double

        public init(footprintBytes: UInt64, cpuSeconds: Double) {
            self.footprintBytes = footprintBytes
            self.cpuSeconds = cpuSeconds
        }
    }

    public struct Row: Equatable, Sendable {
        public var task: Task
        /// Memory, CPU and pid are shown once per process, on its first row, as in Chromium.
        public var memory: String
        public var cpu: String
        public var network: String
        public var processID: String

        public var cells: [String] { [task.title, memory, cpu, network, processID] }
    }

    /// The table: the browser first, then helpers, then tabs, each process's tasks together, with the process
    /// numbers on the first row of each. `previous` and `interval` give CPU as a percentage
    /// of one core over the last refresh; with no previous sample CPU reads 0.0.
    public static func rows(
        tasks: [Task],
        samples: [Int32: Sample],
        previous: [Int32: Sample] = [:],
        interval: TimeInterval = refreshInterval
    ) -> [Row] {
        // Grouped by kind in Chromium's order; within a kind, a process's tasks stay together where its
        // first task falls, and tabs keep their sidebar order.
        var order: [Int32: Int] = [:]
        for (index, task) in tasks.enumerated() {
            if let pid = task.pid, order[pid] == nil { order[pid] = index }
        }
        let sorted = tasks.enumerated().sorted { a, b in
            if a.element.kind != b.element.kind { return a.element.kind < b.element.kind }
            let ga = a.element.pid.flatMap { order[$0] } ?? a.offset
            let gb = b.element.pid.flatMap { order[$0] } ?? b.offset
            return ga != gb ? ga < gb : a.offset < b.offset
        }.map(\.element)

        var shown = Set<Int32>()
        return sorted.map { task in
            guard let pid = task.pid, shown.insert(pid).inserted else {
                let pidText = task.pid == nil ? notAvailable : ""
                let blank = task.pid == nil ? notAvailable : ""
                return Row(task: task, memory: blank, cpu: blank, network: notAvailable, processID: pidText)
            }
            guard let sample = samples[pid] else {
                return Row(task: task, memory: notAvailable, cpu: notAvailable, network: notAvailable, processID: String(pid))
            }
            let cpu = previous[pid].map { cpuPercent(from: $0, to: sample, interval: interval) } ?? 0
            return Row(
                task: task,
                memory: formatMemory(sample.footprintBytes),
                cpu: formatCPU(cpu),
                network: notAvailable,
                processID: String(pid)
            )
        }
    }

    /// Kibibytes with grouping, as Chromium writes them ("145,268K").
    public static func formatMemory(_ bytes: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        let kilobytes = NSNumber(value: bytes / 1024)
        return (formatter.string(from: kilobytes) ?? kilobytes.stringValue) + "K"
    }

    /// One decimal place ("0.0", "12.5").
    public static func formatCPU(_ percent: Double) -> String {
        String(format: "%.1f", max(0, percent))
    }

    public static func cpuPercent(from old: Sample, to new: Sample, interval: TimeInterval) -> Double {
        guard interval > 0 else { return 0 }
        return max(0, new.cpuSeconds - old.cpuSeconds) / interval * 100
    }

    /// What a Chromium helper process is, from its command line: the GPU process, or a utility
    /// process named after its service. Renderers (and anything else) give nil: tabs come from
    /// the pages themselves.
    public static func helperTask(arguments: [String], pid: Int32) -> Task? {
        func value(_ flag: String) -> String? {
            arguments.first { $0.hasPrefix("--\(flag)=") }.map { String($0.dropFirst(flag.count + 3)) }
        }
        switch value("type") {
        case "gpu-process":
            return Task(kind: .gpu, pid: pid)
        case "utility":
            return Task(kind: .utility, name: utilityName(subType: value("utility-sub-type") ?? ""), pid: pid)
        default:
            return nil
        }
    }

    /// Chromium's display names for the common services; otherwise the mojo interface's name.
    static func utilityName(subType: String) -> String {
        let known = [
            "network.mojom.NetworkService": "Network Service",
            "storage.mojom.StorageService": "Storage Service",
            "audio.mojom.AudioService": "Audio Service",
            "video_capture.mojom.VideoCaptureService": "Video Capture Service",
            "data_decoder.mojom.DataDecoderService": "Data Decoder Service",
            "proxy_resolver.mojom.ProxyResolverFactory": "V8 Proxy Resolver",
        ]
        if let name = known[subType] { return name }
        // "foo.mojom.BarService" → "BarService".
        return subType.split(separator: ".").last.map(String.init) ?? subType
    }
}
