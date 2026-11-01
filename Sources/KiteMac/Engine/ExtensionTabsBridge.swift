#if canImport(CEFBridge)
import AppKit
import CEFBridge
import KiteCore

/// A Kite tab as extensions should see it.
struct ExtensionTab {
    let id: UUID
    let page: ChromiumPage
    let active: Bool
    let pinned: Bool
}

/// The window whose tabs extensions see, and what they may ask of it.
@MainActor
protocol ExtensionTabsHost: AnyObject {
    /// Live tabs, in sidebar order.
    var extensionTabs: [ExtensionTab] { get }
    /// In screen points, origin top left (Chrome's coordinates).
    var extensionWindowBounds: CGRect { get }
    var extensionWindowIsFocused: Bool { get }
    var extensionWindowIsFullScreen: Bool { get }
    /// A new tab, loaded now even if it stays in the background.
    func openTabForExtension(url: URL?, active: Bool) -> ChromiumPage?
    func activateTabForExtension(_ id: UUID)
}

/// Makes Kite's tabs visible to extensions (tabs.query, windows.*, tabs.create, …).
///
/// Chromium doesn't count Kite's Alloy-style tabs as being in any window, so it can't
/// answer those calls itself (see ExtensionTabsScript). Kite's in-process DevTools can
/// attach to every extension's service worker, though: this keeps a hidden page of Kite's
/// helper extension open, attaches from it to each extension's worker, and runs
/// ExtensionTabsScript there with Kite's tab list. The helper page also maps Kite's tabs
/// to Chromium's tab ids (chrome.debugger.getTargets, which only lists them).
///
/// While attached, Chromium keeps the workers running, so the script stays in place.
@MainActor
final class ExtensionTabsBridge {
    static let windowID = 1

    private weak var host: ExtensionTabsHost?
    private var helper: ChromiumPage?
    private var helperReady = false
    /// Worker session ids by DevTools target id.
    private var sessions: [String: String] = [:]
    private var nextMessageID = 1
    private var replies: [Int: ([String: Any]?, String?) -> Void] = [:]
    /// Chromium's tab id for each page's DevTools target, and each page's target.
    private var tabIDs: [String: Int] = [:]
    private var targetIDs: [ObjectIdentifier: String] = [:]
    private var lookingUpTargets: Set<ObjectIdentifier> = []
    private var lastState: String?
    private var updateScheduled = false
    private var observers: [NSObjectProtocol] = []
    private var healthCheck: Timer?

    init(host: ExtensionTabsHost) {
        self.host = host
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didMoveNotification,
                     NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setNeedsUpdate() }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func start(engine: WebEngine) {
        guard helper == nil,
              let url = URL(string: "chrome-extension://\(KiteHelperExtension.id)/\(KiteHelperExtension.pagePath)"),
              let page = engine.makePage(url: url, restoring: nil) as? ChromiumPage else { return }
        helper = page
        if let content = NSApp.mainWindow?.contentView ?? NSApp.windows.first?.contentView {
            page.view.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            page.view.isHidden = true
            content.addSubview(page.view, positioned: .below, relativeTo: nil)
        }
        page.browser.devToolsEventHandler = { [weak self] method, params in self?.handleEvent(method, params) }
        page.browser.sessionMessageHandler = { [weak self] message in self?.handleSessionMessage(message) }
        page.onEvent = { [weak self] event in
            guard let self, case let .navigationState(isLoading, _, _) = event, !isLoading, !self.helperReady else { return }
            self.helperReady = true
            page.browser.callDevToolsMethod("Target.setDiscoverTargets", params: ["discover": true]) { _, error in
                if let error { NSLog("Kite: extensions can't see Kite's tabs: %@", error) }
            }
            self.setNeedsUpdate()
        }
        // Also checks every worker still has the script.
        healthCheck = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushState(force: true) }
        }
    }

    /// Tabs, selection or the window changed: tell the workers (once per run loop turn).
    func setNeedsUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            self.pushState(force: false)
        }
    }

    // MARK: Workers

    private func handleEvent(_ method: String, _ params: [AnyHashable: Any]) {
        guard let info = params["targetInfo"] as? [String: Any], let targetID = info["targetId"] as? String else {
            if method == "Target.detachedFromTarget", let session = params["sessionId"] as? String {
                sessions = sessions.filter { $0.value != session }
            }
            return
        }
        switch method {
        case "Target.targetCreated", "Target.targetInfoChanged":
            guard Self.isExtensionWorker(info), sessions[targetID] == nil else { return }
            sessions[targetID] = ""
            helper?.browser.callDevToolsMethod("Target.attachToTarget", params: ["targetId": targetID, "flatten": true]) { [weak self] _, error in
                if error != nil { self?.sessions[targetID] = nil }
            }
        case "Target.attachedToTarget":
            guard Self.isExtensionWorker(info), let session = params["sessionId"] as? String else { return }
            sessions[targetID] = session
            prepare(session)
        case "Target.targetDestroyed":
            sessions[targetID] = nil
        default:
            break
        }
    }

    private static func isExtensionWorker(_ info: [String: Any]) -> Bool {
        guard info["type"] as? String == "service_worker", let url = info["url"] as? String,
              let host = URL(string: url)?.host, url.hasPrefix("chrome-extension://") else { return false }
        return host != KiteHelperExtension.id
    }

    /// The binding first, so the script finds it; Runtime events tell Kite when the
    /// worker restarted and needs the script again.
    private func prepare(_ session: String) {
        send(session, "Runtime.addBinding", ["name": ExtensionTabsScript.bindingName])
        send(session, "Runtime.enable")
        inject(session)
    }

    private func inject(_ session: String) {
        send(session, "Runtime.evaluate", ["expression": ExtensionTabsScript.source + ";" + updateCall(lastState ?? currentState())]) { _, error in
            if let error { NSLog("Kite: couldn't give an extension Kite's tabs: %@", error) }
        }
    }

    private func send(_ session: String, _ method: String, _ params: [String: Any] = [:], reply: (([String: Any]?, String?) -> Void)? = nil) {
        let id = nextMessageID
        nextMessageID += 1
        if let reply { replies[id] = reply }
        helper?.browser.sendDevToolsMessage(["id": id, "sessionId": session, "method": method, "params": params])
    }

    private func handleSessionMessage(_ message: [AnyHashable: Any]) {
        guard let session = message["sessionId"] as? String else { return }
        if let id = message["id"] as? Int {
            let reply = replies.removeValue(forKey: id)
            let error = (message["error"] as? [String: Any])?["message"] as? String
                ?? (((message["result"] as? [String: Any])?["exceptionDetails"] as? [String: Any]).map { _ in "exception" })
            reply?(message["result"] as? [String: Any], error)
            return
        }
        let params = message["params"] as? [String: Any] ?? [:]
        switch message["method"] as? String {
        case "Runtime.executionContextCreated":
            // The worker started again with a fresh global scope.
            inject(session)
        case "Runtime.bindingCalled" where params["name"] as? String == ExtensionTabsScript.bindingName:
            guard let payload = (params["payload"] as? String)?.data(using: .utf8),
                  let call = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let id = call["id"] as? Int, let op = call["op"] as? String else { return }
            perform(op, call["args"] as? [String: Any] ?? [:]) { [weak self] value, error in
                self?.resolve(session, id, value, error)
            }
        default:
            break
        }
    }

    private func resolve(_ session: String, _ id: Int, _ value: Any?, _ error: String?) {
        let arguments = [id, value ?? NSNull(), error ?? NSNull()]
        guard let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return }
        send(session, "Runtime.evaluate", ["expression": "globalThis.__kite?.resolve(...\(json))"])
    }

    // MARK: Requests from extensions

    private func perform(_ op: String, _ args: [String: Any], completion: @escaping (Any?, String?) -> Void) {
        guard let host else { return completion(nil, "No current window") }
        switch op {
        case "create":
            let url = (args["url"] as? String).flatMap { URL(string: $0) }
            guard let page = host.openTabForExtension(url: url, active: args["active"] as? Bool ?? true) else {
                return completion(nil, "Kite couldn't open a tab")
            }
            tabID(for: page, attempts: 20) { [weak self] tabID in
                guard let tabID else { return completion(nil, "Kite couldn't open a tab") }
                self?.pushState(force: false)
                completion(["id": tabID], nil)
            }
        case "activate":
            guard let tabID = args["id"] as? Int,
                  let tab = host.extensionTabs.first(where: { targetIDs[ObjectIdentifier($0.page)].flatMap { tabIDs[$0] } == tabID }) else {
                return completion(nil, "No tab with id: \(args["id"] ?? "")")
            }
            host.activateTabForExtension(tab.id)
            completion(true, nil)
        case "capture":
            guard let page = host.extensionTabs.first(where: \.active)?.page else { return completion(nil, "No current window") }
            let format = args["format"] as? String == "png" ? "png" : "jpeg"
            var params: [String: Any] = ["format": format]
            if format == "jpeg" { params["quality"] = args["quality"] as? Int ?? 92 }
            page.browser.callDevToolsMethod("Page.captureScreenshot", params: params) { result, error in
                guard let data = result?["data"] as? String else { return completion(nil, error ?? "Couldn't capture the tab") }
                completion("data:image/\(format);base64,\(data)", nil)
            }
        default:
            completion(nil, "Kite doesn't support \(op)")
        }
    }

    // MARK: Kite's tabs

    private func pushState(force: Bool) {
        guard helperReady else { return }
        let state = currentState()
        guard force || state != lastState else { return }
        lastState = state
        for session in sessions.values where !session.isEmpty {
            // A worker whose script went missing (it restarted unseen) gets it again.
            send(session, "Runtime.evaluate", ["expression": updateCall(state), "returnByValue": true]) { [weak self] result, _ in
                if (result?["result"] as? [String: Any])?["value"] as? Bool == false { self?.inject(session) }
            }
        }
    }

    private func updateCall(_ state: String) -> String {
        "globalThis.__kite ? (globalThis.__kite.update(\(state)), true) : false"
    }

    /// Kite's tabs as JSON for ExtensionTabsScript. Tabs whose Chromium id isn't known
    /// yet are looked up, and the state is sent again once they are.
    private func currentState() -> String {
        guard let host else { return #"{"windows":[],"tabs":[]}"# }
        var tabs: [[String: Any]] = []
        let live = host.extensionTabs
        let liveKeys = Set(live.map { ObjectIdentifier($0.page) })
        targetIDs = targetIDs.filter { liveKeys.contains($0.key) }
        for tab in live {
            guard let target = targetIDs[ObjectIdentifier(tab.page)], let tabID = tabIDs[target] else {
                tabID(for: tab.page, attempts: 3) { [weak self] id in if id != nil { self?.setNeedsUpdate() } }
                continue
            }
            tabs.append(["id": tabID, "windowId": Self.windowID, "index": tabs.count, "active": tab.active, "pinned": tab.pinned])
        }
        let bounds = host.extensionWindowBounds
        let window: [String: Any] = [
            "id": Self.windowID,
            "focused": host.extensionWindowIsFocused,
            "top": Int(bounds.minY), "left": Int(bounds.minX), "width": Int(bounds.width), "height": Int(bounds.height),
            "state": host.extensionWindowIsFullScreen ? "fullscreen" : "normal",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: ["windows": [window], "tabs": tabs], options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? #"{"windows":[],"tabs":[]}"#
    }

    /// Chromium's tab id for a page: its DevTools target id, then the helper's
    /// chrome.debugger.getTargets() for the tab id behind that target.
    private func tabID(for page: ChromiumPage, attempts: Int, completion: @escaping (Int?) -> Void) {
        let key = ObjectIdentifier(page)
        if let target = targetIDs[key] {
            if let id = tabIDs[target] { return completion(id) }
            return refreshTabIDs { [weak self, weak page] in
                guard let self, let page else { return completion(nil) }
                if let id = self.tabIDs[target] { return completion(id) }
                // chrome.debugger doesn't list other extensions' pages, but an extension
                // page knows its own tab.
                page.evaluate(Self.ownTabIDScript, userGesture: false) { [weak self, weak page] value, _ in
                    guard let self, let page else { return completion(nil) }
                    if let id = value as? Int {
                        self.tabIDs[target] = id
                        return completion(id)
                    }
                    guard attempts > 1 else { return completion(nil) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.tabID(for: page, attempts: attempts - 1, completion: completion)
                    }
                }
            }
        }
        guard !lookingUpTargets.contains(key) else { return completion(nil) }
        lookingUpTargets.insert(key)
        page.browser.callDevToolsMethod("Target.getTargetInfo", params: nil) { [weak self, weak page] result, _ in
            guard let self else { return }
            self.lookingUpTargets.remove(key)
            guard let page, let target = (result?["targetInfo"] as? [String: Any])?["targetId"] as? String else {
                guard attempts > 1, let page else { return completion(nil) }
                return DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.tabID(for: page, attempts: attempts - 1, completion: completion)
                }
            }
            self.targetIDs[key] = target
            self.tabID(for: page, attempts: attempts, completion: completion)
        }
    }

    private static let ownTabIDScript =
        "globalThis.chrome?.tabs?.getCurrent ? chrome.tabs.getCurrent().then((t) => (t ? t.id : null), () => null) : null"

    private var refreshing: [() -> Void]?

    private func refreshTabIDs(_ completion: @escaping () -> Void) {
        if refreshing != nil { refreshing?.append(completion); return }
        refreshing = [completion]
        helper?.evaluate("kiteHelper.tabTargets()", userGesture: false) { [weak self] value, _ in
            guard let self else { return }
            if let json = (value as? String)?.data(using: .utf8),
               let targets = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] {
                var ids: [String: Int] = [:]
                for target in targets {
                    if let targetID = target["targetId"] as? String, let tab = target["tabId"] as? Int { ids[targetID] = tab }
                }
                self.tabIDs.merge(ids) { $1 }
            }
            let waiting = self.refreshing ?? []
            self.refreshing = nil
            waiting.forEach { $0() }
        }
    }
}
#endif
