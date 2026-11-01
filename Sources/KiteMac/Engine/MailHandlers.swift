import AppKit
import KiteCore
import SwiftUI

/// mailto: links, as Arc 1.171 handles them (docs/arc-visual-spec.md, "mailto: handling"): a web
/// mail site registers itself with `navigator.registerProtocolHandler("mailto", …)`, Kite asks
/// "Make <site> your default mail app?", and once allowed every mailto: link, in a page or from
/// another app (Kite registers for mailto like Arc), opens that site's compose page. With no
/// handler, links go to the system's mail app as before. Both engines get `script`, which
/// replaces the page's registerProtocolHandler and reports calls to `request`.
@MainActor
final class MailHandlers {
    static let shared = MailHandlers(fileURL: AppDelegate.supportDirectory.appendingPathComponent("MailHandler.json"))

    private(set) var settings: MailHandlerSettings {
        didSet { if settings != oldValue { save() } }
    }
    private let fileURL: URL
    private weak var prompt: NSPopover?

    init(fileURL: URL) {
        self.fileURL = fileURL
        settings = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(MailHandlerSettings.self, from: $0) }
            ?? MailHandlerSettings()
    }

    /// The handler's page for a mailto: link, or nil when no site is the default mail app.
    func destination(for url: URL) -> URL? {
        MailHandler.isMailto(url) ? settings.destination(for: url) : nil
    }

    func isDefault(host: String?) -> Bool { settings.isDefault(host: host) }

    func remove(host: String?) { settings.remove(host: host) }

    /// A mailto: link with no web handler goes to the system's mail app, unless that app is Kite
    /// itself (Kite set as the default mail app), which would hand it straight back.
    func openInSystemMailApp(_ url: URL) {
        if let app = NSWorkspace.shared.urlForApplication(toOpen: url),
           app.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL { return }
        NSWorkspace.shared.open(url)
    }

    /// A page at `pageURL` called registerProtocolHandler(scheme, url). Asks once per new handler,
    /// in a popover over `view`; a refused handler never asks again.
    func request(scheme: String, url: String, pageURL: URL?, from view: NSView) {
        guard let pageURL, let handler = MailHandler.registration(scheme: scheme, url: url, pageURL: pageURL),
              settings.asks(for: handler), prompt?.isShown != true, view.window != nil else { return }
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        let content = MailHandlerPrompt(site: handler.host ?? pageURL.host ?? "This site") { [weak self, weak popover] allow in
            guard let self else { return }
            if allow { self.settings.allow(handler) } else { self.settings.block(handler) }
            popover?.close()
        }
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        // Hangs into the page from its top edge, near the sidebar's address field.
        let top = view.isFlipped ? view.bounds.minY : view.bounds.maxY - 1
        popover.show(relativeTo: NSRect(x: view.bounds.minX + 28, y: top, width: 1, height: 1), of: view,
                     preferredEdge: view.isFlipped ? .maxY : .minY)
        prompt = popover
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Kite: couldn't save the mail handler: \(error)")
        }
    }

    /// Replaces navigator.registerProtocolHandler in the page's main frame with HTML's checks (it
    /// throws as Chromium does), reporting each call through `send`, a JS expression that's a
    /// function of one JSON string (nil when the bridge is missing).
    static func script(send: String) -> String {
        """
        (() => {
          if (window.top !== window) return;
          const send = \(send);
          if (typeof send !== 'function') return;
          const mark = 'kitemailtoplaceholder';
          const registerProtocolHandler = function registerProtocolHandler(scheme, url) {
            if (arguments.length < 2) throw new TypeError("Failed to execute 'registerProtocolHandler' on 'Navigator': 2 arguments required, but only " + arguments.length + " present.");
            scheme = String(scheme); url = String(url);
            if (!url.includes('%s')) throw new DOMException("The url provided ('" + url + "') does not contain '%s'.", 'SyntaxError');
            let resolved;
            try { resolved = new URL(url.replace('%s', mark), document.baseURI); }
            catch (e) { throw new DOMException("The custom handler URL is invalid.", 'SyntaxError'); }
            if (resolved.origin !== location.origin) throw new DOMException("Can only register custom handler in the document's origin.", 'SecurityError');
            send(JSON.stringify({ scheme, url: resolved.href.replace(mark, '%s') }));
          };
          Object.defineProperty(Navigator.prototype, 'registerProtocolHandler', { value: registerProtocolHandler, writable: true, configurable: true, enumerable: true });
        })();
        """
    }

    /// The scheme and handler URL a script call reported.
    static func parse(_ payload: String) -> (scheme: String, url: String)? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scheme = object["scheme"] as? String, let url = object["url"] as? String else { return nil }
        return (scheme, url)
    }
}

/// Arc's permission popover for a mailto handler: "Make %@ your default mail app?" (its binary's
/// string), with deny and allow buttons. Arc's button titles and layout weren't observed.
private struct MailHandlerPrompt: View {
    let site: String
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Make \(site) your default mail app?")
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Deny") { answer(false) }
                Button("Allow") { answer(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 262, alignment: .leading)
    }
}
