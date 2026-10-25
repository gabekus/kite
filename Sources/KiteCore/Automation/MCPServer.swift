import Foundation

/// The Model Context Protocol side of `kite mcp`: JSON-RPC 2.0 messages in,
/// responses out. Transport-free, so it's tested here and the CLI only moves
/// lines between stdio and the app's socket.
public struct MCPServer: Sendable {
    /// Newest first. A client asking for one of these gets it back; anything else gets the newest.
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    public enum ErrorCode: Int, Sendable {
        case parseError = -32700
        case invalidRequest = -32600
        case methodNotFound = -32601
        case invalidParams = -32602
    }

    public var name: String
    public var version: String

    public init(name: String = "kite", version: String) {
        self.name = name
        self.version = version
    }

    public static let instructions = """
        Kite is the user's own web browser. These tools act in their real tabs, signed in as them. \
        Call tabs_context first for tab ids, and read_page or find before click, type or form_input to get element refs; \
        screenshot pixels are the coordinates the computer tool clicks. Tools work on background tabs without switching to them. \
        \(UntrustedContent.notice) \
        Kite asks the user before anything that submits a form, sends, posts, pays, buys or deletes, and before typing \
        into password or payment fields, and before running JavaScript; if they decline, the tool returns an error. \
        Don't retry a declined action. \
        To check Kite's own interface (sidebar, command bar, menus, cursors, animations), use the ui tool, not \
        screenshots of the screen or the user's mouse. \
        When debugging a site, network_log shows what the tabs requested (pass its cursor back as since to see only \
        new requests) and network_request gives one request's headers and bodies.
        """

    public var tools: JSONValue {
        .array(AutomationCommand.Tool.allCases.map { tool in
            [
                "name": .string(tool.rawValue),
                "title": .string(tool.title),
                "description": .string(tool.summary),
                "inputSchema": tool.inputSchema,
                "annotations": [
                    "readOnlyHint": .bool(tool.isReadOnly),
                    "destructiveHint": .bool(tool.isDestructive),
                    "openWorldHint": true,
                ],
            ]
        })
    }

    /// Handles one parsed message. Returns nil for notifications and responses, which get no reply.
    /// `callTool` runs a tool with its arguments as sent; it's only called once they parse.
    public func handle(
        _ message: JSONValue,
        callTool: @Sendable (AutomationCommand.Tool, JSONValue) async -> ToolOutput
    ) async -> JSONValue? {
        guard case .object(let object) = message else {
            return Self.error(id: .null, .invalidRequest, "Expected a JSON-RPC object (batches aren't supported).")
        }
        let id = object["id"]
        guard let method = object["method"]?.stringValue else {
            // A response from the client (we never send requests) or garbage.
            let isResponse = object["result"] != nil || object["error"] != nil
            guard let id, !isResponse else { return nil }
            return Self.error(id: id, .invalidRequest, "Missing method.")
        }
        guard let id, !id.isNull else { return nil }  // Notification: initialized, cancelled, …
        guard id.stringValue != nil || id.intValue != nil else {
            return Self.error(id: .null, .invalidRequest, "The id must be a string or an integer.")
        }
        let params = object["params"]

        switch method {
        case "initialize":
            let requested = params?["protocolVersion"]?.stringValue ?? ""
            let version = Self.supportedProtocolVersions.contains(requested) ? requested : Self.supportedProtocolVersions[0]
            return Self.result(id: id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(name), "title": "Kite", "version": .string(self.version)],
                "instructions": .string(Self.instructions),
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": tools])
        case "tools/call":
            guard let name = params?["name"]?.stringValue else {
                return Self.error(id: id, .invalidParams, "tools/call needs a tool name.")
            }
            guard let tool = AutomationCommand.Tool(name: name) else {
                return Self.error(id: id, .invalidParams, "Unknown tool \"\(name)\".")
            }
            let arguments = params?["arguments"] ?? .object([:])
            let output: ToolOutput
            do {
                // Validate here so the model hears about bad arguments without a round trip to the app.
                _ = try AutomationCommand(tool: name, arguments: arguments)
                output = await callTool(tool, arguments)
            } catch {
                // Bad arguments are a tool error the model can read and fix, not a protocol error.
                output = .failure(AutomationError(.invalidArguments, "\(error)"))
            }
            return Self.result(id: id, Self.json(output))
        default:
            return Self.error(id: id, .methodNotFound, "Kite doesn't support \(method).")
        }
    }

    public static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    public static func error(id: JSONValue, _ code: ErrorCode, _ message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code.rawValue)), "message": .string(message)]]
    }

    static func json(_ output: ToolOutput) -> JSONValue {
        // ToolOutput is already in MCP's CallToolResult shape.
        (try? JSONValue.decode(JSONEncoder().encode(output))) ?? ["content": [], "isError": true]
    }
}
