import AppKit
import Darwin
import KiteCore

/// Help › Troubleshooting › Open Task Manager: Chromium's task manager as Arc opens it, drawn by
/// Kite (see `TaskManager`). Chromium's refreshed layout: category tabs and a search field above
/// a table of running tasks (the browser, each live tab, and on Chromium the GPU and utility
/// processes), refreshed every second, sortable by any column, with columns chosen from the
/// header's context menu, and End Task for the selected rows' processes.
@MainActor
final class TaskManagerWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate,
    NSMenuDelegate, NSSearchFieldDelegate {
    private static var shared: TaskManagerWindow?

    /// Opens it, or brings the open one forward, as Chromium does; either way the active tab's
    /// row is selected (TaskManagerView::SelectTaskOfActiveTab).
    static func show(activeTab: UUID? = nil, controllers: @escaping () -> [BrowserWindowController]) {
        let manager = shared ?? TaskManagerWindow(controllers: controllers)
        shared = manager
        manager.refresh()
        manager.startTimer()
        manager.select(tab: activeTab)
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
    private let searchField = TestClickableSearchField()
    private var categoryButtons: [CategoryTabButton] = []
    private var settings: TaskManager.Settings
    private var search = ""
    private var rows: [TaskManager.Row] = []
    private var tasks: [TaskManager.Task] = []
    private var samples: [Int32: TaskManager.Sample] = [:]
    private var previous: [Int32: TaskManager.Sample] = [:]
    private var previousNetwork: [String: UInt64] = [:]
    private var interval = TaskManager.refreshInterval
    private var previousTime: Date?
    private var timer: Timer?
    private var searchTimer: Timer?

    /// Chromium keeps these in local state, beside the profile; Kite keeps them in its support folder.
    private static var settingsURL: URL { AppDelegate.supportDirectory.appendingPathComponent("TaskManager.json") }

    private init(controllers: @escaping () -> [BrowserWindowController]) {
        self.controllers = controllers
        settings = TaskManager.Settings.decode(try? Data(contentsOf: Self.settingsURL))
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
        // A test profile mustn't move the user's saved frame (it lives in the app's defaults).
        if ProcessInfo.processInfo.environment["KITE_SUPPORT_PATH"] == nil { window.setFrameAutosaveName("TaskManager") }
        if window.frame.origin == .zero { window.center() }
        buildContent()
    }

    private func saveSettings() {
        guard let data = settings.encoded() else { return }
        try? FileManager.default.createDirectory(at: AppDelegate.supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.settingsURL, options: .atomic)
    }

    private func buildContent() {
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        // Chromium turns alternating rows off on every platform, the Mac included.
        table.usesAlternatingRowBackgroundColors = false
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.target = self
        table.doubleAction = #selector(activateTab(_:))
        table.setAccessibilityLabel("Task Manager")
        // Right-click the header (or the rows) to choose columns, as in Chromium.
        table.headerView = TestClickableHeaderView()
        let columnMenu = NSMenu()
        columnMenu.delegate = self
        table.menu = columnMenu
        table.headerView?.menu = columnMenu
        buildColumns()

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // The header: category tabs on the left, the search field on the right (flex 7:3 in Chromium),
        // over a separator.
        let tabs = NSStackView()
        tabs.orientation = .horizontal
        tabs.spacing = 0
        tabs.translatesAutoresizingMaskIntoConstraints = false
        for category in TaskManager.Category.allCases {
            let button = CategoryTabButton(category: category, target: self, action: #selector(selectCategory(_:)))
            categoryButtons.append(button)
            tabs.addArrangedSubview(button)
        }
        updateCategoryButtons()

        searchField.placeholderString = TaskManager.searchPlaceholder
        searchField.setAccessibilityLabel(TaskManager.searchDescription)
        (searchField.cell as? NSSearchFieldCell)?.cancelButtonCell?.setAccessibilityLabel(TaskManager.clearSearchTitle)
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        endButton.target = self
        endButton.action = #selector(endTask(_:))
        endButton.bezelStyle = .push
        endButton.isEnabled = false
        endButton.setAccessibilityHelp("Ends the highlighted task.")
        endButton.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        for view in [tabs, searchField, separator, scroll, endButton] { content.addSubview(view) }
        let searchWidth = searchField.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.3)
        searchWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            searchField.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            searchField.leadingAnchor.constraint(greaterThanOrEqualTo: tabs.trailingAnchor, constant: 12),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            searchWidth,
            separator.topAnchor.constraint(equalTo: tabs.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
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

    // MARK: Columns and sorting

    private func buildColumns() {
        for column in table.tableColumns { table.removeTableColumn(column) }
        for column in settings.visibleColumns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = Self.width(column)
            if column != .task { tableColumn.headerCell.alignment = .right }
            // Room for the title and the sort arrow; past that the table scrolls sideways.
            tableColumn.minWidth = column == .task ? 120 : tableColumn.headerCell.cellSize.width + 22
            table.addTableColumn(tableColumn)
        }
        updateSortIndicators()
        table.sizeToFit()
    }

    private static func width(_ column: TaskManager.Column) -> CGFloat {
        switch column {
        case .task: return 200
        case .memory: return 140
        case .cpu: return 70
        case .network: return 90
        case .processID: return 80
        case .idleWakeups: return 100
        case .fileDescriptors: return 110
        }
    }

    private func column(_ tableColumn: NSTableColumn?) -> TaskManager.Column? {
        tableColumn.flatMap { TaskManager.Column(rawValue: $0.identifier.rawValue) }
    }

    private func updateSortIndicators() {
        for tableColumn in table.tableColumns {
            let sorted = settings.sort.flatMap { $0.column == column(tableColumn) ? $0 : nil }
            let image = sorted.map { NSImage(named: $0.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator") }
            table.setIndicatorImage(image ?? nil, in: tableColumn)
        }
        table.highlightedTableColumn = settings.sort.flatMap { sort in
            table.tableColumns.first { column($0) == sort.column }
        }
    }

    /// A header click: Chromium's three-step cycle (initial order, reversed, unsorted).
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let column = column(tableColumn) else { return }
        settings.sort = TaskManager.Sort.toggled(settings.sort, by: column)
        saveSettings()
        updateSortIndicators()
        rebuildRows()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for column in TaskManager.Column.allCases {
            let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            item.state = settings.isVisible(column) ? .on : .off
            item.isEnabled = settings.canToggle(column)
            menu.addItem(item)
        }
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let column = TaskManager.Column(rawValue: raw) else { return }
        settings.toggle(column)
        saveSettings()
        buildColumns()
        rebuildRows()
    }

    // MARK: Categories and search

    @objc private func selectCategory(_ sender: CategoryTabButton) {
        guard settings.category != sender.category else { return }
        settings.category = sender.category
        saveSettings()
        updateCategoryButtons()
        // A new tab clears the selection (TaskManagerView::PerformFilter).
        table.deselectAll(nil)
        rebuildRows()
    }

    private func updateCategoryButtons() {
        for button in categoryButtons { button.isSelected = button.category == settings.category }
    }

    @objc private func searchChanged(_ sender: Any?) {
        // Chromium waits a moment after each keystroke before filtering.
        searchTimer?.invalidate()
        searchTimer = Timer.scheduledTimer(withTimeInterval: TaskManager.searchDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.search != self.searchField.stringValue else { return }
                self.search = self.searchField.stringValue
                self.rebuildRows()
            }
        }
    }

    func controlTextDidChange(_ notification: Notification) { searchChanged(nil) }

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
        searchTimer?.invalidate()
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
                    tabID: id,
                    networkBytes: page.networkBytes
                ))
            }
        }
        // Chromium's GPU and utility processes are Kite's children; WebKit's run under launchd. Their
        // network reads 0, as in Chromium, which counts the network service's bytes for the tasks
        // that asked for them.
        tasks += Self.childPIDs().compactMap { pid in
            TaskManager.helperTask(arguments: Self.arguments(of: pid), pid: pid).map { task in
                var task = task
                task.networkBytes = 0
                return task
            }
        }
        return tasks
    }

    private func refresh() {
        let current = currentTasks()
        var sampled: [Int32: TaskManager.Sample] = [:]
        for pid in Set(current.compactMap(\.pid)) {
            if let sample = Self.sample(pid) { sampled[pid] = sample }
        }
        let now = Date()
        // The last refresh's numbers become the baseline for rates (CPU, wakeups, network).
        previous = samples
        previousNetwork = Dictionary(tasks.compactMap { task in task.networkBytes.map { (task.key, $0) } },
                                     uniquingKeysWith: { a, _ in a })
        interval = previousTime.map { now.timeIntervalSince($0) } ?? TaskManager.refreshInterval
        previousTime = now
        tasks = current
        samples = sampled
        rebuildRows()
    }

    /// The table from the last sample, with the current category, search and sort; keeps the selection.
    private func rebuildRows() {
        let selectedKeys = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].task.key : nil })
        rows = TaskManager.rows(
            tasks: tasks, samples: samples, previous: previous, previousNetwork: previousNetwork, interval: interval,
            category: settings.category, search: search, sort: settings.sort
        )
        table.reloadData()
        let keep = IndexSet(rows.indices.filter { selectedKeys.contains(rows[$0].task.key) })
        table.selectRowIndexes(keep, byExtendingSelection: false)
        updateButton()
    }

    private func select(tab id: UUID?) {
        guard let id, let row = rows.firstIndex(where: { $0.task.tabID == id }) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        updateButton()
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
        return TaskManager.Sample(footprintBytes: info.ri_phys_footprint, cpuSeconds: seconds,
                                  wakeups: info.ri_interrupt_wkups, openFiles: openFiles(pid))
    }

    /// Chromium's File Descriptors column on the Mac: the process's open descriptors.
    static func openFiles(_ pid: Int32) -> Int? {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return nil }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 8)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
        guard filled > 0 else { return nil }
        return Int(filled) / MemoryLayout<proc_fdinfo>.stride
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
        // Every selected task must be one that can end (TaskManagerView::IsEndProcessButtonEnabled).
        let selected = selectedTasks
        endButton.isEnabled = !selected.isEmpty && selected.allSatisfy(\.canEnd)
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
        guard let column = column(tableColumn), rows.indices.contains(row) else { return nil }
        return rows[row][column]
    }

    func tableView(_ tableView: NSTableView, willDisplayCell cell: Any, for tableColumn: NSTableColumn?, row: Int) {
        guard let cell = cell as? NSTextFieldCell, let column = column(tableColumn) else { return }
        cell.alignment = column == .task ? .left : .right
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

private final class TestClickableHeaderView: NSTableHeaderView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        UIDiagnostics.enabledByEnvironment || super.acceptsFirstMouse(for: event)
    }
}

private final class TestClickableSearchField: NSSearchField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        UIDiagnostics.enabledByEnvironment || super.acceptsFirstMouse(for: event)
    }
}

/// One of the category tabs over the table: an icon and a title, the selected one in the accent
/// colour with a bar under it (Chromium's TabbedPaneTabStrip, kWithIcon style).
private final class CategoryTabButton: NSButton {
    let category: TaskManager.Category
    private let underline = NSView()

    var isSelected = false {
        didSet {
            state = isSelected ? .on : .off
            contentTintColor = isSelected ? .controlAccentColor : .secondaryLabelColor
            underline.isHidden = !isSelected
            setAccessibilityValue(isSelected)
        }
    }

    init(category: TaskManager.Category, target: AnyObject, action: Selector) {
        self.category = category
        super.init(frame: .zero)
        title = category.title
        image = Self.icon(category)
        imagePosition = .imageLeading
        imageHugsTitle = true
        isBordered = false
        setButtonType(.toggle)
        font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        self.target = target
        self.action = action
        setAccessibilityRole(.radioButton)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        underline.wantsLayer = true
        underline.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        underline.layer?.cornerRadius = 1
        underline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(underline)
        NSLayoutConstraint.activate([
            underline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            underline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            underline.bottomAnchor.constraint(equalTo: bottomAnchor),
            underline.heightAnchor.constraint(equalToConstant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 24, height: size.height)
    }

    override func updateLayer() {
        super.updateLayer()
        underline.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        UIDiagnostics.enabledByEnvironment || super.acceptsFirstMouse(for: event)
    }

    /// Chromium's tab, product and list icons.
    private static func icon(_ category: TaskManager.Category) -> NSImage? {
        switch category {
        case .tabsAndExtensions: return NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        case .browser:
            let icon = NSApp.applicationIconImage.copy() as? NSImage
            icon?.size = NSSize(width: 16, height: 16)
            return icon
        case .all: return NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)
        }
    }
}
