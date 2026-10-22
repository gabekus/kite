import AppKit
import KiteCore

/// What Claude can do to one page, implemented per engine.
@MainActor
protocol PageAutomation {
    /// The accessibility outline (nil if the engine can't produce one) and the page's visible text.
    func read() async throws -> (outline: String?, text: String)
    /// Finds the element, scrolls it into view and describes it for the policy.
    func locate(_ target: AutomationTarget) async throws -> LocatedElement
    /// The element that has keyboard focus, if any.
    func focusedElement() async throws -> LocatedElement?
    func click(_ element: LocatedElement) async throws
    /// Focuses the element (when given), replaces its contents with `text`, then presses Return if asked.
    func type(_ text: String, into element: LocatedElement?, submit: Bool) async throws
    /// PNG data of the visible viewport.
    func screenshot() async throws -> Data
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
        function () {
          const el = this;
          if (!(el instanceof Element)) return null;
          el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
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
            href: el.href ? String(el.href) : null,
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
