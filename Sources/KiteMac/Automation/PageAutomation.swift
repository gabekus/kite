import AppKit
import KiteCore

/// What every engine can do for Claude: read and capture. Acting on a page
/// (clicks, keys, form values, JavaScript, waits) needs `ChromiumAutomation`.
@MainActor
protocol PageAutomation {
    /// The accessibility outline (nil if the engine can't produce one) and the page's visible text.
    func read(interactiveOnly: Bool) async throws -> (outline: String?, text: String)
    /// The page's main text: its article or main element when it has one. `source` names which.
    func mainText() async throws -> (source: String, text: String)
    /// The visible viewport, one image pixel per CSS pixel (the coordinates clicks use).
    func screenshot() async throws -> Screenshot
}

/// Acting on a page: everything beyond reading. Only Chromium tabs can do it.
@MainActor
protocol PageActions: PageAutomation {
    /// Starts DevTools events for `TabActivity`; `stopEvents` ends them.
    func startEvents(_ handler: @escaping (String, JSONValue) -> Void) async throws
    func stopEvents() async
    /// Accessibility nodes of every readable frame, for `find`.
    func allNodes() async throws -> [AXNode]
    /// Finds the element, scrolls it into view and describes it for the policy.
    func locate(_ target: AutomationTarget) async throws -> LocatedElement
    /// The control under a viewport point (the hit-tested element, or the control it belongs to).
    func element(at point: ViewportPoint) async throws -> LocatedElement?
    /// The element that has keyboard focus, if any.
    func focusedElement() async throws -> LocatedElement?
    func click(_ element: LocatedElement) async throws
    func click(at point: ViewportPoint, button: ComputerAction.Button, count: Int, modifiers: KeyChord.Modifiers) async throws
    func hover(_ point: ViewportPoint) async throws
    func scroll(at point: ViewportPoint?, direction: ComputerAction.Direction, amount: Int) async throws
    func drag(from: ViewportPoint, to: ViewportPoint) async throws
    func press(_ chords: [KeyChord]) async throws
    func insertText(_ text: String) async throws
    /// Focuses the element (when given), replaces its contents with `text`, then presses Return if asked.
    func type(_ text: String, into element: LocatedElement?, submit: Bool) async throws
    /// Returns the value the control ended up with.
    func setValue(_ value: JSONValue, on element: LocatedElement) async throws -> String
    func setFiles(_ paths: [String], on element: LocatedElement) async throws
    /// Runs JavaScript and returns its result as text.
    func run(_ code: String) async throws -> String
    func answerDialog(accept: Bool, promptText: String?) async throws
    func waitFor(selector: String?, text: String?, timeout: TimeInterval) async throws -> Bool
    func readyStateIsComplete() async throws -> Bool
    func zoom(x0: Double, y0: Double, x1: Double, y1: Double) async throws -> Screenshot
}

struct Screenshot {
    var png: Data
    var width: Int
    var height: Int
}

/// An element found on the page, plus what the engine needs to act on it.
struct LocatedElement {
    var description: ElementDescription
    /// Center of the element in viewport CSS pixels.
    var point: CGPoint
    /// Whether a click at `point` would land on the element (nothing covers it).
    var isHittable: Bool
    /// Engine handle: a CDP remote object id, or a WebKit element index.
    var handle: String
}

/// Page scripts shared by both engines. They never write to the page's DOM.
enum PageScripts {
    /// Body of a function whose `this` is the element. Returns the description plus geometry.
    static let describe = """
        function (scroll, climb) {
          let el = this && this.nodeType === 1 ? this : this && this.parentElement;
          if (!(el instanceof Element)) return null;
          // A point hit-test lands on the innermost node; act on the control it belongs to.
          if (climb) {
            el = el.closest('a[href], button, input, select, textarea, summary, label, [role=button], [role=link], ' +
              '[role=checkbox], [role=radio], [role=menuitem], [role=tab], [role=option], [role=switch], [contenteditable=""], ' +
              '[contenteditable=true], iframe') || el;
          }
          if (scroll) el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
          const r = el.getBoundingClientRect();
          const tag = el.tagName.toLowerCase();
          const text = (s) => (s || '').replace(/\\s+/g, ' ').trim().slice(0, 200);
          const label = (() => {
            const aria = el.getAttribute('aria-label');
            if (aria) return text(aria);
            const by = el.getAttribute('aria-labelledby');
            if (by) {
              const t = by.split(/\\s+/).map((id) => document.getElementById(id)?.innerText || '').join(' ');
              if (text(t)) return text(t);
            }
            if (el.labels && el.labels.length) return text([...el.labels].map((l) => l.innerText).join(' '));
            if (tag === 'input' && ['submit', 'button', 'reset'].includes(el.type)) return text(el.value);
            if (tag === 'input' || tag === 'textarea' || tag === 'select') return text(el.title);
            if (tag === 'img') return text(el.alt);
            return text(el.innerText || el.textContent || el.title);
          })();
          const x = r.left + r.width / 2, y = r.top + r.height / 2;
          const hit = document.elementFromPoint(x, y);
          return {
            tag,
            type: tag === 'input' ? el.type : el.getAttribute('type'),
            role: el.getAttribute('role'),
            label,
            name: el.getAttribute('name'),
            id: el.id || null,
            autocomplete: el.getAttribute('autocomplete'),
            placeholder: el.getAttribute('placeholder'),
            href: el.href ? String(el.href) : (el.src ? String(el.src) : null),
            inForm: !!(el.form || el.closest('form')),
            isContentEditable: el.isContentEditable,
            x, y, width: r.width, height: r.height,
            hittable: r.width > 0 && r.height > 0 && !!hit && (hit === el || el.contains(hit)),
          };
        }
        """

    /// Focuses the element and selects its contents, so typing replaces them.
    static let focusAndSelect = """
        function () {
          this.focus();
          if (typeof this.select === 'function' && (this.tagName === 'INPUT' || this.tagName === 'TEXTAREA')) {
            this.select();
          } else if (this.isContentEditable) {
            const range = document.createRange();
            range.selectNodeContents(this);
            const selection = getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
          }
          return document.activeElement === this || this.contains(document.activeElement);
        }
        """

    /// Fallback when synthetic key input didn't reach the field: set the value the way a
    /// framework-friendly paste would (native setter, then input and change events).
    static let setValue = """
        function (text) {
          if (this.isContentEditable) {
            this.textContent = text;
          } else {
            const proto = this.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
            setter ? setter.call(this, text) : (this.value = text);
          }
          this.dispatchEvent(new Event('input', { bubbles: true }));
          this.dispatchEvent(new Event('change', { bubbles: true }));
          return true;
        }
        """

    static let currentValue = """
        function () { return this.isContentEditable ? this.textContent : (this.value ?? null); }
        """

    static let pageText = "document.body ? document.body.innerText : ''"

    /// The article or main element's text when there's a real one, else the body's.
    static let mainText = """
        (() => {
          const pick = document.querySelector('article') || document.querySelector('main, [role=main]');
          const text = pick ? pick.innerText.trim() : '';
          if (text.length >= 200) return { source: pick.tagName.toLowerCase(), text };
          return { source: 'body', text: document.body ? document.body.innerText : '' };
        })()
        """

    /// Sets a control's value the way a person would, firing the events frameworks listen for.
    static let formValue = """
        function (value) {
          const el = this, tag = el.tagName.toLowerCase(), fire = (type) => el.dispatchEvent(new Event(type, { bubbles: true }));
          if (tag === 'select') {
            const want = String(value).trim().toLowerCase(), options = [...el.options];
            const option = options.find((o) => o.value.toLowerCase() === want)
              || options.find((o) => o.text.trim().toLowerCase() === want)
              || options.find((o) => o.text.trim().toLowerCase().includes(want));
            if (!option) return { ok: false, error: 'No option matches. Options: ' + options.slice(0, 40).map((o) => o.text.trim()).join(' | ') };
            el.value = option.value; fire('input'); fire('change');
            return { ok: true, value: option.text.trim() };
          }
          if (tag === 'input' && (el.type === 'checkbox' || el.type === 'radio')) {
            const want = value === true || value === 1 || ['true', 'on', 'yes', 'checked', '1'].includes(String(value).toLowerCase());
            if (el.checked !== want) el.click();
            return { ok: el.checked === want, value: String(el.checked), error: el.checked === want ? null : 'The page kept it ' + (el.checked ? 'checked' : 'unchecked') + '.' };
          }
          if (el.isContentEditable) { el.focus(); el.textContent = String(value); fire('input'); return { ok: true, value: el.textContent }; }
          if (tag !== 'input' && tag !== 'textarea') return { ok: false, error: 'That element (' + tag + ') has no value to set.' };
          const proto = tag === 'textarea' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          el.focus();
          Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, String(value));
          fire('input'); fire('change');
          return { ok: true, value: el.value };
        }
        """

    /// Resolves true once a selector matches (or text appears), false at the timeout. Pushed by a
    /// MutationObserver, not polled.
    static func waitFor(selector: String?, text: String?, timeoutMs: Int) -> String {
        let selectorJS = selector.map(jsString) ?? "null"
        let textJS = text.map(jsString) ?? "null"
        return """
            new Promise((resolve) => {
              const selector = \(selectorJS), text = \(textJS);
              const found = () => selector ? !!document.querySelector(selector) : (document.body?.innerText || '').includes(text);
              if (found()) return resolve(true);
              const observer = new MutationObserver(() => { if (found()) { observer.disconnect(); clearTimeout(timer); resolve(true); } });
              observer.observe(document, { childList: true, subtree: true, characterData: true, attributes: !!selector });
              const timer = setTimeout(() => { observer.disconnect(); resolve(false); }, \(timeoutMs));
            })
            """
    }

    static func jsString(_ string: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [string])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    static func decodeDescription(_ object: Any?) throws -> (ElementDescription, CGPoint, Bool) {
        guard let dictionary = object as? [String: Any] else {
            throw AutomationError(.notFound, "That isn't an element on the page.")
        }
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        let description = try JSONDecoder().decode(ElementDescription.self, from: data)
        let point = CGPoint(x: dictionary["x"] as? Double ?? 0, y: dictionary["y"] as? Double ?? 0)
        return (description, point, dictionary["hittable"] as? Bool ?? false)
    }
}

/// Waits for a callback-based call, failing with `.timeout` if it never answers.
@MainActor
func withTimeout<T>(
    _ seconds: TimeInterval,
    _ what: String,
    _ body: (@escaping (Result<T, Error>) -> Void) -> Void
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        var finished = false
        let finish: (Result<T, Error>) -> Void = { result in
            MainActor.assumeIsolated {
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            finish(.failure(AutomationError(.timeout, "\(what) didn't answer within \(Int(seconds)) seconds.")))
        }
        body(finish)
    }
}
