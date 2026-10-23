import Foundation

/// SPIKE: an "Add to Kite" button next to Chrome Web Store results on Google.
/// It only opens the extension's store page with #kite-add, where WebStoreScript
/// starts the store's own Add flow; installing still needs the user to confirm.
enum GoogleResultsScript {
    static func script(for url: URL) -> String? {
        guard let host = url.host, url.path == "/search" else { return nil }
        let labels = host.split(separator: ".")
        // google.com, www.google.co.uk, …
        let isGoogle = labels.contains("google") && (labels.first == "google" || labels.first == "www")
        return isGoogle ? source : nil
    }

    private static let source = #"""
    (() => {
      if (!/(^|\.)google\.[a-z.]+$/.test(location.hostname) || location.pathname !== '/search' || window.__kiteAddButtons) return;
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
          text-decoration: none; cursor: pointer; }
        .kite-add:hover { background: #f1f3f4; }
        @media (prefers-color-scheme: dark) {
          .kite-add { border-color: #5f6368; background: #303134; color: #99c3ff; }
          .kite-add:hover { background: #3c4043; }
        }`;
      const addButton = (link, id) => {
        if (link.dataset.kiteAdd) return;
        link.dataset.kiteAdd = '1';
        // The title link holds the result's h3; put the button on its own line under it.
        const anchorBlock = link.closest('div') || link;
        if (anchorBlock.parentElement?.querySelector(`:scope > .kite-add[data-id="${id}"]`)) return;
        const button = document.createElement('a');
        button.className = 'kite-add';
        button.dataset.id = id;
        button.textContent = 'Add to Kite';
        button.href = `https://chromewebstore.google.com/detail/${id}#kite-add`;
        button.target = '_blank';
        button.rel = 'noopener';
        anchorBlock.insertAdjacentElement('afterend', button);
      };
      const scan = () => {
        if (!style.isConnected && document.head) document.head.append(style);
        for (const link of document.querySelectorAll('a[href]')) {
          if (!link.querySelector('h3') || link.dataset.kiteAdd) continue;
          const id = extensionID(link.getAttribute('href'));
          if (id) addButton(link, id);
        }
      };
      new MutationObserver(scan).observe(document, { childList: true, subtree: true });
      document.addEventListener('DOMContentLoaded', scan);
    })();
    """#
}
