import AppKit
import KiteCore
import WebKit

/// WebKit has no DevTools protocol to drive, so Claude gets read-only access:
/// the page's text and screenshots. Clicking and typing need the Chromium engine.
@MainActor
struct WebKitAutomation: PageAutomation {
    let webView: WKWebView

    private static let unsupported = AutomationError(.unsupported,
        "This Kite is running the WebKit engine, which lets Claude read pages and take screenshots but not click or type. Run Kite.app with Chromium for that.")

    func read() async throws -> (outline: String?, text: String) {
        let text: String = try await withTimeout(10, "The page") { done in
            webView.evaluateJavaScript(PageScripts.pageText) { result, error in
                if let error { done(.failure(AutomationError(.failed, "The page threw: \(error.localizedDescription)"))) }
                else { done(.success(result as? String ?? "")) }
            }
        }
        return (nil, text)
    }

    func locate(_ target: AutomationTarget) async throws -> LocatedElement { throw Self.unsupported }
    func focusedElement() async throws -> LocatedElement? { throw Self.unsupported }
    func click(_ element: LocatedElement) async throws { throw Self.unsupported }
    func type(_ text: String, into element: LocatedElement?, submit: Bool) async throws { throw Self.unsupported }

    func screenshot() async throws -> Data {
        let image: NSImage = try await withTimeout(10, "WebKit") { done in
            webView.takeSnapshot(with: nil) { image, error in
                if let image { done(.success(image)) }
                else { done(.failure(AutomationError(.failed, "WebKit couldn't capture the page: \(error?.localizedDescription ?? "no image")."))) }
            }
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw AutomationError(.failed, "Couldn't encode the screenshot.")
        }
        return png
    }
}

extension WebPage {
    /// The engine's automation driver.
    var automation: PageAutomation? {
        #if canImport(CEFBridge)
        if let page = self as? ChromiumPage { return ChromiumAutomation(browser: page.browser) }
        #endif
        if let page = self as? WebKitPage { return WebKitAutomation(webView: page.webView) }
        return nil
    }
}
