import Foundation

/// Asks a login shell what Kite can't see as a GUI app: its PATH, and where `claude` is. The script
/// writes its answer to the file in `$1`, and the shell's stdin, stdout and stderr are /dev/null. So
/// a background job the startup files (.zshenv, .zprofile, .zlogin) leave running, like `nohup x &`,
/// neither holds a pipe open nor gets killed: only the shell itself is ended, and only when it runs
/// past the timeout.
public enum LoginShellProbe {
    /// How long a login shell may take before Kite gives up on it for now.
    public static let timeout: TimeInterval = 30

    /// One shell for both questions: the PATH on the first line, `command -v claude` (if any) on the next.
    public static let script = #"{ printf '%s\n' "$PATH"; command -v claude || true; } > "$1""#

    public enum Outcome: Equatable, Sendable {
        /// What the script wrote (it exited 0 and wrote something).
        case answer(String)
        /// It exited non-zero, wrote nothing or couldn't start.
        case noAnswer
        /// It ran past the timeout.
        case timedOut
    }

    /// What the shell said. A nil field is one it didn't answer.
    public struct Answers: Equatable, Sendable {
        public var path: String?
        public var claude: String?

        public init(path: String? = nil, claude: String? = nil) {
            self.path = path
            self.claude = claude
        }

        /// `script`'s output: a PATH with a `/` in it, then an absolute `claude`.
        public init(_ output: String) {
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            path = lines.first.flatMap { $0.contains("/") ? $0 : nil }
            claude = lines.dropFirst().first.flatMap { $0.hasPrefix("/") ? $0 : nil }
        }
    }

    public static func run(_ script: String = script, shell: String = "/bin/zsh", flags: [String] = ["-lc"],
                           timeout: TimeInterval = timeout) -> Outcome {
        let answer = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kite-shell-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: answer) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = flags + [script, "kite-shell-probe", answer.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return .noAnswer }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return .timedOut
        }
        guard process.terminationStatus == 0, let data = try? Data(contentsOf: answer), !data.isEmpty else { return .noAnswer }
        return .answer(String(decoding: data, as: UTF8.self))
    }
}

/// The login shell's answers, asked once at a time (single flight: callers that come while a probe
/// runs await that one, and no thread is held waiting) and kept only when they came back. A PATH or
/// `claude` the shell didn't give is asked again `retryInterval` after the last try, or right away
/// after `invalidate` (an install just ran). So a slow or failing shell at launch never leaves
/// every later `claude` on launchd's bare PATH.
public final class LoginShellCache: @unchecked Sendable {
    public static let retryInterval: TimeInterval = 60

    public struct Snapshot: Equatable, Sendable {
        public var answers: LoginShellProbe.Answers
        /// The last probe ran past its timeout: a missing `claude` is unknown, not absent.
        public var timedOut: Bool
    }

    private let probe: @Sendable () -> LoginShellProbe.Outcome
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var known = LoginShellProbe.Answers()
    private var lastTry: Date?
    private var timedOut = false
    private var running: Task<Snapshot, Never>?

    public init(probe: @escaping @Sendable () -> LoginShellProbe.Outcome = { LoginShellProbe.run() },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.probe = probe
        self.now = now
    }

    /// The answers, probing first when one is missing and it's time to try again.
    public func snapshot() async -> Snapshot {
        switch next() {
        case .ready(let snapshot): return snapshot
        case .wait(let task): return await task.value
        }
    }

    private enum Next {
        case ready(Snapshot)
        case wait(Task<Snapshot, Never>)
    }

    /// What `snapshot` does now: answer from what's known, or wait for the probe (starting it if none runs).
    private func next() -> Next {
        lock.lock()
        defer { lock.unlock() }
        if let running { return .wait(running) }
        if (known.path != nil && known.claude != nil)
            || lastTry.map({ now().timeIntervalSince($0) < Self.retryInterval }) == true {
            return .ready(Snapshot(answers: known, timedOut: timedOut))
        }
        let probe = probe
        let task = Task.detached { [weak self] in
            let outcome = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: probe()) }
            }
            return self?.finish(outcome) ?? Snapshot(answers: LoginShellProbe.Answers(), timedOut: false)
        }
        running = task
        return .wait(task)
    }

    /// Starts a probe in the background (at launch), so the first `claude` doesn't wait for it.
    public func warm() {
        Task.detached { [self] in _ = await snapshot() }
    }

    /// Forgets when it last asked, so the next `snapshot` asks again (after an install).
    public func invalidate() {
        lock.lock()
        lastTry = nil
        lock.unlock()
    }

    private func finish(_ outcome: LoginShellProbe.Outcome) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        if case .answer(let output) = outcome {
            let answers = LoginShellProbe.Answers(output)
            known.path = answers.path ?? known.path
            known.claude = answers.claude ?? known.claude
        }
        timedOut = outcome == .timedOut
        lastTry = now()
        running = nil
        return Snapshot(answers: known, timedOut: timedOut)
    }
}
