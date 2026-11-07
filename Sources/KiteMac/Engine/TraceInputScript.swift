import Foundation

/// The action trace's page script (Chromium, normal windows only): what the person does on a page, as events and
/// never content. A click's role and accessible name (and a link's address); a field focused and left, with its
/// kind and the length of what's in it, never the value; a scroll, collapsed to one report when it settles; and the
/// load's timings (time to first byte, DOMContentLoaded, load, first contentful paint). It runs in its own world, in
/// the top frame, and reports through a binding only that world has (`TracePageInput` reads the reports).
enum TraceInputScript {
    static let worldName = "kite-trace"
    static let bindingName = "kiteTraceInput"

    static let source = #"""
    (() => {
      if (window !== window.top || window.__kiteTrace) return;
      window.__kiteTrace = true;
      const binding = globalThis.kiteTraceInput;
      if (typeof binding !== 'function') return;
      const post = (o) => { try { binding(JSON.stringify(o)); } catch (e) {} };
      const fieldTags = { INPUT: 1, TEXTAREA: 1, SELECT: 1 };
      const isField = (el) => el && (fieldTags[el.tagName] || el.isContentEditable);
      const roleOf = (el) => {
        const role = el.getAttribute && el.getAttribute('role');
        if (role) return role;
        switch (el.tagName) {
          case 'A': return el.hasAttribute('href') ? 'link' : 'generic';
          case 'BUTTON': case 'SUMMARY': return 'button';
          case 'SELECT': return 'combobox';
          case 'TEXTAREA': return 'textbox';
          case 'INPUT': {
            const t = (el.type || 'text').toLowerCase();
            if (['button', 'submit', 'reset', 'image'].includes(t)) return 'button';
            if (t === 'checkbox' || t === 'radio') return t;
            return 'textbox';
          }
          default: return el.isContentEditable ? 'textbox' : el.tagName.toLowerCase();
        }
      };
      const nameOf = (el, role) => {
        if (role === 'textbox' || role === 'combobox' || role === 'searchbox') return '';
        const label = el.getAttribute('aria-label') || el.getAttribute('title') || el.getAttribute('alt');
        // An input's value is only a name on a button; anywhere else it's what was entered.
        const text = label || (el.tagName === 'INPUT' ? (role === 'button' ? el.value : '') : el.innerText) || '';
        return String(text).replace(/\s+/g, ' ').trim().slice(0, 80);
      };
      const describe = (el) => ({
        tag: el.tagName.toLowerCase(), type: el.type || undefined, role: el.getAttribute('role') || undefined,
        name: el.getAttribute('name') || undefined, id: el.id || undefined,
        autocomplete: el.getAttribute('autocomplete') || undefined, placeholder: el.getAttribute('placeholder') || undefined,
        label: el.getAttribute('aria-label') || (el.labels && el.labels[0] ? el.labels[0].innerText.slice(0, 60) : undefined),
        editable: !!el.isContentEditable,
      });
      addEventListener('click', (e) => {
        if (!e.isTrusted) return;
        const el = e.target && e.target.closest ? e.target.closest('a[href],button,[role],input,select,textarea,summary,label') || e.target : null;
        if (!el || !el.tagName) return;
        const role = roleOf(el);
        const report = { t: 'click', role, name: nameOf(el, role), button: e.button };
        if (el.tagName === 'A' && el.href) {
          report.href = el.href;
          report.newTab = el.target === '_blank' || e.metaKey || e.ctrlKey || e.button === 1;
        }
        post(report);
      }, true);
      const focused = new WeakMap();
      addEventListener('focusin', (e) => {
        const el = e.target;
        if (!e.isTrusted || !isField(el)) return;
        focused.set(el, { at: performance.now(), len: (el.value || el.innerText || '').length });
        post(Object.assign({ t: 'focus' }, describe(el)));
      }, true);
      addEventListener('focusout', (e) => {
        const el = e.target;
        const was = isField(el) && focused.get(el);
        if (!was) return;
        focused.delete(el);
        const len = el.tagName === 'SELECT' ? (el.selectedIndex >= 0 ? 1 : 0)
          : el.type === 'checkbox' || el.type === 'radio' ? (el.checked ? 1 : 0)
          : (el.isContentEditable ? el.innerText : el.value || '').length;
        post(Object.assign({ t: 'blur', len, changed: len !== was.len, ms: Math.round(performance.now() - was.at) }, describe(el)));
      }, true);
      let scroll = null;
      addEventListener('scroll', (e) => {
        if (!e.isTrusted) return;
        const now = performance.now();
        if (!scroll) scroll = { at: now, x: scrollX, y: scrollY, n: 0, timer: 0 };
        scroll.n += 1;
        clearTimeout(scroll.timer);
        scroll.timer = setTimeout(() => {
          const s = scroll; scroll = null;
          post({ t: 'scroll', dx: Math.round(scrollX - s.x), dy: Math.round(scrollY - s.y), n: s.n, ms: Math.round(performance.now() - s.at) });
        }, 300);
      }, { capture: true, passive: true });
      const timing = () => {
        const nav = performance.getEntriesByType('navigation')[0];
        if (!nav) return;
        const report = (fcp, lcp) => post({ t: 'timing', ttfb: nav.responseStart, dcl: nav.domContentLoadedEventEnd,
                                            load: nav.loadEventEnd, fcp, lcp, nav: nav.type });
        const paint = performance.getEntriesByName('first-contentful-paint')[0];
        if (paint) return report(paint.startTime);
        try {
          let done = false;
          const observer = new PerformanceObserver((list) => {
            const entry = list.getEntriesByName('first-contentful-paint')[0];
            if (entry && !done) { done = true; observer.disconnect(); report(entry.startTime); }
          });
          observer.observe({ type: 'paint', buffered: true });
          setTimeout(() => { if (!done) { done = true; observer.disconnect(); report(undefined); } }, 3000);
        } catch (e) { report(undefined); }
      };
      if (document.readyState === 'complete') setTimeout(timing, 0);
      else addEventListener('load', () => setTimeout(timing, 0), { once: true });
    })();
    """#
}
