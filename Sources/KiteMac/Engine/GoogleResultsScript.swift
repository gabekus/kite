import Foundation
import KiteCore

/// "Add to Kite" next to Chrome Web Store results on Google.
///
/// The script runs in Kite's own isolated world on Google results pages, where Google's
/// scripts can't reach its click listeners or the `__kiteAddToKite` binding. Only a
/// real (trusted) click calls the binding; ChromiumPage checks the call came from that
/// world in the main frame of a Google results page before installing anything.
enum GoogleResultsScript {
    static let worldName = "kite"
    static let bindingName = "__kiteAddToKite"

    /// The extension id in the binding's payload, when it's well formed.
    static func extensionID(fromPayload payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String, ChromeWebStore.isExtensionID(id) else { return nil }
        return id
    }

    /// Sets the buttons for one extension on a results page to `text`.
    static func label(_ extensionID: String, _ text: String, disabled: Bool) -> String? {
        guard ChromeWebStore.isExtensionID(extensionID),
              let quoted = try? JSONSerialization.data(withJSONObject: [text]),
              let json = String(data: quoted, encoding: .utf8) else { return nil }
        return """
        document.querySelectorAll('.kite-add[data-id="\(extensionID)"]').forEach((b) => {
          b.textContent = \(json)[0];
          b.disabled = \(disabled);
        });
        """
    }

    static let source = #"""
    (() => {
      if (window !== window.top || window.__kiteAddButtons) return;
      if (!/(^|\.)google\.[a-z.]+$/.test(location.hostname) || location.pathname !== '/search') return;
      if (typeof __kiteAddToKite !== 'function') return;
      window.__kiteAddButtons = true;
      const ID = /^[a-p]{32}$/;
      // The extension id when `href` is a store detail page, directly or through Google's /url redirect.
      const extensionID = (href) => {
        let url;
        try { url = new URL(href, location.href); } catch { return null; }
        if (url.hostname === location.hostname && url.pathname === '/url') {
          try { url = new URL(url.searchParams.get('q') || url.searchParams.get('url') || ''); } catch { return null; }
        }
        if (url.protocol !== 'https:' || url.hostname !== 'chromewebstore.google.com') return null;
        const parts = url.pathname.split('/').filter(Boolean);
        if (parts[0] !== 'detail' || parts.length < 2 || parts.length > 3) return null;
        const id = parts[parts.length - 1];
        return ID.test(id) ? id : null;
      };
      const style = document.createElement('style');
      style.textContent = `
        .kite-add { display: inline-flex; align-items: center; margin: 6px 0 2px; padding: 0 12px; height: 28px;
          border-radius: 14px; border: 1px solid #dadce0; background: #fff; color: #1a0dab;
          font: 500 13px/1 arial, sans-serif; cursor: pointer; }
        .kite-add:hover:not(:disabled) { background: #f1f3f4; }
        .kite-add:disabled { cursor: default; opacity: 0.7; }
        @media (prefers-color-scheme: dark) {
          .kite-add { border-color: #5f6368; background: #303134; color: #99c3ff; }
          .kite-add:hover:not(:disabled) { background: #3c4043; }
        }`;
      const seen = new WeakSet();
      const addButton = (link, id) => {
        // The title link holds the result's h3; the button goes on its own line under it.
        const block = link.closest('div') || link;
        const button = document.createElement('button');
        button.type = 'button';
        button.className = 'kite-add';
        button.dataset.id = id;
        button.textContent = 'Add to Kite';
        // This listener lives in Kite's world; the page can only send untrusted clicks.
        button.addEventListener('click', (event) => {
          event.preventDefault();
          event.stopPropagation();
          if (event.isTrusted && !button.disabled) __kiteAddToKite(JSON.stringify({ id }));
        });
        block.insertAdjacentElement('afterend', button);
      };
      const scan = () => {
        if (!style.isConnected && document.head) document.head.append(style);
        for (const link of document.querySelectorAll('a[href]')) {
          if (seen.has(link)) continue;
          seen.add(link);
          if (!link.querySelector('h3')) continue;
          const id = extensionID(link.getAttribute('href'));
          if (id) addButton(link, id);
        }
      };
      new MutationObserver(scan).observe(document, { childList: true, subtree: true });
      scan();
    })();
    """#
}
