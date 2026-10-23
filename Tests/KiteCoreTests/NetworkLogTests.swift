import Foundation
import Testing
@testable import KiteCore

@Suite struct NetworkLogTests {
    private let tab = "11111111-2222-3333-4444-555555555555"

    /// A request going out, answered, and finishing, as Chromium reports it.
    private func load(_ log: inout NetworkLog, id: String, url: String, method: String = "GET", type: String = "Fetch",
                      status: Int = 200, start: Double = 100, end: Double = 100.25, tab: String? = nil,
                      requestHeaders: JSONValue = [:], responseHeaders: JSONValue = [:]) -> [NetworkLog.Entry] {
        let tab = tab ?? self.tab
        var done = log.ingest(method: "Network.requestWillBeSent", params: [
            "requestId": .string(id), "timestamp": .number(start), "wallTime": 1_760_000_000, "type": .string(type),
            "request": ["url": .string(url), "method": .string(method), "headers": requestHeaders],
            "initiator": ["type": "script", "stack": ["callFrames": [["url": "https://app.example/main.js", "lineNumber": 41]]]],
        ], tab: tab)
        done += log.ingest(method: "Network.responseReceived", params: [
            "requestId": .string(id), "type": .string(type),
            "response": [
                "status": .number(Double(status)), "statusText": "OK", "mimeType": "application/json", "protocol": "h2",
                "remoteIPAddress": "203.0.113.5", "remotePort": 443, "headers": responseHeaders,
                "timing": ["requestTime": .number(start + 0.01), "dnsStart": 0, "dnsEnd": 5, "connectStart": 5, "connectEnd": 30,
                           "sslStart": 12, "sslEnd": 30, "sendStart": 31, "sendEnd": 32, "receiveHeadersEnd": 200],
            ],
        ], tab: tab)
        done += log.ingest(method: "Network.loadingFinished",
                           params: ["requestId": .string(id), "timestamp": .number(end), "encodedDataLength": 1234], tab: tab)
        return done
    }

    @Test func recordsAFinishedRequestWithTimings() throws {
        var log = NetworkLog()
        let done = load(&log, id: "1", url: "https://api.example/v1/items?page=2")
        let entry = try #require(done.first)
        #expect(entry.seq == 1 && log.cursor == 1)
        #expect(entry.method == "GET" && entry.status == 200 && entry.type == "fetch")
        #expect(entry.httpVersion == "h2" && entry.remoteAddress == "203.0.113.5:443" && entry.transferSize == 1234)
        #expect(entry.initiator == "script https://app.example/main.js:42")
        #expect(abs((entry.duration ?? 0) - 250) < 0.001)
        let t = try #require(entry.timings)
        #expect(abs((t.blocked ?? 0) - 10) < 0.001)  // 10ms queued before requestTime, then dns starts at once
        #expect(t.dns == 5 && t.connect == 25 && t.ssl == 18 && t.send == 1 && t.wait == 168)
        #expect(abs((t.receive ?? 0) - 40) < 0.001)  // 240ms after requestTime, headers at 200
        #expect(NetworkLog.line(entry, showTab: false) == "#1 GET 200 fetch 250ms 1.2kB api.example/v1/items?page=2")
    }

    @Test func redirectsBecomeTheirOwnEntries() {
        var log = NetworkLog()
        _ = log.ingest(method: "Network.requestWillBeSent", params: [
            "requestId": "7", "timestamp": 10, "request": ["url": "http://a.example/", "method": "GET"], "type": "Document",
        ], tab: tab)
        let hop = log.ingest(method: "Network.requestWillBeSent", params: [
            "requestId": "7", "timestamp": 10.1, "request": ["url": "https://a.example/", "method": "GET"], "type": "Document",
            "redirectResponse": ["status": 301, "headers": ["Location": "https://a.example/"]],
        ], tab: tab)
        #expect(hop.count == 1)
        #expect(hop.first?.status == 301 && hop.first?.redirectedTo == "https://a.example/")
        _ = log.ingest(method: "Network.loadingFailed", params: ["requestId": "7", "timestamp": 10.2, "errorText": "net::ERR_ABORTED"], tab: tab)
        #expect(log.entries.map(\.seq) == [1, 2])
        #expect(log.entries.last?.failure == "net::ERR_ABORTED")
        #expect(log.entries.last?.isError == true)
    }

    @Test func requestIDsAreOnlyUniqueWithinATab() {
        var log = NetworkLog()
        let other = "99999999-2222-3333-4444-555555555555"
        _ = log.ingest(method: "Network.requestWillBeSent", params: ["requestId": "1", "request": ["url": "https://a.example/"]], tab: tab)
        _ = log.ingest(method: "Network.requestWillBeSent", params: ["requestId": "1", "request": ["url": "https://b.example/"]], tab: other)
        _ = log.ingest(method: "Network.loadingFinished", params: ["requestId": "1"], tab: other)
        #expect(log.entries.map(\.url) == ["https://b.example/"])
        log.forget(tab: tab)
        #expect(log.ingest(method: "Network.loadingFinished", params: ["requestId": "1"], tab: tab).isEmpty)
    }

    @Test func skipsDataURLs() {
        var log = NetworkLog()
        _ = log.ingest(method: "Network.requestWillBeSent", params: ["requestId": "1", "request": ["url": "data:image/png;base64,AAAA"]], tab: tab)
        #expect(log.ingest(method: "Network.loadingFinished", params: ["requestId": "1"], tab: tab).isEmpty)
    }

    @Test func cursorTailsAndFiltersAreCheap() {
        var log = NetworkLog()
        _ = load(&log, id: "1", url: "https://app.example/", type: "Document")
        _ = load(&log, id: "2", url: "https://cdn.example/logo.png", type: "Image")
        _ = load(&log, id: "3", url: "https://api.example/v1/me", status: 401)
        _ = load(&log, id: "4", url: "https://cdn.example/missing.css", type: "Stylesheet", status: 404)

        let all = log.report(NetworkLog.Query(), recording: true)
        // A successful image is hidden by default; a failing stylesheet isn't.
        #expect(!all.contains("logo.png") && all.contains("missing.css"))
        #expect(all.contains("(1 successful image/font/stylesheet/media requests hidden"))
        #expect(all.hasSuffix("cursor: 4"))
        #expect(all.contains("<untrusted-page-content"))

        #expect(log.matching(NetworkLog.Query(types: ["all"])).total == 4)
        #expect(log.matching(NetworkLog.Query(status: "errors")).shown.map(\.seq) == [3, 4])
        #expect(log.matching(NetworkLog.Query(status: "4xx", types: ["fetch"])).shown.map(\.seq) == [3])
        #expect(log.matching(NetworkLog.Query(host: "other.example")).total == 0)
        #expect(log.matching(NetworkLog.Query(host: "example", status: "errors")).total == 2)
        #expect(log.matching(NetworkLog.Query(host: "api.example")).shown.map(\.seq) == [3])
        #expect(log.matching(NetworkLog.Query(urlPattern: "V1/ME")).shown.map(\.seq) == [3])

        // Tail: nothing new, then only what's new.
        #expect(log.report(NetworkLog.Query(since: 4), recording: true) == "No new requests.\ncursor: 4")
        _ = load(&log, id: "5", url: "https://api.example/v1/items", method: "POST")
        let tail = log.report(NetworkLog.Query(since: 4), recording: true)
        #expect(tail.contains("#5 POST 200 fetch") && !tail.contains("#3"))
        #expect(tail.hasSuffix("cursor: 5"))
        #expect(log.matching(NetworkLog.Query(types: ["all"], limit: 2)).shown.map(\.seq) == [4, 5])
        #expect(log.entry(3)?.status == 401 && log.entry(6) == nil)
    }

    @Test func leavesOutTabsTheUserTookBack() {
        var log = NetworkLog()
        let other = "99999999-2222-3333-4444-555555555555"
        _ = load(&log, id: "1", url: "https://a.example/")
        _ = load(&log, id: "1", url: "https://b.example/", tab: other)
        var query = NetworkLog.Query()
        query.excludedTabs = [other]
        #expect(log.matching(query).shown.map(\.url) == ["https://a.example/"])
        // Several tabs in one listing say which is which.
        #expect(log.report(NetworkLog.Query(), recording: true).contains("[9999]"))
    }

    @Test func explainsAnEmptyLog() {
        let log = NetworkLog()
        #expect(log.report(NetworkLog.Query(), recording: false).contains("Record Network for Claude"))
        #expect(log.report(NetworkLog.Query(), recording: true).hasPrefix("No requests yet."))
    }

    @Test func redactsHeadersAsItRecords() throws {
        var log = NetworkLog()
        let entry = try #require(load(&log, id: "1", url: "https://api.example/x", requestHeaders: [
            "Authorization": "Bearer abc.def", "Cookie": "sid=s3cret; theme=dark", "X-Request-Id": "r-1", "X-Session-Token": "t",
            "Accept": "application/json",
        ], responseHeaders: [
            "Set-Cookie": "sid=new; Path=/; HttpOnly\nlang=en; Path=/", "Access-Control-Allow-Credentials": "true",
            "WWW-Authenticate": "Bearer realm=\"api\"", "Content-Type": "application/json",
        ]).first)
        let request = Dictionary(entry.requestHeaders.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
        #expect(request["Authorization"] == "[redacted]")
        #expect(request["Cookie"] == "sid=[redacted]; theme=[redacted]")
        #expect(request["X-Session-Token"] == "[redacted]")
        #expect(request["X-Request-Id"] == "r-1" && request["Accept"] == "application/json")
        let response = entry.responseHeaders.map { "\($0.name): \($0.value)" }
        #expect(response.contains("Set-Cookie: sid=[redacted]; Path=/; HttpOnly"))
        #expect(response.contains("Set-Cookie: lang=[redacted]; Path=/"))
        #expect(response.contains("Access-Control-Allow-Credentials: true"))
        #expect(response.contains("WWW-Authenticate: Bearer realm=\"api\""))
        // The detail view and anything saved only ever see the redacted values.
        let detail = NetworkLog.detail(entry, headers: true)
        #expect(!detail.contains("abc.def") && !detail.contains("s3cret"))
        let saved = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        #expect(!saved.contains("abc.def") && !saved.contains("s3cret"))
    }

    @Test func usesTheHeadersThatActuallyWentOut() throws {
        var log = NetworkLog()
        // Extra info can arrive before the request it belongs to.
        _ = log.ingest(method: "Network.requestWillBeSentExtraInfo", params: ["requestId": "1", "headers": ["cookie": "a=1", "accept": "*/*"]], tab: tab)
        _ = log.ingest(method: "Network.requestWillBeSent", params: ["requestId": "1", "request": ["url": "https://a.example/", "headers": ["Accept": "*/*"]]], tab: tab)
        _ = log.ingest(method: "Network.responseReceived", params: ["requestId": "1", "response": ["status": 200, "headers": ["a": "b"]]], tab: tab)
        _ = log.ingest(method: "Network.responseReceivedExtraInfo", params: ["requestId": "1", "headers": ["set-cookie": "a=2", "a": "b"]], tab: tab)
        let entry = try #require(log.ingest(method: "Network.loadingFinished", params: ["requestId": "1"], tab: tab).first)
        #expect(entry.requestHeaders.map(\.name) == ["accept", "cookie"])
        #expect(entry.requestHeaders.last?.value == "a=[redacted]")
        #expect(entry.responseHeaders.map(\.name) == ["a", "set-cookie"])
    }

    @Test func redactsURLs() {
        #expect(Redaction.url("https://a.example/cb?code=xyz&state=abc&page=2") == "https://a.example/cb?code=REDACTED&state=REDACTED&page=2")
        #expect(Redaction.url("https://user:pw@a.example:8443/x?access_token=t0k&q=shoes#id_token=jwt&x=1")
            == "https://user@a.example:8443/x?access_token=REDACTED&q=shoes#id_token=REDACTED&x=1")
        #expect(Redaction.url("https://a.example/#/route") == "https://a.example/#/route")
        #expect(Redaction.url("https://a.example/search?q=monkey&keyboard=1") == "https://a.example/search?q=monkey&keyboard=1")
        #expect(Redaction.url("https://s3.example/o?X-Amz-Signature=abc&X-Amz-Date=1").contains("X-Amz-Date=1"))
        #expect(!Redaction.url("https://s3.example/o?X-Amz-Signature=abc&X-Amz-Date=1").contains("abc"))
    }

    @Test func redactsBodies() {
        let json = #"{"user":"gabe","access_token":"eyJ.abc","nested":{"client_secret":"s"},"count":3,"password":"p\"w"}"#
        let redacted = Redaction.body(json)
        #expect(!redacted.contains("eyJ.abc") && !redacted.contains(#""s""#) && !redacted.contains(#"p\"w"#))
        #expect(redacted.contains(#""user":"gabe""#) && redacted.contains(#""count":3"#))
        #expect(Redaction.body("username=g&password=hunter2&remember=1") == "username=g&password=[redacted]&remember=1")
        #expect(Redaction.body("<p>a=b</p>\n") == "<p>a=b</p>\n")
        #expect(Redaction.body("if(a==b&&key=1)run()") == "if(a==b&&key=1)run()")
    }

    @Test func exportsHAR() throws {
        var log = NetworkLog()
        let entries = load(&log, id: "1", url: "https://api.example/v1/items?page=2&token=abc", requestHeaders: ["Authorization": "x"])
        let har = log.har(entries, bodies: [1: (text: #"{"ok":true}"#, base64: false)])
        let entry = try #require(har["log"]?["entries"]?[0])
        #expect(har["log"]?["version"] == "1.2")
        #expect(entry["request"]?["method"] == "GET")
        #expect(entry["request"]?["queryString"]?.arrayValue?.count == 2)
        #expect(entry["response"]?["status"] == 200)
        #expect(entry["response"]?["content"]?["text"] == #"{"ok":true}"#)
        #expect(entry["timings"]?["wait"] == 168)
        #expect(entry["timings"]?["blocked"]?.doubleValue.map { abs($0 - 10) < 0.01 } == true)
        #expect(entry["startedDateTime"]?.stringValue?.hasPrefix("2025-10-09T") == true)
        let text = String(decoding: try har.encoded(), as: UTF8.self)
        #expect(!text.contains("token=abc") && !text.contains(#""value":"x""#))
    }
}

@Suite struct NetworkLogStoreTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kite-netlog-\(UUID().uuidString)", isDirectory: true)
    }

    private func entry(_ seq: Int) -> NetworkLog.Entry {
        NetworkLog.Entry(seq: seq, tab: "T", requestID: "\(seq)", time: 0, method: "GET", url: "https://a.example/\(seq)")
    }

    @Test func writesOneLinePerRequestReadableOnlyByTheUser() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let store = NetworkLogStore(directory: dir, calendar: calendar)
        let now = Date(timeIntervalSince1970: 1_760_000_000)  // 2025-10-09
        store.append([entry(1), entry(2)], now: now)
        store.append([entry(3)], now: now)
        store.flush()
        let file = dir.appendingPathComponent("2025-10-09.ndjson")
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 3)
        let decoded = try JSONDecoder().decode(NetworkLog.Entry.self, from: Data(lines[2].utf8))
        #expect(decoded.seq == 3 && decoded.url == "https://a.example/3")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let dirAttributes = try FileManager.default.attributesOfItem(atPath: dir.path)
        #expect((dirAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func keepsAWeek() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["2025-10-01", "2025-10-02", "2025-10-08"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name + ".ndjson").path, contents: Data())
        }
        let store = NetworkLogStore(directory: dir, calendar: calendar)
        store.prune(now: Date(timeIntervalSince1970: 1_760_000_000))  // 2025-10-09: keeps the 2nd through today
        store.flush()
        #expect(store.files().map(\.lastPathComponent) == ["2025-10-02.ndjson", "2025-10-08.ndjson"])
    }

    @Test func stopsAtTheDailyLimit() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NetworkLogStore(directory: dir, dailyLimit: 600)
        for seq in 1...20 { store.append([entry(seq)]) }
        store.flush()
        let text = try String(contentsOf: try #require(store.files().first), encoding: .utf8)
        #expect(text.contains("size limit"))
        #expect(text.utf8.count < 1_000)
    }

    @Test func exportsHARFiles() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NetworkLogStore(directory: dir)
        let now = Date()
        let first = try store.export(["log": [:]], now: now)
        let second = try store.export(["log": [:]], now: now)
        #expect(first != second && first.pathExtension == "har")
        let attributes = try FileManager.default.attributesOfItem(atPath: second.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
