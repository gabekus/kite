#if canImport(CEFBridge)
import AppKit
import CEFBridge
import KiteCore

/// Drives a Chromium tab through the DevTools protocol (`ExecuteDevToolsMethod`,
/// which works without DevTools open). Input goes in as real mouse and key
/// events, so pages see the same thing as a person clicking.
@MainActor
struct ChromiumAutomation: PageAutomation {
    let browser: KCBrowser

    /// Calls a DevTools method. A tab that was just created has no browser for a
    /// moment, so "not-ready" is retried for a few seconds.
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

    // MARK: PageAutomation

    func read() async throws -> (outline: String?, text: String) {
        let tree = try await call("Accessibility.getFullAXTree")
        let nodesJSON = try JSONSerialization.data(withJSONObject: tree["nodes"] ?? [])
        let nodes = try JSONDecoder().decode([AXNode].self, from: nodesJSON)
        let text = try await evaluate(PageScripts.pageText) as? String ?? ""
        return (AccessibilityOutline.render(nodes).text, text)
    }

    func locate(_ target: AutomationTarget) async throws -> LocatedElement {
        let objectID: String
        switch target {
        case .ref(let ref):
            guard let backendID = AccessibilityOutline.backendNodeID(fromRef: ref) else {
                throw AutomationError(.invalidArguments, "\"\(ref)\" isn't a ref. Refs look like e42 and come from read_page.")
            }
            do {
                let resolved = try await call("DOM.resolveNode", ["backendNodeId": backendID])
                guard let id = (resolved["object"] as? [String: Any])?["objectId"] as? String else { throw staleRef(ref) }
                objectID = id
            } catch let error as AutomationError where error.code == .failed {
                throw staleRef(ref)
            }
        case .selector(let selector):
            let result = try await call("Runtime.evaluate", [
                "expression": "document.querySelector(\(Self.jsString(selector)))",
            ])
            if let exception = result["exceptionDetails"] as? [String: Any] {
                throw AutomationError(.invalidArguments, "Bad selector: \(Self.exceptionText(exception))")
            }
            guard let id = (result["result"] as? [String: Any])?["objectId"] as? String else {
                throw AutomationError(.notFound, "Nothing on the page matches \(selector). Call read_page to see what's there.")
            }
            objectID = id
        }
        return try await describe(objectID)
    }

    func focusedElement() async throws -> LocatedElement? {
        let result = try await call("Runtime.evaluate", [
            "expression": "document.activeElement && document.activeElement !== document.body ? document.activeElement : null",
        ])
        guard let id = (result["result"] as? [String: Any])?["objectId"] as? String else { return nil }
        return try await describe(id)
    }

    func click(_ element: LocatedElement) async throws {
        guard element.isHittable else {
            // Covered or zero-sized: fall back to a DOM click so the action still happens.
            _ = try await callFunction(element.handle, "function () { this.click(); return true; }")
            return
        }
        let x = Double(element.point.x), y = Double(element.point.y)
        _ = try await call("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": x, "y": y])
        _ = try await call("Input.dispatchMouseEvent", ["type": "mousePressed", "x": x, "y": y, "button": "left", "clickCount": 1])
        _ = try await call("Input.dispatchMouseEvent", ["type": "mouseReleased", "x": x, "y": y, "button": "left", "clickCount": 1])
    }

    func type(_ text: String, into element: LocatedElement?, submit: Bool) async throws {
        if let element {
            _ = try await callFunction(element.handle, PageScripts.focusAndSelect)
        }
        _ = try await call("Input.insertText", ["text": text])
        // A background tab may not take key input; make sure the text actually landed.
        if let element, !text.isEmpty,
           let value = try await callFunction(element.handle, PageScripts.currentValue) as? String, !value.contains(text) {
            _ = try await callFunction(element.handle, PageScripts.setValue, arguments: [text])
        }
        if submit {
            let enter: [String: Any] = ["key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13, "nativeVirtualKeyCode": 36]
            _ = try await call("Input.dispatchKeyEvent", enter.merging(["type": "keyDown", "text": "\r", "unmodifiedText": "\r"]) { a, _ in a })
            _ = try await call("Input.dispatchKeyEvent", enter.merging(["type": "keyUp"]) { a, _ in a })
        }
    }

    func screenshot() async throws -> Data {
        let result = try await call("Page.captureScreenshot", ["format": "png"], timeout: 10)
        guard let base64 = result["data"] as? String, let data = Data(base64Encoded: base64) else {
            throw AutomationError(.failed, "Chromium returned no image.")
        }
        return data
    }

    // MARK: Helpers

    private func describe(_ objectID: String) async throws -> LocatedElement {
        let value = try await callFunction(objectID, PageScripts.describe)
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

    private func staleRef(_ ref: String) -> AutomationError {
        AutomationError(.notFound, "\(ref) is no longer on the page. Call read_page again for fresh refs.")
    }

    static func jsString(_ string: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [string])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    static func exceptionText(_ exception: [String: Any]) -> String {
        ((exception["exception"] as? [String: Any])?["description"] as? String)
            ?? exception["text"] as? String ?? "unknown error"
    }
}
#endif
