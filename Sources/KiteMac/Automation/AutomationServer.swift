import Darwin
import Foundation
import KiteCore

/// The automation socket: a Unix domain socket in the profile, never a network
/// port. Its folder is 0700 and the socket 0600, and each connection's peer
/// must be the same user, so only this user's own processes (the `kite` CLI)
/// can reach it. One JSON request per line in, one response per line out.
///
/// Nothing here blocks: sockets stay non-blocking, and what the main thread asks
/// (`isListening`, `ownsSocketFile`, `stop`) never waits on `queue`, so a client
/// that stops reading can't stall Kite.
final class AutomationServer: @unchecked Sendable {
    /// `received` is when the request's line arrived (`TraceClock.monotonic`), for the trace's queue phase.
    typealias Handler = @Sendable (AutomationWire.Request, _ connection: Int, _ received: Double) async -> ToolOutput

    let socketURL: URL
    private let handler: Handler
    private let onDisconnect: @Sendable (Int) -> Void
    private let queue = DispatchQueue(label: "dev.gabek.Kite.automation")
    /// Guards `listenFD`, `boundFile` and `listenSource`, which the main thread reads and `stop()` clears. Never
    /// held across a write or a wait on `queue`.
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    /// The socket file this server bound (device and inode), so it only ever deletes its own.
    private var boundFile: (dev: dev_t, ino: ino_t)?
    private var listenSource: DispatchSourceRead?
    /// On `queue`.
    private var connections: [Int: Connection] = [:]
    /// Connection ids are unique across servers, so a late disconnect from a server that was replaced (the socket
    /// reopened) can't be taken for a new server's connection with the same number.
    private static let connectionIDs = ConnectionIDs()

    init(socketURL: URL, handler: @escaping Handler, onDisconnect: @escaping @Sendable (Int) -> Void) {
        self.socketURL = socketURL
        self.handler = handler
        self.onDisconnect = onDisconnect
    }

    /// Never waits on `queue`: the last release can happen on it (a block that held the server outliving the
    /// controller's reference), and a `queue.sync` there would deadlock.
    deinit {
        _ = stopListening()
        let open = Array(connections.values)
        if !open.isEmpty { queue.async { for connection in open { connection.close() } } }
    }

    func start() throws {
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // An existing folder keeps its mode, so set it every time.
        guard chmod(directory.path, 0o700) == 0 else { throw posixError("chmod") }

        let path = socketURL.path
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            throw AutomationError(.failed, "The profile path is too long for a socket: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        // Don't take the socket from another Kite that's still answering on it
        // (it would lose Claude's connection). The controller tries again when the folder changes.
        if Self.isAnswering(address) {
            throw SocketTaken(path: path, holder: SocketServerProcess.serving(socketPath: path))
        }
        // A socket left behind by a crash would make bind fail.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket") }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            let error = posixError("bind")
            close(fd)
            unlink(path)
            throw error
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnections(fd) }
        source.setCancelHandler { close(fd) }
        var info = stat()
        lock.lock()
        if lstat(path, &info) == 0 { boundFile = (info.st_dev, info.st_ino) }
        listenFD = fd
        listenSource = source
        lock.unlock()
        source.resume()
    }

    /// Another process answers on the socket: named, so a stale or test build holding it is obvious.
    struct SocketTaken: Error, CustomStringConvertible {
        let path: String
        /// Nil if it quit between answering and the lookup.
        let holder: SocketServerProcess?

        var description: String {
            "Another Kite is already answering at \(path)" + (holder.map { ": \($0.summary)." } ?? ".")
        }
    }

    /// Stops listening and drops every connection. Returns at once: the connections close on `queue`.
    func stop() {
        guard stopListening() else { return }
        queue.async { [self] in
            for connection in Array(connections.values) { connection.close() }
            connections.removeAll()
        }
    }

    /// Cancels the listener and deletes the socket file if it's still ours. True if it was listening.
    private func stopListening() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard listenFD >= 0 else { return false }
        // Only our own file: a newer Kite may have bound the path since
        // (an update relaunching, a second instance), and deleting its
        // socket leaves Claude unable to find the running Kite.
        if ownsSocketFileLocked { unlink(socketURL.path) }
        listenSource?.cancel()
        listenSource = nil
        listenFD = -1
        boundFile = nil
        return true
    }

    /// True while the server is listening.
    var isListening: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listenFD >= 0
    }

    /// True while the file at `socketURL` is still the socket this server bound.
    var ownsSocketFile: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ownsSocketFileLocked
    }

    /// With `lock` held.
    private var ownsSocketFileLocked: Bool {
        guard let boundFile else { return false }
        var info = stat()
        guard lstat(socketURL.path, &info) == 0 else { return false }
        return info.st_dev == boundFile.dev && info.st_ino == boundFile.ino
    }

    /// Whether something accepts connections at the address right now.
    private static func isAnswering(_ address: sockaddr_un) -> Bool {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }
        var address = address
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return connected == 0
    }

    // MARK: Private (on `queue`)

    private func acceptConnections(_ listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                close(fd)
                continue
            }
            // Accepted sockets inherit O_NONBLOCK, and keep it: a blocking write to a client that stopped reading
            // would stall `queue` (see `Connection.flush`).
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let id = Self.connectionIDs.next()
            let connection = Connection(id: id, fd: fd, queue: queue)
            connection.onLine = { [weak self] line in self?.received(line, on: connection) }
            connection.onClose = { [weak self] in
                Trace.event("connection.closed", actor: .kite, connection: id)
                guard let self else { return }
                connections[id] = nil
                onDisconnect(id)
            }
            connections[id] = connection
            Trace.event("connection.opened", actor: .kite, connection: id)
            connection.start()
        }
    }

    private func received(_ line: Data, on connection: Connection) {
        let received = TraceClock.monotonic()
        guard let request = try? JSONDecoder().decode(AutomationWire.Request.self, from: line) else {
            connection.send(AutomationWire.Response(id: -1, output: .failure(AutomationError(.invalidArguments, "Malformed request."))))
            return
        }
        let handler = self.handler
        Task {
            let output = await handler(request, connection.id, received)
            connection.send(AutomationWire.Response(id: request.id, output: output))
        }
    }

    private func posixError(_ call: String) -> AutomationError {
        AutomationError(.failed, "\(call) failed: \(String(cString: strerror(errno)))")
    }
}

private final class ConnectionIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var last = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        last += 1
        return last
    }
}

/// One client connection. Reads and writes happen on the server's queue and never block: a response the client
/// isn't reading yet waits in `pending`, and a client that reads none of it for `stallTimeout`, or lets more than
/// `maxPending` pile up, is dropped.
private final class Connection: @unchecked Sendable {
    static let stallTimeout: TimeInterval = 10
    /// A few full-page screenshots.
    static let maxPending = 64 << 20

    let id: Int
    private let fd: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    /// Created suspended; resumed only while `pending` waits for room in the socket.
    private var writeSource: DispatchSourceWrite?
    private var writing = false
    /// Sources whose cancel handlers haven't run: `fd` closes after the last.
    private var openSources = 0
    private var pending = Data()
    /// When a write last went through (or `pending` began waiting).
    private var lastProgress = Date()
    /// Fires at `lastProgress + stallTimeout` while `pending` waits (one per connection).
    private var stallTimer: DispatchSourceTimer?
    private var lines = LineBuffer()
    private var closed = false
    var onLine: ((Data) -> Void)?
    var onClose: (() -> Void)?

    init(id: Int, fd: Int32, queue: DispatchQueue) {
        self.id = id
        self.fd = fd
        self.queue = queue
    }

    func start() {
        let fd = self.fd
        // Cancel handlers run on `queue`, one after the other; they keep the connection alive until both have.
        let cancelled: @Sendable () -> Void = { [self] in
            openSources -= 1
            if openSources == 0 { Darwin.close(fd) }
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler(handler: cancelled)
        let writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        writeSource.setEventHandler { [weak self] in self?.flush() }
        writeSource.setCancelHandler(handler: cancelled)
        self.source = source
        self.writeSource = writeSource
        openSources = 2
        source.resume()
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(fd, &buffer, buffer.count)
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        guard count > 0 else { return close() }
        do {
            for line in try lines.append(Data(buffer[0..<count])) { onLine?(line) }
        } catch {
            close()
        }
    }

    func send(_ response: AutomationWire.Response) {
        guard let data = try? AutomationWire.encodeLine(response) else { return }
        queue.async { [self] in
            guard !closed else { return }
            if pending.isEmpty { lastProgress = Date() }
            pending.append(data)
            guard pending.count <= Self.maxPending else {
                NSLog("Kite: dropped Claude's connection \(id): over \(Self.maxPending >> 20) MB of responses it isn't reading.")
                return close()
            }
            flush()
        }
    }

    /// Writes what the socket takes now, and waits on the write source for room for the rest.
    private func flush() {
        guard !closed else { return }
        while !pending.isEmpty {
            let written = pending.withUnsafeBytes { raw in write(fd, raw.baseAddress!, raw.count) }
            if written > 0 {
                pending.removeFirst(written)
                lastProgress = Date()
            } else if written < 0, errno == EINTR {
                continue
            } else if written < 0, errno == EAGAIN {
                if !writing {
                    writing = true
                    writeSource?.resume()
                }
                watchStall()
                return
            } else {
                return close()
            }
        }
        // A fresh buffer, so a big screenshot's storage goes once it's sent.
        pending = Data()
        stallTimer?.cancel()
        stallTimer = nil
        if writing {
            writing = false
            writeSource?.suspend()
        }
    }

    /// Drops the connection once the client has read nothing of a waiting response for `stallTimeout`: one timer,
    /// set for `lastProgress + stallTimeout` and moved on when it finds progress.
    private func watchStall() {
        if stallTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in
                guard let self, !closed, writing else { return }
                let left = Self.stallTimeout - Date().timeIntervalSince(lastProgress)
                if left <= 0 {
                    NSLog("Kite: dropped Claude's connection \(id): it stopped reading a response.")
                    close()
                } else {
                    stallTimer?.schedule(deadline: .now() + left, leeway: .milliseconds(500))
                }
            }
            stallTimer = timer
            timer.schedule(deadline: .now() + Self.stallTimeout - Date().timeIntervalSince(lastProgress), leeway: .milliseconds(500))
            timer.resume()
        }
    }

    /// Call on the queue.
    func close() {
        guard !closed else { return }
        closed = true
        source?.cancel()
        source = nil
        // A suspended source never runs its cancel handler: resume it first.
        if !writing { writeSource?.resume() }
        writing = false
        writeSource?.cancel()
        writeSource = nil
        stallTimer?.cancel()
        stallTimer = nil
        pending = Data()
        onClose?()
        // They hold the connection (onLine captures it): let it go.
        onLine = nil
        onClose = nil
    }
}
