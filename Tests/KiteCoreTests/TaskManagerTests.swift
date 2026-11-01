import Foundation
import Testing
@testable import KiteCore

@Suite struct TaskManagerTests {
    @Test func titlesFollowChromium() {
        #expect(TaskManager.Task(kind: .browser, pid: 1).title == "Browser")
        #expect(TaskManager.Task(kind: .tab, name: "Example", pid: 2).title == "Tab: Example")
        #expect(TaskManager.Task(kind: .tab, name: "Example", pid: 2, incognito: true).title == "Incognito Tab: Example")
        #expect(TaskManager.Task(kind: .gpu, pid: 3).title == "GPU Process")
        #expect(TaskManager.Task(kind: .utility, name: "Network Service", pid: 4).title == "Utility: Network Service")
    }

    @Test func browserCantBeEnded() {
        #expect(!TaskManager.Task(kind: .browser, pid: 1).canEnd)
        #expect(TaskManager.Task(kind: .tab, name: "a", pid: 2).canEnd)
        #expect(!TaskManager.Task(kind: .tab, name: "a", pid: nil).canEnd)
    }

    @Test func browserFirstAndSharedProcessGrouped() {
        let tasks = [
            TaskManager.Task(kind: .tab, name: "A", pid: 10),
            TaskManager.Task(kind: .tab, name: "B", pid: 20),
            TaskManager.Task(kind: .tab, name: "C", pid: 10),
            TaskManager.Task(kind: .browser, pid: 1),
            TaskManager.Task(kind: .utility, name: "Network Service", pid: 30),
            TaskManager.Task(kind: .gpu, pid: 40),
        ]
        let samples: [Int32: TaskManager.Sample] = [
            1: .init(footprintBytes: 200 * 1024 * 1024, cpuSeconds: 5),
            10: .init(footprintBytes: 150_000 * 1024, cpuSeconds: 2),
            20: .init(footprintBytes: 1024, cpuSeconds: 1),
        ]
        let previous: [Int32: TaskManager.Sample] = [10: .init(footprintBytes: 0, cpuSeconds: 1.5)]
        let rows = TaskManager.rows(tasks: tasks, samples: samples, previous: previous, interval: 1)
        #expect(rows.map(\.task.title) == [
            "Browser", "GPU Process", "Utility: Network Service", "Tab: A", "Tab: C", "Tab: B",
        ])
        #expect(rows[0].cells == ["Browser", "204,800K", "0.0", "N/A", "1"])
        #expect(rows[1].cells == ["GPU Process", "N/A", "N/A", "N/A", "40"])
        #expect(rows[3].cells == ["Tab: A", "150,000K", "50.0", "N/A", "10"])
        // Same process as the row above: the process's numbers aren't repeated.
        #expect(rows[4].cells == ["Tab: C", "", "", "", ""])
        #expect(rows[5].cells == ["Tab: B", "1K", "0.0", "N/A", "20"])
    }

    @Test func unknownProcessReadsNA() {
        let rows = TaskManager.rows(tasks: [TaskManager.Task(kind: .tab, name: "A", pid: nil)], samples: [:])
        #expect(rows[0].cells == ["Tab: A", "N/A", "N/A", "N/A", "N/A"])
        let gone = TaskManager.rows(tasks: [TaskManager.Task(kind: .tab, name: "A", pid: 7)], samples: [:])
        #expect(gone[0].cells == ["Tab: A", "N/A", "N/A", "N/A", "7"])
    }

    @Test func helperProcessesFromCommandLine() {
        let gpu = TaskManager.helperTask(arguments: ["Kite Helper (GPU)", "--type=gpu-process", "--foo"], pid: 5)
        #expect(gpu?.title == "GPU Process")
        let network = TaskManager.helperTask(
            arguments: ["Kite Helper", "--type=utility", "--utility-sub-type=network.mojom.NetworkService"], pid: 6)
        #expect(network?.title == "Utility: Network Service")
        let other = TaskManager.helperTask(arguments: ["--type=utility", "--utility-sub-type=foo.mojom.BarService"], pid: 7)
        #expect(other?.title == "Utility: BarService")
        #expect(TaskManager.helperTask(arguments: ["--type=renderer"], pid: 8) == nil)
    }

    @Test func cpuPercentOfOneCore() {
        let a = TaskManager.Sample(footprintBytes: 0, cpuSeconds: 1)
        let b = TaskManager.Sample(footprintBytes: 0, cpuSeconds: 1.25)
        #expect(TaskManager.cpuPercent(from: a, to: b, interval: 0.5) == 50)
        #expect(TaskManager.formatCPU(-1) == "0.0")
    }

    @Test func networkRateIsPerProcessAndNAWhenUncounted() {
        let tasks = [
            TaskManager.Task(kind: .browser, pid: 1),
            TaskManager.Task(kind: .gpu, pid: 2, networkBytes: 0),
            TaskManager.Task(kind: .tab, name: "A", pid: 10, tabID: UUID(), networkBytes: 10_192),
            TaskManager.Task(kind: .tab, name: "B", pid: 10, tabID: UUID(), networkBytes: 6_000),
        ]
        let previous = [tasks[2].key: 4_000, tasks[3].key: 4_000].mapValues(UInt64.init)
        let samples: [Int32: TaskManager.Sample] = [1: .init(footprintBytes: 0, cpuSeconds: 0),
                                                    2: .init(footprintBytes: 0, cpuSeconds: 0),
                                                    10: .init(footprintBytes: 0, cpuSeconds: 0)]
        let rows = TaskManager.rows(tasks: tasks, samples: samples, previousNetwork: previous, interval: 2)
        #expect(rows.map { $0[.network] } == ["N/A", "0", "4.0 KB/s", ""])
        // A task seen for the first time has no rate yet.
        #expect(TaskManager.rows(tasks: [tasks[2]], samples: samples)[0][.network] == "0")
    }

    @Test func speedsFormatLikeChromium() {
        #expect(TaskManager.formatSpeed(nil) == "N/A")
        #expect(TaskManager.formatSpeed(0) == "0")
        #expect(TaskManager.formatSpeed(512) == "512 B/s")
        #expect(TaskManager.formatSpeed(3071) == "3,071 B/s")
        #expect(TaskManager.formatSpeed(3072) == "3.0 KB/s")
        #expect(TaskManager.formatSpeed(150 * 1024) == "150 KB/s")
        #expect(TaskManager.formatSpeed(2 * 1024 * 1024) == "2.0 MB/s")
    }

    @Test func categoriesFilterByKind() {
        let tasks = [
            TaskManager.Task(kind: .browser, pid: 1),
            TaskManager.Task(kind: .gpu, pid: 2),
            TaskManager.Task(kind: .tab, name: "A", pid: 10),
        ]
        func titles(_ category: TaskManager.Category) -> [String] {
            TaskManager.rows(tasks: tasks, samples: [:], category: category).map(\.task.title)
        }
        #expect(titles(.tabsAndExtensions) == ["Tab: A"])
        #expect(titles(.browser) == ["Browser", "GPU Process"])
        #expect(titles(.all) == ["Browser", "GPU Process", "Tab: A"])
        #expect(TaskManager.Category.allCases.map(\.title) == ["Tabs & extensions", "Browser", "All tasks"])
    }

    @Test func searchKeepsWholeProcessesIgnoringCaseAndAccents() {
        let tasks = [
            TaskManager.Task(kind: .browser, pid: 1),
            TaskManager.Task(kind: .tab, name: "Café", pid: 10),
            TaskManager.Task(kind: .tab, name: "Other", pid: 10),
            TaskManager.Task(kind: .tab, name: "Mail", pid: 20),
        ]
        func titles(_ search: String, _ category: TaskManager.Category = .all) -> [String] {
            TaskManager.rows(tasks: tasks, samples: [:], category: category, search: search).map(\.task.title)
        }
        #expect(titles("CAFE") == ["Tab: Café", "Tab: Other"])
        #expect(titles("mail") == ["Tab: Mail"])
        #expect(titles("browser") == ["Browser"])
        #expect(titles("browser", .tabsAndExtensions) == [])
        #expect(titles("tab:", .tabsAndExtensions).count == 3)
        #expect(titles("zzz").isEmpty)
    }

    @Test func sortKeepsProcessesTogether() {
        let tasks = [
            TaskManager.Task(kind: .browser, pid: 1),
            TaskManager.Task(kind: .tab, name: "B", pid: 10),
            TaskManager.Task(kind: .tab, name: "A", pid: 10),
            TaskManager.Task(kind: .tab, name: "C", pid: 20),
        ]
        let samples: [Int32: TaskManager.Sample] = [
            1: .init(footprintBytes: 300, cpuSeconds: 0),
            10: .init(footprintBytes: 100, cpuSeconds: 0),
            20: .init(footprintBytes: 200, cpuSeconds: 0),
        ]
        func titles(_ sort: TaskManager.Sort?) -> [String] {
            TaskManager.rows(tasks: tasks, samples: samples, sort: sort).map(\.task.title)
        }
        #expect(titles(nil) == ["Browser", "Tab: B", "Tab: A", "Tab: C"])
        #expect(titles(.init(column: .memory, ascending: false)) == ["Browser", "Tab: C", "Tab: B", "Tab: A"])
        #expect(titles(.init(column: .memory, ascending: true)) == ["Tab: B", "Tab: A", "Tab: C", "Browser"])
        // By the process's first row's title; the process's rows keep their order.
        #expect(titles(.init(column: .task, ascending: true)) == ["Browser", "Tab: B", "Tab: A", "Tab: C"])
        #expect(titles(.init(column: .task, ascending: false)) == ["Tab: C", "Tab: B", "Tab: A", "Browser"])
        // The process's numbers move with its first row.
        let sorted = TaskManager.rows(tasks: tasks, samples: samples, sort: .init(column: .processID, ascending: false))
        #expect(sorted.map { $0[.processID] } == ["20", "10", "", "1"])
    }

    @Test func headerClicksCycleLikeChromium() {
        var sort: TaskManager.Sort? = .initial
        #expect(sort == .init(column: .cpu, ascending: false))
        sort = TaskManager.Sort.toggled(sort, by: .cpu)
        #expect(sort == .init(column: .cpu, ascending: true))
        sort = TaskManager.Sort.toggled(sort, by: .cpu)
        #expect(sort == nil)
        sort = TaskManager.Sort.toggled(sort, by: .task)
        #expect(sort == .init(column: .task, ascending: true))
        sort = TaskManager.Sort.toggled(sort, by: .memory)
        #expect(sort == .init(column: .memory, ascending: false))
    }

    @Test func columnSettings() {
        var settings = TaskManager.Settings()
        #expect(settings.visibleColumns.map(\.title) == ["Task", "Memory Footprint", "CPU", "Network", "Process ID"])
        #expect(settings.category == .tabsAndExtensions)
        settings.toggle(.fileDescriptors)
        settings.toggle(.cpu)
        #expect(settings.visibleColumns == [.task, .memory, .network, .processID, .fileDescriptors])
        // Hiding the sorted column clears the sort.
        #expect(settings.sort == nil)
        for column in [TaskManager.Column.memory, .network, .processID, .fileDescriptors] { settings.toggle(column) }
        #expect(settings.visibleColumns == [.task])
        #expect(!settings.canToggle(.task))
        settings.toggle(.task)
        #expect(settings.visibleColumns == [.task])
        settings.category = .all
        #expect(TaskManager.Settings.decode(settings.encoded()) == settings)
        #expect(TaskManager.Settings.decode(Data("junk".utf8)) == TaskManager.Settings())
    }

    @Test func optionalColumns() {
        let a = TaskManager.Sample(footprintBytes: 0, cpuSeconds: 0, wakeups: 100, openFiles: 1234)
        let b = TaskManager.Sample(footprintBytes: 0, cpuSeconds: 0, wakeups: 160, openFiles: 1234)
        let rows = TaskManager.rows(tasks: [.init(kind: .tab, name: "A", pid: 5)], samples: [5: b], previous: [5: a], interval: 2)
        #expect(rows[0][.idleWakeups] == "30")
        #expect(rows[0][.fileDescriptors] == "1,234")
        let unread = TaskManager.rows(tasks: [.init(kind: .tab, name: "A", pid: 5)], samples: [5: .init(footprintBytes: 0, cpuSeconds: 0)])
        #expect(unread[0][.fileDescriptors] == "N/A")
        #expect(unread[0][.idleWakeups] == "0")
    }
}
