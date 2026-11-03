// Chromium's own openPopup, taken before Kite's script replaces it.
const original = chrome.action.openPopup;
const native = original.bind(chrome.action);

chrome.runtime.onMessage.addListener((message, _sender, reply) => {
  if (message === 'replaced') return reply({ replaced: chrome.action.openPopup !== original });
  const open = message === 'native' ? native : () => chrome.action.openPopup();
  Promise.resolve()
    .then(open)
    .then(() => reply({ ok: true }), (error) => reply({ ok: false, error: error.message }));
  return true;
});
