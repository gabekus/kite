import Foundation

/// `handoff`: Claude hands steps it can't (or mustn't) do to the user, and Kite shows them where they happen.
///
/// Claude stops for things only the user can do: its safety check won't let it approve a DNS change, a page
/// wants a click on Super Administrator, a script reads 1Password. Instead of a list in the chat, Claude calls
/// `handoff` with why it stopped and the steps. Kite then:
/// - rings the control to click on the page itself, with the step's text beside it;
/// - marks those tabs, and the Claude folders holding them, in the sidebar;
/// - shows a card over the page with the reason, the step, a copyable command for steps outside the browser,
///   and Done, Skip and Next;
/// - tells Claude which steps the user did when it asks (`handoff_status`), or when its wait ends.
///
/// A step on a page is done when the user clicks (or changes) the ringed control, or presses Done. Only real
/// clicks count: the page's own scripts can't fake one, since the ring and its listeners live in an isolated
/// world the page can't reach.
public enum UserHandoff {
    public static let maxSteps = 12
    public static let maxReasonLength = 400
    public static let maxInstructionLength = 240
    public static let maxCommandLength = 4_000
    /// The longest one call waits for the user, in seconds. Claude calls handoff_status again to wait longer.
    public static let maxWait: Double = 600
    /// How often Kite looks at the page in front while a step waits on it.
    public static let pollInterval: TimeInterval = 0.5
    /// The isolated world the ring lives in, and the binding it reports clicks through.
    public static let worldName = "kite-handoff"
    public static let bindingName = "kiteHandoffEvent"
    /// The attribute that marks an element Claude named by ref, so the ring finds it again.
    public static let markerAttribute = "data-kite-handoff"

    /// What Claude points a step at.
    public enum Target: Hashable, Sendable {
        /// A ref from read_page or find.
        case ref(String)
        case selector(String)
        /// The visible text of a button, link, checkbox or label: "Save", "Super Administrator".
        case text(String)
    }

    /// One step as Claude asks for it.
    public struct StepRequest: Hashable, Sendable {
        /// What to do, in a few words: "Approve Apple", "Tick Super Administrator".
        public var instruction: String
        /// The tab it happens in. Nil: the call's tab, the front tab (for a step with a target), or no tab.
        public var tab: String?
        public var target: Target?
        /// A command for the user to run in their terminal, shown copyable.
        public var command: String?
        /// Why this step is the user's, when it differs from the call's reason.
        public var why: String?

        public init(instruction: String, tab: String? = nil, target: Target? = nil, command: String? = nil, why: String? = nil) {
            self.instruction = instruction
            self.tab = tab
            self.target = target
            self.command = command
            self.why = why
        }
    }

    /// A handoff as Claude asks for it.
    public struct Request: Hashable, Sendable {
        /// Why Claude stopped and needs the user: "My safety check won't let me change nameservers."
        public var reason: String
        public var steps: [StepRequest]
        /// The tab for steps that don't name one.
        public var tab: String?
        /// Seconds to wait for the user before returning (0 returns at once).
        public var wait: Double

        public init(reason: String, steps: [StepRequest], tab: String? = nil, wait: Double = 0) {
            self.reason = reason
            self.steps = steps
            self.tab = tab
            self.wait = wait
        }
    }

    // MARK: Parsing

    static func parse(_ values: [String: JSONValue], tab: String?) throws -> Request {
        typealias Invalid = AutomationCommand.InvalidArguments
        func text(_ value: JSONValue?, _ key: String, limit: Int) throws -> String? {
            guard let value, !value.isNull else { return nil }
            guard let string = value.stringValue else { throw Invalid("\"\(key)\" must be a string.") }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard trimmed.count <= limit else { throw Invalid("\"\(key)\" is at most \(limit) characters.") }
            return trimmed
        }
        guard let reason = try text(values["reason"], "reason", limit: maxReasonLength) else {
            throw Invalid("\"reason\" is required: say why you stopped and need the user, e.g. \"My safety check won't let me change nameservers\".")
        }
        guard let list = values["steps"]?.arrayValue, !list.isEmpty else {
            throw Invalid("\"steps\" must be a list of {\"instruction\": …, \"tab\"?, \"ref\" | \"selector\" | \"text\"?, \"command\"?}.")
        }
        guard list.count <= maxSteps else { throw Invalid("A handoff has at most \(maxSteps) steps.") }
        let steps: [StepRequest] = try list.enumerated().map { index, item in
            guard let step = item.objectValue else { throw Invalid("Step \(index + 1) must be an object.") }
            func field(_ key: String, limit: Int = maxInstructionLength) throws -> String? {
                do { return try text(step[key], key, limit: limit) } catch let error as Invalid {
                    throw Invalid("Step \(index + 1): \(error.description)")
                }
            }
            guard let instruction = try field("instruction") else {
                throw Invalid("Step \(index + 1) needs an \"instruction\": what the user does, like \"Approve Apple\".")
            }
            let command = try field("command", limit: maxCommandLength)
            let targets: [Target] = [
                try field("ref").map(Target.ref), try field("selector", limit: 1_000).map(Target.selector), try field("text").map(Target.text),
            ].compactMap { $0 }
            guard targets.count <= 1 else { throw Invalid("Step \(index + 1): pass one of \"ref\", \"selector\" or \"text\", not several.") }
            if command != nil, !targets.isEmpty {
                throw Invalid("Step \(index + 1): a \"command\" step runs outside the browser, so it takes no ref, selector or text.")
            }
            if case .selector(let selector)? = targets.first, selector.contains("\u{0}") {
                throw Invalid("Step \(index + 1): that selector isn't valid.")
            }
            return StepRequest(instruction: instruction, tab: try field("tab"), target: targets.first, command: command, why: try field("why"))
        }
        let wait = try values["wait"].flatMap { value -> Double? in
            guard !value.isNull else { return nil }
            guard let number = value.doubleValue, number.isFinite, number >= 0, number <= maxWait else {
                throw Invalid("\"wait\" is 0 to \(Int(maxWait)) seconds.")
            }
            return number
        } ?? 0
        return Request(reason: reason, steps: steps, tab: tab, wait: wait)
    }
}

/// A handoff while it's live in Kite: its steps and how far the user got.
public struct Handoff: Identifiable, Hashable, Codable, Sendable {
    public struct Step: Identifiable, Hashable, Codable, Sendable {
        public enum State: String, Hashable, Codable, Sendable { case waiting, done, skipped }

        /// How Kite finds the step's control on the page.
        public enum Locator: Hashable, Codable, Sendable {
            case selector(String)
            case text(String)
            /// An element Claude named by ref, marked with `UserHandoff.markerAttribute`; `label` finds it again if
            /// the page redraws it.
            case marker(String, label: String?)
        }

        /// "h1.2": the handoff and the step's number.
        public let id: String
        /// From 1, in the order Claude gave.
        public let number: Int
        public var instruction: String
        public var why: String?
        public var command: String?
        public var tab: UUID?
        public var locator: Locator?
        public var state: State = .waiting
        /// What finished it, in words for Claude: "the user clicked the highlighted control".
        public var how: String?
        /// Whether the ring found the control on the page the last time Kite looked.
        public var found: Bool?

        public init(id: String, number: Int, instruction: String, why: String? = nil, command: String? = nil, tab: UUID? = nil,
                    locator: Locator? = nil) {
            self.id = id
            self.number = number
            self.instruction = instruction
            self.why = why
            self.command = command
            self.tab = tab
            self.locator = locator
        }

        public var isWaiting: Bool { state == .waiting }

        /// `found` is only what the last look saw, so it isn't saved.
        enum CodingKeys: String, CodingKey { case id, number, instruction, why, command, tab, locator, state, how }
    }

    /// "h1", "h2": short enough for Claude to pass back.
    public let id: String
    public var reason: String
    /// The Claude session folder of the session that asked, when it named one.
    public var session: String?
    public var created: Date
    public var steps: [Step]

    public init(id: String, reason: String, session: String? = nil, created: Date = Date(), steps: [Step]) {
        self.id = id
        self.reason = reason
        self.session = session
        self.created = created
        self.steps = steps
    }

    public var waiting: [Step] { steps.filter(\.isWaiting) }
    public var isFinished: Bool { !steps.contains(where: \.isWaiting) }

    /// The step a tab shows: its first waiting one, so "Approve, then Save" on one tab goes in order.
    public func current(on tab: UUID) -> Step? {
        steps.first { $0.isWaiting && $0.tab == tab }
    }

    /// Ends a waiting step. Steps already ended stay as they are, so a late click can't undo a Skip.
    @discardableResult
    public mutating func finish(_ stepID: String, _ state: Step.State, how: String) -> Bool {
        guard let index = steps.firstIndex(where: { $0.id == stepID }), steps[index].isWaiting, state != .waiting else { return false }
        steps[index].state = state
        steps[index].how = how
        return true
    }

    /// Ends every waiting step (the user dismissed the handoff, Claude withdrew it, or the tab closed).
    public mutating func finishAll(_ state: Step.State, how: String, where include: (Step) -> Bool = { _ in true }) {
        for index in steps.indices where steps[index].isWaiting && include(steps[index]) {
            steps[index].state = state
            steps[index].how = how
        }
    }

    /// What `handoff` and `handoff_status` tell Claude. `place` gives a tab's URL and title for steps on tabs.
    public func report(waitedOut: Bool = false, place: (UUID) -> (url: String?, title: String)?) -> String {
        let done = steps.filter { $0.state == .done }.count
        let skipped = steps.filter { $0.state == .skipped }.count
        let left = steps.count - done - skipped
        var lines = ["Handoff \(id): \(done) of \(steps.count) done" + (skipped > 0 ? ", \(skipped) skipped" : "")
            + (left > 0 ? ", \(left) waiting for the user." : ".")]
        for step in steps {
            var line = "\(step.number). [\(step.state.rawValue)] \(step.instruction)"
            if let how = step.how { line += " (\(how))" }
            if let tab = step.tab {
                if let place = place(tab) {
                    line += " · tab \(tab.uuidString) at \(place.url ?? "an unknown URL") (“\(place.title)”)"
                } else {
                    line += " · tab \(tab.uuidString), now closed"
                }
            }
            lines.append(line)
        }
        if left == 0 {
            lines.append(skipped == 0
                ? "The user did every step. Read the pages to check they took, then carry on."
                : "Skipped steps weren't done: don't do them yourself. Say what's left and why, then carry on with what you can.")
        } else if waitedOut {
            lines.append("The steps stay in Kite for the user. Call handoff_status with id \"\(id)\" and wait to keep waiting, "
                + "or carry on with work that doesn't need them.")
        } else {
            lines.append("Kite is showing these to the user. Call handoff_status with id \"\(id)\" (and wait, up to "
                + "\(Int(UserHandoff.maxWait)) seconds) to hear when they're done.")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: Keeping handoffs across launches

extension Handoff {
    /// Where a profile keeps its handoffs, so steps still waiting come back when Kite does.
    public static func fileURL(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("Claude Handoffs.json")
    }

    /// How long a handoff lasts across launches, waiting or not.
    public static let lifetime: TimeInterval = 7 * 24 * 3600
    /// Finished handoffs kept for handoff_status.
    public static let keptFinished = 20

    /// The saved handoffs still worth keeping: under a week old, and the newest finished ones.
    public static func load(from url: URL, now: Date = Date()) -> [Handoff] {
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder.handoffs.decode([Handoff].self, from: data) else { return [] }
        return pruned(saved.filter { now.timeIntervalSince($0.created) < lifetime })
    }

    public static func save(_ handoffs: [Handoff], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.handoffs.encode(handoffs).write(to: url, options: .atomic)
    }

    /// Drops the oldest finished handoffs past `keptFinished`; waiting ones always stay.
    public static func pruned(_ handoffs: [Handoff]) -> [Handoff] {
        let finished = handoffs.filter(\.isFinished)
        guard finished.count > keptFinished else { return handoffs }
        let drop = Set(finished.prefix(finished.count - keptFinished).map(\.id))
        return handoffs.filter { !drop.contains($0.id) }
    }

    /// The number after "h" in the newest id, so new handoffs don't reuse a saved one's.
    public static func lastNumber(in handoffs: [Handoff]) -> Int {
        handoffs.compactMap { Int($0.id.dropFirst()) }.max() ?? 0
    }
}

private extension JSONEncoder {
    static var handoffs: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var handoffs: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: The ring on the page

extension UserHandoff {
    /// What the page script needs for the step a tab shows.
    public struct RingConfig: Encodable, Equatable, Sendable {
        public var step: String
        public var number: Int
        public var label: String
        public var selector: String?
        public var text: String?
        public var marker: String?
        /// Scroll the control into view the first time it's found.
        public var scroll: Bool

        public init(step: Handoff.Step, scroll: Bool) {
            self.step = step.id
            number = step.number
            label = step.instruction
            self.scroll = scroll
            switch step.locator {
            case .selector(let selector)?: self.selector = selector
            case .text(let text)?: self.text = text
            case .marker(let marker, let label)?:
                self.marker = marker
                text = label
            case nil: break
            }
        }
    }

    /// What the page script reports back.
    public struct RingState: Decodable, Equatable, Sendable {
        /// The control is on the page (and shown).
        public var found: Bool
        /// How the user finished the step, if they did since the last look ("click", "change").
        public var done: String?

        public init(found: Bool, done: String? = nil) {
            self.found = found
            self.done = done
        }

        public init?(json: String) {
            guard let state = try? JSONDecoder().decode(RingState.self, from: Data(json.utf8)) else { return nil }
            self = state
        }
    }

    /// A click the ring's listener reported through the binding.
    public struct RingEvent: Decodable, Equatable, Sendable {
        public var step: String
        public var how: String

        public init?(json: String) {
            guard let event = try? JSONDecoder().decode(RingEvent.self, from: Data(json.utf8)) else { return nil }
            self = event
        }
    }

    /// Words for Claude about how the page saw the user finish.
    public static func describe(_ how: String) -> String {
        switch how {
        case "change": "the user changed the highlighted control"
        default: "the user clicked the highlighted control"
        }
    }

    /// Shows (or moves) the ring for one step, in the isolated world. Returns `RingState` as JSON.
    public static func ringScript(_ config: RingConfig) -> String {
        let json = (try? JSONEncoder().encode(config)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
        return "(\(ringFunction))(\(json))"
    }

    /// Takes the ring off the page.
    public static let clearScript = "(() => { const K = window.__kiteHandoff; if (K) K.clear(); return true; })()"

    /// The ring itself. It lives in a closed shadow root on a host element that takes no clicks, in an isolated
    /// world, so the page can neither style it nor read or fake its state. Every frame it follows the control's
    /// box; the control is looked up again when the page redraws it.
    static let ringFunction = #"""
        (cfg) => {
          const K = window.__kiteHandoff || (window.__kiteHandoff = { step: null, el: null, done: null, scrolled: false, raf: 0, retry: 0 });
          const norm = (s) => (s || '').replace(/\s+/g, ' ').trim().toLowerCase();
          const shown = (el) => {
            const r = el.getBoundingClientRect(), s = getComputedStyle(el);
            return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
          };
          const controls = 'button,a[href],input:not([type=hidden]),select,textarea,label,summary,[role=button],[role=link],'
            + '[role=checkbox],[role=switch],[role=radio],[role=tab],[role=menuitem],[role=menuitemcheckbox],[role=option],[tabindex]';
          const words = (el) => norm(el.getAttribute('aria-label') || el.innerText || el.value || el.title
            || (el.labels && el.labels[0] && el.labels[0].innerText) || '');
          const byText = (want) => {
            want = norm(want);
            if (!want) return null;
            let best = null, score = 0;
            for (const el of document.querySelectorAll(controls)) {
              if (!shown(el)) continue;
              const t = words(el);
              if (!t) continue;
              const s = t === want ? 3 : t.startsWith(want) ? 2 : t.includes(want) ? 1 : 0;
              // A tighter match wins; at a tie, the smaller element (a button inside a matching row).
              if (s > score || (s === score && s > 0 && best && best.contains(el))) { best = el; score = s; }
            }
            return best;
          };
          // The control's own box. A label or other block that holds a short control ("☐ Super Administrator"
          // across a whole row) is ringed around what it shows, not its full width.
          const box = (el) => {
            const r = el.getBoundingClientRect();
            if (getComputedStyle(el).display === 'inline' || el.matches('input,select,textarea,button')) return r;
            const range = document.createRange();
            range.selectNodeContents(el);
            const c = range.getBoundingClientRect();
            if (c.width <= 0 || c.height <= 0 || c.width >= r.width - 1) return r;
            return { left: c.left, top: Math.min(c.top, r.top), right: c.right, bottom: Math.max(c.bottom, r.bottom),
              width: c.width, height: Math.max(c.bottom, r.bottom) - Math.min(c.top, r.top) };
          };
          const find = (c) => {
            if (c.marker) {
              const marked = document.querySelector('[data-kite-handoff="' + CSS.escape(c.marker) + '"]');
              if (marked) return marked;
            }
            if (c.selector) { try { return document.querySelector(c.selector); } catch (e) { return null; } }
            return c.text ? byText(c.text) : null;
          };
          if (!K.clear) {
            K.clear = () => {
              K.step = null; K.el = null; K.cfg = null; K.done = null;
              if (K.raf) cancelAnimationFrame(K.raf);
              K.raf = 0;
              if (K.host) K.host.remove();
              K.host = null;
            };
            const report = (how) => (e) => {
              if (!e.isTrusted || !K.step || !K.el || K.done) return;
              const path = e.composedPath ? e.composedPath() : [];
              if (!(path.includes(K.el) || K.el.contains(e.target))) return;
              K.done = how;
              try { window.kiteHandoffEvent(JSON.stringify({ step: K.step, how })); } catch (err) {}
            };
            document.addEventListener('click', report('click'), true);
            document.addEventListener('change', report('change'), true);
          }
          if (!cfg) return JSON.stringify({ found: false });
          if (K.step !== cfg.step) { K.step = cfg.step; K.el = null; K.done = null; K.scrolled = false; }
          K.cfg = cfg;
          if (!K.host || !K.host.isConnected) {
            const host = document.createElement('kite-handoff');
            host.style.cssText = 'all:initial;position:fixed;inset:0;pointer-events:none;z-index:2147483647;display:block;';
            const root = host.attachShadow({ mode: 'closed' });
            root.innerHTML = '<style>'
              + ':host{all:initial}'
              + '.ring{position:fixed;display:none;box-sizing:border-box;border:2px solid #D97757;border-radius:8px;'
              + 'box-shadow:0 0 0 4px rgba(217,119,87,.25);animation:kh 1.6s ease-in-out infinite;pointer-events:none}'
              + '@keyframes kh{50%{box-shadow:0 0 0 8px rgba(217,119,87,.12)}}'
              + '.tag{position:fixed;display:none;max-width:320px;padding:4px 9px;border-radius:7px;background:#D97757;color:#fff;'
              + 'font:600 12px/16px -apple-system,BlinkMacSystemFont,system-ui,sans-serif;white-space:nowrap;overflow:hidden;'
              + 'text-overflow:ellipsis;box-shadow:0 2px 8px rgba(0,0,0,.18);pointer-events:none}'
              + '@media (prefers-reduced-motion:reduce){.ring{animation:none}}'
              + '</style><div class="ring"></div><div class="tag"></div>';
            (document.documentElement || document.body).appendChild(host);
            K.host = host; K.ring = root.querySelector('.ring'); K.tag = root.querySelector('.tag');
          }
          K.tag.textContent = 'Claude needs you · ' + cfg.number + '. ' + cfg.label;
          const place = () => {
            K.raf = 0;
            if (!K.cfg || !K.host) return;
            if (!K.el || !K.el.isConnected || !shown(K.el)) {
              const now = Date.now();
              // Looking the control up walks the page: at most every 400ms while it's missing.
              if (now - K.retry > 400) { K.retry = now; K.el = find(K.cfg); }
            }
            const el = K.el && K.el.isConnected && shown(K.el) ? K.el : null;
            if (el) {
              if (K.cfg.scroll && !K.scrolled) {
                K.scrolled = true;
                const r0 = el.getBoundingClientRect();
                if (r0.top < 0 || r0.bottom > innerHeight || r0.left < 0 || r0.right > innerWidth) {
                  el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'smooth' });
                }
              }
              const r = box(el), pad = 4;
              Object.assign(K.ring.style, { display: 'block', left: (r.left - pad) + 'px', top: (r.top - pad) + 'px',
                width: (r.width + pad * 2) + 'px', height: (r.height + pad * 2) + 'px' });
              K.tag.style.display = 'block';
              const th = K.tag.offsetHeight || 24, tw = K.tag.offsetWidth || 200, gap = 8;
              // Beside the control on its own line when there's room (so it hides nothing the user reads),
              // then above, then below.
              let left, top;
              const middle = r.top + r.height / 2 - th / 2;
              if (r.right + pad + gap + tw <= innerWidth - 4) {
                left = r.right + pad + gap; top = middle;
              } else if (r.left - pad - gap - tw >= 4) {
                left = r.left - pad - gap - tw; top = middle;
              } else {
                const above = r.top - pad - th - 6;
                top = above >= 4 ? above : r.bottom + pad + 6;
                left = r.left - pad;
              }
              left = Math.max(4, Math.min(innerWidth - tw - 4, left));
              top = Math.max(4, Math.min(innerHeight - th - 4, top));
              Object.assign(K.tag.style, { left: left + 'px', top: top + 'px' });
            } else {
              K.ring.style.display = 'none'; K.tag.style.display = 'none';
            }
            K.raf = requestAnimationFrame(place);
          };
          if (!K.raf) place();
          const el = K.el && K.el.isConnected ? K.el : (K.el = find(cfg));
          return JSON.stringify({ found: !!(el && shown(el)), done: K.done });
        }
        """#
}
