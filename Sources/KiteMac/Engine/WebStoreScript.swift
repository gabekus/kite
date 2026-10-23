import Foundation

/// SPIKE: on the Chrome Web Store, say "Add to Kite" and drop the "Switch to Chrome"
/// banner and popup. The store installs into Kite's Chromium either way; Arc's
/// copy of the page shows "Add to Arc" and no promos.
enum WebStoreScript {
    static func script(for url: URL) -> String? {
        url.host == "chromewebstore.google.com" ? source : nil
    }

    private static let source = #"""
    (() => {
      if (location.hostname !== 'chromewebstore.google.com' || window.__kiteWebStore) return;
      window.__kiteWebStore = true;
      // The smallest block holding the promo text and a button, then the outermost
      // wrapper around it that holds nothing else (the popup's card and shadow).
      const promo = (text) => {
        let block = null;
        for (const el of document.querySelectorAll('div, section, aside')) {
          if (el.textContent.includes(text) && el.querySelector('button')) block = el;
        }
        if (!block) return null;
        const own = block.textContent.trim();
        while (block.parentElement && block.parentElement !== document.body &&
               block.parentElement.textContent.trim() === own) block = block.parentElement;
        return block;
      };
      const fix = () => {
        for (const span of document.querySelectorAll('button span')) {
          if (span.childElementCount !== 0) continue;
          if (span.textContent === 'Add to Chrome') span.textContent = 'Add to Kite';
          else if (span.textContent === 'Remove from Chrome') span.textContent = 'Remove from Kite';
        }
        for (const text of ['Switch to Chrome to install extensions and themes', 'Switch to Chrome?']) {
          promo(text)?.remove();
        }
      };
      new MutationObserver(fix).observe(document, { childList: true, subtree: true });
    })();
    """#
}
