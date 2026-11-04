import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One run of a command-line tool that reads its input, answers on stdout and exits: Claude Code's
/// `claude -p` for Tidy Tab Titles, Tidy Downloads and link preview summaries.
///
/// A tool can leave children behind that inherited its stdout (an MCP server, a shell's background
/// job). Killing only the tool leaves them holding the pipe open, and a read to its end blocks for
/// good. So on macOS the tool runs in a process group of its own, which is ended whole once the run is
/// over (by its exit, the deadline or `cancel`), and the pipes are read and written with `poll`
/// against the deadline on the calling thread: `run` returns by the deadline, give or take a poll
/// tick, whatever the tool or anything it started does.
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
    /// The running tool's process group (its pid), while it's reserved: cleared before the tool is
    /// reaped, so `cancel` can never signal a recycled group.
    private var group: Int32 = 0
    private var cancelled = false

    /// How long the pipe may stay open once the tool has exited, for its last output to arrive, before
    /// the run ends with what was read.
    public static let exitGrace: TimeInterval = 1

    public init(executable: String, arguments: [String], environment: [String: String]? = nil, directory: URL? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
    }

    /// Runs the tool with `input` on stdin, blocking this thread. Nil when it couldn't start, was
    /// cancelled or ran past `timeout`. A tool that exited 0 answers with what it wrote, even when
    /// something it started still holds the pipe.
    public func run(input: Data, timeout: TimeInterval) -> Result? {
        #if canImport(Darwin)
        return runSpawned(input: input, timeout: timeout)
        #else
        return runWithProcess(input: input, timeout: timeout)
        #endif
    }

    /// `run` off the cooperative pool; cancelling the task ends the run.
    public func run(input: Data, timeout: TimeInterval) async -> Result? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: self.run(input: input, timeout: timeout))
                }
            }
        } onCancel: {
            cancel()
        }
    }

    /// Ends the run (and, on macOS, everything it started); `run` returns nil.
    public func cancel() {
        lock.lock()
        cancelled = true
        #if canImport(Darwin)
        let group = group
        if group > 0 { killpg(group, SIGKILL) }
        lock.unlock()
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
        let deadline = Date().addingTimeInterval(timeout)
        var inPipe: [Int32] = [-1, -1], outPipe: [Int32] = [-1, -1]
        guard pipe(&inPipe) == 0 else { return nil }
        guard pipe(&outPipe) == 0 else {
            close(inPipe[0]); close(inPipe[1])
            return nil
        }
        // Nothing else Kite starts meanwhile inherits them (the child gets its own copies on 0 and 1).
        for fd in inPipe + outPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

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
        // Its own process group (pgid = its pid), none of Kite's other files open in it, and signals as a
        // fresh process has them.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignals = sigset_t(), allSignals = sigset_t()
        sigemptyset(&noSignals)
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)

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
        if cancelled { killpg(pid, SIGKILL) }
        lock.unlock()

        var writeFD: Int32 = inPipe[1], readFD: Int32 = outPipe[0]
        // A tool that stops reading mustn't take Kite down with SIGPIPE.
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
        for fd in [writeFD, readFD] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        func closeWrite() { if writeFD >= 0 { close(writeFD); writeFD = -1 } }
        func closeRead() { if readFD >= 0 { close(readFD); readFD = -1 } }
        if input.isEmpty { closeWrite() }

        var output = Data()
        var written = 0
        var exitedAt: Date?
        var timedOut = false
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if exitedAt == nil, Self.hasExited(pid) { exitedAt = Date() }
            if readFD < 0, exitedAt != nil { break }
            let now = Date()
            if now >= deadline { timedOut = true; break }
            // Exited with the pipe still open: something it started holds it. Take what came.
            if let exitedAt, now.timeIntervalSince(exitedAt) >= Self.exitGrace { break }
            if isCancelled { break }

            var fds: [pollfd] = []
            if readFD >= 0 { fds.append(pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)) }
            if writeFD >= 0 { fds.append(pollfd(fd: writeFD, events: Int16(POLLOUT), revents: 0)) }
            // A short tick, to notice the tool exiting and the deadline passing.
            let tick = Int32(max(1, min(50, deadline.timeIntervalSince(now) * 1000)))
            if fds.isEmpty { usleep(useconds_t(tick) * 1000); continue }
            guard poll(&fds, nfds_t(fds.count), tick) >= 0 || errno == EINTR else { break }
            for entry in fds where entry.revents != 0 {
                if entry.fd == readFD {
                    while true {
                        let n = read(readFD, &chunk, chunk.count)
                        if n > 0 { output.append(contentsOf: chunk[0..<n]); continue }
                        if n < 0, errno == EINTR { continue }
                        if n < 0, errno == EAGAIN { break }
                        closeRead()  // the end of the pipe, or an error
                        break
                    }
                } else if entry.fd == writeFD {
                    if entry.revents & Int16(POLLOUT) == 0 { closeWrite(); continue }  // POLLHUP / POLLERR
                    let n = input.withUnsafeBytes { buffer in
                        write(writeFD, buffer.baseAddress! + written, buffer.count - written)
                    }
                    if n > 0 { written += n } else if n < 0, errno == EINTR || errno == EAGAIN { continue } else { closeWrite() }
                    if written >= input.count { closeWrite() }
                }
            }
        }
        closeWrite()
        closeRead()

        // End whatever is left in the group while the unreaped tool still reserves its id, then let the
        // id go before reaping, so a late `cancel` can't reach a recycled group.
        lock.lock()
        killpg(pid, SIGKILL)
        group = 0
        let wasCancelled = cancelled
        lock.unlock()
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        guard !timedOut, !wasCancelled else { return nil }
        // WIFEXITED / WEXITSTATUS; a signal reads as 128 + its number, as a shell reports it.
        let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return Result(status: code, output: output)
    }

    /// Whether the tool has exited, without reaping it: an unreaped tool keeps its process group's id
    /// reserved for the final `killpg`.
    private static func hasExited(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 else { return true }
        return info.si_pid == pid
    }
    #else
    // TODO(Windows): run the tool in a Job Object and close the job at the deadline, so its children end
    // with it. Until then only the tool itself is terminated, and the read can strand a thread.
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

#if !canImport(Darwin)
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    var data: Data {
        get { lock.lock(); defer { lock.unlock() }; return bytes }
        set { lock.lock(); bytes = newValue; lock.unlock() }
    }
}
#endif
