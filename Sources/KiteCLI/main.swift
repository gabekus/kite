import Darwin
import Foundation
import KiteCore

// `kite`: drive Kite's tabs from a terminal, or `kite mcp` to give them to Claude Code:
//
//     claude mcp add kite -- /Applications/Kite.app/Contents/Helpers/kite mcp
//
// Everything goes through the running app's automation socket, which exists only
// while "Allow Claude to Control the Browser" is on.

let version = "0.1.0"
let usage = """
    kite: control Kite's tabs from the command line or Claude Code.

    Usage:
      kite tabs                                      List open tabs
      kite read [--tab ID] [--max N] [--interactive] Read a page: outline with refs, then its text
      kite text [--tab ID] [--max N]                 The page's main text
      kite find QUERY [--tab ID]                     Find elements ("search box") and their refs
      kite click (REF | --selector CSS) [--tab ID]   Click an element
      kite type TEXT [--ref REF | --selector CSS] [--submit] [--tab ID]
                                                     Type into an element (or the focused one)
      kite key KEYS [--tab ID]                       Press keys, e.g. "cmd+a Backspace" or Enter
      kite open URL [--here | --tab ID]              Open URL in a new background tab (or navigate one)
      kite screenshot [--tab ID] [--format png] [-o FILE]
                                                     Save a screenshot of a tab (JPEG unless --format png)
      kite js CODE [--tab ID]                        Run JavaScript in the page (Kite asks first)
      kite console [--tab ID] [--errors]             Console messages since Claude started driving the tab
      kite network [--tab ID] [--errors] [--status 4xx] [--host H] [--type fetch,xhr] [--url REGEX] [--all]
                   [--since N] [--follow]            Kite's network log; --follow keeps printing new requests
      kite request ID [--no-body]                    One request in full (headers, timing, bodies)
      kite har [--tab ID] [--bodies] [filters]       Export the network log as a HAR file
      kite spaces                                    List spaces
      kite call TOOL [JSON]                          Call any MCP tool, e.g. kite call computer '{"action":"scroll"}'
      kite ui ACTION [JSON] [-o FILE]                Kite's own UI (Diagnostics for Claude): windows, tree, capture,
                                                     pointer, input, menu, key_log, trace. kite ui tree '{"match":"Sidebar"}'
      kite probe APP [tree | capture] [...]          The same for another app, e.g. Arc (kite probe --help)
      kite tools                                     List every tool
      kite mcp                                       Run as an MCP server on stdin/stdout

    Without --tab, commands act on the tab in front.
    Options: --socket PATH (default: the Kite profile's, or $KITE_SUPPORT_PATH's)
    Turn on "Allow Claude to Control the Browser" in Kite's app menu first.
    """

signal(SIGPIPE, SIG_IGN)

/// A connection to the app that survives Kite restarting or the setting being toggled.
final class KiteConnection: @unchecked Sendable {
    private let path: String
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<ToolOutput, Never>] = [:]

    init(path: String) { self.path = path }

    func call(_ tool: String, _ arguments: JSONValue) async -> ToolOutput {
        await withCheckedContinuation { continuation in
            lock.lock()
            if fd < 0, !connect() {
                lock.unlock()
                return continuation.resume(returning: .failure(.disabled))
            }
            let id = nextID
            nextID += 1
            pending[id] = continuation
            let socket = fd
            lock.unlock()

            guard let line = try? AutomationWire.encodeLine(AutomationWire.Request(id: id, tool: tool, arguments: arguments)),
                  writeAll(socket, line) else {
                finish(id, .failure(AutomationError(.failed, "Lost the connection to Kite.")))
                disconnect(socket)
                return
            }
        }
    }

    /// Call with the lock held.
    private func connect() -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        // The socket may sit in a shared folder (/tmp for deep profiles): only talk to one the user owns.
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid() else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(socket)
            return false
        }
        fd = socket
        Thread.detachNewThread { [self] in readLoop(socket) }
        return true
    }

    private func readLoop(_ socket: Int32) {
        var lines = LineBuffer()
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let count = read(socket, &buffer, buffer.count)
            guard count > 0, let received = try? lines.append(Data(buffer[0..<count])) else { break }
            for line in received {
                if let response = try? JSONDecoder().decode(AutomationWire.Response.self, from: line) {
                    finish(response.id, response.output)
                }
            }
        }
        disconnect(socket)
    }

    private func disconnect(_ socket: Int32) {
        lock.lock()
        guard fd == socket else { return lock.unlock() }
        fd = -1
        let failed = pending
        pending.removeAll()
        lock.unlock()
        close(socket)
        for continuation in failed.values {
            continuation.resume(returning: .failure(AutomationError(.failed,
                "Kite closed the connection (it quit, or \"Allow Claude to Control the Browser\" was turned off).")))
        }
    }

    private func finish(_ id: Int, _ output: ToolOutput) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(returning: output)
    }

    private func writeAll(_ socket: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(socket, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }
}

/// Serializes writes to stdout; MCP needs every message on its own line.
final class LineWriter: @unchecked Sendable {
    private let lock = NSLock()
    func write(_ value: JSONValue) {
        guard var data = try? value.encoded() else { return }
        data.append(0x0A)
        lock.lock()
        FileHandle.standardOutput.write(data)
        lock.unlock()
    }
}

// MARK: Arguments

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    static let valued: Set<String> = ["--tab", "--max", "--selector", "--ref", "--socket", "-o", "--output", "--format",
                                      "--window", "--depth", "--match", "--region", "--pixels",
                                      "--status", "--host", "--type", "--url", "--since", "--limit"]

    init(_ raw: ArraySlice<String>) throws {
        var iterator = raw.makeIterator()
        while let arg = iterator.next() {
            if Self.valued.contains(arg) {
                guard let value = iterator.next() else { throw CLIError("\(arg) needs a value.") }
                options[arg == "--output" ? "-o" : arg] = value
            } else if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "="), Self.valued.contains(String(arg[..<eq])) {
                options[String(arg[..<eq])] = String(arg[arg.index(after: eq)...])
            } else if arg.hasPrefix("-") && arg.count > 1 && Double(arg) == nil {
                flags.insert(arg)
            } else {
                positional.append(arg)
            }
        }
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func socketPath(_ arguments: Arguments) -> String {
    if let path = arguments.options["--socket"] { return path }
    let support: URL
    if let override = ProcessInfo.processInfo.environment["KITE_SUPPORT_PATH"] {
        support = URL(fileURLWithPath: override, isDirectory: true)
    } else {
        support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kite", isDirectory: true)
    }
    return AutomationWire.socketURL(supportDirectory: support).path
}

/// Turns a subcommand into a tool call: (tool name, arguments).
func toolCall(for name: String, _ args: Arguments) throws -> (AutomationCommand.Tool, JSONValue) {
    var json: [String: JSONValue] = [:]
    if let tab = args.options["--tab"] { json["tab"] = .string(tab) }
    if let selector = args.options["--selector"] { json["selector"] = .string(selector) }
    if let ref = args.options["--ref"] { json["ref"] = .string(ref) }
    if let max = args.options["--max"] {
        guard let n = Int(max) else { throw CLIError("--max needs a number.") }
        json["max_text_length"] = .number(Double(n))
    }
    func first(_ what: String) throws -> String {
        guard let value = args.positional.first else { throw CLIError("kite \(name) needs \(what).") }
        return value
    }
    let tool: String
    switch name {
    case "tabs", "list":
        tool = "tabs_context"
    case "read":
        tool = "read_page"
        if args.flags.contains("--interactive") { json["filter"] = "interactive" }
    case "text":
        tool = "get_page_text"
    case "find":
        tool = "find"
        json["query"] = .string(try first("what to find"))
    case "click":
        tool = "click"
        if let ref = args.positional.first { json["ref"] = .string(ref) }
    case "type":
        tool = "type"
        json["text"] = .string(try first("the text to type"))
        if args.flags.contains("--submit") { json["submit"] = true }
    case "key", "keys", "press":
        tool = "computer"
        json["action"] = "key"
        json["text"] = .string(try first("the keys to press"))
    case "open", "navigate", "go":
        tool = "navigate"
        json["url"] = .string(try first("a URL"))
        if args.options["--tab"] == nil && !args.flags.contains("--here") { json["new_tab"] = true }
    case "screenshot", "shot":
        tool = "screenshot"
        if let format = args.options["--format"] { json["format"] = .string(format) }
    case "js", "eval":
        tool = "javascript"
        json["code"] = .string(try first("the code to run"))
    case "console":
        tool = "read_console_messages"
        if args.flags.contains("--errors") { json["only_errors"] = true }
    case "network", "har":
        tool = name == "har" ? "export_har" : "network_log"
        for (option, key) in [("--status", "status"), ("--host", "host"), ("--type", "type"), ("--url", "url_pattern")] {
            if let value = args.options[option] { json[key] = .string(value) }
        }
        for (option, key) in [("--since", "since"), ("--limit", "limit")] {
            guard let value = args.options[option] else { continue }
            guard let n = Int(value) else { throw CLIError("\(option) needs a number.") }
            json[key] = .number(Double(n))
        }
        if args.flags.contains("--errors") { json["status"] = "errors" }
        if args.flags.contains("--all") { json["type"] = "all" }
        if args.flags.contains("--bodies") { json["bodies"] = true }
    case "request":
        tool = "network_request"
        guard let id = Int(try first("a request id").trimmingCharacters(in: CharacterSet(charactersIn: "#"))) else {
            throw CLIError("kite request needs the number from kite network, like 12.")
        }
        json["id"] = .number(Double(id))
        if args.flags.contains("--no-body") { json["body"] = false }
    case "spaces":
        tool = "list_spaces"
    case "ui":
        tool = "ui"
        json["action"] = .string(try first("an action (windows, tree, capture, pointer, input, menu, key_log, trace)"))
        if args.positional.count > 1 {
            guard case .object(let given)? = try? JSONValue.decode(Data(args.positional[1].utf8)) else {
                throw CLIError("The arguments must be a JSON object.")
            }
            json.merge(given) { _, new in new }
        }
        // Kite writes a capture at full resolution itself; the image sent back is scaled for Claude.
        if json["action"] == .string("capture"), let output = args.options["-o"], json["save"] == nil {
            json["save"] = .string(URL(fileURLWithPath: output).path)
            json["image"] = .bool(false)
        }
    case "call":
        tool = try first("a tool name")
        if args.positional.count > 1 {
            guard case .object(let given)? = try? JSONValue.decode(Data(args.positional[1].utf8)) else {
                throw CLIError("The arguments must be a JSON object.")
            }
            json.merge(given) { _, new in new }
        }
    default:
        throw CLIError("Unknown command \"\(name)\".\n\n\(usage)")
    }
    json.removeValue(forKey: "max_text_length").map { value in
        if ["read_page", "get_page_text"].contains(tool) { json["max_text_length"] = value }
    }
    do {
        let command = try AutomationCommand(tool: tool, arguments: .object(json))
        return (command.tool, .object(json))
    } catch {
        throw CLIError("\(error)")
    }
}

func runMCP(_ connection: KiteConnection) async {
    let server = MCPServer(version: version)
    let out = LineWriter()
    let input = AsyncStream<String> { continuation in
        Thread.detachNewThread {
            while let line = readLine(strippingNewline: true) { continuation.yield(line) }
            continuation.finish()
        }
    }
    await withTaskGroup(of: Void.self) { group in
        for await line in input where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let message = try? JSONValue.decode(Data(line.utf8)) else {
                out.write(MCPServer.error(id: .null, .parseError, "That wasn't JSON."))
                continue
            }
            // Concurrently, so a call waiting on the user's confirmation doesn't block pings.
            group.addTask {
                let response = await server.handle(message) { tool, arguments in
                    await connection.call(tool.rawValue, arguments)
                }
                if let response { out.write(response) }
            }
        }
    }
}

/// `kite network --follow`: prints new requests as they finish, like `tail -f`, by asking
/// for everything after the last cursor once a second.
func follow(_ connection: KiteConnection, _ arguments: JSONValue) async -> Int32 {
    var arguments = arguments.objectValue ?? [:]
    var first = true
    while true {
        let output = await connection.call(AutomationCommand.Tool.networkLog.rawValue, .object(arguments))
        if output.isError {
            FileHandle.standardError.write(Data("kite: \(output.text)\n".utf8))
            return 1
        }
        for line in output.text.split(separator: "\n") {
            if let cursor = line.wholeMatch(of: /cursor: (\d+)/).flatMap({ Int($0.1) }) {
                arguments["since"] = .number(Double(cursor))
            } else if line.hasPrefix("#") || (first && line.hasPrefix("No requests yet")) {
                print(line)
            }
        }
        fflush(stdout)
        first = false
        // A tail asks for everything new, so later calls aren't capped at the first call's limit.
        arguments["limit"] = 1000
        try? await Task.sleep(for: .seconds(1))
    }
}

func main() async -> Int32 {
    // Options may come before the command too: `kite --socket PATH mcp`.
    var raw = Array(CommandLine.arguments.dropFirst())
    var commandIndex = 0
    while commandIndex < raw.count, raw[commandIndex].hasPrefix("-"), !["-h", "--help", "--version"].contains(raw[commandIndex]) {
        commandIndex += Arguments.valued.contains(raw[commandIndex]) ? 2 : 1
    }
    guard commandIndex < raw.count, !["-h", "--help", "help"].contains(raw[commandIndex]) else {
        print(usage)
        return raw.isEmpty ? 1 : 0
    }
    let name = raw.remove(at: commandIndex)
    if name == "--version" || name == "version" {
        print("kite \(version)")
        return 0
    }
    do {
        let args = try Arguments(raw[...])
        let connection = KiteConnection(path: socketPath(args))
        if name == "mcp" {
            await runMCP(connection)
            return 0
        }
        if name == "probe" {
            if args.flags.contains("--help") || args.positional.isEmpty {
                print(probeUsage)
                return 0
            }
            return try await Probe.run(args)
        }
        if name == "tools" {
            for tool in AutomationCommand.Tool.allCases { print("\(tool.rawValue): \(tool.summary)") }
            return 0
        }
        let (tool, arguments) = try toolCall(for: name, args)
        if tool == .networkLog && args.flags.contains("--follow") {
            return await follow(connection, arguments)
        }
        let output = await connection.call(tool.rawValue, arguments)
        if output.isError {
            FileHandle.standardError.write(Data("kite: \(output.text)\n".utf8))
            return 1
        }
        for content in output.content {
            switch content {
            case .text(let text) where tool == .ui || !output.content.contains(where: { if case .image = $0 { true } else { false } }):
                print(text)
            case .text:
                break
            case let .image(base64, mimeType):
                let ext = mimeType == "image/jpeg" ? "jpg" : "png"
                let path = args.options["-o"] ?? "kite-screenshot-\(Int(Date().timeIntervalSince1970)).\(ext)"
                guard let data = Data(base64Encoded: base64) else { throw CLIError("Kite sent an unreadable image.") }
                try data.write(to: URL(fileURLWithPath: path))
                print(path)
            }
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("kite: \(error)\n".utf8))
        return 2
    }
}

exit(await main())
