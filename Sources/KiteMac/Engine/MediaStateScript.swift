import Foundation

/// Reports what a page is playing (MediaState) and runs the Mini Player's commands.
///
/// `source` runs in Kite's own isolated world in every page's main frame and reports through
/// `report` (a CDP binding on Chromium, a script message handler on WebKit): `null` as the page
/// starts, then the element that played last whenever its state, metadata or picture in
/// picture changes. Commands run in the same world (`MediaCommand.script`).
///
/// `pageHook` runs in the page's own world, only to learn which Media Session actions
/// (previous / next track) the page handles and to call its handler when asked. It talks to the
/// isolated world with string-only window events; it calls nothing but the page's own handlers.
enum MediaStateScript {
    static let worldName = "kite-media"
    /// The Chromium binding and the WebKit message handler.
    static let bindingName = "__kiteMediaReport"

    static let source = #"""
    (() => {
      if (window !== window.top || globalThis.__kiteMedia) return;
      const send = typeof __kiteMediaReport === 'function'
        ? (s) => __kiteMediaReport(s)
        : (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.__kiteMediaReport)
          ? (s) => window.webkit.messageHandlers.__kiteMediaReport.postMessage(s) : null;
      if (!send) return;

      let current = null;
      let actions = [];
      let last = 'null';
      let poll = 0;

      const pip = (m) => document.pictureInPictureElement === m || m.webkitPresentationMode === 'picture-in-picture';
      const snapshot = () => {
        if (!current || !current.isConnected || !(current.currentSrc || current.srcObject)) return null;
        const meta = navigator.mediaSession && navigator.mediaSession.metadata;
        const art = meta && meta.artwork && meta.artwork.length ? meta.artwork[meta.artwork.length - 1].src : null;
        return {
          playing: !current.paused && !current.ended,
          video: current instanceof HTMLVideoElement && current.videoWidth > 0,
          muted: current.muted || current.volume === 0,
          pip: pip(current),
          title: (meta && meta.title) || document.title || '',
          artist: (meta && meta.artist) || null,
          artwork: art,
          actions,
        };
      };
      const report = () => {
        const state = snapshot();
        if (!state) current = null;
        const json = JSON.stringify(state);
        if (json !== last) { last = json; send(json); }
        // Titles change without media events (the next song); look again while there's media.
        clearInterval(poll);
        poll = state ? setInterval(report, state.playing ? 2000 : 10000) : 0;
      };

      const events = ['play', 'playing', 'pause', 'ended', 'emptied', 'volumechange', 'loadedmetadata',
        'enterpictureinpicture', 'leavepictureinpicture', 'webkitpresentationmodechanged'];
      for (const type of events) {
        document.addEventListener(type, (e) => {
          const m = e.target;
          if (!(m instanceof HTMLMediaElement)) return;
          // Like Chromium's media sessions: muted autoplay (background videos) doesn't count
          // until it's unmuted.
          if (m !== current && (type === 'play' || type === 'playing' || type === 'volumechange')
              && !m.paused && !m.muted && m.volume > 0) current = m;
          if (m === current) report();
        }, true);
      }
      window.addEventListener('__kiteMediaActions', (e) => {
        actions = typeof e.detail === 'string' && e.detail ? e.detail.split(',') : [];
        if (current) report();
      });

      const playing = () => [...document.querySelectorAll('video,audio')].find((m) => !m.paused && !m.ended);
      globalThis.__kiteMedia = {
        run(command) {
          const m = current || playing();
          switch (command) {
            case 'play': if (m) m.play().catch(() => {}); break;
            case 'pause': if (m) m.pause(); break;
            case 'previoustrack': case 'nexttrack':
              window.dispatchEvent(new CustomEvent('__kiteMediaAction', { detail: command })); break;
            case 'enterpip':
              if (m instanceof HTMLVideoElement && !pip(m)) {
                if (m.requestPictureInPicture && document.pictureInPictureEnabled !== false) m.requestPictureInPicture().catch(() => {});
                else if (m.webkitSetPresentationMode) m.webkitSetPresentationMode('picture-in-picture');
              }
              break;
            case 'exitpip':
              if (document.pictureInPictureElement) document.exitPictureInPicture().catch(() => {});
              else if (m && m.webkitPresentationMode === 'picture-in-picture') m.webkitSetPresentationMode('inline');
              break;
          }
        },
      };
      send('null');
    })();
    """#

    static let pageHook = #"""
    (() => {
      if (window !== window.top || typeof MediaSession === 'undefined') return;
      const proto = MediaSession.prototype;
      const original = proto.setActionHandler;
      if (typeof original !== 'function') return;
      const handlers = new Map();
      const wanted = ['previoustrack', 'nexttrack'];
      proto.setActionHandler = function (action, handler) {
        const result = original.apply(this, arguments);
        if (wanted.includes(action)) {
          if (typeof handler === 'function') handlers.set(action, handler); else handlers.delete(action);
          window.dispatchEvent(new CustomEvent('__kiteMediaActions', { detail: [...handlers.keys()].join(',') }));
        }
        return result;
      };
      window.addEventListener('__kiteMediaAction', (e) => {
        const handler = handlers.get(e.detail);
        if (handler) handler.call(navigator.mediaSession, { action: e.detail });
      });
    })();
    """#
}
