#if canImport(CEFBridge)
import AppKit
import CEFBridge
import KiteCore

/// Drives a Chromium tab through the DevTools protocol (`ExecuteDevToolsMethod`,
/// which works without DevTools open and without any debugging port). Input
/// goes in as real mouse and key events, so pages see what a person would do.
@MainActor
struct ChromiumAutomation: PageActions {
    let browser: KCBrowser

    /// Calls a DevTools method. A tab that was just created has no browser for a
    /// moment, so "not-ready" is retried for a few seconds.
    @discardableResult
    func call(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 15) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            do {
                return try await withTimeout(max(1, deadline.timeIntervalSinceNow), method) { done in
                    browser.callDevToolsMethod(method, params: params.isEmpty ? nil : params) { result, error in
                        switch error {
                        case nil: done(.success((result as? [String: Any]) ?? [:]))
                        case "not-ready": done(.failure(NotReady()))
                        case let error?: done(.failure(AutomationError(.failed, "\(method): \(error)")))
                        }
                    }
                }
            } catch is NotReady {
                guard Date() < deadline else { throw AutomationError(.timeout, "The tab's page didn't start in time.") }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private struct NotReady: Error {}

    // MARK: Events

    /// Starts the domains whose events feed `TabActivity` (console, network, dialogs, loads).
    func startEvents(_ handler: @escaping (String, JSONValue) -> Void) async throws {
        browser.devToolsEventHandler = { method, params in
            let json = (try? JSONSerialization.data(withJSONObject: params)).flatMap { try? JSONValue.decode($0) } ?? .object([:])
            handler(method, json)
        }
        for domain in ["Page", "Runtime", "Log", "Network"] { try await call("\(domain).enable") }
    }

    func stopEvents() async {
        browser.devToolsEventHandler = nil
        for domain in ["Network", "Log", "Runtime"] { _ = try? await call("\(domain).disable", timeout: 3) }
    }

    // MARK: Reading

    func read(interactiveOnly: Bool) async throws -> (outline: String?, text: String) {
        var sections: [String] = []
        for frame in try await frames() {
            do {
                let nodes = try await axNodes(frameID: frame.isMain ? nil : frame.id)
                let outline = AccessibilityOutline.render(nodes, interactiveOnly: interactiveOnly).text
                sections.append(frame.isMain ? outline : "Frame \(frame.url):\n" + (outline.isEmpty ? "(empty)" : outline))
            } catch where !frame.isMain {
                // Cross-site frames run in another process that this connection can't read.
                sections.append("Frame \(frame.url): (another site's frame; Kite can't read inside it)")
            }
        }
        let text = try await evaluate(PageScripts.pageText) as? String ?? ""
        return (sections.joined(separator: "\n\n"), text)
    }

    /// Every readable frame's accessibility nodes, for `find`.
    func allNodes() async throws -> [AXNode] {
        var nodes: [AXNode] = []
        for frame in try await frames() {
            if let frameNodes = try? await axNodes(frameID: frame.isMain ? nil : frame.id) { nodes += frameNodes }
        }
        return nodes
    }

    func mainText() async throws -> (source: String, text: String) {
        let value = try await evaluate(PageScripts.mainText) as? [String: Any]
        return (value?["source"] as? String ?? "body", value?["text"] as? String ?? "")
    }

    private struct Frame {
        var id: String
        var url: String
        var isMain: Bool
    }

    private func frames() async throws -> [Frame] {
        let tree = try await call("Page.getFrameTree")
        var frames: [Frame] = []
        func walk(_ node: [String: Any], main: Bool) {
            if let frame = node["frame"] as? [String: Any], let id = frame["id"] as? String {
                frames.append(Frame(id: id, url: frame["url"] as? String ?? "", isMain: main))
            }
            for child in node["childFrames"] as? [[String: Any]] ?? [] { walk(child, main: false) }
        }
        walk(tree["frameTree"] as? [String: Any] ?? [:], main: true)
        return frames.isEmpty ? [Frame(id: "", url: "", isMain: true)] : frames
    }

    private func axNodes(frameID: String?) async throws -> [AXNode] {
        let tree = try await call("Accessibility.getFullAXTree", frameID.map { ["frameId": $0] } ?? [:])
        let json = try JSONSerialization.data(withJSONObject: tree["nodes"] ?? [])
        return try JSONDecoder().decode([AXNode].self, from: json)
    }

    // MARK: Elements

    func locate(_ target: AutomationTarget) async throws -> LocatedElement {
        let objectID: String
        switch target {
        case .ref(let ref):
            guard let backendID = AccessibilityOutline.backendNodeID(fromRef: ref) else {
                throw AutomationError(.invalidArguments, "\"\(ref)\" isn't a ref. Refs look like e42 and come from read_page or find.")
            }
            objectID = try await resolve(backendID: backendID, ref: ref)
        case .selector(let selector):
            let result = try await call("Runtime.evaluate", ["expression": "document.querySelector(\(PageScripts.jsString(selector)))"])
            if let exception = result["exceptionDetails"] as? [String: Any] {
                throw AutomationError(.invalidArguments, "Bad selector: \(Self.exceptionText(exception))")
            }
            guard let id = (result["result"] as? [String: Any])?["objectId"] as? String else {
                throw AutomationError(.notFound, "Nothing on the page matches \(selector). Call read_page or find to see what's there.")
            }
            objectID = id
        }
        return try await describe(objectID, scroll: true, climb: false)
    }

    /// The control under a viewport point, for the policy and for clicks by coordinate.
    func element(at point: ViewportPoint) async throws -> LocatedElement? {
        try await call("DOM.getDocument", ["depth": 0])
        guard let node = try? await call("DOM.getNodeForLocation", [
            "x": Int(point.x.rounded()), "y": Int(point.y.rounded()), "ignorePointerEventsNone": true,
        ]), let backendID = node["backendNodeId"] as? Int else { return nil }
        let objectID = try await resolve(backendID: backendID, ref: nil)
        var element = try await describe(objectID, scroll: false, climb: true)
        element.point = CGPoint(x: point.x, y: point.y)
        return element
    }

    func focusedElement() async throws -> LocatedElement? {
        let result = try await call("Runtime.evaluate", [
            "expression": "document.activeElement && document.activeElement !== document.body ? document.activeElement : null",
        ])
        guard let id = (result["result"] as? [String: Any])?["objectId"] as? String else { return nil }
        return try await describe(id, scroll: false, climb: false)
    }

    // MARK: Mouse

    func click(_ element: LocatedElement) async throws {
        guard element.isHittable else {
            // Covered or zero-sized: fall back to a DOM click so the action still happens.
            try await callFunction(element.handle, "function () { this.click(); return true; }")
            return
        }
        try await click(at: ViewportPoint(x: element.point.x, y: element.point.y), button: .left, count: 1, modifiers: [])
    }

    func click(at point: ViewportPoint, button: ComputerAction.Button, count: Int, modifiers: KeyChord.Modifiers) async throws {
        let base: [String: Any] = ["x": point.x, "y": point.y, "modifiers": modifiers.rawValue]
        try await call("Input.dispatchMouseEvent", base.merging(["type": "mouseMoved"]) { a, _ in a })
        for n in 1...max(1, count) {
            let press = base.merging(["button": button.rawValue, "clickCount": n]) { a, _ in a }
            try await call("Input.dispatchMouseEvent", press.merging(["type": "mousePressed"]) { a, _ in a })
            try await call("Input.dispatchMouseEvent", press.merging(["type": "mouseReleased"]) { a, _ in a })
        }
    }

    func hover(_ point: ViewportPoint) async throws {
        try await call("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": point.x, "y": point.y])
    }

    /// Scrolls whatever scrolls under the point (or the page). Done in the page rather than with
    /// wheel events, which a background tab never acknowledges.
    func scroll(at point: ViewportPoint?, direction: ComputerAction.Direction, amount: Int) async throws {
        let delta = Double(amount) * 100
        let (dx, dy): (Double, Double) = switch direction {
        case .up: (0, -delta)
        case .down: (0, delta)
        case .left: (-delta, 0)
        case .right: (delta, 0)
        }
        let x = point.map { String($0.x) } ?? "innerWidth / 2", y = point.map { String($0.y) } ?? "innerHeight / 2"
        _ = try await evaluate("""
            (() => {
              const dx = \(dx), dy = \(dy);
              const scrolls = (el) => {
                const style = getComputedStyle(el);
                return (dy && /(auto|scroll)/.test(style.overflowY) && el.scrollHeight > el.clientHeight)
                  || (dx && /(auto|scroll)/.test(style.overflowX) && el.scrollWidth > el.clientWidth);
              };
              let el = document.elementFromPoint(\(x), \(y));
              while (el && el !== document.body && el !== document.documentElement && !scrolls(el)) el = el.parentElement;
              const target = el && el !== document.body && el !== document.documentElement ? el : (document.scrollingElement || document.documentElement);
              target.scrollBy({ left: dx, top: dy, behavior: 'instant' });
              return true;
            })()
            """)
    }

    func drag(from: ViewportPoint, to: ViewportPoint) async throws {
        try await call("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": from.x, "y": from.y])
        try await call("Input.dispatchMouseEvent", ["type": "mousePressed", "x": from.x, "y": from.y, "button": "left", "clickCount": 1])
        let steps = 12
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            try await call("Input.dispatchMouseEvent", [
                "type": "mouseMoved", "x": from.x + (to.x - from.x) * t, "y": from.y + (to.y - from.y) * t, "button": "left", "buttons": 1,
            ])
        }
        try await call("Input.dispatchMouseEvent", ["type": "mouseReleased", "x": to.x, "y": to.y, "button": "left", "clickCount": 1])
    }

    // MARK: Keyboard

    func press(_ chords: [KeyChord]) async throws {
        for chord in chords {
            var event: [String: Any] = [
                "key": chord.key, "code": chord.code, "windowsVirtualKeyCode": chord.keyCode, "modifiers": chord.modifiers.rawValue,
            ]
            if !chord.commands.isEmpty { event["commands"] = chord.commands }
            var down = event
            if let text = chord.text {
                down["type"] = "keyDown"
                down["text"] = text
                down["unmodifiedText"] = text
            } else {
                down["type"] = "rawKeyDown"
            }
            try await call("Input.dispatchKeyEvent", down)
            try await call("Input.dispatchKeyEvent", event.merging(["type": "keyUp"]) { a, _ in a })
        }
    }

    func insertText(_ text: String) async throws {
        try await call("Input.insertText", ["text": text])
    }

    func type(_ text: String, into element: LocatedElement?, submit: Bool) async throws {
        if let element { try await callFunction(element.handle, PageScripts.focusAndSelect) }
        try await insertText(text)
        // A background tab may not take key input; make sure the text actually landed.
        if let element, !text.isEmpty,
           let value = try await callFunction(element.handle, PageScripts.currentValue) as? String, !value.contains(text) {
            try await callFunction(element.handle, PageScripts.setValue, arguments: [text])
        }
        if submit { try await press([try KeyChord.parse("Enter")]) }
    }

    // MARK: Values, files, scripts, dialogs

    /// Returns the value the control ended up with.
    func setValue(_ value: JSONValue, on element: LocatedElement) async throws -> String {
        let argument: Any = value.boolValue.map { $0 as Any } ?? value.doubleValue.map { $0 as Any } ?? (value.stringValue ?? "")
        let result = try await callFunction(element.handle, PageScripts.formValue, arguments: [argument]) as? [String: Any]
        guard result?["ok"] as? Bool == true else {
            throw AutomationError(.failed, UntrustedContent.wrap(result?["error"] as? String ?? "The value didn't take.", source: "page"))
        }
        return result?["value"] as? String ?? ""
    }

    func setFiles(_ paths: [String], on element: LocatedElement) async throws {
        try await call("DOM.setFileInputFiles", ["files": paths, "objectId": element.handle])
    }

    /// Runs code in the page; returns the result as JSON text (or a description for things that aren't JSON).
    func run(_ code: String) async throws -> String {
        let result = try await call("Runtime.evaluate", [
            "expression": code, "awaitPromise": true, "returnByValue": true, "userGesture": true, "replMode": true,
        ], timeout: 30)
        if let exception = result["exceptionDetails"] as? [String: Any] {
            throw AutomationError(.failed, "The script threw: " + UntrustedContent.wrap(Self.exceptionText(exception), source: "page"))
        }
        let remote = result["result"] as? [String: Any] ?? [:]
        if remote["type"] as? String == "undefined" { return "undefined" }
        if let value = remote["value"] {
            if let string = value as? String { return string }
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) {
                return String(decoding: data, as: UTF8.self)
            }
        }
        return remote["description"] as? String ?? remote["unserializableValue"] as? String ?? "(no value)"
    }

    func answerDialog(accept: Bool, promptText: String?) async throws {
        var params: [String: Any] = ["accept": accept]
        if let promptText { params["promptText"] = promptText }
        try await call("Page.handleJavaScriptDialog", params, timeout: 5)
    }

    /// Waits inside the page for a selector or text (a MutationObserver, not polling).
    func waitFor(selector: String?, text: String?, timeout: TimeInterval) async throws -> Bool {
        let script = PageScripts.waitFor(selector: selector, text: text, timeoutMs: Int(timeout * 1000))
        let result = try await call("Runtime.evaluate", ["expression": script, "awaitPromise": true, "returnByValue": true],
                                    timeout: timeout + 5)
        if let exception = result["exceptionDetails"] as? [String: Any] {
            throw AutomationError(.invalidArguments, "The wait failed: \(Self.exceptionText(exception))")
        }
        return (result["result"] as? [String: Any])?["value"] as? Bool ?? false
    }

    func readyStateIsComplete() async throws -> Bool {
        try await evaluate("document.readyState") as? String == "complete"
    }

    // MARK: Screenshots

    /// The visible viewport at one image pixel per CSS pixel, so screenshot pixels are click coordinates.
    func screenshot(format: ImageFormat) async throws -> Screenshot {
        let viewport = try await self.viewport()
        let scale = ScreenshotScale(viewportWidth: viewport.width).factor
        let data = try await capture(x: 0, y: 0, width: viewport.width, height: viewport.height, scale: scale / viewport.scale, format: format)
        return Screenshot(data: data, format: format, width: Int((viewport.width * scale).rounded()),
                          height: Int((viewport.height * scale).rounded()), scale: scale)
    }

    func screenshotScale() async throws -> ScreenshotScale {
        ScreenshotScale(viewportWidth: try await viewport().width)
    }

    /// A region at full device resolution.
    func zoom(x0: Double, y0: Double, x1: Double, y1: Double) async throws -> Screenshot {
        let viewport = try await self.viewport()
        let width = min(x1, viewport.width) - x0, height = min(y1, viewport.height) - y0
        guard width > 0, height > 0 else { throw AutomationError(.invalidArguments, "That region is outside the viewport.") }
        let png = try await capture(x: x0, y: y0, width: width, height: height, scale: 1, format: .png)
        return Screenshot(data: png, format: .png, width: Int((width * viewport.scale).rounded()), height: Int((height * viewport.scale).rounded()))
    }

    private func capture(x: Double, y: Double, width: Double, height: Double, scale: Double, format: ImageFormat) async throws -> Data {
        let metrics = try await call("Page.getLayoutMetrics")
        let visual = metrics["cssVisualViewport"] as? [String: Any] ?? [:]
        let pageX = visual["pageX"] as? Double ?? 0, pageY = visual["pageY"] as? Double ?? 0
        var params: [String: Any] = [
            "format": format.rawValue,
            "clip": ["x": pageX + x, "y": pageY + y, "width": width, "height": height, "scale": scale],
        ]
        // Quality 70 keeps text readable at a fraction of PNG's size.
        if format == .jpeg { params["quality"] = 70 }
        let result = try await call("Page.captureScreenshot", params, timeout: 10)
        guard let base64 = result["data"] as? String, let data = Data(base64Encoded: base64) else {
            throw AutomationError(.failed, "Chromium returned no image.")
        }
        return data
    }

    /// CSS size of the visible viewport and device pixels per CSS pixel.
    private func viewport() async throws -> (width: Double, height: Double, scale: Double) {
        let value = try await evaluate("({ w: innerWidth, h: innerHeight, s: devicePixelRatio })") as? [String: Any]
        let width = value?["w"] as? Double ?? 800, height = value?["h"] as? Double ?? 600
        return (width, height, max(0.25, value?["s"] as? Double ?? 1))
    }

    private func viewportCenter() async throws -> ViewportPoint {
        let viewport = try await self.viewport()
        return ViewportPoint(x: viewport.width / 2, y: viewport.height / 2)
    }

    // MARK: Helpers

    private func resolve(backendID: Int, ref: String?) async throws -> String {
        let stale = AutomationError(.notFound, "\(ref ?? "That element") is no longer on the page. Call read_page or find again for fresh refs.")
        do {
            let resolved = try await call("DOM.resolveNode", ["backendNodeId": backendID])
            guard let id = (resolved["object"] as? [String: Any])?["objectId"] as? String else { throw stale }
            return id
        } catch let error as AutomationError where error.code == .failed {
            throw stale
        }
    }

    private func describe(_ objectID: String, scroll: Bool, climb: Bool) async throws -> LocatedElement {
        let value = try await callFunction(objectID, PageScripts.describe, arguments: [scroll, climb])
        let (description, point, hittable) = try PageScripts.decodeDescription(value)
        return LocatedElement(description: description, point: point, isHittable: hittable, handle: objectID)
    }

    private func evaluate(_ expression: String) async throws -> Any? {
        let result = try await call("Runtime.evaluate", ["expression": expression, "returnByValue": true])
        if let exception = result["exceptionDetails"] as? [String: Any] {
            throw AutomationError(.failed, "The page threw: \(Self.exceptionText(exception))")
        }
        return (result["result"] as? [String: Any])?["value"]
    }

    @discardableResult
    private func callFunction(_ objectID: String, _ function: String, arguments: [Any] = []) async throws -> Any? {
        let result = try await call("Runtime.callFunctionOn", [
            "objectId": objectID,
            "functionDeclaration": function,
            "arguments": arguments.map { ["value": $0] },
            "returnByValue": true,
        ])
        if let exception = result["exceptionDetails"] as? [String: Any] {
            throw AutomationError(.failed, "The page threw: \(Self.exceptionText(exception))")
        }
        return (result["result"] as? [String: Any])?["value"]
    }

    static func exceptionText(_ exception: [String: Any]) -> String {
        ((exception["exception"] as? [String: Any])?["description"] as? String)
            ?? exception["text"] as? String ?? "unknown error"
    }
}
#endif
