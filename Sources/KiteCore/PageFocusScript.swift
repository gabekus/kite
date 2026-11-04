/// Scripts that read or move a page's keyboard focus and selection (Edit › Undo, Edit › Find › Jump to Selection).
public enum PageFocusScript {
    /// `isTextField(e)`: an enabled, writable text input or textarea, which keeps its own selection and undo.
    static let isTextField = """
      const isTextField = (e) => {
        if (!e || e.disabled || e.readOnly) return false;
        if (e.tagName === 'TEXTAREA') return true;
        if (e.tagName !== 'INPUT') return false;
        const type = (e.getAttribute('type') || 'text').toLowerCase();
        return ['text', 'search', 'url', 'tel', 'email', 'password', 'number', 'date', 'datetime-local',
                'month', 'time', 'week'].includes(type);
      };
    """

    /// Whether ⌘Z on the page would undo the page's own editing. A focused frame Kite can't look into
    /// (another site's iframe) counts as editing, so typing there is never lost to a sidebar undo.
    public static let editingFocus = """
    (() => {
    \(isTextField)
      const editing = (doc) => {
        if (!doc) return true;
        if (doc.designMode === 'on') return true;
        let e = doc.activeElement;
        while (e && e.shadowRoot && e.shadowRoot.activeElement) e = e.shadowRoot.activeElement;
        if (!e || e === doc.body || e === doc.documentElement) return false;
        if (e.isContentEditable) return true;
        const tag = e.tagName;
        if (tag === 'IFRAME' || tag === 'FRAME') {
          let inner = null;
          try { inner = e.contentDocument; } catch (_) {}
          return editing(inner);
        }
        return isTextField(e);
      };
      return editing(document);
    })()
    """

    /// Edit › Find › Jump to Selection: scrolls the selection's own box (its first line) to the middle of
    /// the view, through any scrolling boxes it sits in. The selection wins, also inside a contenteditable
    /// editor or a designMode page, where a caret alone counts too; a focused text input or textarea, whose
    /// selection the page can't measure, is centred as a whole. False when there's nothing to jump to.
    public static let jumpToSelection = """
    (() => {
    \(isTextField)
      let active = document.activeElement;
      while (active && active.shadowRoot && active.shadowRoot.activeElement) active = active.shadowRoot.activeElement;
      const selection = getSelection();
      const editing = document.designMode === 'on' || (active && active.isContentEditable);
      let range = null, target = null;
      if (active && isTextField(active)) {
        target = active;
      } else if (selection && selection.rangeCount && (!selection.isCollapsed || editing)) {
        range = selection.getRangeAt(0);
        const node = range.startContainer;
        target = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
      }
      if (!target) return false;
      const empty = (r) => !r || (r.width === 0 && r.height === 0 && r.top === 0 && r.left === 0);
      const measure = () => {
        if (range) {
          const rects = range.getClientRects();
          const r = rects.length ? rects[0] : range.getBoundingClientRect();
          if (!empty(r)) return r;
        }
        return target.getBoundingClientRect();
      };
      if (range && empty(range.getClientRects()[0] || range.getBoundingClientRect())) {
        target.scrollIntoView({ block: 'nearest', inline: 'nearest' });
      }
      const middle = (r) => [r.left + r.width / 2, r.top + r.height / 2];
      for (let e = target.parentElement; e && e !== document.body && e !== document.documentElement; e = e.parentElement) {
        if (e.scrollHeight <= e.clientHeight && e.scrollWidth <= e.clientWidth) continue;
        const style = getComputedStyle(e);
        if (!/(auto|scroll|overlay)/.test(style.overflowX + ' ' + style.overflowY)) continue;
        const [x, y] = middle(measure()), box = e.getBoundingClientRect();
        e.scrollTop += y - (box.top + box.height / 2);
        const r = measure();
        if (r.left < box.left || r.right > box.right) e.scrollLeft += x - (box.left + box.width / 2);
      }
      const r = measure(), [x, y] = middle(r);
      const left = r.left < 0 || r.right > innerWidth ? x - innerWidth / 2 : 0;
      window.scrollBy({ top: y - innerHeight / 2, left, behavior: 'instant' });
      return true;
    })()
    """
}
