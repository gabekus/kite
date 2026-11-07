import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Which process serves an automation socket: its PID, app and start time, read from the socket itself
/// (`LOCAL_PEERPID`), so a stale or test build answering on the real profile's socket is named at once.
public struct SocketServerProcess: Equatable, Sendable {
    public var pid: Int32
    /// The executable, e.g. /Applications/Kite.app/Contents/MacOS/Kite.
    public var executablePath: String?
    /// The .app the executable is in, if any.
    public var bundlePath: String?
    public var bundleID: String?
    /// CFBundleVersion.
    public var build: String?
    public var startedAt: Date?

    public init(pid: Int32, executablePath: String?, bundlePath: String? = nil, bundleID: String? = nil,
                build: String? = nil, startedAt: Date? = nil) {
        self.pid = pid
        self.executablePath = executablePath
        self.bundlePath = bundlePath ?? executablePath.flatMap(Self.bundlePath(ofExecutable:))
        self.bundleID = bundleID
        self.build = build
        self.startedAt = startedAt
    }

    /// The .app around an executable at `Contents/MacOS/<name>`.
    public static func bundlePath(ofExecutable path: String) -> String? {
        let macOS = (path as NSString).deletingLastPathComponent
        let contents = (macOS as NSString).deletingLastPathComponent
        guard (macOS as NSString).lastPathComponent == "MacOS", (contents as NSString).lastPathComponent == "Contents" else {
            return nil
        }
        let bundle = (contents as NSString).deletingLastPathComponent
        return bundle.hasSuffix(".app") ? bundle : nil
    }

    /// Whether it's the installed Kite (see `RealProfileGuard`).
    public func isInstalledKite(home: String = NSHomeDirectory()) -> Bool {
        RealProfileGuard.isInstalledKite(bundleID: bundleID, bundlePath: bundlePath, home: home)
    }

    /// "PID 651 (/Users/gabe/dev/kite-perf/build/baseline.app, dev.gabek.Kite.dev build 1231, started 2026-11-05 17:12:03)".
    public var summary: String {
        var details = [bundlePath ?? executablePath ?? "unknown executable"]
        if let bundleID { details.append(build.map { "\(bundleID) build \($0)" } ?? bundleID) }
        if let startedAt { details.append("started \(Self.format(startedAt))") }
        return "PID \(pid) (\(details.joined(separator: ", ")))"
    }

    /// The warning the CLI, `kite mcp` and Kite give when the real profile's socket isn't served by the installed Kite.
    public var notInstalledWarning: String {
        "Warning: Kite's automation socket is served by \(summary), not /Applications/Kite.app. Every Kite tool is "
            + "talking to that build, not the user's Kite: its tools, tabs and sign-ins may be different or missing. "
            + "Tell the user to quit it (kill \(pid)) and reopen /Applications/Kite.app."
    }

    static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    #if canImport(Darwin)
    /// The process at the other end of a connected Unix socket.
    public static func peerPID(of socket: Int32) -> Int32? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return nil }
        return pid
    }

    /// What's known about a running process; nil if it's gone.
    public static func lookup(pid: Int32) -> SocketServerProcess? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let executable = proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let started = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size
            ? Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
            : nil
        guard executable != nil || started != nil else { return nil }
        var process = SocketServerProcess(pid: pid, executablePath: executable, startedAt: started)
        if let bundle = process.bundlePath,
           let plist = NSDictionary(contentsOfFile: (bundle as NSString).appendingPathComponent("Contents/Info.plist")) {
            process.bundleID = plist["CFBundleIdentifier"] as? String
            process.build = plist["CFBundleVersion"] as? String
        }
        return process
    }

    /// Connects to the socket at `path` and asks who accepted. Nil when nothing answers there.
    public static func serving(socketPath path: String) -> SocketServerProcess? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return nil }
        defer { close(probe) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0, let pid = peerPID(of: probe) else { return nil }
        return lookup(pid: pid) ?? SocketServerProcess(pid: pid, executablePath: nil)
    }
    #endif
}
