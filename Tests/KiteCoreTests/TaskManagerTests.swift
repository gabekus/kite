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
        #expect(rows[4].cells == ["Tab: C", "", "", "N/A", ""])
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
}
