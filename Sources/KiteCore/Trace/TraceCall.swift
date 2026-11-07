import Foundation

/// The record of one tool call: who called it, how long it took and where the time went, how it ended, and the
/// safe details of its arguments. Built by the app's dispatcher (`AutomationController.perform`), one per call and
/// one per batch step.
public enum TraceCall {
    /// What a call's arguments may say in a trace. Never the text typed, a form value, a script, a find query, a
    /// note or a path: only which kind of thing, how long, how many, and choices from a fixed list.
    public static func attributes(tool name: String, arguments: JSONValue) -> [String: JSONValue] {
        let a = arguments.objectValue ?? [:]
        var out: [String: JSONValue] = [:]
        func length(_ key: String, as label: String = "len") {
            if let text = a[key]?.stringValue { out[label] = .number(Double(text.count)) }
        }
        func flag(_ key: String) {
            if let value = a[key]?.boolValue { out[key] = .bool(value) }
        }
        func choice(_ key: String, _ allowed: Set<String>) {
            if let value = a[key]?.stringValue?.lowercased(), allowed.contains(value) { out[key] = .string(value) }
        }
        func target() {
            if a["ref"]?.stringValue != nil { out["target"] = "ref" }
            if a["selector"]?.stringValue != nil { out["target"] = "selector" }
            if a["coordinate"] != nil { out["target"] = "point" }
        }
        func url(_ key: String) {
            guard let text = a[key]?.stringValue else { return }
            if ["back", "forward"].contains(text.lowercased()) {
                out["nav"] = .string(text.lowercased())
                return
            }
            let parsed = URL(string: text.contains("://") ? text : "https://" + text)
            let (host, path) = TraceRedaction.place(parsed)
            if let host { out["url_host"] = .string(host) }
            if let path { out["url_path"] = .string(path) }
        }
        guard let tool = AutomationCommand.Tool(name: name) else { return out }
        switch tool {
        case .type:
            length("text")
            flag("submit")
            target()
        case .formInput:
            if let text = a["value"]?.stringValue {
                out["len"] = .number(Double(text.count))
                out["value_type"] = "string"
            } else if a["value"]?.boolValue != nil {
                out["value_type"] = "bool"
            } else if a["value"]?.doubleValue != nil {
                out["value_type"] = "number"
            }
            target()
        case .computer:
            choice("action", Set(ComputerAction.actionNames))
            target()
            if a["action"]?.stringValue == "type" { length("text") }
            if a["action"]?.stringValue == "key", let text = a["text"]?.stringValue {
                let chords = (try? KeyChord.parseSequence(text)) ?? []
                out["keys"] = .number(Double(chords.count))
                if chords.contains(where: \.isEnter) { out["enter"] = true }
                if chords.contains(where: { !$0.modifiers.isEmpty }) { out["shortcut"] = true }
            }
            choice("scroll_direction", ["up", "down", "left", "right"])
            if let amount = a["scroll_amount"]?.intValue { out["scroll_amount"] = .number(Double(amount)) }
        case .click, .uploadFile:
            target()
            if let paths = a["paths"]?.arrayValue { out["files"] = .number(Double(paths.count)) }
        case .navigate:
            url("url")
            flag("new_tab")
            if a["space"]?.stringValue != nil { out["space"] = true }
        case .tabsCreate:
            url("url")
            flag("active")
            flag("claude_folder")
            if a["space"]?.stringValue != nil { out["space"] = true }
        case .find:
            length("query")
        case .javascript:
            length(a["code"] != nil ? "code" : "text")
        case .waitFor:
            choice("condition", ["load", "navigation", "selector", "text", "network_idle"])
            if let ms = a["timeout_ms"]?.doubleValue { out["timeout_ms"] = .number(ms) }
        case .readPage:
            choice("filter", ["all", "interactive"])
            flag("changes_only")
        case .screenshot:
            choice("format", ["jpeg", "png"])
        case .handleDialog:
            flag("accept")
            length("prompt_text", as: "prompt_len")
        case .tabStatus:
            choice("state", ["working", "done"])
            length("note", as: "note_len")
        case .handoff:
            if let steps = a["steps"]?.arrayValue { out["steps"] = .number(Double(steps.count)) }
            if let wait = a["wait"]?.doubleValue { out["wait"] = .number(wait) }
        case .handoffStatus:
            if let wait = a["wait"]?.doubleValue { out["wait"] = .number(wait) }
            flag("cancel")
        case .batch:
            if let steps = a["steps"]?.arrayValue { out["steps"] = .number(Double(steps.count)) }
        case .vpn:
            choice("action", Set(VPNAction.names))
        case .ui:
            choice("action", Set(UIInspection.actions))
        case .moveToFolder:
            if a["folder"]?.stringValue?.lowercased() == "claude" { out["folder"] = "claude" }
        default:
            break
        }
        return out
    }

    /// The result's size as sent (its JSON), and how many images it holds.
    public static func size(of output: ToolOutput) -> (bytes: Int, images: Int) {
        var bytes = 0
        var images = 0
        for content in output.content {
            switch content {
            case .text(let text): bytes += text.utf8.count
            case .image(let data, _):
                bytes += data.utf8.count
                images += 1
            }
        }
        return (bytes, images)
    }

    /// The first text block of a failed call, redacted: what went wrong, never what the page or the call said.
    public static func error(of output: ToolOutput) -> String? {
        guard output.isError else { return nil }
        return TraceRedaction.error(output.text)
    }

    /// The actor for a call from `client`.
    public static func actor(client: String?) -> TraceActor {
        .agent(client: TraceRedaction.word(client ?? "cli").isEmpty ? "cli" : TraceRedaction.word(client ?? "cli"))
    }
}
