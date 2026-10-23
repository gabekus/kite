import Foundation

/// What a driven tab has been doing, built from DevTools protocol events:
/// console messages, network requests, an open JavaScript dialog, and how
/// many requests are in flight (for `wait_for` network idle).
///
/// Kept only while Claude is driving the tab, and capped, so a chatty page
/// can't grow it without bound.
public struct TabActivity: Sendable {
    public struct ConsoleEntry: Hashable, Sendable {
        /// log, info, warning, error, debug; "exception" for uncaught errors.
        public var level: String
        public var text: String
        public var source: String?
        public var isError: Bool { level == "error" || level == "exception" || level == "assert" }
    }

    public struct Request: Hashable, Sendable {
        public var id: String
        public var method: String
        public var url: String
        public var type: String?
        public var status: Int?
        public var failure: String?
        public var finished: Bool
    }

    public struct Dialog: Hashable, Sendable {
        /// alert, confirm, prompt, beforeunload.
        public var kind: String
        public var message: String
        public var defaultPrompt: String?
    }

    public static let consoleCapacity = 1_000
    public static let networkCapacity = 1_000

    public private(set) var console: [ConsoleEntry] = []
    public private(set) var requests: [Request] = []
    public private(set) var dialog: Dialog?
    /// When the last request started or ended, for network idle.
    public private(set) var lastNetworkChange: Date = .distantPast
    private var requestIndex: [String: Int] = [:]

    public init() {}

    public var inFlight: Int { requests.lazy.filter { !$0.finished }.count }

    public mutating func clearConsole() { console.removeAll() }

    public mutating func clearNetwork() {
        requests.removeAll { $0.finished }
        reindex()
    }

    public mutating func dialogClosed() { dialog = nil }

    /// Takes one DevTools event. Returns true if it was one this log keeps.
    @discardableResult
    public mutating func ingest(method: String, params: JSONValue, now: Date = Date()) -> Bool {
        switch method {
        case "Runtime.consoleAPICalled":
            let args = params["args"]?.arrayValue ?? []
            let text = args.map(Self.describe).joined(separator: " ")
            let frame = params["stackTrace"]?["callFrames"]?[0]
            appendConsole(ConsoleEntry(level: Self.level(params["type"]?.stringValue ?? "log"), text: text,
                                       source: Self.location(frame?["url"]?.stringValue, frame?["lineNumber"]?.intValue.map { $0 + 1 })))
        case "Runtime.exceptionThrown":
            let details = params["exceptionDetails"]
            let text = details?["exception"]?["description"]?.stringValue ?? details?["text"]?.stringValue ?? "Uncaught error"
            appendConsole(ConsoleEntry(level: "exception", text: text,
                                       source: Self.location(details?["url"]?.stringValue, details?["lineNumber"]?.intValue.map { $0 + 1 })))
        case "Log.entryAdded":
            let entry = params["entry"]
            appendConsole(ConsoleEntry(level: entry?["level"]?.stringValue ?? "info", text: entry?["text"]?.stringValue ?? "",
                                       source: Self.location(entry?["url"]?.stringValue, entry?["lineNumber"]?.intValue.map { $0 + 1 })))
        case "Network.requestWillBeSent":
            guard let id = params["requestId"]?.stringValue, let request = params["request"] else { return false }
            let entry = Request(id: id, method: request["method"]?.stringValue ?? "GET", url: request["url"]?.stringValue ?? "",
                                type: params["type"]?.stringValue, status: nil, failure: nil, finished: false)
            if let i = requestIndex[id] {
                // A redirect reuses the id: the old hop is done, the new one starts.
                requests[i] = entry
            } else {
                requests.append(entry)
                if requests.count > Self.networkCapacity {
                    // Drop the oldest finished requests; in-flight ones still count for idleness.
                    if let oldest = requests.firstIndex(where: { $0.finished }) { requests.remove(at: oldest) }
                    else { requests.removeFirst() }
                }
                reindex()
            }
            lastNetworkChange = now
        case "Network.responseReceived":
            guard let i = params["requestId"]?.stringValue.flatMap({ requestIndex[$0] }) else { return false }
            requests[i].status = params["response"]?["status"]?.intValue
            if requests[i].type == nil { requests[i].type = params["type"]?.stringValue }
        case "Network.loadingFinished", "Network.loadingFailed":
            guard let i = params["requestId"]?.stringValue.flatMap({ requestIndex[$0] }) else { return false }
            requests[i].finished = true
            if method == "Network.loadingFailed" {
                requests[i].failure = params["errorText"]?.stringValue ?? "failed"
                if params["canceled"]?.boolValue == true { requests[i].failure = "canceled" }
            }
            lastNetworkChange = now
        case "Page.javascriptDialogOpening":
            dialog = Dialog(kind: params["type"]?.stringValue ?? "alert", message: params["message"]?.stringValue ?? "",
                            defaultPrompt: params["defaultPrompt"]?.stringValue)
        case "Page.javascriptDialogClosed":
            dialog = nil
        case "Page.frameNavigated" where params["frame"]?["parentId"] == nil:
            // A new document: requests from the old one will never finish.
            for i in requests.indices where !requests[i].finished { requests[i].finished = true }
            lastNetworkChange = now
        default:
            return false
        }
        return true
    }

    /// Quiet for `quietPeriod` with nothing in flight.
    public func isNetworkIdle(now: Date = Date(), quietPeriod: TimeInterval = 0.5) -> Bool {
        inFlight == 0 && now.timeIntervalSince(lastNetworkChange) >= quietPeriod
    }

    // MARK: Reports

    public func consoleReport(pattern: String?, onlyErrors: Bool, limit: Int) -> String {
        let regex = pattern.flatMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
        let matching = console.filter { entry in
            (!onlyErrors || entry.isError) && (regex.map { Self.matches($0, entry.text) } ?? true)
        }
        guard !matching.isEmpty else {
            return console.isEmpty ? "No console messages since Claude started driving this tab." : "No console messages match."
        }
        let shown = matching.suffix(limit)
        let lines = shown.map { entry in
            "[\(entry.level)] \(Self.truncate(entry.text, 500))" + (entry.source.map { " (\($0))" } ?? "")
        }
        return "\(matching.count) message\(matching.count == 1 ? "" : "s")\(matching.count > shown.count ? ", newest \(shown.count) shown" : ""):\n"
            + lines.joined(separator: "\n")
    }

    public func networkReport(urlPattern: String?, limit: Int) -> String {
        let regex = urlPattern.flatMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
        let matching = requests.filter { request in regex.map { Self.matches($0, request.url) } ?? true }
        guard !matching.isEmpty else {
            return requests.isEmpty ? "No network requests since Claude started driving this tab." : "No requests match."
        }
        let shown = matching.suffix(limit)
        let lines = shown.map { request -> String in
            let state = request.failure.map { "failed (\($0))" }
                ?? request.status.map(String.init) ?? (request.finished ? "done" : "pending")
            return "\(request.method) \(state) \(request.type ?? "-") \(Self.truncate(request.url, 400))"
        }
        return "\(matching.count) request\(matching.count == 1 ? "" : "s")\(matching.count > shown.count ? ", newest \(shown.count) shown" : ""):\n"
            + lines.joined(separator: "\n")
    }

    // MARK: Private

    private mutating func appendConsole(_ entry: ConsoleEntry) {
        console.append(entry)
        if console.count > Self.consoleCapacity { console.removeFirst(console.count - Self.consoleCapacity) }
    }

    private mutating func reindex() {
        requestIndex = Dictionary(requests.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    static func level(_ type: String) -> String {
        switch type {
        case "warning", "warn": "warning"
        case "error", "assert": type == "assert" ? "assert" : "error"
        case "debug", "trace": "debug"
        case "info": "info"
        default: "log"
        }
    }

    /// A console argument as DevTools would print it.
    static func describe(_ arg: JSONValue) -> String {
        if let value = arg["value"] {
            switch value {
            case .string(let string): return string
            case .number, .bool, .null: return (try? String(decoding: value.encoded(), as: UTF8.self)) ?? ""
            default: break
            }
        }
        if let unserializable = arg["unserializableValue"]?.stringValue { return unserializable }
        return arg["description"]?.stringValue ?? arg["type"]?.stringValue ?? ""
    }

    static func location(_ url: String?, _ line: Int?) -> String? {
        guard let url, !url.isEmpty else { return nil }
        return line.map { "\(url):\($0)" } ?? url
    }

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func truncate(_ text: String, _ limit: Int) -> String {
        text.count > limit ? text.prefix(limit - 1) + "…" : text
    }
}
