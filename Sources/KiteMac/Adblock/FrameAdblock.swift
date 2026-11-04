#if canImport(CEFBridge)
import CEFBridge
import Foundation

/// Cross-site iframes run in renderers of their own, which the tab's document-start
/// script never reaches. uBO injects scriptlets into every frame, and the players and
/// popups on ad-heavy sites (streaming, embeds) live in such frames. So each tab
/// auto-attaches to its iframes, which wait before they load; Kite registers the
/// frame's own script, then lets it go.
@MainActor
final class FrameAdblock {
    private weak var browser: KCBrowser?
    private let adblocker: Adblocker
    private let pageURL: () -> URL?
    /// Where each frame is navigating, from `Page.frameStartedNavigating`. A frame
    /// attaches before its URL is known (`targetInfo.url` is empty), and its target id
    /// is its frame id.
    private var destinations: [String: URL] = [:]
    /// Raw DevTools message ids, kept clear of ExecuteDevToolsMethod's (which count up from 1000).
    private var nextID = 1 << 30

    init(browser: KCBrowser, adblocker: Adblocker, pageURL: @escaping () -> URL?) {
        self.browser = browser
        self.adblocker = adblocker
        self.pageURL = pageURL
        // Results and events of attached frames come back here, and nothing else needs them.
        browser.sessionMessageHandler = { [weak self] message in
            self?.handle(message["method"] as? String, message["params"] as? [AnyHashable: Any] ?? [:])
        }
        browser.executeDevToolsMethod("Target.setAutoAttach", params: Self.autoAttach, completion: nil)
    }

    /// Only iframes: workers would wait too, and Kite has nothing to inject there.
    private static let autoAttach: [String: Any] = [
        "autoAttach": true, "waitForDebuggerOnStart": true, "flatten": true,
        "filter": [["type": "iframe", "exclude": false]],
    ]

    /// Frames let go untouched: Cloudflare's challenge (Turnstile) never passes while
    /// DevTools is attached to its frame as it loads, even with nothing injected.
    private static let untouchedHosts: Set<String> = ["challenges.cloudflare.com"]

    /// An event from the tab's own session (or, via the session handler, a frame's).
    func handle(_ method: String?, _ params: [AnyHashable: Any]) {
        switch method {
        case "Page.frameStartedNavigating":
            guard let frame = params["frameId"] as? String, let url = (params["url"] as? String).flatMap(URL.init(string:)) else { return }
            if destinations.count > 256 { destinations.removeAll() }
            destinations[frame] = url
        case "Target.attachedToTarget":
            // CEF reports the attach before Chromium starts holding the frame, and a
            // resume sent that early is lost: the frame would never load. Answer once
            // this task is done.
            DispatchQueue.main.async { [weak self] in self?.attached(params) }
        default:
            break
        }
    }

    private func attached(_ params: [AnyHashable: Any]) {
        guard let session = params["sessionId"] as? String else { return }
        let info = params["targetInfo"] as? [String: Any]
        let target = info?["targetId"] as? String
        let reported = (info?["url"] as? String).flatMap(URL.init(string:))
        let url = reported?.host() != nil ? reported : target.flatMap { destinations.removeValue(forKey: $0) }
        if let host = url?.host()?.lowercased(), Self.untouchedHosts.contains(host) {
            // Resume it and detach before it runs; its own iframes then don't attach either.
            send(session, "Runtime.runIfWaitingForDebugger")
            nextID += 1
            browser?.sendDevToolsMessage(["id": nextID, "method": "Target.detachFromTarget", "params": ["sessionId": session]])
            return
        }
        // Page events name the destinations of the frame's own iframes; document-start
        // scripts also need the Page domain.
        send(session, "Page.enable")
        if info?["type"] as? String == "iframe", let url, let script = adblocker.frameStartScript(for: url, page: pageURL()) {
            send(session, "Page.addScriptToEvaluateOnNewDocument", ["source": script])
        }
        send(session, "Target.setAutoAttach", Self.autoAttach)
        guard params["waitingForDebugger"] as? Bool == true else { return }
        // A session handles messages in order, so the script is in place before the frame loads.
        send(session, "Runtime.runIfWaitingForDebugger")
        // Belt and braces: a frame left waiting never loads, and resuming twice is harmless.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.send(session, "Runtime.runIfWaitingForDebugger") }
    }

    private func send(_ session: String, _ method: String, _ params: [String: Any] = [:]) {
        nextID += 1
        browser?.sendDevToolsMessage(["id": nextID, "sessionId": session, "method": method, "params": params])
    }
}
#endif
