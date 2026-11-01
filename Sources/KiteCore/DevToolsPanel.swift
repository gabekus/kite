import Foundation

/// What View › Developer opens DevTools on (Arc 1.171: Developer Tools ⌥⌘I, Inspect
/// Elements ⌥⌘C, JavaScript Console ⌥⌘J, Network Inspector).
public enum DevToolsPanel: String, CaseIterable, Sendable {
    /// DevTools as it last was.
    case last
    /// The element picker, like Chrome's ⌥⌘C.
    case inspectElement
    case console
    case network

    /// The `DevToolsAPI` call (Chromium's DevTools embedder API, devtools_compatibility.js)
    /// that Chrome itself makes for ⌥⌘C and ⌥⌘J.
    var devToolsAPICall: String? {
        switch self {
        case .last: return nil
        case .inspectElement: return "DevToolsAPI.enterInspectElementMode()"
        case .console: return "DevToolsAPI.showPanel('console')"
        case .network: return "DevToolsAPI.showPanel('network')"
        }
    }

    /// Script Kite runs in Chromium's DevTools frontend page each time it opens or
    /// brings it forward. The frontend drops panel calls until it has finished starting
    /// (well after the page's load event), and says so by calling
    /// `InspectorFrontendHost.loadCompleted()`, the signal Chrome waits for. The script
    /// hooks that call once per frontend and holds the panel call until then.
    public var chromiumFrontendScript: String {
        let call = devToolsAPICall.map { "function () { \($0); }" } ?? "null"
        return """
        (function (call) {
          var host = window.InspectorFrontendHost;
          if (!host) return;
          if (!host.kiteState) {
            var state = host.kiteState = { loaded: false, queue: [] };
            var loadCompleted = host.loadCompleted;
            host.loadCompleted = function () {
              var result = loadCompleted.apply(this, arguments);
              state.loaded = true;
              state.queue.splice(0).forEach(function (f) { setTimeout(f, 0); });
              return result;
            };
          }
          if (!call) return;
          if (host.kiteState.loaded) call(); else host.kiteState.queue.push(call);
        })(\(call));
        """
    }
}
