import Foundation

/// A HAR-style record of every request in the tabs Kite watches, built from
/// DevTools `Network.*` events: method, URL, status, type, timing, sizes and
/// headers. Secrets are redacted as entries are made, so nothing unredacted is
/// kept, listed or written to disk. Bodies are never kept; `network_request`
/// fetches one from Chromium while the page still has it.
///
/// Each finished request gets the next `seq`, so `since` is a cursor: asking
/// for entries after the last one seen is a cheap tail.
public struct NetworkLog: Sendable {
    public struct Header: Codable, Hashable, Sendable {
        public var name: String
        public var value: String
        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    /// HAR's phases, in milliseconds. nil when the phase didn't happen (a reused connection has no dns or connect).
    public struct Timings: Codable, Hashable, Sendable {
        public var blocked: Double?
        public var dns: Double?
        public var connect: Double?
        public var ssl: Double?
        public var send: Double?
        public var wait: Double?
        public var receive: Double?
    }

    public struct Entry: Codable, Hashable, Sendable {
        public var seq: Int
        /// Kite's tab id.
        public var tab: String
        /// Chromium's id for the request, for fetching its body while the page lives.
        public var requestID: String
        /// Wall clock, seconds since 1970.
        public var time: Double
        public var method: String
        public var url: String
        /// Chromium's resource type, lowercased: document, xhr, fetch, script, image, ...
        public var type: String?
        public var status: Int?
        public var statusText: String?
        public var mimeType: String?
        public var httpVersion: String?
        public var remoteAddress: String?
        public var fromCache: Bool = false
        public var failure: String?
        /// From the request going out to the last byte (or the failure), in milliseconds.
        public var duration: Double?
        public var timings: Timings?
        /// Bytes over the wire, headers included.
        public var transferSize: Int?
        public var hasRequestBody: Bool = false
        /// "parser https://…/page", "script https://…/app.js", "other".
        public var initiator: String?
        public var redirectedTo: String?
        public var requestHeaders: [Header] = []
        public var responseHeaders: [Header] = []

        public var isError: Bool { failure != nil || (status ?? 0) >= 400 }
    }

    /// What `network_log` asks for.
    public struct Query: Hashable, Sendable {
        public var tab: String?
        /// Only entries with a larger seq (the cursor from the last call).
        public var since: Int?
        public var urlPattern: String?
        /// The host or any subdomain of it.
        public var host: String?
        /// "2xx", "3xx", "4xx", "5xx", or "errors" (4xx, 5xx and failures).
        public var status: String?
        /// Resource types to include, lowercased; nil hides successful static files; ["all"] shows everything.
        public var types: Set<String>?
        public var limit: Int
        /// Tabs the user took away from Claude.
        public var excludedTabs: Set<String> = []

        public init(tab: String? = nil, since: Int? = nil, urlPattern: String? = nil, host: String? = nil, status: String? = nil,
                    types: Set<String>? = nil, limit: Int = NetworkLog.defaultLimit) {
            self.tab = tab
            self.since = since
            self.urlPattern = urlPattern
            self.host = host
            self.status = status
            self.types = types
            self.limit = limit
        }
    }

    public static let capacity = 5_000
    public static let pendingCapacity = 2_000
    public static let defaultLimit = 50
    public static let statusFilters = ["2xx", "3xx", "4xx", "5xx", "errors"]
    /// Hidden by default when they load fine: they rarely matter when debugging and cost the most lines.
    public static let staticTypes: Set<String> = ["image", "font", "stylesheet", "media", "texttrack", "manifest"]

    public private(set) var entries: [Entry] = []
    /// The seq of the newest entry (0 before any).
    public private(set) var cursor = 0

    private struct Pending: Sendable {
        var entry: Entry
        /// Chromium's monotonic clock, seconds, when the request went out.
        var start: Double
        /// `response.timing.requestTime` and the phase offsets (ms) from it.
        var timing: [String: Double] = [:]
        var rawRequestHeaders: [Header]?
        var rawResponseHeaders: [Header]?
    }

    /// Keyed by tab and request id: ids are only unique within a tab.
    private var pending: [String: Pending] = [:]
    private var pendingOrder: [String] = []
    /// Extra-info headers that arrived before their request.
    private var earlyHeaders: [String: (request: [Header]?, response: [Header]?)] = [:]

    public init() {}

    public mutating func clear() {
        entries.removeAll()
        pending.removeAll()
        pendingOrder.removeAll()
        earlyHeaders.removeAll()
    }

    /// Drops a closed tab's unfinished requests. Its finished ones stay in the log.
    public mutating func forget(tab: String) {
        let prefix = tab + "|"
        pending = pending.filter { !$0.key.hasPrefix(prefix) }
        pendingOrder.removeAll { !pending.keys.contains($0) }
        earlyHeaders = earlyHeaders.filter { !$0.key.hasPrefix(prefix) }
    }

    public func entry(_ seq: Int) -> Entry? {
        // Seqs are consecutive, so the position is known unless the log was cleared.
        guard let first = entries.first, seq >= first.seq else { return nil }
        let index = seq - first.seq
        if entries.indices.contains(index), entries[index].seq == seq { return entries[index] }
        return entries.first { $0.seq == seq }
    }

    /// Takes one DevTools event from a tab. Returns the requests it finished, to save.
    @discardableResult
    public mutating func ingest(method: String, params: JSONValue, tab: String) -> [Entry] {
        guard let id = params["requestId"]?.stringValue else { return [] }
        let key = tab + "|" + id
        switch method {
        case "Network.requestWillBeSent":
            guard let request = params["request"], let url = request["url"]?.stringValue,
                  !url.hasPrefix("data:"), !url.hasPrefix("blob:") else { return [] }
            var finished: [Entry] = []
            // A redirect reuses the id: the hop before it is done.
            if let redirect = params["redirectResponse"], var hop = pending[key] {
                Self.apply(response: redirect, to: &hop)
                hop.entry.redirectedTo = Redaction.url(url)
                if let done = finish(hop, at: params["timestamp"]?.doubleValue, encodedLength: nil) { finished.append(done) }
            }
            var entry = Entry(seq: 0, tab: tab, requestID: id, time: params["wallTime"]?.doubleValue ?? Date().timeIntervalSince1970,
                              method: request["method"]?.stringValue ?? "GET", url: Redaction.url(url))
            entry.type = params["type"]?.stringValue?.lowercased()
            entry.hasRequestBody = request["hasPostData"]?.boolValue == true || request["postData"] != nil
            entry.requestHeaders = Self.headers(request["headers"])
            entry.initiator = Self.initiator(params["initiator"])
            var item = Pending(entry: entry, start: params["timestamp"]?.doubleValue ?? 0)
            if let early = earlyHeaders.removeValue(forKey: key) {
                item.rawRequestHeaders = early.request
                item.rawResponseHeaders = early.response
            }
            if pending[key] == nil { pendingOrder.append(key) }
            pending[key] = item
            if pendingOrder.count > Self.pendingCapacity {
                // Requests that never finish (a tab that went away mid-load) can't pile up.
                pending[pendingOrder.removeFirst()] = nil
            }
            return finished
        case "Network.requestWillBeSentExtraInfo":
            // The headers that actually went out, cookies included (redacted when kept).
            let headers = Self.headers(params["headers"])
            if pending[key] != nil { pending[key]!.rawRequestHeaders = headers } else { earlyHeaders[key, default: (nil, nil)].request = headers }
        case "Network.responseReceivedExtraInfo":
            let headers = Self.headers(params["headers"])
            if pending[key] != nil { pending[key]!.rawResponseHeaders = headers } else { earlyHeaders[key, default: (nil, nil)].response = headers }
            if earlyHeaders.count > Self.pendingCapacity { earlyHeaders.removeAll() }
        case "Network.responseReceived":
            guard pending[key] != nil, let response = params["response"] else { return [] }
            Self.apply(response: response, to: &pending[key]!)
            if pending[key]!.entry.type == nil { pending[key]!.entry.type = params["type"]?.stringValue?.lowercased() }
        case "Network.loadingFinished", "Network.loadingFailed":
            guard var item = pending.removeValue(forKey: key) else { return [] }
            pendingOrder.removeAll { $0 == key }
            if method == "Network.loadingFailed" {
                let blocked = params["blockedReason"]?.stringValue
                item.entry.failure = params["canceled"]?.boolValue == true ? "canceled"
                    : blocked.map { "blocked (\($0))" } ?? params["errorText"]?.stringValue ?? "failed"
                if item.entry.type == nil { item.entry.type = params["type"]?.stringValue?.lowercased() }
            }
            return finish(item, at: params["timestamp"]?.doubleValue, encodedLength: params["encodedDataLength"]?.intValue).map { [$0] } ?? []
        default:
            break
        }
        return []
    }

    // MARK: Reading

    public func matching(_ query: Query) -> (shown: [Entry], total: Int, hiddenStatic: Int) {
        let regex = query.urlPattern.flatMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
        let host = query.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        var hiddenStatic = 0
        let since = query.since ?? 0
        var matches: [Entry] = []
        // Newest last; walk only what's after the cursor.
        let start = entries.firstIndex { $0.seq > since } ?? entries.endIndex
        for entry in entries[start...] {
            if let tab = query.tab, entry.tab.lowercased() != tab.lowercased() { continue }
            if query.excludedTabs.contains(entry.tab) { continue }
            if let host {
                let entryHost = URLComponents(string: entry.url)?.host?.lowercased() ?? ""
                if entryHost != host && !entryHost.hasSuffix("." + host) { continue }
            }
            if let regex, !TabActivity.matches(regex, entry.url) { continue }
            if let status = query.status, !Self.status(entry, matches: status) { continue }
            if let types = query.types {
                if !types.contains("all") && !types.contains(entry.type ?? "other") { continue }
            } else if Self.staticTypes.contains(entry.type ?? ""), !entry.isError {
                hiddenStatic += 1
                continue
            }
            matches.append(entry)
        }
        return (Array(matches.suffix(query.limit)), matches.count, hiddenStatic)
    }

    /// One short line per request (page-controlled, so wrapped as untrusted), then the cursor.
    /// Built to be cheap for a model to read.
    public func report(_ query: Query, recording: Bool) -> String {
        let (shown, total, hiddenStatic) = matching(query)
        var lines: [String] = []
        if shown.isEmpty {
            if entries.isEmpty {
                lines.append(recording ? "No requests yet." : "No requests yet. Only tabs Claude has driven are logged; "
                    + "the user can turn on Record Network for Claude in Kite's menu to log every tab.")
            } else {
                lines.append(query.since != nil ? "No new requests." : "No requests match.")
            }
        } else {
            let tabs = Set(shown.map(\.tab))
            lines.append("\(total) request\(total == 1 ? "" : "s")" + (total > shown.count ? ", newest \(shown.count) shown" : "") + ":")
            lines.append(UntrustedContent.wrap(shown.map { Self.line($0, showTab: tabs.count > 1) }.joined(separator: "\n"),
                                               source: "network log"))
        }
        if hiddenStatic > 0 { lines.append("(\(hiddenStatic) successful image/font/stylesheet/media requests hidden; type \"all\" shows them)") }
        lines.append("cursor: \(cursor)")
        return lines.joined(separator: "\n")
    }

    /// `#12 GET 200 fetch 85ms 1.2kB api.example.com/v1/items?page=2`
    static func line(_ entry: Entry, showTab: Bool) -> String {
        // Chromium fails a document with an empty error response (a bare 404) after its status arrived.
        let state = entry.failure.map { (entry.status.map { "\($0) " } ?? "") + "ERR(\($0))" } ?? entry.status.map(String.init) ?? "-"
        var parts = ["#\(entry.seq)"]
        if showTab { parts.append("[" + entry.tab.prefix(4).lowercased() + "]") }
        parts += [entry.method, state, entry.type ?? "other"]
        if let duration = entry.duration { parts.append(Self.milliseconds(duration)) }
        if let size = entry.transferSize, size > 0 { parts.append(Self.bytes(size)) }
        if entry.fromCache { parts.append("cached") }
        var url = entry.url
        for scheme in ["https://", "http://"] where url.hasPrefix(scheme) { url.removeFirst(scheme.count) }
        parts.append(TabActivity.truncate(url, 200))
        if let to = entry.redirectedTo { parts.append("→ " + TabActivity.truncate(to, 120)) }
        return parts.joined(separator: " ")
    }

    /// Everything about one request, for `network_request`. Bodies are added by the caller.
    public static func detail(_ entry: Entry, headers: Bool) -> String {
        var lines = ["#\(entry.seq) \(entry.method) \(entry.url)"]
        var status = entry.failure.map { "Failed: \($0)" } ?? entry.status.map { "Status: \($0)" + (entry.statusText.map { " \($0)" } ?? "") } ?? "Status: pending"
        if let version = entry.httpVersion { status += " · \(version)" }
        if let size = entry.transferSize { status += " · \(bytes(size))" }
        if let duration = entry.duration { status += " · \(milliseconds(duration))" }
        if entry.fromCache { status += " · from cache" }
        lines.append(status)
        var about = "Type: \(entry.type ?? "other")"
        if let mime = entry.mimeType { about += " · \(mime)" }
        if let initiator = entry.initiator { about += " · initiator: \(TabActivity.truncate(initiator, 300))" }
        lines.append(about)
        lines.append("Tab: \(entry.tab) · started \(timestamp(entry.time))" + (entry.remoteAddress.map { " · server \($0)" } ?? ""))
        if let to = entry.redirectedTo { lines.append("Redirected to: \(to)") }
        if let t = entry.timings {
            let phases: [(String, Double?)] = [("blocked", t.blocked), ("dns", t.dns), ("connect", t.connect), ("ssl", t.ssl),
                                              ("send", t.send), ("wait", t.wait), ("receive", t.receive)]
            let shown = phases.compactMap { name, value in value.map { "\(name) \(milliseconds($0))" } }
            if !shown.isEmpty { lines.append("Timing: " + shown.joined(separator: " · ")) }
        }
        if headers {
            lines.append("Request headers:" + (entry.requestHeaders.isEmpty ? " (none recorded)" : ""))
            lines += entry.requestHeaders.map { "  \($0.name): \(TabActivity.truncate($0.value, 500))" }
            if entry.status != nil {
                lines.append("Response headers:" + (entry.responseHeaders.isEmpty ? " (none recorded)" : ""))
                lines += entry.responseHeaders.map { "  \($0.name): \(TabActivity.truncate($0.value, 500))" }
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: HAR

    /// HAR 1.2. `bodies` maps seq to a response body already fetched (and redacted).
    public func har(_ entries: [Entry], bodies: [Int: (text: String, base64: Bool)] = [:], version: String = "0.1.0") -> JSONValue {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func headers(_ list: [Header]) -> JSONValue { .array(list.map { ["name": .string($0.name), "value": .string($0.value)] }) }
        func ms(_ value: Double?) -> JSONValue { .number(value.map { ($0 * 1000).rounded() / 1000 } ?? -1) }
        let items: [JSONValue] = entries.map { entry in
            let query = URLComponents(string: entry.url)?.queryItems ?? []
            var content: [String: JSONValue] = ["size": .number(-1), "mimeType": .string(entry.mimeType ?? "")]
            if let body = bodies[entry.seq] {
                content["text"] = .string(body.text)
                if body.base64 { content["encoding"] = "base64" }
            }
            let t = entry.timings
            var item: [String: JSONValue] = [
                "startedDateTime": .string(formatter.string(from: Date(timeIntervalSince1970: entry.time))),
                "time": .number(max(0, entry.duration ?? 0)),
                "request": [
                    "method": .string(entry.method), "url": .string(entry.url), "httpVersion": .string(entry.httpVersion ?? ""),
                    "headers": headers(entry.requestHeaders), "cookies": [],
                    "queryString": .array(query.map { ["name": .string($0.name), "value": .string($0.value ?? "")] }),
                    "headersSize": -1, "bodySize": .number(entry.hasRequestBody ? -1 : 0),
                ],
                "response": [
                    "status": .number(Double(entry.status ?? 0)), "statusText": .string(entry.statusText ?? ""),
                    "httpVersion": .string(entry.httpVersion ?? ""), "headers": headers(entry.responseHeaders), "cookies": [],
                    "content": .object(content), "redirectURL": .string(entry.redirectedTo ?? ""),
                    "headersSize": -1, "bodySize": .number(Double(entry.transferSize ?? -1)),
                ],
                "cache": [:],
                // HAR requires send, wait and receive; the rest are -1 when they didn't happen.
                "timings": [
                    "blocked": ms(t?.blocked), "dns": ms(t?.dns), "connect": ms(t?.connect), "ssl": ms(t?.ssl),
                    "send": ms(t?.send ?? 0), "wait": ms(t?.wait ?? entry.duration ?? 0), "receive": ms(t?.receive ?? 0),
                ],
                "_kiteSeq": .number(Double(entry.seq)), "_kiteTab": .string(entry.tab),
                "_resourceType": .string(entry.type ?? "other"),
            ]
            if let address = entry.remoteAddress { item["serverIPAddress"] = .string(address) }
            if let failure = entry.failure { item["_error"] = .string(failure) }
            return .object(item)
        }
        return ["log": [
            "version": "1.2", "creator": ["name": "Kite", "version": .string(version)],
            "pages": [], "entries": .array(items),
        ]]
    }

    // MARK: Private

    private mutating func finish(_ item: Pending, at timestamp: Double?, encodedLength: Int?) -> Entry? {
        var entry = item.entry
        if let raw = item.rawRequestHeaders, !raw.isEmpty { entry.requestHeaders = raw }
        if let raw = item.rawResponseHeaders, !raw.isEmpty, entry.status != nil { entry.responseHeaders = raw }
        entry.requestHeaders = Redaction.headers(entry.requestHeaders)
        entry.responseHeaders = Redaction.headers(entry.responseHeaders)
        if let encodedLength { entry.transferSize = encodedLength }
        if let timestamp, item.start > 0 {
            entry.duration = max(0, (timestamp - item.start) * 1000)
            entry.timings = Self.timings(item.timing, start: item.start, end: timestamp)
        }
        cursor += 1
        entry.seq = cursor
        entries.append(entry)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        return entry
    }

    private static func apply(response: JSONValue, to item: inout Pending) {
        item.entry.status = response["status"]?.intValue
        item.entry.statusText = response["statusText"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        item.entry.mimeType = response["mimeType"]?.stringValue
        item.entry.httpVersion = response["protocol"]?.stringValue
        if let ip = response["remoteIPAddress"]?.stringValue, !ip.isEmpty {
            item.entry.remoteAddress = ip + (response["remotePort"]?.intValue.map { ":\($0)" } ?? "")
        }
        item.entry.fromCache = response["fromDiskCache"]?.boolValue == true || response["fromPrefetchCache"]?.boolValue == true
            || response["fromServiceWorker"]?.boolValue == true
        item.entry.responseHeaders = headers(response["headers"])
        if let size = response["encodedDataLength"]?.intValue, size > 0 { item.entry.transferSize = size }
        if case .object(let timing)? = response["timing"] {
            item.timing = timing.compactMapValues(\.doubleValue)
        }
    }

    /// Chromium's ResourceTiming (offsets in ms from requestTime; -1 when a phase didn't happen) as HAR phases.
    static func timings(_ t: [String: Double], start: Double, end: Double) -> Timings? {
        guard let requestTime = t["requestTime"], let sendStart = t["sendStart"], sendStart >= 0 else { return nil }
        func span(_ from: String, _ to: String) -> Double? {
            guard let a = t[from], let b = t[to], a >= 0, b >= a else { return nil }
            return b - a
        }
        // Time queued before requestTime counts as blocked, as in Chrome's HAR export.
        let queued = max(0, (requestTime - start) * 1000)
        let firstPhase = [t["dnsStart"], t["connectStart"], t["sendStart"]].compactMap { $0 }.first { $0 >= 0 } ?? sendStart
        let headersEnd = t["receiveHeadersEnd"] ?? sendStart
        let sendEnd = t["sendEnd"] ?? sendStart
        var timings = Timings()
        timings.blocked = queued + firstPhase
        timings.dns = span("dnsStart", "dnsEnd")
        timings.connect = span("connectStart", "connectEnd")
        timings.ssl = span("sslStart", "sslEnd")
        timings.send = max(0, sendEnd - sendStart)
        timings.wait = max(0, headersEnd - sendEnd)
        timings.receive = max(0, (end - requestTime) * 1000 - headersEnd)
        return timings
    }

    private static func headers(_ value: JSONValue?) -> [Header] {
        guard case .object(let object)? = value else { return [] }
        // Chromium joins repeated headers (Set-Cookie) with newlines.
        return object.keys.sorted { $0.lowercased() < $1.lowercased() }.flatMap { name in
            (object[name]?.stringValue ?? "").split(separator: "\n", omittingEmptySubsequences: false)
                .map { Header(name: name, value: String($0)) }
        }
    }

    private static func initiator(_ value: JSONValue?) -> String? {
        guard let value, let type = value["type"]?.stringValue else { return nil }
        let url = value["url"]?.stringValue ?? value["stack"]?["callFrames"]?[0]?["url"]?.stringValue
        guard let url, !url.isEmpty else { return type }
        let line = value["lineNumber"]?.intValue ?? value["stack"]?["callFrames"]?[0]?["lineNumber"]?.intValue
        return "\(type) \(Redaction.url(url))" + (line.map { ":\($0 + 1)" } ?? "")
    }

    private static func status(_ entry: Entry, matches filter: String) -> Bool {
        switch filter {
        case "errors": return entry.isError
        default:
            guard let status = entry.status, let digit = filter.first?.wholeNumberValue else { return false }
            return status / 100 == digit
        }
    }

    static func milliseconds(_ ms: Double) -> String {
        ms >= 10_000 ? String(format: "%.1fs", ms / 1000) : "\(Int(ms.rounded()))ms"
    }

    static func bytes(_ count: Int) -> String {
        switch count {
        case ..<1_000: "\(count)B"
        case ..<1_000_000: String(format: "%.1fkB", Double(count) / 1_000)
        default: String(format: "%.1fMB", Double(count) / 1_000_000)
        }
    }

    static func timestamp(_ time: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: Date(timeIntervalSince1970: time))
    }
}

/// Takes secrets out of what the network log keeps: cookie values, credentials in
/// headers, and token-like query parameters and body fields. Names stay, so it's
/// still clear what was sent.
public enum Redaction {
    public static let mask = "[redacted]"

    /// Headers whose value is always a credential.
    static let secretHeaders: Set<String> = [
        "authorization", "proxy-authorization", "x-api-key", "api-key", "x-csrf-token", "x-xsrf-token", "x-auth-token",
        "x-amz-security-token", "x-goog-api-key",
    ]
    /// Any name containing one of these is treated as secret.
    static let secretWords = ["token", "secret", "password", "passwd", "auth", "session", "apikey", "api_key", "api-key",
                              "signature", "credential", "cookie", "jwt", "csrf", "xsrf"]
    /// Query and body field names that are secret on their own but too short to match inside other words.
    static let secretNames: Set<String> = ["key", "sig", "code", "pwd", "pass", "otp", "sid", "ticket", "nonce", "state", "hash"]

    public static func isSecret(_ name: String) -> Bool {
        let lower = name.lowercased()
        if secretHeaders.contains(lower) || secretNames.contains(lower) { return true }
        if secretWords.contains(where: { lower.contains($0) }) { return true }
        // "access_key", "x-amz-signature", "client.sig"
        let parts = lower.split(whereSeparator: { "_-.[]".contains($0) }).map(String.init)
        return parts.contains { secretNames.contains($0) }
    }

    /// Headers whose names look secret but whose values aren't: CORS and auth challenges, which matter when debugging.
    static func publicHeader(_ lower: String) -> Bool {
        lower.hasPrefix("access-control-") || lower == "www-authenticate" || lower == "proxy-authenticate"
    }

    public static func headers(_ headers: [NetworkLog.Header]) -> [NetworkLog.Header] {
        headers.map { header in
            var header = header
            switch header.name.lowercased() {
            case "cookie":
                // Which cookies went, not their values.
                header.value = header.value.split(separator: ";").map { pair in
                    let name = pair.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    return "\(name)=\(mask)"
                }.joined(separator: "; ")
            case "set-cookie":
                // The cookie's name and attributes, not its value.
                var parts = header.value.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
                if let first = parts.first {
                    let name = first.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    parts[0] = "\(name)=\(mask)"
                }
                header.value = parts.joined(separator: ";")
            case let name where isSecret(name) && !publicHeader(name):
                header.value = mask
            default:
                break
            }
            return header
        }
    }

    /// What stands in for a secret inside a URL, where brackets would make it unparseable.
    public static let urlMask = "REDACTED"

    /// The URL with secret query or fragment parameters masked and any password in it removed.
    public static func url(_ string: String) -> String {
        var url = string.count > 4_000 ? String(string.prefix(4_000)) : string
        // https://user:password@host → https://user@host
        if let scheme = url.range(of: "://") {
            let authority = url[scheme.upperBound...].prefix { !"/?#".contains($0) }
            if let at = authority.lastIndex(of: "@"), let colon = authority[..<at].firstIndex(of: ":") {
                url.removeSubrange(colon..<at)
            }
        }
        var fragment: String?
        if let hash = url.firstIndex(of: "#") {
            fragment = String(url[url.index(after: hash)...])
            url = String(url[..<hash])
        }
        if let question = url.firstIndex(of: "?") {
            url = String(url[...question]) + form(String(url[url.index(after: question)...]), mask: urlMask)
        }
        // OAuth's implicit flow puts tokens in the fragment.
        if let fragment { url += "#" + (fragment.contains("=") ? form(fragment, mask: urlMask) : fragment) }
        return url
    }

    /// A request or response body with secret JSON fields and form fields masked.
    public static func body(_ text: String) -> String {
        var result = text
        // "access_token": "…"  (string values only; numbers and objects stay)
        if let json = try? NSRegularExpression(pattern: #""([^"\\]{1,100})"\s*:\s*"((?:[^"\\]|\\.)*)""#) {
            let matches = json.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                guard let nameRange = Range(match.range(at: 1), in: result), isSecret(String(result[nameRange])),
                      let valueRange = Range(match.range(at: 2), in: result) else { continue }
                result.replaceSubrange(valueRange, with: mask)
            }
        }
        // a=1&password=…  (a whole-body form)
        if result.wholeMatch(of: /[^\s=&]+=[^\s&]*(&[^\s=&]+=[^\s&]*)*/) != nil {
            result = form(result)
        }
        return result
    }

    /// `a=1&token=xyz` → `a=1&token=[redacted]`.
    static func form(_ string: String, mask: String = Redaction.mask) -> String {
        string.split(separator: "&", omittingEmptySubsequences: false).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return String(pair) }
            let name = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            return isSecret(name) ? "\(parts[0])=\(mask)" : String(pair)
        }.joined(separator: "&")
    }
}
