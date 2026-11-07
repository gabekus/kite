import Foundation
import Testing
@testable import KiteCore

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kite-trace-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func call(_ name: String, m: Double, dur: Double, conn: Int? = 1, ok: Bool = true, parent: String? = nil,
                  phases: [String: Double]? = nil, id: String? = nil) -> TraceRecord {
    var record = TraceRecord(kind: .call, name: name, t: 1_762_300_000_000 + m, m: m, dur: dur, actor: "agent:claude-code",
                             id: id ?? "x-\(Int(m))", parent: parent)
    record.conn = conn
    record.ok = ok
    record.phases = phases
    return record
}

private func event(_ name: String, m: Double, dur: Double? = nil, tab: String? = nil, host: String? = nil,
                   attrs: [String: JSONValue]? = nil, actor: String = "user") -> TraceRecord {
    var record = TraceRecord(kind: .event, name: name, t: 1_762_300_000_000 + m, m: m, dur: dur, actor: actor, attrs: attrs)
    record.tab = tab
    record.host = host
    return record
}

@Suite struct TraceRecordTests {
    @Test func encodesOneSortedLineWithTheSchemaVersion() throws {
        var record = TraceRecord(kind: .call, name: "click", t: 1_762_300_000_123.5, m: 98_765.25, dur: 184.5, actor: "agent:claude-code",
                                 id: "ab12-7")
        record.conn = 3
        record.client = "claude-code"
        record.session = "Cloudflare DNS move"
        record.tab = "3F2A0000-0000-0000-0000-000000000000"
        record.host = "example.com"
        record.path = "/login"
        record.hostEnd = "example.com"
        record.pathEnd = "/account"
        record.ok = true
        record.bytes = 512
        record.images = 0
        record.phases = ["js": 120, "wait": 60]
        record.attrs = ["target": "ref"]
        let line = String(decoding: try record.encoded(), as: UTF8.self)
        #expect(!line.contains("\n"))
        #expect(line.hasPrefix(#"{"actor":"agent:claude-code","attrs":{"target":"ref"},"bytes":512,"client":"claude-code","conn":3"#))
        #expect(line.contains(#""host_end":"example.com""#) && line.contains(#""path_end":"/account""#))
        #expect(line.contains(#""v":1"#))
        #expect(TraceRecord.decode(Data(line.utf8)) == record)
        #expect(record.mEnd == 98_765.25 + 184.5)
    }

    @Test func clocksMoveForward() {
        let a = TraceClock.now()
        let b = TraceClock.now()
        #expect(b.m >= a.m && a.m > 0)
        #expect(abs(a.t - Date().timeIntervalSince1970 * 1000) < 5_000)
    }

    @Test func actorsRoundTripAndFilter() {
        #expect(TraceActor.agent(client: "claude-code").name == "agent:claude-code")
        #expect(TraceActor.named("agent:cli") == .agent(client: "cli"))
        #expect(TraceActor.named("kite") == .kite && TraceActor.named("user") == .user)
        #expect(TraceActor.matches("agent:claude-code", filter: "agent"))
        #expect(!TraceActor.matches("agent:claude-code", filter: "user"))
        #expect(TraceActor.matches(nil, filter: "user"))
    }
}

@Suite struct TraceRedactionTests {
    @Test func urlsKeepHostAndPathWithQueryValuesStripped() {
        let place = TraceRedaction.place(URL(string: "https://me:hunter2@Shop.Example.com/cart/checkout?coupon=SAVE10&step=2#card")!)
        #expect(place.host == "shop.example.com")
        #expect(place.path == "/cart/checkout?coupon=&step=")
        #expect(TraceRedaction.place(URL(string: "https://example.com")!).path == "/")
    }

    @Test func idsTokensAndEmailsInPathsAreMasked() {
        let place = TraceRedaction.place(URL(string: "https://example.com/users/48213977/reset/k9Xq2LmP0zR7tY5wQe1/jane@example.com/settings")!)
        #expect(place.path == "/users/:n/reset/:id/:email/settings")
        #expect(TraceRedaction.place(URL(string: "https://example.com/orders/3f2a9c1e-77b0-4d2e-9f00-1c2d3e4f5a6b")!).path == "/orders/:id")
    }

    @Test func nonWebURLsKeepOnlyTheirScheme() {
        #expect(TraceRedaction.place(URL(string: "file:///Users/gabe/Taxes/2026.pdf")!) == ("file:", nil))
        #expect(TraceRedaction.place(URL(string: "data:text/html,secret")!).host == "data:")
        #expect(TraceRedaction.place(nil) == (nil, nil))
    }

    @Test func fieldRoles() {
        func role(_ element: ElementDescription) -> String { TraceRedaction.fieldRole(element) }
        #expect(role(ElementDescription(tag: "input", type: "password", name: "pw")) == "password")
        #expect(role(ElementDescription(tag: "input", autocomplete: "cc-number")) == "card")
        #expect(role(ElementDescription(tag: "input", name: "cardNumber")) == "card")
        #expect(role(ElementDescription(tag: "input", autocomplete: "one-time-code")) == "code")
        #expect(role(ElementDescription(tag: "input", label: "Enter your PIN")) == "code")
        #expect(role(ElementDescription(tag: "input", type: "email", name: "e")) == "email")
        #expect(role(ElementDescription(tag: "input", type: "tel")) == "phone")
        #expect(role(ElementDescription(tag: "input", name: "shipping_address_line1")) == "address")
        #expect(role(ElementDescription(tag: "input", name: "shippingZip")) == "address")
        #expect(role(ElementDescription(tag: "input", autocomplete: "given-name")) == "name")
        #expect(role(ElementDescription(tag: "input", type: "search", name: "q")) == "search")
        #expect(role(ElementDescription(tag: "input", label: "SSN")) == "id_number")
        #expect(role(ElementDescription(tag: "textarea", label: "Message")) == "text")
        #expect(role(ElementDescription(tag: "select", label: "Country")) == "address")
        #expect(TraceRedaction.fieldRole(nil) == "focused")
    }

    @Test func errorsLosePageContentAndQuotedText() {
        let message = "The script threw: " + UntrustedContent.wrap("Uncaught: card 4242 4242 4242 4242 declined", source: "page")
            + " and \"cmd+zz\" isn't a key; the page asks: “Delete jane@example.com?”"
        let redacted = TraceRedaction.error(message)
        #expect(!redacted.contains("4242") && !redacted.contains("jane@") && !redacted.contains("cmd+zz"))
        #expect(redacted.contains("[page content]") && redacted.contains("“…”") && redacted.contains("\"…\""))
        #expect(TraceRedaction.error(String(repeating: "a", count: 1000)).count <= TraceRedaction.maxError + 1)
    }

    @Test func accessibleNamesAreShortAndMasked() {
        #expect(TraceRedaction.accessibleName("  Sign   in ", role: "button") == "Sign in")
        #expect(TraceRedaction.accessibleName("Order 12345678 for jane@example.com", role: "link") == "Order ######## for :email")
        #expect(TraceRedaction.accessibleName("Hello", role: "textbox") == nil)
        #expect((TraceRedaction.accessibleName(String(repeating: "word ", count: 30), role: "button")?.count ?? 0) <= TraceRedaction.maxName + 1)
    }
}

/// The trace must be safe to hand to an eval pipeline: what was typed never reaches a record, in memory or on disk.
@Suite struct TraceTypedTextTests {
    static let secret = "SECRET-TYPED-hunter2-4242424242424242"

    static let calls: [(String, JSONValue)] = [
        ("type", ["text": .string(secret), "ref": "e1", "submit": true]),
        ("form_input", ["value": .string(secret), "ref": "e2"]),
        ("computer", ["action": "type", "text": .string(secret)]),
        ("computer", ["action": "key", "text": "cmd+a Backspace"]),
        ("find", ["query": .string(secret)]),
        ("javascript", ["code": .string("document.querySelector('#pw').value = '\(secret)'")]),
        ("handle_dialog", ["accept": true, "prompt_text": .string(secret)]),
        ("tab_status", ["state": "done", "note": .string(secret)]),
        ("navigate", ["url": .string("https://example.com/search?q=\(secret)")]),
        ("tabs_create", ["url": .string("https://example.com/?token=\(secret)"), "space": .string(secret), "session": "Taxes"]),
        ("handoff", ["reason": .string(secret), "steps": [["instruction": .string(secret)]]]),
        ("upload_file", ["ref": "e3", "paths": [.string("/Users/me/\(secret).pdf")]]),
        ("wait_for", ["condition": "text", "value": .string(secret)]),
        ("move_to_folder", ["folder": .string(secret)]),
        ("vpn", ["action": .string(secret)]),
    ]

    @Test func callAttributesNeverHoldTheText() throws {
        for (tool, arguments) in Self.calls {
            var record = TraceRecord(kind: .call, name: tool, t: 0, m: 0, actor: "agent:cli", attrs: TraceCall.attributes(tool: tool, arguments: arguments))
            record.error = TraceCall.error(of: .failure(AutomationError(.failed, "Couldn't type \"\(Self.secret)\": " + UntrustedContent.wrap(Self.secret))))
            let line = String(decoding: try record.encoded(), as: UTF8.self)
            #expect(!line.contains(Self.secret), "\(tool): \(line)")
            #expect(!line.contains("hunter2"), "\(tool)")
        }
        let typed = TraceCall.attributes(tool: "type", arguments: ["text": .string(Self.secret), "ref": "e1"])
        #expect(typed["len"] == .number(Double(Self.secret.count)) && typed["target"] == "ref")
        let keys = TraceCall.attributes(tool: "computer", arguments: ["action": "key", "text": "cmd+a Enter"])
        #expect(keys["keys"] == 2 && keys["enter"] == true && keys["shortcut"] == true)
        #expect(TraceCall.attributes(tool: "navigate", arguments: ["url": "back"])["nav"] == "back")
    }

    @Test func pageInputNeverHoldsTheValue() throws {
        // A page's report could carry anything: only known keys survive, and a field's value is never one of them.
        let blur = #"{"t":"blur","tag":"input","type":"password","name":"pw","len":14,"ms":5200,"value":"\#(Self.secret)","placeholder":"\#(Self.secret)"}"#
        let parsed = try #require(TracePageInput.parse(blur))
        #expect(parsed.name == "input.field_blur" && parsed.attrs["field"] == "password" && parsed.attrs["len"] == 14 && parsed.duration == 5200)
        let click = #"{"t":"click","role":"button","name":"Pay \#(Self.secret)","href":"https://pay.example/c?k=\#(Self.secret)"}"#
        let clicked = try #require(TracePageInput.parse(click))
        for event in [parsed, clicked] {
            let record = TraceRecord(kind: .event, name: event.name, t: 0, m: 0, attrs: event.attrs)
            let line = String(decoding: try record.encoded(), as: UTF8.self)
            #expect(!line.contains(Self.secret) && !line.contains("hunter2"), "\(line)")
        }
        #expect(clicked.attrs["link_host"] == "pay.example" && clicked.attrs["link_path"] == "/c?k=")
        #expect(TracePageInput.parse(#"{"t":"textContent","text":"\#(Self.secret)"}"#) == nil)
        #expect(TracePageInput.parse("not json") == nil)
    }

    @Test func nothingTypedReachesTheFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TraceStore(directory: directory)
        for (tool, arguments) in Self.calls {
            store.append(TraceRecord(kind: .call, name: tool, t: TraceClock.wall(), m: TraceClock.monotonic(),
                                     attrs: TraceCall.attributes(tool: tool, arguments: arguments)))
        }
        store.flush()
        let text = try store.files().map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        #expect(text.split(separator: "\n").count == Self.calls.count)
        #expect(!text.contains(Self.secret) && !text.contains("hunter2"))
    }
}

@Suite struct TraceStoreTests {
    private func utc() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func rotatesDailyAndReadsBackInOrder() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TraceStore(directory: directory, calendar: utc())
        let lateNov4 = Date(timeIntervalSince1970: 1_762_300_000).timeIntervalSince1970 * 1000  // 2025-11-04 23:46:40 UTC
        store.append(TraceRecord(kind: .event, name: "a", t: lateNov4, m: 10))
        store.append(TraceRecord(kind: .event, name: "b", t: lateNov4 + 30 * 60_000, m: 20))  // past midnight
        store.append(TraceRecord(kind: .event, name: "c", t: lateNov4 + 31 * 60_000, m: 30))
        store.flush()
        #expect(store.files().map(\.lastPathComponent) == ["2025-11-04.jsonl", "2025-11-05.jsonl"])
        let all = TraceStore.read(directory: directory, calendar: utc())
        #expect(all.map(\.name) == ["a", "b", "c"])
        let later = TraceStore.read(directory: directory, since: Date(timeIntervalSince1970: lateNov4 / 1000 + 600), calendar: utc())
        #expect(later.map(\.name) == ["b", "c"])
        // Owner-only, on disk.
        let mode = (try FileManager.default.attributesOfItem(atPath: store.files()[0].path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
    }

    @Test func keepsNinetyDays() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["2025-08-01", "2025-08-06", "2025-08-07", "2025-11-04"] {
            FileManager.default.createFile(atPath: directory.appendingPathComponent(name + ".jsonl").path, contents: Data("{}\n".utf8))
        }
        let store = TraceStore(directory: directory, calendar: utc())
        // Writing on a new day prunes what's past retention: 2025-11-05 keeps 2025-08-07 onward.
        store.append(TraceRecord(kind: .event, name: "today", t: Date(timeIntervalSince1970: 1_762_340_000).timeIntervalSince1970 * 1000, m: 1))
        store.flush()
        #expect(store.files().map { $0.deletingPathExtension().lastPathComponent } == ["2025-08-07", "2025-11-04", "2025-11-05"])
        #expect(TraceStore.read(directory: directory, calendar: utc()).map(\.name) == ["today"])
    }

    @Test func appendingNeverWaitsForTheDisk() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TraceStore(directory: directory, flushInterval: 60)
        let record = TraceRecord(kind: .event, name: "x", t: TraceClock.wall(), m: TraceClock.monotonic())
        let start = TraceClock.monotonic()
        for _ in 0..<1000 { store.append(record) }
        let elapsed = TraceClock.monotonic() - start
        #expect(elapsed < 100, "1000 appends took \(elapsed) ms")
        store.flush()
        #expect(TraceStore.read(directory: directory).count == 1000)
    }
}

@Suite(.serialized) struct TraceHotPathTests {
    /// Gabe's bar: tracing adds under 1 ms per event on the main thread.
    @Test @MainActor func anEventCostsUnderAMillisecond() throws {
        let directory = temporaryDirectory()
        defer {
            Trace.configure(nil)
            try? FileManager.default.removeItem(at: directory)
        }
        Trace.configure(TraceStore(directory: directory), enabled: true)
        let tab = UUID()
        let url = URL(string: "https://example.com/inbox/48213977?folder=work")!
        let count = 2000
        let start = TraceClock.monotonic()
        for i in 0..<count {
            Trace.event("page.load", tab: tab, url: url, duration: Double(i), ["cause": "link", "engine": "Chromium"])
        }
        let perEvent = (TraceClock.monotonic() - start) / Double(count)
        #expect(perEvent < 1, "an event took \(perEvent) ms on the main thread")
        Trace.flush()
        #expect(TraceStore.read(directory: directory).count == count)
    }

    @Test @MainActor func aSidebarDiffCostsUnderAMillisecond() {
        var tabs: [BrowserTab] = []
        for i in 0..<300 { tabs.append(BrowserTab(url: URL(string: "https://site\(i).example/page")!)) }
        let space = Space(name: "Work", icon: "💼", theme: Theme.presets[0], tabs: tabs)
        var state = BrowserState(spaces: [space])
        let before = TraceLayout(state)
        state.select(tab: tabs[42].id)
        // The best of a few rounds, so other suites running alongside don't decide it.
        var best = Double.infinity
        var changes = 0
        for _ in 0..<5 {
            let start = TraceClock.monotonic()
            for _ in 0..<10 { changes += TraceLayout(state).changes(since: before).count }
            best = min(best, (TraceClock.monotonic() - start) / 10)
        }
        #expect(changes == 50)
        #expect(best < 1, "a 300-tab sidebar diff took \(best) ms")
    }

    @Test func intentsAndReactionsAreTakenOnce() {
        let directory = temporaryDirectory()
        defer {
            Trace.configure(nil)
            try? FileManager.default.removeItem(at: directory)
        }
        Trace.configure(TraceStore(directory: directory))
        let tab = UUID()
        Trace.intend("back", tab: tab, since: 5)
        #expect(Trace.takeIntent(tab: tab)?.cause == "back")
        #expect(Trace.takeIntent(tab: tab) == nil)
        Trace.stepFinished(connection: 9, at: 100)
        #expect(Trace.takeReaction(connection: 9, now: 350) == 250)
        #expect(Trace.takeReaction(connection: 9, now: 400) == nil)
    }

    @Test func offCostsNothingAndWritesNothing() {
        Trace.configure(nil)
        #expect(!Trace.isEnabled)
        Trace.event("x")  // no store: returns at once
        Trace.setEnabled(true)
        #expect(!Trace.isEnabled)
    }
}

@Suite struct TraceSpanTests {
    @Test func phasesAddUpAndNestedMeasuresDontDoubleCount() async {
        let span = TraceSpan(id: "s-1", connection: 4, session: "Taxes")
        await Trace.$span.withValue(span) {
            Trace.phase("js", 10)
            Trace.phase("js", 5)
            await Trace.measure("wait") {
                Trace.phase("js", 1000)  // inside the wait: the wait counts it
                try? await Task.sleep(for: .milliseconds(20))
            }
            span.set("field", "password")
        }
        let phases = span.recordedPhases
        #expect(phases["js"] == 15)
        // The wait is the sleep's real time (the 1000 ms js inside it isn't added anywhere).
        #expect((phases["wait"] ?? 0) >= 15)
        #expect(phases.keys.sorted() == ["js", "wait"])
        #expect(span.recordedAttrs["field"] == "password")
    }
}

@Suite struct TraceLayoutTests {
    @Test func tabEventsFromSidebarChanges() throws {
        let a = BrowserTab(url: URL(string: "https://a.example/")!)
        let b = BrowserTab(url: URL(string: "https://b.example/")!)
        let space = Space(name: "Work", icon: "💼", theme: Theme.presets[0], tabs: [a, b], selectedTabID: a.id)
        var state = BrowserState(spaces: [space])
        let start = TraceLayout(state)

        let opened = state.openTab(url: URL(string: "https://c.example/x")!)
        var changes = TraceLayout(state).changes(since: start)
        #expect(changes.map(\.name) == ["tab.opened", "tab.selected"])
        #expect(changes[0].tab == opened && changes[0].url?.host() == "c.example")

        let before = TraceLayout(state)
        state.togglePin(tab: b.id)
        _ = state.close(tab: a.id)
        changes = TraceLayout(state).changes(since: before)
        #expect(changes.map(\.name).contains("tab.closed"))
        #expect(changes.first { $0.name == "tab.pinned" }?.tab == b.id)

        // Into Claude › Taxes: the session is the folder's name.
        let spaceID = state.spaces[0].id
        let moved = TraceLayout(state)
        let made = state.claudeSessionFolder(named: "Taxes", inSpace: spaceID)
        let folder = try #require(made)
        let didMove = state.moveTab(opened, toFolder: folder)
        #expect(didMove)
        changes = TraceLayout(state).changes(since: moved)
        let move = try #require(changes.first { $0.tab == opened && $0.name != "tab.selected" })
        #expect(move.session == "Taxes" && move.attrs["into_session"] == true)
        #expect(changes.contains { $0.name == "folder.created" })
    }

    @Test func switchingSpaces() {
        let work = Space(name: "Work", icon: "💼", theme: Theme.presets[0], tabs: [BrowserTab(url: nil)])
        let home = Space(name: "Home", icon: "🏠", theme: Theme.presets[1], tabs: [BrowserTab(url: nil)])
        var state = BrowserState(spaces: [work, home])
        let before = TraceLayout(state)
        state.selectSpace(home.id)
        #expect(TraceLayout(state).changes(since: before).map(\.name).first == "space.switched")
    }
}

@Suite struct TraceReportTests {
    @Test func percentilesAreNearestRank() {
        let values: [Double] = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100]
        #expect(TraceReport.percentile(values, 50) == 50)
        #expect(TraceReport.percentile(values, 95) == 100)
        #expect(TraceReport.percentile(values, 90) == 90)
        #expect(TraceReport.percentile([7], 95) == 7)
        #expect(TraceReport.percentile([], 50) == 0)
        #expect(TraceReport.percentile([3, 1, 2], 50) == 2)
    }

    @Test func durations() {
        #expect(TraceReport.duration("90s") == 90)
        #expect(TraceReport.duration("15m") == 900)
        #expect(TraceReport.duration("1h") == 3600)
        #expect(TraceReport.duration("2d") == 172_800)
        #expect(TraceReport.duration("5") == 300)
        #expect(TraceReport.duration("soon") == nil)
    }

    @Test func summaryMath() throws {
        var records: [TraceRecord] = []
        // Five clicks: 100…500 ms, one failing. Calls follow each other on connection 1 with 50 ms gaps.
        var m = 0.0
        for (i, dur) in [100.0, 200, 300, 400, 500].enumerated() {
            records.append(call("click", m: m, dur: dur, ok: i != 2))
            m += dur + 50
        }
        // A handoff wait of 4 s, a read with a 1 s confirmation sheet, and a batch with a step.
        records.append(call("handoff_status", m: m, dur: 4000))
        m += 4000 + 50
        records.append(call("navigate", m: m, dur: 1500, phases: ["confirm": 1000, "wait": 400]))
        m += 1500 + 50
        records.append(call("batch", m: m, dur: 300, id: "b-1"))
        records.append(call("screenshot", m: m + 10, dur: 250, parent: "b-1"))
        m += 300
        records.append(event("agent.reaction", m: m, dur: 800))
        records.append(event("agent.reaction", m: m, dur: 200))
        records.append(event("page.load", m: m, dur: 900, host: "slow.example", attrs: ["intent_ms": 1200]))
        records.append(event("page.load", m: m, dur: 300, host: "slow.example"))
        records.append(event("page.load", m: m, dur: 100, host: "fast.example", attrs: ["intent_ms": 400]))
        var sample = TraceRecord(kind: .sample, name: "proc", t: 0, m: m, attrs: [
            "proc": "renderer", "hosts": ["a.example", "b.example"], "sessions": ["Taxes"], "energy_mj": 300, "footprint_mb": 200,
            "tabs": ["T1", "T2"], "cpu_pct": 10,
        ])
        records.append(sample)
        sample.attrs = ["proc": "gpu", "energy_mj": 50, "footprint_mb": 100]
        records.append(sample)

        let summary = TraceReport.summary(records)
        let click = try #require(summary.tools.first { $0.name == "click" })
        #expect(click.count == 5 && click.errors == 1 && click.p50 == 300 && click.p95 == 500 && click.max == 500 && click.total == 1500)
        #expect(summary.tools.first?.name == "handoff_status")
        #expect(summary.slowest.first?.name == "handoff_status")
        // Waiting on the user: the handoff wait and the confirmation sheet. Working: the rest of the top-level time.
        #expect(summary.waitingOnUser == 5000)
        #expect(summary.working == 1500 + 500 + 300)
        // Gaps between one call's end and the next on the same connection.
        #expect(summary.betweenCalls == 50 * 7)
        #expect(summary.reaction?.count == 2 && summary.reaction?.p50 == 200 && summary.reaction?.max == 800)
        #expect(summary.loads.first?.name == "slow.example" && summary.loads.first?.p95 == 900)
        #expect(summary.intentToReady?.max == 1200 && summary.intentToReady?.p50 == 400)
        #expect(summary.energyByHost.first { $0.0 == "a.example" }?.1 == 150)
        #expect(summary.energyByHost.first { $0.0 == "(gpu)" }?.1 == 50)
        #expect(summary.energyBySession.first?.0 == "Taxes" && summary.energyBySession.first?.1 == 300)

        let text = TraceReport.summaryText(summary)
        #expect(text.contains("click") && text.contains("waiting on the user 5.000s"))
        let use = TraceReport.tabUse(records)
        #expect(use.count == 2 && use.allSatisfy { $0.peakMB == 100 && $0.energyMJ == 150 })
        #expect(TraceReport.resources(records).contains("Top tabs by memory"))
    }

    @Test func filtersBySessionTabActorAndConnection() {
        var mine = call("click", m: 0, dur: 10, conn: 1)
        mine.session = "Taxes"
        mine.tab = "AAAA0000-0000-0000-0000-000000000000"
        var theirs = call("click", m: 20, dur: 10, conn: 2)
        theirs.session = "Other"
        let load = event("page.load", m: 30, dur: 100, tab: "AAAA0000-0000-0000-0000-000000000000")
        let step = call("screenshot", m: 5, dur: 1, conn: nil, parent: mine.id)
        let user = event("tab.selected", m: 40, tab: "BBBB0000-0000-0000-0000-000000000000")
        let records = [mine, step, theirs, load, user]
        #expect(TraceReport.filter(records, .init(session: "Taxes")).map(\.name) == ["click", "page.load"])
        #expect(TraceReport.filter(records, .init(tab: "aaaa")).count == 2)
        #expect(TraceReport.filter(records, .init(actor: "user")).map(\.name) == ["page.load", "tab.selected"])
        #expect(TraceReport.filter(records, .init(actor: "agent")).count == 3)
        #expect(TraceReport.filter(records, .init(connection: 1)).map(\.name) == ["click", "screenshot"])
    }

    @Test func timelineShowsTimeDeltaDurationAndWhat() {
        var first = call("navigate", m: 1000, dur: 812, phases: ["wait": 700, "queue": 0.4])
        first.host = "example.com"
        first.path = "/"
        first.hostEnd = "example.com"
        first.pathEnd = "/login"
        let second = call("click", m: 2312, dur: 184)
        let text = TraceReport.timeline([first, second], timeZone: TimeZone(identifier: "UTC")!)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].contains("+0.000s") && lines[0].contains("812ms") && lines[0].contains("navigate")
            && lines[0].contains("→ example.com/login") && lines[0].contains("wait 700ms"))
        #expect(lines[1].contains("+1.312s") && lines[1].contains("184ms"))
    }
}

@Suite struct ResourceSamplerTests {
    @Test func ratesOverAnInterval() throws {
        let a = ResourceProbe.Counters(residentBytes: 0, footprintBytes: 0, cpuNanoseconds: 1_000_000_000, interruptWakeups: 100,
                                       idleWakeups: 10, energyNanojoules: 5_000_000_000)
        let b = ResourceProbe.Counters(residentBytes: 0, footprintBytes: 0, cpuNanoseconds: 1_500_000_000, interruptWakeups: 300,
                                       idleWakeups: 30, energyNanojoules: 7_000_000_000)
        let rates = try #require(ResourceSampler.rates(from: a, to: b, ms: 10_000))
        #expect(rates.cpuPercent == 5 && rates.wakeupsPerSecond == 20 && rates.idleWakeupsPerSecond == 2)
        #expect(rates.energyMillijoules == 2000 && rates.milliwatts == 200)
        // A process that restarted under the same pid: no rate.
        #expect(ResourceSampler.rates(from: b, to: a, ms: 10_000) == nil)
    }

    @Test func samplesGiveRatesOnTheSecondReading() {
        let sampler = ResourceSampler()
        var energy: UInt64 = 0
        sampler.read = { _ in
            energy += 1_000_000_000
            return ResourceProbe.Counters(residentBytes: 300 << 20, footprintBytes: 200 << 20, cpuNanoseconds: energy / 10,
                                          interruptWakeups: 0, idleWakeups: 0, energyNanojoules: energy)
        }
        sampler.readSystem = {
            ResourceProbe.System(onBattery: true, batteryPercent: 80, minutesToEmpty: 300, thermal: "nominal", lowPowerMode: false,
                                 memoryPressure: "normal")
        }
        let tab = UUID()
        let process = ResourceSampler.Process(pid: 42, kind: "renderer", tabs: [tab], hosts: ["mail.example"], sessions: ["Taxes"])
        let first = sampler.sample([process], clock: (0, 0))
        #expect(first.map(\.name) == ["proc", "totals", "system"])
        #expect(first[0].attrs?["energy_mj"] == nil && first[0].attrs?["footprint_mb"] == 200)
        let second = sampler.sample([process], clock: (10_000, 10_000))
        #expect(second[0].attrs?["energy_mj"] == 1000 && second[0].attrs?["power_mw"] == 100)
        #expect(second[0].tab == tab.uuidString && second[0].host == "mail.example" && second[0].session == "Taxes")
        #expect(second[1].attrs?["energy_mj"] == 1000)
        #expect(second[2].attrs?["on_battery"] == true && second[2].attrs?["battery_pct"] == 80)
    }

    #if os(macOS)
    /// Gabe's bar: one sample takes under 5 ms, off the main thread.
    @Test func aRealSampleIsCheapOffTheMainThread() async throws {
        let sampler = ResourceSampler()
        let pid = getpid()
        let (elapsed, records): (Double, [TraceRecord]) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                // The first reading lists the helpers (their argv, once); the second is the steady state.
                let processes = sampler.processes(pages: [:], browser: pid)
                _ = sampler.sample(processes)
                let start = TraceClock.monotonic()
                let processesAgain = sampler.processes(pages: [:], browser: pid)
                let records = sampler.sample(processesAgain)
                continuation.resume(returning: (TraceClock.monotonic() - start, records))
            }
        }
        #expect(elapsed < 5, "a sample took \(elapsed) ms")
        let me = try #require(records.first { $0.name == "proc" })
        #expect(me.attrs?["proc"] == "browser" && (me.attrs?["footprint_mb"]?.doubleValue ?? 0) > 0)
        #expect(records.contains { $0.name == "system" && $0.attrs?["thermal"] != nil })
    }
    #endif

    @Test func helperKinds() {
        #expect(ResourceProbe.helperKind(["Kite Helper", "--type=gpu-process"]).kind == "gpu")
        #expect(ResourceProbe.helperKind(["Kite Helper", "--type=renderer"]).kind == "renderer")
        #expect(ResourceProbe.helperKind(["Kite Helper", "--type=renderer", "--extension-process"]).kind == "extension")
        let utility = ResourceProbe.helperKind(["x", "--type=utility", "--utility-sub-type=network.mojom.NetworkService"])
        #expect(utility.kind == "utility" && utility.service == "Network Service")
    }
}

@Suite struct TraceToolTests {
    @Test func parsesTheTraceTool() throws {
        guard case .trace(let request) = try AutomationCommand(tool: "trace", arguments: ["since": "1h", "session": "Taxes", "actor": "agent"]) else {
            Issue.record("expected trace")
            return
        }
        #expect(request.since == 3600 && request.session == "Taxes" && request.actor == "agent" && !request.all)
        guard case .trace(let defaults) = try AutomationCommand(tool: "trace", arguments: [:]) else { return }
        #expect(defaults.since == TraceRequest.defaultSince && defaults.limit == TraceRequest.defaultLimit)
        #expect(throws: AutomationCommand.InvalidArguments.self) { try AutomationCommand(tool: "trace", arguments: ["since": "soon"]) }
        #expect(throws: AutomationCommand.InvalidArguments.self) { try AutomationCommand(tool: "trace", arguments: ["actor": "robot"]) }
        #expect(AutomationCommand.Tool.trace.isReadOnly && !AutomationCommand.Tool.trace.isDestructive)
    }

    @Test func outputSize() {
        let output = ToolOutput(content: [.text("héllo"), .image(base64: "AAAA", mimeType: "image/png")])
        #expect(TraceCall.size(of: output) == (bytes: 10, images: 1))
        #expect(TraceCall.actor(client: nil) == .agent(client: "cli"))
        #expect(TraceCall.actor(client: "claude-code") == .agent(client: "claude-code"))
    }
}
