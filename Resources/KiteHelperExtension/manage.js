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
