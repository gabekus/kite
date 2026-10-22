import Foundation

/// Any JSON value. MCP and the automation socket pass arbitrary JSON around
/// (tool arguments, schemas, request ids), so this keeps it typed without `Any`.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let array) = self, array.indices.contains(index) { return array[index] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let bool) = self { return bool }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let number) = self { return number }
        return nil
    }

    /// Only whole numbers; 1.5 isn't an Int.
    public var intValue: Int? {
        guard case .number(let number) = self, number.rounded() == number, abs(number) < 1e15 else { return nil }
        return Int(number)
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }

    public var isNull: Bool { self == .null }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let bool = try? c.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? c.decode(Double.self) {
            self = .number(number)
        } else if let string = try? c.decode(String.self) {
            self = .string(string)
        } else if let array = try? c.decode([JSONValue].self) {
            self = .array(array)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let bool): try c.encode(bool)
        // Whole numbers go out as integers, so a request id 1 comes back as 1, not 1.0.
        case .number(let number):
            if let int = JSONValue.number(number).intValue { try c.encode(int) } else { try c.encode(number) }
        case .string(let string): try c.encode(string)
        case .array(let array): try c.encode(array)
        case .object(let object): try c.encode(object)
        }
    }
}

// Deliberately not ExpressibleByNilLiteral: `value == nil` must keep meaning "absent", not JSON null.
extension JSONValue: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension JSONValue {
    /// Compact, key-sorted JSON (one line, so it can be a line-delimited message).
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
