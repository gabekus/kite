import Foundation
import Testing
@testable import KiteCore

@Suite struct StoreFileTests {
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kite-storefile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func backups(in folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".corrupt-") }
    }

    @Test func aMissingFileIsNotAnError() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(StoreFile.load([String].self, from: folder.appendingPathComponent("none.json")) == nil)
        #expect(try backups(in: folder).isEmpty)
    }

    @Test func aCorruptTaskListIsKeptAside() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("tasks.json")
        try Data("{\"tasks\": [ not json".utf8).write(to: url)

        #expect(ClaudeTaskList.load(from: url).tasks.isEmpty)
        // Moved aside before anything could save over it, with what was in it.
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let kept = try backups(in: folder)
        #expect(kept.count == 1)
        #expect(try String(contentsOf: kept[0], encoding: .utf8) == "{\"tasks\": [ not json")
        // The next save starts a new file and leaves the copy alone.
        try ClaudeTaskList(tasks: [ClaudeTask(goal: "New")]).save(to: url)
        #expect(try backups(in: folder).count == 1)
    }

    @Test func anUnknownEntryKindDoesNotFailTheList() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("tasks.json")
        var task = ClaudeTask(goal: "Find a flight")
        task.append(ClaudeTask.Entry(.tool, "read_page"))
        task.status = .done
        try ClaudeTaskList(tasks: [task]).save(to: url)
        // As a newer build might write it: an entry kind and a status this one doesn't know.
        let text = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\"kind\":\"tool\"", with: "\"kind\":\"thinking\"")
            .replacingOccurrences(of: "\"status\":\"done\"", with: "\"status\":\"paused\"")
        try Data(text.utf8).write(to: url)

        let list = ClaudeTaskList.load(from: url)
        #expect(list.tasks.count == 1)
        #expect(list.tasks.first?.entries.map(\.kind) == [.user, .note])
        #expect(list.tasks.first?.status == .stopped)
        #expect(try backups(in: folder).isEmpty)
    }

    @Test func aTaskThatDoesNotDecodeIsDroppedAndTheFileCopied() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("tasks.json")
        try ClaudeTaskList(tasks: [ClaudeTask(goal: "One"), ClaudeTask(goal: "Two")]).save(to: url)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var tasks = try #require(json["tasks"] as? [[String: Any]])
        tasks[1]["id"] = 42
        json["tasks"] = tasks
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let list = ClaudeTaskList.load(from: url)
        #expect(list.tasks.map(\.title) == ["One"])
        #expect(list.dropped == 1)
        // The original stays where it was, and a copy of it is kept for the task that was left out.
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try backups(in: folder).count == 1)
    }

    @Test func anUnknownRouteFallsBackToANewChat() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("routes.json")
        let a = UUID(), b = UUID()
        var routes = ClaudeRoutes()
        routes.set(.folder(path: "/tmp/project"), for: a)
        routes.set(.folder(path: "/tmp/other"), for: b)
        try routes.save(to: url)
        // A route kind from a newer build replaces b's.
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var spaces = try #require(json["spaces"] as? [String: Any])
        #expect(spaces[b.uuidString] != nil)
        spaces[b.uuidString] = ["agent": ["name": "x"]]
        json["spaces"] = spaces
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let loaded = ClaudeRoutes.load(from: url)
        #expect(loaded.route(for: a) == .folder(path: "/tmp/project"))
        #expect(loaded.route(for: b) == .newChat)
    }

    @Test func corruptRoutesAreKeptAside() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("routes.json")
        try Data("[]".utf8).write(to: url)
        #expect(ClaudeRoutes.load(from: url) == ClaudeRoutes())
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try backups(in: folder).count == 1)
    }

    @Test func corruptHandoffsAreKeptAside() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = Handoff.fileURL(supportDirectory: folder)
        try Data("[{\"id\": ".utf8).write(to: url)
        #expect(Handoff.load(from: url).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try backups(in: folder).count == 1)
    }

    @Test func aHandoffThatDoesNotDecodeIsLeftOut() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = Handoff.fileURL(supportDirectory: folder)
        try Data("[{\"id\": 7}]".utf8).write(to: url)
        #expect(Handoff.load(from: url).isEmpty)
        // The list itself decoded, so the file stays where it is.
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func twoBackupsInOneSecondDoNotCollide() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("x.json")
        let now = Date()
        try Data("1".utf8).write(to: url)
        let first = StoreFile.setAside(url, now: now)
        try Data("2".utf8).write(to: url)
        let second = StoreFile.setAside(url, now: now)
        #expect(first != nil && second != nil && first != second)
        #expect(try backups(in: folder).count == 2)
    }
}
