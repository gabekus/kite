import Foundation

/// SPIKE: an "Add to Kite" button next to Chrome Web Store results on Google.
///
/// The script runs in Kite's isolated world ("kite"), where Google's own scripts
/// can't reach its listeners or the `__kiteAddToKite` binding. A real (trusted)
/// click calls the binding; ChromiumPage checks it came from that world in the main
/// frame of a google.*/search page and only then asks Kite to open the store tab.
enum GoogleResultsScript {
    static let worldName = "kite"
    static let bindingName = "__kiteAddToKite"

    static func isSearchPage(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.path == "/search", let host = url.host else { return false }
        let labels = host.split(separator: ".")
        guard let google = labels.firstIndex(of: "google") else { return false }
        // google.com, www.google.co.uk: nothing but "www" before it, a TLD after it.
        return labels[..<google].allSatisfy { $0 == "www" } && google < labels.count - 1 && google <= 1
    }

    /// The extension id from the binding's payload, when it's well formed.
    static func extensionID(fromPayload payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String,
              id.count == 32, id.allSatisfy({ ("a"..."p").contains($0) }) else { return nil }
        return id
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
        if (/(^|\.)google\.[a-z.]+$/.test(url.hostname) && url.pathname === '/url') {
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
          border-radius: 14px; border: 1px solid #dadce0; background: #fff; color: #1a0dab; font: 500 13px/1 arial, sans-serif;
          cursor: pointer; }
        .kite-add:hover { background: #f1f3f4; }
        @media (prefers-color-scheme: dark) {
          .kite-add { border-color: #5f6368; background: #303134; color: #99c3ff; }
          .kite-add:hover { background: #3c4043; }
        }`;
      const seen = new WeakSet();
      const addButton = (link, id) => {
        seen.add(link);
        // The title link holds the result's h3; put the button on its own line under it.
        const block = link.closest('div') || link;
        const button = document.createElement('button');
        button.type = 'button';
        button.className = 'kite-add';
        button.textContent = 'Add to Kite';
        // Listeners added here live in Kite's world; the page can only send untrusted clicks.
        button.addEventListener('click', (event) => {
          event.preventDefault();
          event.stopPropagation();
          if (event.isTrusted) __kiteAddToKite(JSON.stringify({ id }));
        });
        block.insertAdjacentElement('afterend', button);
      };
      const scan = () => {
        if (!style.isConnected && document.head) document.head.append(style);
        for (const link of document.querySelectorAll('a[href]')) {
          if (seen.has(link) || !link.querySelector('h3')) continue;
          const id = extensionID(link.getAttribute('href'));
          if (id) addButton(link, id);
          else seen.add(link);
        }
      };
      new MutationObserver(scan).observe(document, { childList: true, subtree: true });
      scan();
    })();
    """#
}
