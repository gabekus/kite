import AppKit
import ObjectiveC
import WebKit
import KiteCore
#if canImport(CEFBridge)
import CEFBridge
#endif

/// Keeps one page's zaps applied: a document-start script in Kite's own world for every new
/// document, and the page's CSS replaced live when the library changes. Each engine calls
/// `attach(to:)` once from its page's init; this stays out of the engines' other scripts so it
/// can later fold into Boosts' script without either depending on the other.
@MainActor
final class ZapInjection: NSObject {
    private weak var page: WebPage?
    private let install: (String) -> Void
    private nonisolated(unsafe) static var key: UInt8 = 0

    private init(page: WebPage, install: @escaping (String) -> Void) {
        self.page = page
        self.install = install
        super.init()
        install(ZapsModel.shared.documentStartScript)
        NotificationCenter.default.addObserver(self, selector: #selector(libraryChanged), name: .kiteZapsChanged, object: nil)
    }

    @objc private func libraryChanged() {
        install(ZapsModel.shared.documentStartScript)
        if let page { ZapsModel.shared.applyLive(to: page) }
    }

    /// Lives as long as the page.
    private static func keep(_ injection: ZapInjection, on owner: NSObject) {
        objc_setAssociatedObject(owner, &key, injection, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    // MARK: WebKit

    /// Controllers can be shared between pages (WebKit copies the configuration's controller by
    /// reference), so the script last added to each is remembered and added once per change.
    /// User scripts can't be removed one by one; a newer one takes over the older one's style element.
    private static let installedScripts = NSMapTable<WKUserContentController, NSString>.weakToStrongObjects()

    static func attach(to page: WebKitPage) {
        let controller = page.webView.configuration.userContentController
        let injection = ZapInjection(page: page) { script in
            guard installedScripts.object(forKey: controller) as String? != script else { return }
            installedScripts.setObject(script as NSString, forKey: controller)
            controller.addUserScript(WKUserScript(
                source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true,
                in: WKContentWorld.world(name: ZapScript.worldName)
            ))
        }
        keep(injection, on: page)
    }

    // MARK: Chromium

    #if canImport(CEFBridge)
    static func attach(to page: ChromiumPage) {
        let browser = page.browser
        let identifier = ScriptIdentifier()
        let injection = ZapInjection(page: page) { [weak browser] script in
            guard let browser else { return }
            if let old = identifier.value {
                browser.executeDevToolsMethod("Page.removeScriptToEvaluateOnNewDocument", params: ["identifier": old], completion: nil)
                identifier.value = nil
            }
            browser.callDevToolsMethod(
                "Page.addScriptToEvaluateOnNewDocument",
                params: ["source": script, "worldName": ZapScript.worldName, "runImmediately": true]
            ) { result, _ in
                identifier.value = result?["identifier"] as? String
            }
        }
        keep(injection, on: page)
    }

    /// The registered script's id, for removing it when the library changes.
    private final class ScriptIdentifier {
        var value: String?
    }
    #endif
}
