import AppKit
import KiteCore
import WebKit

/// WebKit has no DevTools protocol to drive, so Claude gets read-only access:
/// the page's text and screenshots. Everything else needs the Chromium engine.
@MainActor
struct WebKitAutomation: PageAutomation {
    let webView: WKWebView

    static let unsupported = AutomationError(.unsupported,
        "This Kite is running the WebKit engine, which lets Claude read pages and take screenshots but not act on them. Run Kite.app with Chromium for that.")

    func read(interactiveOnly: Bool) async throws -> (outline: String?, text: String) {
        (nil, try await evaluate(PageScripts.pageText) as? String ?? "")
    }

    func mainText() async throws -> (source: String, text: String) {
        let value = try await evaluate(PageScripts.mainText) as? [String: Any]
        return (value?["source"] as? String ?? "body", value?["text"] as? String ?? "")
    }

    func screenshot(format: ImageFormat) async throws -> Screenshot {
        let image: NSImage = try await withTimeout(10, "WebKit") { done in
            let configuration = WKSnapshotConfiguration()
            // One image pixel per CSS pixel, matching Chromium.
            configuration.snapshotWidth = NSNumber(value: Double(webView.bounds.width))
            webView.takeSnapshot(with: configuration) { image, error in
                if let image { done(.success(image)) }
                else { done(.failure(AutomationError(.failed, "WebKit couldn't capture the page: \(error?.localizedDescription ?? "no image")."))) }
            }
        }
        let encoded: Data?
        let bitmap = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
        switch format {
        case .png: encoded = bitmap?.representation(using: .png, properties: [:])
        case .jpeg: encoded = bitmap?.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        }
        guard let bitmap, let encoded else { throw AutomationError(.failed, "Couldn't encode the screenshot.") }
        return Screenshot(data: encoded, format: format, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
    }

    private func evaluate(_ script: String) async throws -> Any? {
        try await withTimeout(10, "The page") { done in
            webView.evaluateJavaScript(script) { result, error in
                if let error { done(.failure(AutomationError(.failed, "The page threw: \(error.localizedDescription)"))) }
                else { done(.success(result)) }
            }
        }
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
