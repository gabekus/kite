// Called by Kite (DevTools Runtime.evaluate in this page), never by websites: only
// Kite can load this page. Every call resolves to a JSON string.
window.kiteHelper = {
  async list() {
    const all = await chrome.management.getAll();
    return JSON.stringify(all.map((e) => ({
      id: e.id,
      name: e.name,
      enabled: e.enabled,
      type: e.type,
      installType: e.installType,
      mayDisable: e.mayDisable,
      optionsUrl: e.optionsUrl || null,
    })));
  },

  async setEnabled(id, enabled) {
    await chrome.management.setEnabled(id, enabled);
    return JSON.stringify((await chrome.management.get(id)).enabled);
  },

  // Chromium's tab id for each page target, so Kite can tell extensions which of its
  // tabs is which (ExtensionTabsBridge). Lists targets only; attaches to nothing.
  async tabTargets() {
    const targets = await chrome.debugger.getTargets();
    return JSON.stringify(targets.filter((t) => t.type === 'page' && t.tabId !== undefined)
      .map((t) => ({ targetId: t.id, tabId: t.tabId })));
  },

  // Needs a user gesture (Kite evaluates it with one), and Chrome asks with its own
  // "Remove …?" dialog. Resolves to false when the user cancels.
  async remove(id) {
    try {
      await chrome.management.uninstall(id, { showConfirmDialog: true });
      return JSON.stringify(true);
    } catch (error) {
      return JSON.stringify(false);
    }
  },
};
