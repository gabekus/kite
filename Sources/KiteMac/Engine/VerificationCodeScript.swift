import Foundation

/// Spots one-time-code fields and offers the code that just came by email or text.
///
/// Runs in Kite's own isolated world in every page's main frame, so the page's scripts
/// can't call the `__kiteWantsCode` binding or reach the suggestion: it's in a closed
/// shadow root, and the code only goes into the field when you click it (or press Enter
/// on it). When a code field gets focus the script asks Kite, which looks in your recent
/// mail and texts (VerificationCodeService) and answers with `__kiteCodes.offer(code, sender)`.
enum VerificationCodeScript {
    static let worldName = "kite-codes"
    static let bindingName = "__kiteWantsCode"

    static func offer(code: String, sender: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [code, sender]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "globalThis.__kiteCodes?.offer(...\(json))"
    }

    static let source = #"""
    (() => {
      if (window !== window.top || globalThis.__kiteCodes || typeof __kiteWantsCode !== 'function') return;
      if (!/^https?:$/.test(location.protocol)) return;

      const WORDS = /(one[-_ ]?time|otp|verif|passcode|2fa|mfa|two[-_ ]?factor|security[-_ ]?code|auth[-_ ]?code|confirm(ation)?[-_ ]?code|login[-_ ]?code|sign[-_ ]?in[-_ ]?code|^code$|[-_ ]code$|^code[-_ ])/i;
      const textual = (i) => i instanceof HTMLInputElement && ['text', 'tel', 'number', 'password', ''].includes(i.type) && !i.disabled && !i.readOnly;
      const describe = (i) => [i.name, i.id, i.getAttribute('aria-label'), i.placeholder, i.getAttribute('data-testid')].filter(Boolean).join(' ');

      // Boxes of one character each, side by side: FedEx's six squares.
      const boxesAround = (input) => {
        if (!textual(input) || input.maxLength !== 1) return null;
        let group = input.parentElement;
        for (let depth = 0; group && depth < 4; depth++, group = group.parentElement) {
          const boxes = [...group.querySelectorAll('input')].filter((i) => textual(i) && i.maxLength === 1 && i.offsetParent !== null);
          if (boxes.length >= 4 && boxes.length <= 8 && boxes.includes(input)) return boxes;
        }
        return null;
      };

      const codeField = (input) => {
        if (!textual(input)) return null;
        const boxes = boxesAround(input);
        if (boxes) return { boxes, length: boxes.length };
        const ac = (input.autocomplete || '').toLowerCase();
        const sized = input.maxLength === -1 || (input.maxLength >= 4 && input.maxLength <= 10);
        if (ac === 'one-time-code' || (sized && WORDS.test(describe(input)))) return { boxes: [input], length: input.maxLength > 0 ? input.maxLength : 0 };
        return null;
      };

      let field = null;
      let chip = null;
      let offered = null;

      const set = (input, value) => {
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        input.focus();
        setter.call(input, value);
        input.dispatchEvent(new InputEvent('input', { bubbles: true, data: value, inputType: 'insertText' }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
      };

      const fill = () => {
        if (!field || !offered) return;
        const { boxes } = field;
        if (boxes.length === 1) set(boxes[0], offered.code);
        else [...offered.code].slice(0, boxes.length).forEach((c, i) => set(boxes[i], c));
        hide();
        offered = null;
        // Kite can stop looking.
        __kiteWantsCode(JSON.stringify({ host: location.hostname, done: true }));
      };

      const hide = () => {
        chip?.remove();
        chip = null;
      };

      const show = () => {
        hide();
        if (!field || !offered) return;
        const anchor = field.boxes[field.boxes.length - 1].getBoundingClientRect();
        const first = field.boxes[0].getBoundingClientRect();
        const host = document.createElement('div');
        const root = host.attachShadow({ mode: 'closed' });
        root.innerHTML = `
          <style>
            button { all: initial; position: fixed; z-index: 2147483647; display: flex; align-items: center; gap: 8px;
              padding: 8px 12px; border-radius: 10px; background: rgba(30, 30, 32, 0.96); color: #fff;
              font: 500 13px/1.2 -apple-system, BlinkMacSystemFont, sans-serif; cursor: pointer;
              box-shadow: 0 6px 24px rgba(0,0,0,.35), 0 0 0 0.5px rgba(255,255,255,.12); }
            button:hover, button:focus-visible { background: rgba(48, 48, 52, 0.98); outline: none; }
            .code { font: 600 15px/1 ui-monospace, SFMono-Regular, Menlo, monospace; letter-spacing: 2px; }
            .from { color: rgba(255,255,255,.6); }
          </style>
          <button type="button"><span class="code"></span><span class="from"></span></button>`;
        const button = root.querySelector('button');
        root.querySelector('.code').textContent = offered.code;
        root.querySelector('.from').textContent = 'from ' + offered.sender + ' · Fill';
        const top = anchor.bottom + 8 + 40 > innerHeight ? first.top - 44 : anchor.bottom + 8;
        button.style.left = Math.max(8, Math.min(first.left, innerWidth - 280)) + 'px';
        button.style.top = Math.max(8, top) + 'px';
        // Only a real click or key press fills; the page can't trigger it.
        button.addEventListener('mousedown', (e) => e.preventDefault());
        button.addEventListener('click', (e) => e.isTrusted && fill());
        document.documentElement.appendChild(host);
        chip = host;
      };

      document.addEventListener('focusin', (e) => {
        const found = codeField(e.target);
        if (!found) return;
        field = found;
        if (offered) return show();
        __kiteWantsCode(JSON.stringify({ host: location.hostname }));
      }, true);
      document.addEventListener('keydown', (e) => {
        if (e.isTrusted && chip && e.key === 'Enter' && field?.boxes.includes(e.target) && field.boxes.every((b) => !b.value)) {
          e.preventDefault();
          fill();
        } else if (e.key === 'Escape') hide();
      }, true);
      addEventListener('scroll', () => chip && show(), true);
      addEventListener('resize', () => chip && show());

      globalThis.__kiteCodes = {
        offer(code, sender) {
          offered = { code: String(code), sender: String(sender) };
          if (field && field.boxes.every((b) => !b.value) && field.boxes.some((b) => b.isConnected)) show();
        },
      };
    })();
    """#
}
