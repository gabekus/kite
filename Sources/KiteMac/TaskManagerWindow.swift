import AppKit
import Darwin
import KiteCore

/// Help › Troubleshooting › Open Task Manager: Chromium's task manager as Arc opens it, drawn by
/// Kite (see `TaskManager`). One row per running task (the browser, each live tab, and on
/// Chromium the GPU and utility processes) with Chromium's default columns, refreshed every
/// second, and End Task for the selected rows' processes.
@MainActor
final class TaskManagerWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private static var shared: TaskManagerWindow?

    /// Opens it, or brings the open one forward, as Chromium does.
    static func show(controllers: @escaping () -> [BrowserWindowController]) {
        let manager = shared ?? TaskManagerWindow(controllers: controllers)
        shared = manager
        manager.refresh()
        manager.startTimer()
        if UIDiagnostics.enabledByEnvironment {
            // Test runs stay behind the user's windows.
            manager.window.orderBack(nil)
        } else {
            manager.window.makeKeyAndOrderFront(nil)
        }
    }

    private let controllers: () -> [BrowserWindowController]
    private let window: NSWindow
    private let table = TestClickableTableView()
    private let endButton = TestClickableButton(title: TaskManager.endTaskTitle, target: nil, action: nil)
    private var rows: [TaskManager.Row] = []
    private var previous: [Int32: TaskManager.Sample] = [:]
    private var previousTime: Date?
    private var timer: Timer?

    private init(controllers: @escaping () -> [BrowserWindowController]) {
        self.controllers = controllers
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        super.init()
        window.title = "Task Manager"
        window.minSize = NSSize(width: 420, height: 240)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("TaskManager")
        if window.frame.origin == .zero { window.center() }
        buildContent()
    }

    private func buildContent() {
        for (index, title) in TaskManager.columns.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
            column.title = title
            column.width = [200, 120, 80, 90, 90][index]
            column.minWidth = 40
            if index > 0 { column.headerCell.alignment = .right }
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.target = self
        table.doubleAction = #selector(activateTab(_:))
        table.setAccessibilityLabel("Task Manager")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        endButton.target = self
        endButton.action = #selector(endTask(_:))
        endButton.bezelStyle = .push
        endButton.isEnabled = false
        endButton.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(endButton)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: endButton.topAnchor, constant: -12),
            endButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            endButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        // Fit the columns to the window: the Task column takes up the difference.
        table.sizeToFit()
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: TaskManager.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        previous = [:]
        previousTime = nil
        Self.shared = nil
    }

    // MARK: Sampling

    private func currentTasks() -> [TaskManager.Task] {
        var tasks = [TaskManager.Task(kind: .browser, pid: getpid())]
        var seen = Set<ObjectIdentifier>()
        for controller in controllers() {
            let state = controller.store.state
            // Sidebar order, then pages whose tab isn't in the sidebar (a popup being adopted).
            let live = controller.pool.livePages
            let sidebar = (state.favorites + state.spaces.flatMap(\.allTabs)).map(\.id)
            let ordered = sidebar.filter { live[$0] != nil } + live.keys.filter { state.tab($0) == nil }
            for id in ordered {
                // No process (crashed or ended, or not started): Chromium drops the tab's task too.
                guard let page = live[id], let pid = page.processIdentifier,
                      seen.insert(ObjectIdentifier(page)).inserted else { continue }
                tasks.append(TaskManager.Task(
                    kind: .tab,
                    name: state.tab(id)?.title ?? "",
                    pid: pid,
                    incognito: controller.isIncognito,
                    tabID: id
                ))
            }
        }
        // Chromium's GPU and utility processes are Kite's children; WebKit's run under launchd.
        tasks += Self.childPIDs().compactMap { pid in
            TaskManager.helperTask(arguments: Self.arguments(of: pid), pid: pid)
        }
        return tasks
    }

    private func refresh() {
        let selectedKeys = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? key(rows[$0].task) : nil })
        let tasks = currentTasks()
        var samples: [Int32: TaskManager.Sample] = [:]
        for pid in Set(tasks.compactMap(\.pid)) {
            if let sample = Self.sample(pid) { samples[pid] = sample }
        }
        let now = Date()
        let interval = previousTime.map { now.timeIntervalSince($0) } ?? TaskManager.refreshInterval
        rows = TaskManager.rows(tasks: tasks, samples: samples, previous: previous, interval: interval)
        previous = samples
        previousTime = now
        table.reloadData()
        let keep = IndexSet(rows.indices.filter { selectedKeys.contains(key(rows[$0].task)) })
        table.selectRowIndexes(keep, byExtendingSelection: false)
        updateButton()
    }

    private func key(_ task: TaskManager.Task) -> String {
        task.tabID.map { "tab:\($0)" } ?? "\(task.kind.rawValue):\(task.pid ?? -1)"
    }

    private static var timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Footprint and CPU time from proc_pid_rusage (Chromium's Mac task manager reads the same
    /// footprint). Works for any process of the same user; nil once it's gone.
    static func sample(_ pid: Int32) -> TaskManager.Sample? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        // CPU times are in Mach absolute time units.
        let ticks = Double(info.ri_user_time + info.ri_system_time)
        let seconds = ticks * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        return TaskManager.Sample(footprintBytes: info.ri_phys_footprint, cpuSeconds: seconds)
    }

    static func childPIDs() -> [Int32] {
        let count = proc_listchildpids(getpid(), nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) * 2)
        let filled = proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled))).filter { $0 > 0 }
    }

    /// A process's argv (KERN_PROCARGS2), for telling Chromium's helpers apart.
    static func arguments(of pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        // argc, then the executable path, NUL padding, then argc NUL-terminated arguments.
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    // MARK: End Task

    private var selectedTasks: [TaskManager.Task] {
        table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].task : nil }
    }

    private func updateButton() {
        endButton.isEnabled = selectedTasks.contains { $0.canEnd }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButton()
    }

    @objc private func endTask(_ sender: Any?) {
        let pids = Set(selectedTasks.filter(\.canEnd).compactMap(\.pid))
        for pid in pids where Self.isKitesHelper(pid) {
            Self.terminate(pid)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }

    /// Only Kite's own processes: Chromium's helpers are its children, and WebKit's web
    /// processes are the ones its pages reported. Never Kite itself.
    private static func isKitesHelper(_ pid: Int32) -> Bool {
        guard pid > 1, pid != getpid() else { return false }
        if childPIDs().contains(pid) { return true }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        return String(cString: path).contains("com.apple.WebKit.WebContent")
    }

    /// Chromium's Process::Terminate: SIGTERM, then SIGKILL if it's still there.
    private static func terminate(_ pid: Int32) {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        proc_pidpath(pid, &path, UInt32(path.count))
        let executable = String(cString: path)
        kill(pid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            var now = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            // Same process still running (not a reused pid).
            if proc_pidpath(pid, &now, UInt32(now.count)) > 0, String(cString: now) == executable {
                kill(pid, SIGKILL)
            }
        }
    }

    /// Double-clicking a tab's row shows that tab, as in Chromium.
    @objc private func activateTab(_ sender: Any?) {
        let row = table.clickedRow
        guard rows.indices.contains(row), let id = rows[row].task.tabID else { return }
        guard let controller = controllers().first(where: { $0.pool.livePages[id] != nil }) else { return }
        controller.store.mutate { $0.select(tab: id) }
        controller.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard let column = tableColumn.flatMap({ Int($0.identifier.rawValue) }), rows.indices.contains(row) else { return nil }
        return rows[row].cells[column]
    }

    func tableView(_ tableView: NSTableView, willDisplayCell cell: Any, for tableColumn: NSTableColumn?, row: Int) {
        guard let cell = cell as? NSTextFieldCell, let column = tableColumn.flatMap({ Int($0.identifier.rawValue) }) else { return }
        cell.alignment = column == 0 ? .left : .right
        cell.lineBreakMode = .byTruncatingTail
    }
}

/// A diagnostics run stays in the background, where `ui input` drops clicks on views that
/// don't take the first mouse; these take it there so End Task can be exercised. Unchanged otherwise.
private final class TestClickableTableView: NSTableView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        UIDiagnostics.enabledByEnvironment || super.acceptsFirstMouse(for: event)
    }
}

private final class TestClickableButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        UIDiagnostics.enabledByEnvironment || super.acceptsFirstMouse(for: event)
    }
}
