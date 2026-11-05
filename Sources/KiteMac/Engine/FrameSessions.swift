#if canImport(CEFBridge)
import CEFBridge
import Foundation
import KiteCore

/// A tab's cross-site iframes. They run in renderers of their own, which the tab's own DevTools session (and its
/// document-start scripts) never reach, so each tab auto-attaches to them (flatten) and keeps their sessions:
/// - the ad blocker registers a frame's own scriptlets before it loads (uBO injects into every frame, and the players
///   and popups on ad-heavy sites live in such frames), which is why a frame waits before it loads when there is one;
/// - handoff's ring looks for a step's control in them (`ChromiumAutomation.childFrames`), for a sign-in form or
///   other control that lives in another site's frame.
@MainActor
final class FrameSessions {
    /// A cross-site frame Kite is attached to. A frame's target id is its frame id.
    struct Attached: Hashable {
        var session: String
        var frame: String
        var url: URL?
    }

    private weak var browser: KCBrowser?
    private let adblocker: Adblocker?
    private let pageURL: () -> URL?
    /// Where each frame is navigating, from `Page.frameStartedNavigating`. A frame
    /// attaches before its URL is known (`targetInfo.url` is empty), and its target id
    /// is its frame id.
    private var destinations: [String: URL] = [:]
    /// The frames attached now, by session id.
    private(set) var attached: [String: Attached] = [:]
    /// Replies Kite waits for from frame sessions, by message id.
    private var replies: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    /// Raw DevTools message ids, kept clear of ExecuteDevToolsMethod's (which count up from 1000).
    private var nextID = 1 << 30
    /// Events from the frames' sessions, with the session: handoff's ring hears its binding through these.
    var onEvent: ((_ session: String, _ method: String, _ params: [AnyHashable: Any]) -> Void)?

    init(browser: KCBrowser, adblocker: Adblocker?, pageURL: @escaping () -> URL?) {
        self.browser = browser
        self.adblocker = adblocker
        self.pageURL = pageURL
        // Results and events of attached frames come back here, and nothing else needs them.
        browser.sessionMessageHandler = { [weak self] message in self?.received(message) }
        browser.executeDevToolsMethod("Target.setAutoAttach", params: autoAttach, completion: nil)
    }

    /// Iframes, and dedicated workers only to let them go: the renderer holds every new dedicated worker while
    /// `waitForDebuggerOnStart` is on, filtered out or not, and one never attached is never resumed (Wix sites, which
    /// run in a worker, never finished loading). Kite has nothing to inject into workers. A frame waits before it
    /// loads only when the ad blocker has scriptlets to put in first.
    private var autoAttach: [String: Any] {
        ["autoAttach": true, "waitForDebuggerOnStart": adblocker != nil, "flatten": true,
         "filter": [["type": "iframe", "exclude": false], ["type": "worker", "exclude": false]]]
    }

    /// Frames let go untouched: Cloudflare's challenge (Turnstile) never passes while
    /// DevTools is attached to its frame as it loads, even with nothing injected.
    private static let untouchedHosts: Set<String> = ["challenges.cloudflare.com"]

    /// An event from the tab's own session (or, via `received`, a frame's).
    func handle(_ method: String?, _ params: [AnyHashable: Any]) {
        switch method {
        case "Page.frameStartedNavigating":
            guard let frame = params["frameId"] as? String, let url = (params["url"] as? String).flatMap(URL.init(string:)) else { return }
            if destinations.count > 256 { destinations.removeAll() }
            destinations[frame] = url
            if let session = attached.first(where: { $0.value.frame == frame })?.key { attached[session]?.url = url }
        case "Target.attachedToTarget":
            // CEF reports the attach before Chromium starts holding the frame, and a
            // resume sent that early is lost: the frame would never load. Answer once
            // this task is done.
            DispatchQueue.main.async { [weak self] in self?.attachedFrame(params) }
        case "Target.detachedFromTarget":
            if let session = params["sessionId"] as? String { attached[session] = nil }
        default:
            break
        }
    }

    private func received(_ message: [AnyHashable: Any]) {
        if let id = message["id"] as? Int {
            guard let reply = replies.removeValue(forKey: id) else { return }
            if let error = (message["error"] as? [String: Any])?["message"] as? String {
                reply(.failure(AutomationError(.failed, error)))
            } else {
                reply(.success(message["result"] as? [String: Any] ?? [:]))
            }
            return
        }
        let method = message["method"] as? String
        let params = message["params"] as? [AnyHashable: Any] ?? [:]
        handle(method, params)
        if let method, let session = message["sessionId"] as? String, attached[session] != nil { onEvent?(session, method, params) }
    }

    private func attachedFrame(_ params: [AnyHashable: Any]) {
        guard let session = params["sessionId"] as? String else { return }
        let info = params["targetInfo"] as? [String: Any]
        let target = info?["targetId"] as? String
        let reported = (info?["url"] as? String).flatMap(URL.init(string:))
        let url = reported?.host() != nil ? reported : target.flatMap { destinations.removeValue(forKey: $0) }
        if info?["type"] as? String == "worker" || url?.host().map({ Self.untouchedHosts.contains($0.lowercased()) }) == true {
            // Resume it and detach before it runs; its own iframes then don't attach either.
            send(session, "Runtime.runIfWaitingForDebugger")
            nextID += 1
            browser?.sendDevToolsMessage(["id": nextID, "method": "Target.detachFromTarget", "params": ["sessionId": session]])
            return
        }
        if info?["type"] as? String == "iframe", let target { attached[session] = Attached(session: session, frame: target, url: url) }
        // Page events name the destinations of the frame's own iframes; document-start
        // scripts also need the Page domain.
        send(session, "Page.enable")
        if info?["type"] as? String == "iframe", let url, let adblocker, let script = adblocker.frameStartScript(for: url, page: pageURL()) {
            send(session, "Page.addScriptToEvaluateOnNewDocument", ["source": script])
        }
        send(session, "Target.setAutoAttach", autoAttach)
        guard params["waitingForDebugger"] as? Bool == true else { return }
        // A session handles messages in order, so the script is in place before the frame loads.
        send(session, "Runtime.runIfWaitingForDebugger")
        // Belt and braces: a frame left waiting never loads, and resuming twice is harmless.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.send(session, "Runtime.runIfWaitingForDebugger") }
    }

    /// Calls a DevTools method in a frame's session and waits for its result.
    func call(_ session: String, _ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 5) async throws -> [String: Any] {
        guard browser != nil, attached[session] != nil else { throw AutomationError(.failed, "That frame is gone.") }
        return try await withTimeout(timeout, method) { done in
            nextID += 1
            replies[nextID] = done
            let id = nextID
            browser?.sendDevToolsMessage(["id": id, "sessionId": session, "method": method, "params": params])
            // A reply that never comes mustn't keep its slot.
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout + 1) { [weak self] in self?.replies[id] = nil }
        }
    }

    private func send(_ session: String, _ method: String, _ params: [String: Any] = [:]) {
        nextID += 1
        browser?.sendDevToolsMessage(["id": nextID, "sessionId": session, "method": method, "params": params])
    }
}
#endif
