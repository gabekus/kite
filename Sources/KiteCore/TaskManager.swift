import Foundation

/// Help › Troubleshooting › Open Task Manager.
///
/// Arc's item opens Chromium's own task manager (ArcCore 156 has TaskManagerView and the
/// IDS_TASK_MANAGER_* strings). Kite can't open Chromium's (CEF only runs Chrome commands for
/// Chrome-style browsers, and Kite's are Alloy style in its own views), so it draws its own,
/// following Chromium's refreshed task manager (task_manager_view.cc, task_manager_table_model.cc,
/// task_manager_columns.h). This is the part that doesn't need AppKit: which rows to show for a
/// category and search, how they sort, and how each cell reads.
public enum TaskManager {
    /// The columns Kite can fill, in Chromium's order (`kColumns`, task_manager_columns.h), with
    /// their Mac titles from Arc's locale.pak. Chromium's other optional columns (Profile, the
    /// WebCore caches, GPU, SQLite, JavaScript and CppGC memory, Process Priority, Keepalive
    /// Count) need numbers from inside the engine, which Kite doesn't have.
    public enum Column: String, CaseIterable, Codable, Sendable {
        case task, memory, cpu, network, processID, idleWakeups, fileDescriptors

        public var title: String {
            switch self {
            case .task: return "Task"
            case .memory: return "Memory Footprint"
            case .cpu: return "CPU"
            case .network: return "Network"
            case .processID: return "Process ID"
            case .idleWakeups: return "Idle Wake Ups"
            case .fileDescriptors: return "File Descriptors"
            }
        }

        /// Chromium's `default_visibility`.
        public var visibleByDefault: Bool {
            switch self {
            case .task, .memory, .cpu, .network, .processID: return true
            case .idleWakeups, .fileDescriptors: return false
            }
        }

        /// The first click on a column header sorts this way (`initial_sort_is_ascending`).
        public var initialSortAscending: Bool { self == .task || self == .processID }

        /// Everything but the task's title is per process: shown on the process's first row only
        /// (Chromium's `IsSharedByGroup`).
        public var isPerProcess: Bool { self != .task }
    }

    /// Chromium's default visible columns.
    public static var columns: [String] { Column.allCases.filter(\.visibleByDefault).map(\.title) }

    /// The tabs above the table. On the Mac Chromium shows three: its `kSystem` category is titled
    /// "Browser" there ("System" is ChromeOS's), and it opens on Tabs & extensions.
    public enum Category: Int, CaseIterable, Codable, Sendable {
        case tabsAndExtensions, browser, all

        public var title: String {
            switch self {
            case .tabsAndExtensions: return "Tabs & extensions"
            case .browser: return "Browser"
            case .all: return "All tasks"
            }
        }

        /// Tabs (and extensions) under the first; the browser, GPU and utility processes under Browser.
        public func contains(_ kind: Kind) -> Bool {
            switch self {
            case .tabsAndExtensions: return kind == .tab
            case .browser: return kind != .tab
            case .all: return true
            }
        }
    }

    /// The table's sort: one column, either way. None is the model's own order.
    public struct Sort: Equatable, Codable, Sendable {
        public var column: Column
        public var ascending: Bool

        public init(column: Column, ascending: Bool) {
            self.column = column
            self.ascending = ascending
        }

        /// Chromium's sort when nothing was saved: CPU, highest first.
        public static let initial = Sort(column: .cpu, ascending: false)

        /// A click on `column`'s header (views::TableView::ToggleSortOrder): a new column sorts its
        /// initial way, the next click reverses it, and the one after that clears the sort.
        public static func toggled(_ sort: Sort?, by column: Column) -> Sort? {
            guard let sort, sort.column == column else {
                return Sort(column: column, ascending: column.initialSortAscending)
            }
            return sort.ascending == column.initialSortAscending ? Sort(column: column, ascending: !sort.ascending) : nil
        }
    }

    /// What Chromium keeps in local state (`task_manager.column_visibility`, with the sort, and
    /// `task_manager.category`) so the next window opens the same way.
    public struct Settings: Equatable, Codable, Sendable {
        public var visibleColumns: [Column]
        public var sort: Sort?
        public var category: Category

        public init(visibleColumns: [Column] = Column.allCases.filter(\.visibleByDefault),
                    sort: Sort? = .initial, category: Category = .tabsAndExtensions) {
            self.visibleColumns = visibleColumns
            self.sort = sort
            self.category = category
        }

        public func isVisible(_ column: Column) -> Bool { visibleColumns.contains(column) }

        /// The last visible column can't be hidden (Chromium greys it out in the menu).
        public func canToggle(_ column: Column) -> Bool { !(visibleColumns == [column]) }

        /// Shows or hides a column, keeping Chromium's column order. Hiding the sorted column clears the sort.
        public mutating func toggle(_ column: Column) {
            guard canToggle(column) else { return }
            var visible = Set(visibleColumns)
            if visible.contains(column) { visible.remove(column) } else { visible.insert(column) }
            visibleColumns = Column.allCases.filter(visible.contains)
            if let sort, !visible.contains(sort.column) { self.sort = nil }
        }

        public static func decode(_ data: Data?) -> Settings {
            guard let data, var settings = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
            settings.visibleColumns = Column.allCases.filter(settings.visibleColumns.contains)
            if settings.visibleColumns.isEmpty { settings.visibleColumns = Settings().visibleColumns }
            return settings
        }

        public func encoded() -> Data? { try? JSONEncoder().encode(self) }
    }

    /// The footer button (locale.pak's "End Task", Chromium's IDS_TASK_MANAGER_KILL_V2).
    public static let endTaskTitle = "End Task"
    /// The search field's placeholder and accessibility description, and its clear button's name.
    public static let searchPlaceholder = "Search"
    public static let searchDescription = "Search for any process from the list."
    public static let clearSearchTitle = "Clear search"
    /// Chromium waits this long after typing before it filters (kInputChangeCallbackDelay).
    public static let searchDelay: TimeInterval = 0.05
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
        /// Bytes this task has received and sent so far, or nil when Kite can't count them.
        public var networkBytes: UInt64?

        public init(kind: Kind, name: String = "", pid: Int32?, incognito: Bool = false, tabID: UUID? = nil,
                    networkBytes: UInt64? = nil) {
            self.kind = kind
            self.name = name
            self.pid = pid
            self.incognito = incognito
            self.tabID = tabID
            self.networkBytes = networkBytes
        }

        /// Stays the same across refreshes, for selection and the network rate.
        public var key: String { tabID.map { "tab:\($0)" } ?? "\(kind.rawValue):\(pid ?? -1)" }

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
        /// Interrupt wakeups so far (what Chromium's Mac idle wakeups count).
        public var wakeups: UInt64
        /// Open file descriptors, nil when unreadable.
        public var openFiles: Int?

        public init(footprintBytes: UInt64, cpuSeconds: Double, wakeups: UInt64 = 0, openFiles: Int? = nil) {
            self.footprintBytes = footprintBytes
            self.cpuSeconds = cpuSeconds
            self.wakeups = wakeups
            self.openFiles = openFiles
        }
    }

    public struct Row: Equatable, Sendable {
        public var task: Task
        /// Each column's text; per-process columns are blank after a process's first row, as in Chromium.
        public var text: [Column: String]
        /// What the sort compares: the process's numbers, except Network, which is the task's own rate.
        var values: [Column: Double]

        public subscript(column: Column) -> String { text[column] ?? "" }
        /// The default columns' text, in order.
        public var cells: [String] { Column.allCases.filter(\.visibleByDefault).map { self[$0] } }
    }

    /// The table: the browser first, then helpers, then tabs, each process's tasks together, with the process
    /// numbers on the first row of each. `previous` and `interval` give CPU as a percentage
    /// of one core over the last refresh (0.0 with no previous sample), and `previousNetwork`
    /// (by task key) gives each task's network rate. Then Chromium's filters: only the tasks in
    /// `category`, and with a search, only processes with a task whose title contains it. Then the sort.
    public static func rows(
        tasks: [Task],
        samples: [Int32: Sample],
        previous: [Int32: Sample] = [:],
        previousNetwork: [String: UInt64] = [:],
        interval: TimeInterval = refreshInterval,
        category: Category = .all,
        search: String = "",
        sort: Sort? = nil
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

        // Network: each task's rate since the last refresh; a process's is the sum of its tasks'.
        func rate(_ task: Task) -> Double? {
            guard let bytes = task.networkBytes else { return nil }
            guard interval > 0, let before = previousNetwork[task.key], bytes >= before else { return 0 }
            return (Double(bytes - before) / interval).rounded()
        }
        var processRate: [Int32: Double] = [:]
        for task in sorted {
            guard let pid = task.pid, let rate = rate(task) else { continue }
            processRate[pid, default: 0] += rate
        }

        // The filters (TaskManagerTableModel::ShouldKeepTask): a search keeps every task of a process
        // that has a matching task in a shown category.
        let query = search.trimmingCharacters(in: .whitespaces)
        var matched = Set<Int32>()
        var matchedLoose = Set<String>()
        if !query.isEmpty {
            for task in sorted where category.contains(task.kind) && matches(task.title, query) {
                if let pid = task.pid { matched.insert(pid) } else { matchedLoose.insert(task.key) }
            }
        }
        let kept = sorted.filter { task in
            guard category.contains(task.kind) else { return false }
            guard !query.isEmpty else { return true }
            return task.pid.map(matched.contains) ?? matchedLoose.contains(task.key)
        }

        var shown = Set<Int32>()
        let rows = kept.map { task -> Row in
            var text: [Column: String] = [.task: task.title]
            var values: [Column: Double] = [:]
            values[.network] = rate(task) ?? -1
            guard let pid = task.pid else {
                for column in Column.allCases where column.isPerProcess { text[column] = notAvailable }
                return Row(task: task, text: text, values: values)
            }
            let first = shown.insert(pid).inserted
            let sample = samples[pid]
            let cpu = sample.map { s in previous[pid].map { cpuPercent(from: $0, to: s, interval: interval) } ?? 0 }
            let wakeups = sample.map { s in previous[pid].map { wakeupsPerSecond(from: $0, to: s, interval: interval) } ?? 0 }
            values[.memory] = sample.map { Double($0.footprintBytes) } ?? -1
            values[.cpu] = cpu ?? -1
            values[.processID] = Double(pid)
            values[.idleWakeups] = wakeups.map(Double.init) ?? -1
            values[.fileDescriptors] = sample?.openFiles.map(Double.init) ?? -1
            guard first else {
                for column in Column.allCases where column.isPerProcess { text[column] = "" }
                return Row(task: task, text: text, values: values)
            }
            text[.processID] = String(pid)
            text[.network] = formatSpeed(task.networkBytes == nil ? nil : processRate[pid] ?? 0)
            if let sample {
                text[.memory] = formatMemory(sample.footprintBytes)
                text[.cpu] = formatCPU(cpu ?? 0)
                text[.idleWakeups] = formatNumber(wakeups ?? 0)
                text[.fileDescriptors] = sample.openFiles.map(formatNumber) ?? notAvailable
            } else {
                for column in [Column.memory, .cpu, .idleWakeups, .fileDescriptors] { text[column] = notAvailable }
            }
            return Row(task: task, text: text, values: values)
        }
        guard let sort else { return rows }
        return grouped(rows, by: sort)
    }

    /// Chromium's grouped sort (views::TableView::GroupSortHelper): each process's rows stay together
    /// in their order, and processes are ordered by their first row.
    static func grouped(_ rows: [Row], by sort: Sort) -> [Row] {
        var groups: [[Row]] = []
        for row in rows {
            if let pid = row.task.pid, let last = groups.last?.first, last.task.pid == pid {
                groups[groups.count - 1].append(row)
            } else {
                groups.append([row])
            }
        }
        let ordered = groups.enumerated().sorted { a, b in
            let result = compare(a.element[0], b.element[0], sort.column)
            if result == .orderedSame { return a.offset < b.offset }
            return sort.ascending ? result == .orderedAscending : result == .orderedDescending
        }
        return ordered.flatMap(\.element)
    }

    static func compare(_ a: Row, _ b: Row, _ column: Column) -> ComparisonResult {
        if column == .task { return a.task.title.localizedCompare(b.task.title) }
        let x = a.values[column] ?? -1, y = b.values[column] ?? -1
        return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
    }

    /// Chromium's StringSearchIgnoringCaseAndAccents.
    static func matches(_ title: String, _ query: String) -> Bool {
        title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
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

    public static func wakeupsPerSecond(from old: Sample, to new: Sample, interval: TimeInterval) -> Int {
        guard interval > 0, new.wakeups >= old.wakeups else { return 0 }
        return Int((Double(new.wakeups - old.wakeups) / interval).rounded())
    }

    /// A whole number with grouping ("1,234"), Chromium's base::FormatNumber.
    public static func formatNumber(_ value: Int) -> String {
        decimal(Double(value), fractionDigits: 0)
    }

    /// A network rate as ui::FormatSpeed writes it: bytes below 3 KiB, KB/s below 2 MiB, MB/s below
    /// 1 GiB, then GB/s; one decimal under 100 (but never for bytes); 0 reads "0", and nil (not
    /// measured) "N/A".
    public static func formatSpeed(_ bytesPerSecond: Double?) -> String {
        guard let bytes = bytesPerSecond else { return notAvailable }
        guard bytes > 0 else { return "0" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        let thresholds: [Double] = [0, 3 * 1024, 2 * 1024 * 1024, 1024 * 1024 * 1024, 1024 * 1024 * 1024 * 1024]
        let unit = thresholds.lastIndex { bytes >= $0 } ?? 0
        let amount = bytes / pow(1024, Double(unit))
        let digits = unit > 0 && amount < 100 ? 1 : 0
        return decimal(amount, fractionDigits: digits) + " " + units[unit]
    }

    private static func decimal(_ value: Double, fractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
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
