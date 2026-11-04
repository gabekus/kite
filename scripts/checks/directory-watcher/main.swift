import Foundation

// Checks DirectoryWatcher (Sources/KiteMac/DirectoryWatcher.swift) outside Kite: an append to a nested
// file calls back with its path, a watched folder that doesn't exist yet (reached through /tmp, a
// symlink to /private/tmp) is picked up when it appears, and nothing comes after stop().
// Run with scripts/checks/directory-watcher.sh.

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let projects = root.appendingPathComponent(".claude/projects", isDirectory: true)
let folder = projects.appendingPathComponent("-tmp-x", isDirectory: true)
try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let file = folder.appendingPathComponent("8c0f6b7e-1d2a-4b3c-9d4e-5f6a7b8c9d0e.jsonl")
FileManager.default.createFile(atPath: file.path, contents: Data("{}\n".utf8))
let missing = root.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)

func append(_ url: URL) {
    let handle = try! FileHandle(forWritingTo: url)
    handle.seekToEndOfFile()
    handle.write(Data("{}\n".utf8))
    try! handle.close()
}

nonisolated(unsafe) var seen: [String] = []
nonisolated(unsafe) var failures = 0
func expect(_ ok: Bool, _ what: String) {
    print(ok ? "ok   \(what)" : "FAIL \(what)")
    if !ok { failures += 1 }
}

MainActor.assumeIsolated {
    let watcher = DirectoryWatcher(paths: [projects, missing], latency: 0.2) { paths in seen += paths }!
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        seen = []
        append(file)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
        expect(seen.contains { $0.hasSuffix(file.lastPathComponent) }, "an append to a nested transcript is reported with its path")
        seen = []
        try! FileManager.default.createDirectory(at: missing.appendingPathComponent("account"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: missing.appendingPathComponent("account/local_1.json").path, contents: Data("{}".utf8))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
        expect(seen.contains { $0.hasSuffix("local_1.json") }, "a folder made after the stream started is watched")
        watcher.stop()
        seen = []
        append(file)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.8) {
        expect(seen.isEmpty, "nothing after stop()")
        exit(failures == 0 ? 0 : 1)
    }
}
dispatchMain()
