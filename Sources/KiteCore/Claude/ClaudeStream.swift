import Foundation

/// One thing Claude Code reported on its `--output-format stream-json` output, reduced
/// to what Claude Tasks shows. Everything else in the stream (rate limits, status, usage)
/// is ignored.
public enum ClaudeStreamEvent: Hashable, Sendable {
    /// The run started. `kiteConnected` is false when Kite's MCP server failed to start.
    case session(id: String, model: String?, kiteConnected: Bool?)
    /// A piece of Claude's reply as it streams in.
    case textDelta(String)
    /// A whole text block of Claude's reply.
    case text(String)
    /// Claude called a tool. `name` has the `mcp__kite__` prefix removed.
    case toolUse(id: String, name: String, summary: String)
    case toolResult(id: String, isError: Bool, summary: String)
    /// The run finished (or gave up).
    case result(isError: Bool, text: String, costUSD: Double?, sessionID: String?)
}

public enum ClaudeStream {
    /// Parses one line of stream-json. Lines it doesn't know give no events.
    public static func events(from line: Data) -> [ClaudeStreamEvent] {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else { return [] }
        return events(from: message)
    }

    public static func events(from message: JSONValue) -> [ClaudeStreamEvent] {
        // Subagents' messages carry their parent's tool id; only the main conversation is shown.
        if let parent = message["parent_tool_use_id"], !parent.isNull { return [] }
        switch message["type"]?.stringValue {
        case "system" where message["subtype"]?.stringValue == "init":
            guard let id = message["session_id"]?.stringValue else { return [] }
            let kite = message["mcp_servers"]?.arrayValue?.first { $0["name"]?.stringValue == "kite" }
            return [.session(id: id, model: message["model"]?.stringValue,
                             kiteConnected: kite.map { $0["status"]?.stringValue == "connected" })]
        case "stream_event":
            let event = message["event"]
            guard event?["type"]?.stringValue == "content_block_delta", event?["delta"]?["type"]?.stringValue == "text_delta",
                  let text = event?["delta"]?["text"]?.stringValue else { return [] }
            return [.textDelta(text)]
        case "assistant":
            return (message["message"]?["content"]?.arrayValue ?? []).compactMap { block -> ClaudeStreamEvent? in
                switch block["type"]?.stringValue {
                case "text":
                    guard let text = block["text"]?.stringValue, !text.isEmpty else { return nil }
                    return .text(text)
                case "tool_use":
                    let name = toolName(block["name"]?.stringValue ?? "tool")
                    return .toolUse(id: block["id"]?.stringValue ?? "", name: name, summary: summary(of: block["input"] ?? .null, tool: name))
                default:
                    return nil
                }
            }
        case "user":
            return (message["message"]?["content"]?.arrayValue ?? []).compactMap { block -> ClaudeStreamEvent? in
                guard block["type"]?.stringValue == "tool_result" else { return nil }
                let isError = block["is_error"]?.boolValue ?? false
                // Results are page content: only an error's first line is worth showing.
                return .toolResult(id: block["tool_use_id"]?.stringValue ?? "", isError: isError,
                                   summary: isError ? firstLine(resultText(block["content"]), limit: 200) : "")
            }
        case "result":
            let subtype = message["subtype"]?.stringValue ?? "success"
            let isError = (message["is_error"]?.boolValue ?? false) || subtype != "success"
            var text = message["result"]?.stringValue ?? ""
            if isError && text.isEmpty {
                let errors = message["errors"]?.arrayValue?.compactMap(\.stringValue) ?? []
                text = errors.isEmpty ? Self.describe(subtype) : errors.joined(separator: "\n")
            }
            return [.result(isError: isError, text: text, costUSD: message["total_cost_usd"]?.doubleValue,
                            sessionID: message["session_id"]?.stringValue)]
        default:
            return []
        }
    }

    /// `mcp__kite__read_page` → `read_page`. Other servers' tools keep their full name.
    static func toolName(_ name: String) -> String {
        name.hasPrefix("mcp__kite__") ? String(name.dropFirst("mcp__kite__".count)) : name
    }

    /// A short line saying what a tool call was for, from its most telling arguments.
    static func summary(of input: JSONValue, tool: String) -> String {
        if tool == "batch", let steps = input["steps"]?.arrayValue {
            let names = steps.compactMap { $0["tool"]?.stringValue }
            return firstLine("\(steps.count) steps: " + names.joined(separator: ", "), limit: 100)
        }
        var parts: [String] = []
        for key in ["url", "query", "action", "text", "value", "ref", "selector", "name", "space", "pattern"] {
            guard let value = input[key] else { continue }
            let string: String
            switch value {
            case .string(let s): string = s
            case .number, .bool: string = "\(value.intValue.map(String.init) ?? value.boolValue.map(String.init) ?? "")"
            default: continue
            }
            if string.isEmpty { continue }
            parts.append(key == "url" || key == "query" || key == "action" ? string : "\(key) \(string)")
            if parts.count == 2 { break }
        }
        return firstLine(parts.joined(separator: " · "), limit: 100)
    }

    static func resultText(_ content: JSONValue?) -> String {
        switch content {
        case .string(let text)?: text
        case .array(let blocks)?: blocks.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        default: ""
        }
    }

    static func firstLine(_ text: String, limit: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    static func describe(_ subtype: String) -> String {
        switch subtype {
        case "error_max_turns": "Claude reached its turn limit before finishing."
        case "error_max_budget_usd": "Claude reached its budget before finishing."
        default: "Claude stopped with an error (\(subtype))."
        }
    }
}
