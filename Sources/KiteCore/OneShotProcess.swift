import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One run of a command-line tool that reads its input, answers on stdout and exits: Claude Code's
/// `claude -p` for Tidy Tab Titles, Tidy Downloads and link preview summaries.
///
/// A tool can leave children behind that inherited its stdout (an MCP server, a shell's background
/// job). Killing only the tool leaves them holding the pipe open, and a read to its end blocks for
/// good. So on macOS the tool runs in a process group of its own, and the deadline, `cancel` or the
/// tool exiting with children still on the pipe ends the whole group; the read gives up at the
/// deadline whatever happens.
public final class OneShotProcess: @unchecked Sendable {
    public struct Result: Sendable, Equatable {
        public let status: Int32
        public let output: Data
    }

    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]?
    private let directory: URL?
    private let lock = NSLock()
    private var group: Int32 = 0
    private var cancelled = false

    /// How long the pipe may stay open once the tool has exited, for its last output to arrive, before
    /// anything left in its group is ended.
    public static let exitGrace: TimeInterval = 1

    public init(executable: String, arguments: [String], environment: [String: String]? = nil, directory: URL? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
    }

    /// Runs the tool with `input` on stdin. Nil when it couldn't start, was cancelled or ran past `timeout`.
    public func run(input: Data, timeout: TimeInterval) -> Result? {
        #if canImport(Darwin)
        return runSpawned(input: input, timeout: timeout)
        #else
        return runWithProcess(input: input, timeout: timeout)
        #endif
    }

    /// Ends the run (and, on macOS, everything it started); `run` returns nil.
    public func cancel() {
        lock.lock()
        cancelled = true
        #if canImport(Darwin)
        let group = group
        lock.unlock()
        if group > 0 { killpg(group, SIGKILL) }
        #else
        let stop = cancelProcess
        lock.unlock()
        stop?()
        #endif
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    #if canImport(Darwin)
    private func runSpawned(input: Data, timeout: TimeInterval) -> Result? {
        let deadline = DispatchTime.now() + timeout
        var inPipe: [Int32] = [-1, -1], outPipe: [Int32] = [-1, -1]
        guard pipe(&inPipe) == 0 else { return nil }
        guard pipe(&outPipe) == 0 else {
            close(inPipe[0]); close(inPipe[1])
            return nil
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        if let directory { posix_spawn_file_actions_addchdir_np(&actions, directory.path) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own process group (pgid = its pid), and none of Kite's other files open in it.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let env = (environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            env.forEach { free($0) }
        }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, env)
        close(inPipe[0])
        close(outPipe[1])
        guard spawned == 0 else {
            close(inPipe[1]); close(outPipe[0])
            return nil
        }
        lock.lock()
        group = pid
        let cancelledEarly = cancelled
        lock.unlock()
        if cancelledEarly { killpg(pid, SIGKILL) }

        // A tool that stops reading mustn't take Kite down with SIGPIPE.
        _ = fcntl(inPipe[1], F_SETNOSIGPIPE, 1)
        let writeFD = inPipe[1], readFD = outPipe[0]
        DispatchQueue.global(qos: .userInitiated).async {
            input.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let n = write(writeFD, buffer.baseAddress! + offset, buffer.count - offset)
                    if n > 0 { offset += n } else if n < 0, errno == EINTR { continue } else { break }
                }
            }
            close(writeFD)
        }

        let output = OutputBox()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(readFD, &chunk, chunk.count)
                if n > 0 { output.append(chunk, count: n) } else if n < 0, errno == EINTR { continue } else { break }
            }
            close(readFD)
            readDone.signal()
        }

        let exited = DispatchSemaphore(value: 0)
        let exitStatus = OutputBox()
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            exitStatus.status = status
            exited.signal()
        }

        var timedOut = false
        if exited.wait(timeout: deadline) == .timedOut {
            timedOut = true
            killpg(pid, SIGKILL)
            exited.wait()
        }
        // Exited, but something it started may still hold stdout: give the last output a moment, then end
        // the group so the read sees the end of the pipe.
        if readDone.wait(timeout: .now() + Self.exitGrace) == .timedOut {
            killpg(pid, SIGKILL)
            if readDone.wait(timeout: .now() + Self.exitGrace) == .timedOut {
                // Something left the group and kept the pipe: leave the reader to it.
                timedOut = true
            }
        }
        lock.lock()
        group = 0
        let wasCancelled = cancelled
        lock.unlock()
        guard !timedOut, !wasCancelled else { return nil }
        let status = exitStatus.status
        // WIFEXITED / WEXITSTATUS; a signal reads as 128 + its number, as a shell reports it.
        let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return Result(status: code, output: output.data)
    }
    #else
    private var cancelProcess: (() -> Void)?

    private func runWithProcess(input: Data, timeout: TimeInterval) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        lock.lock()
        cancelProcess = { if process.isRunning { process.terminate() } }
        lock.unlock()
        DispatchQueue.global().async {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }
        let output = OutputBox()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            output.data = stdout.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }
        var timedOut = false
        if readDone.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            if process.isRunning { process.terminate() }
            _ = readDone.wait(timeout: .now() + Self.exitGrace)
        }
        guard !timedOut, !isCancelled else { return nil }
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: output.data)
    }
    #endif
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var exit: Int32 = 0

    var data: Data {
        get { lock.lock(); defer { lock.unlock() }; return bytes }
        set { lock.lock(); bytes = newValue; lock.unlock() }
    }

    var status: Int32 {
        get { lock.lock(); defer { lock.unlock() }; return exit }
        set { lock.lock(); exit = newValue; lock.unlock() }
    }

    func append(_ chunk: [UInt8], count: Int) {
        lock.lock()
        bytes.append(contentsOf: chunk[0..<count])
        lock.unlock()
    }
}
