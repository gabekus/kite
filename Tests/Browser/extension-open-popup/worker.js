// Chromium's own openPopup, taken before Kite's script replaces it.
const original = chrome.action.openPopup;
const native = original.bind(chrome.action);

// A popup for the active tab only, as an extension sets one with setPopup({ tabId }).
const openTabPopup = async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  await chrome.action.setPopup({ tabId: tab.id, popup: 'tab-popup.html' });
  await chrome.action.openPopup();
};

chrome.runtime.onMessage.addListener((message, _sender, reply) => {
  if (message === 'replaced') return reply({ replaced: chrome.action.openPopup !== original });
  const open = message === 'native' ? native : message === 'tab' ? openTabPopup : () => chrome.action.openPopup();
  Promise.resolve()
    .then(open)
    .then(() => reply({ ok: true }), (error) => {
      // Kite keeps the worker's console for Claude (read_console_messages with extension).
      console.error(`openPopup (${message}) failed: ${error.message}`);
      reply({ ok: false, error: error.message });
    });
  return true;
});
