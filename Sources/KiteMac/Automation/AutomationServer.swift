import Darwin
import Foundation
import KiteCore

/// The automation socket: a Unix domain socket in the profile, never a network
/// port. Its folder is 0700 and the socket 0600, and each connection's peer
/// must be the same user, so only this user's own processes (the `kite` CLI)
/// can reach it. One JSON request per line in, one response per line out.
final class AutomationServer: @unchecked Sendable {
    typealias Handler = @Sendable (AutomationWire.Request, _ connection: Int) async -> ToolOutput

    let socketURL: URL
    private let handler: Handler
    private let onDisconnect: @Sendable (Int) -> Void
    private let queue = DispatchQueue(label: "dev.gabek.Kite.automation")
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var connections: [Int: Connection] = [:]
    private var nextConnectionID = 1

    init(socketURL: URL, handler: @escaping Handler, onDisconnect: @escaping @Sendable (Int) -> Void) {
        self.socketURL = socketURL
        self.handler = handler
        self.onDisconnect = onDisconnect
    }

    deinit { stop() }

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
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        source.setCancelHandler { close(fd) }
        listenSource = source
        source.resume()
    }

    func stop() {
        queue.sync {
            listenSource?.cancel()
            listenSource = nil
            if listenFD >= 0 { unlink(socketURL.path) }
            listenFD = -1
            for connection in Array(connections.values) { connection.close() }
            connections.removeAll()
        }
    }

    // MARK: Private (on `queue`)

    private func acceptConnections() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                close(fd)
                continue
            }
            // Accepted sockets inherit O_NONBLOCK; writes of big screenshots should block instead.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let id = nextConnectionID
            nextConnectionID += 1
            let connection = Connection(id: id, fd: fd, queue: queue)
            connection.onLine = { [weak self] line in self?.received(line, on: connection) }
            connection.onClose = { [weak self] in
                guard let self else { return }
                connections[id] = nil
                onDisconnect(id)
            }
            connections[id] = connection
            connection.start()
        }
    }

    private func received(_ line: Data, on connection: Connection) {
        guard let request = try? JSONDecoder().decode(AutomationWire.Request.self, from: line) else {
            connection.send(AutomationWire.Response(id: -1, output: .failure(AutomationError(.invalidArguments, "Malformed request."))))
            return
        }
        let handler = self.handler
        Task {
            let output = await handler(request, connection.id)
            connection.send(AutomationWire.Response(id: request.id, output: output))
        }
    }

    private func posixError(_ call: String) -> AutomationError {
        AutomationError(.failed, "\(call) failed: \(String(cString: strerror(errno)))")
    }
}

/// One client connection. Reads and writes happen on the server's queue.
private final class Connection: @unchecked Sendable {
    let id: Int
    private let fd: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
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
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        let fd = self.fd
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source
        source.resume()
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(fd, &buffer, buffer.count)
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
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written <= 0 { return }
                    offset += written
                }
            }
        }
    }

    /// Call on the queue.
    func close() {
        guard !closed else { return }
        closed = true
        source?.cancel()
        source = nil
        onClose?()
    }
}
