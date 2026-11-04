#if canImport(Darwin)
import Darwin
import Foundation
import Testing
@testable import KiteCore

/// Stand-ins for `claude`, written to a folder of the test's own and run by absolute path: the real
/// Claude Code is never looked up or started.
@Suite struct OneShotProcessTests {
    private func makeTool(_ body: String) throws -> (tool: String, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kite-oneshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tool = folder.appendingPathComponent("fake-claude")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        return (tool.path, folder)
    }

    /// Whether the background job the tool wrote to `pid` is still alive.
    private func childAlive(in folder: URL) throws -> Bool {
        let text = try String(contentsOf: folder.appendingPathComponent("pid"), encoding: .utf8)
        let pid = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        // A killed orphan answers kill(0) until launchd reaps it: give that a moment.
        for _ in 0..<40 where kill(pid, 0) == 0 { usleep(50_000) }
        return kill(pid, 0) == 0
    }

    @Test func passesInputAndReadsTheReply() throws {
        let (tool, folder) = try makeTool("printf 'got: '; cat; exit 3")
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = OneShotProcess(executable: tool, arguments: [], directory: folder).run(input: Data("hello".utf8), timeout: 10)
        #expect(result == OneShotProcess.Result(status: 3, output: Data("got: hello".utf8)))
    }

    @Test func runsInTheGivenFolderWithTheGivenEnvironment() throws {
        let (tool, folder) = try makeTool("printf '%s|%s' \"$KITE_TEST_VALUE\" \"$(pwd -P)\"")
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = OneShotProcess(executable: tool, arguments: [], environment: ["KITE_TEST_VALUE": "x"],
                                    directory: folder).run(input: Data(), timeout: 10)
        // pwd -P says /private/var for /var.
        let reply = try #require(result.map { String(decoding: $0.output, as: UTF8.self) })
        #expect(reply.hasPrefix("x|/") && reply.hasSuffix("/" + folder.lastPathComponent))
    }

    /// The bug: Process.terminate() at the timeout killed only the tool, and the `sleep` it left holding
    /// stdout kept readDataToEndOfFile() blocked for good.
    @Test func aTimeoutEndsTheToolAndAnythingHoldingItsOutput() throws {
        let (tool, folder) = try makeTool("sleep 999 &\necho $! > pid\necho partial\nsleep 999")
        defer { try? FileManager.default.removeItem(at: folder) }
        let start = Date()
        let result = OneShotProcess(executable: tool, arguments: [], directory: folder).run(input: Data(), timeout: 0.5)
        #expect(result == nil)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(try !childAlive(in: folder))
    }

    @Test func aToolThatExitsLeavingAChildOnItsOutputStillAnswers() throws {
        let (tool, folder) = try makeTool("sleep 999 &\necho $! > pid\necho done")
        defer { try? FileManager.default.removeItem(at: folder) }
        let start = Date()
        let result = OneShotProcess(executable: tool, arguments: [], directory: folder).run(input: Data(), timeout: 30)
        #expect(result == OneShotProcess.Result(status: 0, output: Data("done\n".utf8)))
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(try !childAlive(in: folder))
    }

    /// A descendant that left the group (setsid) can't be ended with it; a tool that exited 0 still
    /// answers with what it wrote, once the grace is up.
    @Test func anEscapedChildOnTheOutputDoesNotLoseTheReply() throws {
        let (tool, folder) = try makeTool(
            "perl -MPOSIX -e 'POSIX::setsid(); open(F, \">pid\"); print F $$; close(F); exec(\"sleep\", \"999\")' &\n"
                + "while [ ! -s pid ]; do sleep 0.05; done\necho answer")
        defer {
            if let text = try? String(contentsOf: folder.appendingPathComponent("pid"), encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(at: folder)
        }
        let start = Date()
        let result = OneShotProcess(executable: tool, arguments: [], directory: folder).run(input: Data(), timeout: 30)
        #expect(result == OneShotProcess.Result(status: 0, output: Data("answer\n".utf8)))
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func aBigInputAndOutputDoNotDeadlock() throws {
        let (tool, folder) = try makeTool("cat")
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = Data((0..<2_000_000).map { UInt8($0 % 251) })
        let result = OneShotProcess(executable: tool, arguments: [], directory: folder).run(input: input, timeout: 30)
        #expect(result?.status == 0)
        #expect(result?.output == input)
    }

    @Test func cancellingTheTaskEndsAnAsyncRun() async throws {
        let (tool, folder) = try makeTool("sleep 999 &\necho $! > pid\nsleep 999")
        defer { try? FileManager.default.removeItem(at: folder) }
        let process = OneShotProcess(executable: tool, arguments: [], directory: folder)
        let start = Date()
        let task = Task { await process.run(input: Data(), timeout: 30) }
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()
        #expect(await task.value == nil)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(try !childAlive(in: folder))
    }

    @Test func cancelEndsTheRun() throws {
        let (tool, folder) = try makeTool("sleep 999 &\necho $! > pid\nsleep 999")
        defer { try? FileManager.default.removeItem(at: folder) }
        let process = OneShotProcess(executable: tool, arguments: [], directory: folder)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { process.cancel() }
        let start = Date()
        #expect(process.run(input: Data(), timeout: 30) == nil)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(try !childAlive(in: folder))
    }

    @Test func aMissingToolIsNil() {
        #expect(OneShotProcess(executable: "/nonexistent/claude", arguments: []).run(input: Data(), timeout: 1) == nil)
    }
}
#endif
