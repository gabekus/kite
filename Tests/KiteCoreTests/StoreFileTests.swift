import Foundation
import Testing
@testable import KiteCore

@Suite struct StoreFileTests {
    /// The tests that make a file impossible to move or copy do it with a read-only folder (chmod 0500).
    #if os(Windows)
    static let readOnlyFoldersWork = false
    #else
    static let readOnlyFoldersWork = true
    #endif

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
        let load = StoreFile.load([String].self, from: folder.appendingPathComponent("none.json"))
        guard case .missing = load else { Issue.record("expected .missing, got \(load)"); return }
        #expect(load.maySave)
        #expect(try backups(in: folder).isEmpty)
    }

    @Test func aCorruptTaskListIsKeptAside() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("tasks.json")
        try Data("{\"tasks\": [ not json".utf8).write(to: url)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let load = ClaudeTaskList.load(from: url, now: now)
        guard case .setAside(let backup) = load else { Issue.record("expected .setAside, got \(load)"); return }
        // Moved aside before anything could save over it, with what was in it, under the stamped name.
        #expect(backup.lastPathComponent == "tasks.corrupt-1800000000.json")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try String(contentsOf: backup, encoding: .utf8) == "{\"tasks\": [ not json")
        // The next save starts a new file and leaves the copy alone.
        try ClaudeTaskList(tasks: [ClaudeTask(goal: "New")]).save(to: url)
        #expect(try backups(in: folder).count == 1)
    }

    @Test(.enabled(if: Self.readOnlyFoldersWork, "Windows ignores a folder's POSIX permissions"))
    func aFileThatCannotBeMovedIsNeverSavedOver() throws {
        let folder = try makeFolder()
        let url = folder.appendingPathComponent("tasks.json")
        try Data("garbage".utf8).write(to: url)
        // A folder Kite can't write in: the file can't be moved aside.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }

        let load = ClaudeTaskList.load(from: url)
        guard case .unmovable = load else { Issue.record("expected .unmovable, got \(load)"); return }
        #expect(!load.maySave)
        #expect(StoreFile.isProtected(url))
        // Even once the folder is writable again, this run doesn't save over the only copy.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        #expect(throws: (any Error).self) { try ClaudeTaskList(tasks: [ClaudeTask(goal: "New")]).save(to: url) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "garbage")
    }

    @Test func anUnknownEntryKindDecodesAndTheFileIsCopied() throws {
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

        let load = ClaudeTaskList.load(from: url)
        guard case .loaded(let list, let lenient) = load else { Issue.record("expected .loaded, got \(load)"); return }
        #expect(lenient == 2)
        #expect(list.tasks.count == 1)
        #expect(list.tasks.first?.entries.map(\.kind) == [.user, .note])
        #expect(list.tasks.first?.status == .stopped)
        // Saving writes the lenient reading back: the newer build's file is kept as it was.
        let kept = try backups(in: folder)
        #expect(kept.count == 1)
        #expect(try String(contentsOf: kept[0], encoding: .utf8) == text)
        #expect(FileManager.default.fileExists(atPath: url.path))
        // A relaunch before any save doesn't make another copy of the same file.
        _ = ClaudeTaskList.load(from: url, now: Date().addingTimeInterval(60))
        #expect(try backups(in: folder).count == 1)
    }

    @Test(.enabled(if: Self.readOnlyFoldersWork, "Windows ignores a folder's POSIX permissions"))
    func aLenientReadThatCannotBeCopiedIsNeverSavedOver() throws {
        let folder = try makeFolder()
        let url = folder.appendingPathComponent("routes.json")
        let text = "{\"spaces\": {\"\(UUID().uuidString)\": {\"agent\": {}}}, \"projects\": []}"
        try Data(text.utf8).write(to: url)
        // A folder Kite can't write in: no copy of the newer build's file can be kept.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }

        let load = StoreFile.load(ClaudeRoutes.self, from: url)
        guard case .loaded(_, let lenient) = load else { Issue.record("expected .loaded, got \(load)"); return }
        #expect(lenient == 1)
        #expect(StoreFile.isProtected(url))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        #expect(throws: (any Error).self) { try ClaudeRoutes().save(to: url) }
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
    }

    @Test func aCleanFileMakesNoCopy() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("tasks.json")
        try ClaudeTaskList(tasks: [ClaudeTask(goal: "One")]).save(to: url)
        let load = ClaudeTaskList.load(from: url)
        guard case .loaded(_, let lenient) = load else { Issue.record("expected .loaded, got \(load)"); return }
        #expect(lenient == 0)
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

        let load = ClaudeTaskList.load(from: url)
        guard case .loaded(let list, let lenient) = load else { Issue.record("expected .loaded, got \(load)"); return }
        #expect(list.tasks.map(\.title) == ["One"])
        #expect(lenient == 1)
        // The original stays where it was, and a copy of it is kept for the task that was left out.
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try backups(in: folder).count == 1)
    }

    @Test func anUnknownRouteFallsBackToANewChatAndTheFileIsCopied() throws {
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
        #expect(try backups(in: folder).count == 1)
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

    @Test func aHandoffThatDoesNotDecodeIsLeftOutAndTheFileCopied() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = Handoff.fileURL(supportDirectory: folder)
        try Data("[{\"id\": 7}]".utf8).write(to: url)
        #expect(Handoff.load(from: url).isEmpty)
        // The list itself decoded, so the file stays where it is, with a copy for the handoff left out.
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try backups(in: folder).count == 1)
    }

    @Test func twoBackupsInOneSecondDoNotCollide() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("x.json")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try Data("1".utf8).write(to: url)
        let first = StoreFile.setAside(url, now: now)
        try Data("2".utf8).write(to: url)
        let second = StoreFile.setAside(url, now: now)
        #expect(first?.lastPathComponent == "x.corrupt-1800000000.json")
        #expect(second?.lastPathComponent == "x.corrupt-1800000000-2.json")
        #expect(try backups(in: folder).count == 2)
    }
}
