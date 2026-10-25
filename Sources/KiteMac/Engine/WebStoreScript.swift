import Foundation
import KiteCore

/// The Chrome Web Store in Kite: it installs into Kite's Chromium, so the buttons say
/// "Add to Kite" / "Remove from Kite" and the "Switch to Chrome" banner and popup go.
/// (Arc's copy of the page says "Add to Arc" and has no promos either.)
enum WebStoreScript {
    static func script(for url: URL) -> String? {
        ChromeWebStore.isStorePage(url) ? source : nil
    }

    /// Run by Kite, never by a page, in a store page it loaded to install one
    /// extension: clicks the store's Add button once it exists. That only starts the
    /// store's own flow; Chrome's dialog still asks.
    static let startAddScript = #"""
    (() => {
      const started = Date.now();
      const tryAdd = () => {
        const button = [...document.querySelectorAll('button')]
          .find((b) => b.textContent.trim() === 'Add to Kite' && !b.disabled);
        if (button) return button.click();
        if (Date.now() - started < 10000) setTimeout(tryAdd, 200);
      };
      tryAdd();
    })();
    """#

    /// The store offers Add again (the dialog was cancelled).
    static let offersAddScript =
        "[...document.querySelectorAll('button')].some((b) => b.textContent.trim() === 'Add to Kite' && !b.disabled)"

    private static let source = #"""
    (() => {
      if (location.hostname !== 'chromewebstore.google.com' || window.__kiteWebStore) return;
      window.__kiteWebStore = true;
      // The smallest block holding the promo text and a button, then the outermost
      // wrapper around it that holds nothing else (the popup's card, scrim and circle).
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
