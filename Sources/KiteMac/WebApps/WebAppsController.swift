import AppKit
import KiteCore

/// Installed web apps: File › Install Page as App… (reads the page's manifest, asks, writes the
/// launcher and opens the app), Window › Web Apps (open or uninstall), and kite-app:// links from the
/// launchers. Apps live in the profile's webapps.json; their icons in WebApps/<id>.png beside it.
///
/// Arc has no installed apps; this follows Chrome and the Web App Manifest spec (see WebApps.swift).
@MainActor
final class WebAppsController: NSObject, NSMenuItemValidation {
    struct Host {
        var engine: () -> WebEngine
        /// Opens a link in the main window (out-of-scope links, new tabs).
        var openTab: (URL) -> Void
        /// A popup the app opened becomes a tab in the main window.
        var adoptPopup: (WebPage) -> Void
        /// Open in Kite: the live page moves to the main window as a tab.
        var move: (_ page: WebPage, _ url: URL?, _ title: String?) -> Void
        /// The main browser window, for sheets when no window is key (never an app-modal alert).
        var mainWindow: () -> NSWindow?
    }

    private(set) var state: WebAppsState {
        didSet {
            guard state != oldValue else { return }
            save()
            rebuildMenu()
        }
    }
    private let fileURL: URL
    private let iconsDirectory: URL
    var host: Host?
    private var windows: [WebAppWindowController] = []
    /// Window › Web Apps.
    weak var menu: NSMenu? {
        didSet { rebuildMenu() }
    }
    private var installing = false

    init(supportDirectory: URL) {
        fileURL = supportDirectory.appendingPathComponent("webapps.json")
        iconsDirectory = supportDirectory.appendingPathComponent("WebApps", isDirectory: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        state = (try? Data(contentsOf: fileURL)).flatMap { try? decoder.decode(WebAppsState.self, from: $0) }
            ?? WebAppsState()
        super.init()
    }

    // MARK: Install

    /// File › Install Page as App…: reads `page`'s manifest (or falls back to its title and icon), then
    /// asks over `window` with the name editable, as Chrome's install dialog does.
    func install(from page: WebPage, over window: NSWindow?) {
        guard !installing else { return }
        installing = true
        page.evaluateJavaScript(WebApps.pageInfoScript) { [weak self] result in
            guard let self else { return }
            guard let info = WebAppPageInfo.decode(result), let documentURL = info.documentURL, WebApps.isWeb(documentURL) else {
                self.installing = false
                return NSSound.beep()
            }
            Task { @MainActor in
                let manifest = await Self.fetchManifest(info)
                guard var app = WebApp.candidate(page: info, manifest: manifest) else {
                    self.installing = false
                    return NSSound.beep()
                }
                let icon = await Self.fetchIcon(app, page: info)
                    ?? WebAppShimWriter.letterIcon(name: app.name, themeColor: app.themeColor)
                self.confirm(app, icon: icon, over: window) { name in
                    self.installing = false
                    guard let name else { return }
                    app.name = name
                    self.finishInstall(app, icon: icon)
                }
            }
        }
    }

    /// Asks with the name editable, in Arc's dialog sheet (`ArcDialog`) rather than an NSAlert.
    private func confirm(_ app: WebApp, icon: NSImage, over window: NSWindow?, completion: @escaping (String?) -> Void) {
        // Always a sheet: an app-modal alert would block Kite (and its test bridge) with no window in front.
        guard let window = window ?? host?.mainWindow() else { return completion(nil) }
        ArcDialog.present(
            on: window,
            title: "Install App?",
            message: "\(app.startURL.host ?? app.startURL.absoluteString) opens in its own window, "
                + "and in Launchpad and Spotlight from ~/Applications/\(WebAppShim.folderName).",
            field: .init(text: app.name, placeholder: "App Name"),
            actions: [.init(title: "Cancel", role: .cancel), .init(title: "Install", role: .primary)]
        ) { action, text in
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(action == 1 ? (name.isEmpty ? app.name : name) : nil)
        }
    }

    private func finishInstall(_ app: WebApp, icon: NSImage, opens: Bool = true) {
        var app = app
        let previous = state.app(id: app.id)
        do {
            app.shimName = try WebAppShimWriter.write(app, icon: icon, replacing: previous?.shimName)
        } catch {
            NSLog("Kite: couldn't write the launcher for \(app.name): \(error)")
            app.shimName = nil
        }
        try? FileManager.default.createDirectory(at: iconsDirectory, withIntermediateDirectories: true)
        if let png = WebAppShimWriter.pngData(icon) { try? png.write(to: iconURL(app.id), options: .atomic) }
        state.install(app)
        WebAppInstallOffers.shared.removeOffers(appID: app.id)
        if opens { open(app.id) }
    }

    // MARK: Chrome's install flow

    /// The install icon in the address field: Chrome's install dialog over the tab (WebAppInstallDialog),
    /// detailed when the manifest has wide screenshots.
    func showInstallDialog(tab: UUID, page: WebPage, in browser: BrowserWindowController) {
        guard !installing else { return }
        installing = true
        page.evaluateJavaScript(WebApps.pageInfoScript) { [weak self, weak browser] result in
            guard let self else { return }
            Task { @MainActor in
                defer { self.installing = false }
                guard let browser, let info = WebAppPageInfo.decode(result),
                      let manifest = await Self.fetchManifest(info), WebAppInstallability.isPromotable(manifest),
                      let app = WebApp.candidate(page: info, manifest: manifest) else { return NSSound.beep() }
                let icon = await Self.fetchIcon(app, page: info) ?? WebAppShimWriter.letterIcon(name: app.name, themeColor: app.themeColor)
                let screenshots = await Self.fetchScreenshots(manifest)
                self.present(app, icon: icon, manifest: manifest, screenshots: screenshots, tab: tab, in: browser)
            }
        }
    }

    private func present(_ app: WebApp, icon: NSImage, manifest: WebAppManifest, screenshots: [NSImage],
                         tab: UUID, in browser: BrowserWindowController) {
        let flow = WebAppInstallFlow(
            name: app.name, origin: WebAppInstallability.displayOrigin(app.startURL), icon: icon,
            description: WebAppInstallability.dialogDescription(manifest.description), screenshots: screenshots
        )
        let hostView = WebAppInstallDialogHost(flow: flow)
        let close: () -> Void = { [weak hostView] in hostView?.removeFromSuperview() }
        flow.onCancel = close
        flow.onLearnMore = { [weak self] in
            close()
            // Chrome's kInstallDialogFlowLearnMoreURL.
            if let url = URL(string: "https://support.google.com/chrome?p=pwa_install") { self?.host?.openTab(url) }
        }
        flow.onInstall = { [weak self] done in
            guard let self else { return done(false) }
            self.finishInstall(app, icon: icon, opens: false)
            done(self.state.app(id: app.id) != nil)
        }
        flow.onShowInFinder = { [weak self] in
            close()
            guard let shim = self?.state.app(id: app.id)?.shimName else { return }
            NSWorkspace.shared.activateFileViewerSelecting([WebAppShimWriter.appsDirectory.appendingPathComponent(shim)])
        }
        // Chrome moves the tab into the new app window; Kite opens the app at the tab's page and closes the tab.
        flow.onOpenApp = { [weak self, weak browser] in
            close()
            guard let self, let installed = self.state.app(id: app.id) else { return }
            let url = browser?.store.state.tab(tab)?.url.flatMap { installed.contains($0) ? $0 : nil }
            self.open(installed.id, at: url)
            if installed.display.opensInWindow { browser?.store.mutate { $0.close(tab: tab) } }
        }
        browser.installOverContent(hostView)
    }

    /// The manifest's wide screenshots that pass Chrome's checks, in order.
    private static func fetchScreenshots(_ manifest: WebAppManifest) async -> [NSImage] {
        var images: [NSImage?] = []
        for shot in WebAppInstallability.desktopScreenshots(manifest) {
            images.append(await fetch(shot.url).flatMap { NSImage(data: $0) })
        }
        let sizes: [(width: Int, height: Int)?] = images.map { image in
            guard let rep = image?.representations.first, rep.pixelsWide > 0 else { return nil }
            return (rep.pixelsWide, rep.pixelsHigh)
        }
        return WebAppInstallability.acceptedScreenshots(sizes).compactMap { images[$0] }
    }

    /// The manifest the page links to, fetched without credentials (the spec's default) and parsed.
    static func fetchManifest(_ info: WebAppPageInfo) async -> WebAppManifest? {
        guard let manifestURL = info.manifestURL, let documentURL = info.documentURL,
              let data = await fetch(manifestURL) else { return nil }
        return WebAppManifest.parse(data, manifestURL: manifestURL, documentURL: documentURL)
    }

    /// The app's chosen icon, else the page's favicon.
    private static func fetchIcon(_ app: WebApp, page: WebAppPageInfo) async -> NSImage? {
        var urls = [app.iconURL]
        if let documentURL = page.documentURL { urls.append(WebApps.faviconURL(for: documentURL)) }
        for url in urls.compactMap({ $0 }) {
            if let data = await fetch(url), let image = NSImage(data: data), image.isValid, image.size.width > 0 { return image }
        }
        return nil
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    private static func fetch(_ url: URL) async -> Data? {
        if url.scheme == "data" { return try? Data(contentsOf: url) }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return data
    }

    // MARK: Open

    /// A kite-app:// link from a launcher: the app's window (an open one comes forward).
    func handleLaunchURL(_ url: URL) -> Bool {
        guard let id = WebApps.appID(fromLaunchURL: url) else { return false }
        if state.app(id: id) == nil { NSLog("Kite: no installed web app \(id)") } else { open(id) }
        return true
    }

    /// The app's window (at `url`, a page in its scope, else its start URL); an open one comes forward.
    func open(_ id: String, at url: URL? = nil) {
        guard let app = state.app(id: id), let host else { return }
        guard app.display.opensInWindow else { return host.openTab(url ?? app.startURL) }
        if let existing = windows.first(where: { $0.app.id == id }) {
            if UIDiagnostics.enabledByEnvironment { existing.window?.orderBack(nil) } else {
                existing.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }
        let controller = WebAppWindowController(app: app, url: url, engine: host.engine(), host: .init(
            openTab: host.openTab, adoptPopup: host.adoptPopup, move: host.move
        ))
        controller.didClose = { [weak self] closed in self?.windows.removeAll { $0 === closed } }
        windows.append(controller)
        if UIDiagnostics.enabledByEnvironment {
            // Test runs stay behind the user's windows.
            controller.window?.orderBack(nil)
        } else {
            controller.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: Uninstall

    func uninstall(_ id: String, over window: NSWindow?) {
        guard let app = state.app(id: id) else { return }
        let alert = NSAlert()
        alert.messageText = "Uninstall “\(app.name)”?"
        alert.informativeText = app.shimName.map { "Removes it from Kite and deletes ~/Applications/\(WebAppShim.folderName)/\($0). Your sign-ins on the site stay in Kite." }
            ?? "Removes it from Kite. Your sign-ins on the site stay in Kite."
        alert.icon = icon(for: app.id)
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertFirstButtonReturn { self?.remove(id) }
        }
        // Always a sheet: an app-modal alert would block Kite (and its test bridge) with no window in front.
        if let window = window ?? host?.mainWindow() { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(.cancel) }
    }

    private func remove(_ id: String) {
        windows.filter { $0.app.id == id }.forEach { $0.close() }
        guard let app = state.app(id: id) else { return }
        if let shim = app.shimName { WebAppShimWriter.remove(shimName: shim, appID: id) }
        try? FileManager.default.removeItem(at: iconURL(id))
        state.remove(id: id)
    }

    // MARK: Menu

    private func iconURL(_ id: String) -> URL { iconsDirectory.appendingPathComponent("\(id).png") }

    private func icon(for id: String) -> NSImage? { NSImage(contentsOf: iconURL(id)) }

    /// Window › Web Apps: each app (opens it), then Uninstall › each app, then the launchers' folder.
    private func rebuildMenu() {
        guard let menu else { return }
        menu.removeAllItems()
        let apps = state.sorted
        if apps.isEmpty {
            let none = NSMenuItem(title: "No Web Apps Installed", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            menu.addItem(.separator())
            let hint = NSMenuItem(title: "Install with File › Install Page as App…", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            return
        }
        for app in apps {
            let item = WebAppMenuItem(title: app.name, action: #selector(openApp(_:)), keyEquivalent: "")
            item.target = self
            item.appID = app.id
            item.toolTip = app.startURL.absoluteString
            if let image = icon(for: app.id) {
                image.size = NSSize(width: 16, height: 16)
                item.image = image
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let uninstall = NSMenu(title: "Uninstall")
        for app in apps {
            let item = WebAppMenuItem(title: app.name, action: #selector(uninstallApp(_:)), keyEquivalent: "")
            item.target = self
            item.appID = app.id
            uninstall.addItem(item)
        }
        let uninstallItem = NSMenuItem(title: "Uninstall", action: nil, keyEquivalent: "")
        uninstallItem.submenu = uninstall
        menu.addItem(uninstallItem)
        // Hidden, for the command bar (it matches on titles): "Open <App>" and "Uninstall <App>…".
        for app in apps {
            for (title, action) in [("Open \(app.name)", #selector(openApp(_:))), ("Uninstall \(app.name)…", #selector(uninstallApp(_:)))] {
                let item = WebAppMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.isHidden = true
                item.appID = app.id
                item.representedObject = CommandBarKeywords([])
                menu.addItem(item)
            }
        }
        let reveal = NSMenuItem(title: "Show Web Apps in Finder", action: #selector(revealAppsFolder(_:)), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
    }

    @objc func openApp(_ sender: NSMenuItem) {
        guard let id = Self.appID(of: sender) else { return }
        open(id)
    }

    @objc func uninstallApp(_ sender: NSMenuItem) {
        guard let id = Self.appID(of: sender) else { return }
        uninstall(id, over: NSApp.keyWindow ?? NSApp.mainWindow ?? host?.mainWindow())
    }

    private static func appID(of item: NSMenuItem) -> String? {
        guard let id = (item as? WebAppMenuItem)?.appID, WebApps.isAppID(id) else { return nil }
        return id
    }

    @objc func revealAppsFolder(_ sender: Any?) {
        let directory = WebAppShimWriter.appsDirectory
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(revealAppsFolder(_:)) {
            return FileManager.default.fileExists(atPath: WebAppShimWriter.appsDirectory.path)
        }
        return true
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(state).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Kite: couldn't save web apps: \(error)")
        }
    }
}

/// A Window › Web Apps item, naming its app.
final class WebAppMenuItem: NSMenuItem {
    var appID = ""
}
