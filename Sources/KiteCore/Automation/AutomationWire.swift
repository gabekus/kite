import Foundation

/// What a tool call returns: MCP's `CallToolResult` shape, so the relay passes it through.
public struct ToolOutput: Codable, Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        case text(String)
        /// Base64-encoded image data.
        case image(base64: String, mimeType: String)
    }

    public var content: [Content]
    public var isError: Bool

    public init(content: [Content], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ text: String) -> ToolOutput { ToolOutput(content: [.text(text)]) }

    public static func failure(_ error: AutomationError) -> ToolOutput {
        ToolOutput(content: [.text(error.message)], isError: true)
    }

    /// All text blocks joined, for the CLI and logs.
    public var text: String {
        content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
    }

    private enum CodingKeys: String, CodingKey { case content, isError }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = try c.decode([Content].self, forKey: .content)
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(content, forKey: .content)
        if isError { try c.encode(true, forKey: .isError) }
    }
}

extension ToolOutput.Content: Codable {
    private enum CodingKeys: String, CodingKey { case type, text, data, mimeType }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "image":
            self = .image(base64: try c.decode(String.self, forKey: .data), mimeType: try c.decode(String.self, forKey: .mimeType))
        default:
            self = .text(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
        case let .image(data, mimeType):
            try c.encode("image", forKey: .type)
            try c.encode(data, forKey: .data)
            try c.encode(mimeType, forKey: .mimeType)
        }
    }
}

/// Why a tool call didn't run. Messages are written for the model and the CLI user alike.
public struct AutomationError: Error, Hashable, Sendable {
    public enum Code: String, Codable, Sendable {
        case invalidArguments, notFound, denied, stopped, unsupported, failed, timeout, disabled
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    public static let disabled = AutomationError(.disabled,
        "Kite isn't running, or \"Allow Claude to Control the Browser\" is off (Kite menu). Ask the user to turn it on.")
    public static let stopped = AutomationError(.stopped,
        "The user stopped Claude's control of this tab. Don't try again unless the user asks.")
    public static func denied(_ action: String) -> AutomationError {
        AutomationError(.denied, "The user didn't allow Claude to \(action). Don't retry it; ask the user what they want instead.")
    }
}

/// The app's automation socket speaks one JSON object per line, in both directions.
public enum AutomationWire {
    public struct Request: Codable, Hashable, Sendable {
        public var id: Int
        public var tool: String
        public var arguments: JSONValue

        public init(id: Int, tool: String, arguments: JSONValue) {
            self.id = id
            self.tool = tool
            self.arguments = arguments
        }
    }

    public struct Response: Codable, Hashable, Sendable {
        public var id: Int
        public var output: ToolOutput

        public init(id: Int, output: ToolOutput) {
            self.id = id
            self.output = output
        }
    }

    /// Upper bound for one line (a full-page screenshot is a few MB of base64).
    public static let maxLineLength = 64 * 1024 * 1024

    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    /// Where the app listens and the CLI connects: inside the profile's support
    /// directory, in a folder only the user can open.
    public static func socketURL(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("Automation", isDirectory: true).appendingPathComponent("kite.sock")
    }
}

/// Splits a byte stream into newline-terminated lines.
public struct LineBuffer: Sendable {
    private var buffer = Data()
    public let maxLineLength: Int

    public struct LineTooLong: Error {}

    public init(maxLineLength: Int = AutomationWire.maxLineLength) {
        self.maxLineLength = maxLineLength
    }

    /// Appends bytes and returns every complete line (without the newline; a trailing \r is dropped too).
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            if !line.isEmpty { lines.append(Data(line)) }
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        if buffer.count > maxLineLength {
            buffer = Data()
            throw LineTooLong()
        }
        return lines
    }
}
