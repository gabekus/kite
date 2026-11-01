import AppKit
import KiteCore

// Cocoa scripting for Resources/Kite.sdef: Arc's AppleScript dictionary (application → windows →
// tabs and spaces) over Kite's window controllers. The rules for what a window lists and how
// results read are in KiteCore/AppleScripting.swift.

extension NSApplication {
    private var kite: AppDelegate? { delegate as? AppDelegate }

    /// `windows`, front to back.
    @objc var appleScriptWindows: [ScriptWindow] {
        (kite?.scriptControllers ?? []).map(ScriptWindow.init(controller:))
    }

    @objc func valueInAppleScriptWindowsWithUniqueID(_ id: String) -> ScriptWindow? {
        appleScriptWindows.first { $0.uniqueID == id }
    }

    /// `make new window [with properties {mode:"incognito"}]`: File › New Window, or New Incognito Window.
    @objc(insertObject:inAppleScriptWindowsAtIndex:)
    func insertInAppleScriptWindows(_ window: ScriptWindow, at index: Int) {
        insertInAppleScriptWindows(window)
    }

    @objc(insertInAppleScriptWindows:)
    func insertInAppleScriptWindows(_ window: ScriptWindow) {
        guard let kite else { return }
        window.controller = kite.openScriptWindow(incognito: AppleScripting.isIncognito(mode: window.newMode, incognito: window.newIncognito?.boolValue))
    }

    /// The application's write-only `tabs`: nothing to read.
    @objc var appleScriptTabs: [ScriptTab] { [] }

    /// `make new tab with properties {URL:…}` sent to the application opens it in Little Kite, as
    /// Arc opens Little Arc.
    @objc(insertObject:inAppleScriptTabsAtIndex:)
    func insertInAppleScriptTabs(_ tab: ScriptTab, at index: Int) {
        insertInAppleScriptTabs(tab)
    }

    @objc(insertInAppleScriptTabs:)
    func insertInAppleScriptTabs(_ tab: ScriptTab) {
        guard let url = ScriptTab.requireURL(tab.newURL) else { return }
        kite?.openLittleKiteWindow(url: url)
    }
}

/// A browser window (the sdef's `window`).
@MainActor
@objc(KiteScriptWindow)
final class ScriptWindow: NSObject {
    weak var controller: BrowserWindowController?
    /// Properties given to `make new window`, before the window exists.
    @objc var newMode: String?
    @objc var newIncognito: NSNumber?

    /// For `make new window`: Cocoa scripting makes the object first, then inserts it.
    override init() {}

    init(controller: BrowserWindowController) {
        self.controller = controller
    }

    private var window: NSWindow? { controller?.window }
    private var state: BrowserState? { controller?.store.state }

    @objc var uniqueID: String { window.map { String($0.windowNumber) } ?? "" }
    @objc var title: String { window?.title ?? "" }
    @objc var orderedIndex: Int {
        get { window?.orderedIndex ?? 0 }
        set { window?.orderedIndex = newValue }
    }
    @objc var hasCloseBox: Bool { window?.styleMask.contains(.closable) ?? false }
    @objc var isMiniaturizable: Bool { window?.styleMask.contains(.miniaturizable) ?? false }
    @objc var isMiniaturized: Bool {
        get { window?.isMiniaturized ?? false }
        set { newValue ? window?.miniaturize(nil) : window?.deminiaturize(nil) }
    }
    @objc var isResizable: Bool { window?.styleMask.contains(.resizable) ?? false }
    @objc var isVisible: Bool {
        get { window?.isVisible ?? false }
        set { newValue ? window?.orderFront(nil) : window?.orderOut(nil) }
    }
    @objc var isZoomable: Bool { window?.styleMask.contains(.resizable) ?? false }
    @objc var isZoomed: Bool {
        get { window?.isZoomed ?? false }
        set { if newValue != window?.isZoomed { window?.zoom(nil) } }
    }
    @objc var isIncognito: Bool {
        get { controller?.isIncognito ?? newIncognito?.boolValue ?? false }
        set { if controller == nil { newIncognito = NSNumber(value: newValue) } }
    }
    @objc var mode: String {
        get { isIncognito ? "incognito" : "normal" }
        set { if controller == nil { newMode = newValue } }
    }

    @objc var appleScriptTabs: [ScriptTab] {
        guard let controller, let state else { return [] }
        return AppleScripting.windowTabs(state).map { ScriptTab(controller: controller, id: $0.id, container: objectSpecifier, key: "appleScriptTabs") }
    }

    @objc func valueInAppleScriptTabsWithUniqueID(_ id: String) -> ScriptTab? {
        appleScriptTabs.first { $0.uniqueID == id }
    }

    @objc var appleScriptSpaces: [ScriptSpace] {
        guard let controller, let state else { return [] }
        return state.spaces.map { ScriptSpace(controller: controller, id: $0.id, window: self) }
    }

    @objc func valueInAppleScriptSpacesWithUniqueID(_ id: String) -> ScriptSpace? {
        appleScriptSpaces.first { $0.uniqueID == id }
    }

    @objc var activeTab: ScriptTab? {
        guard let id = state?.selectedTab?.id else { return nil }
        return valueInAppleScriptTabsWithUniqueID(id.uuidString)
    }

    @objc var activeSpace: ScriptSpace? {
        guard let id = state?.selectedSpaceID else { return nil }
        return valueInAppleScriptSpacesWithUniqueID(id.uuidString)
    }

    /// `make new tab with properties {URL:…}` in this window: a new tab at the top of Today, selected (⌘T's place).
    @objc(insertObject:inAppleScriptTabsAtIndex:)
    func insertInAppleScriptTabs(_ tab: ScriptTab, at index: Int) {
        insertInAppleScriptTabs(tab)
    }

    @objc(insertInAppleScriptTabs:)
    func insertInAppleScriptTabs(_ tab: ScriptTab) {
        guard let controller, let url = ScriptTab.requireURL(tab.newURL) else { return }
        let id = controller.store.mutate { $0.openTab(url: url) }
        tab.attach(controller: controller, id: id, container: objectSpecifier, key: "appleScriptTabs")
    }

    @objc func handleCloseScriptCommand(_ command: NSScriptCommand) -> Any? {
        window?.performClose(nil)
        return nil
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        // NSApplication's description: NSApp's own class (CEF's subclass) has none.
        guard controller != nil, let app = NSScriptClassDescription(for: NSApplication.self) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: app, containerSpecifier: nil, key: "appleScriptWindows", uniqueID: uniqueID)
    }
}

/// A tab in a window or space (the sdef's `tab`).
@MainActor
@objc(KiteScriptTab)
final class ScriptTab: NSObject {
    private weak var controller: BrowserWindowController?
    private var id: UUID?
    private var container: NSScriptObjectSpecifier?
    private var key = "appleScriptTabs"
    /// The URL given to `make new tab`, before the tab exists.
    var newURL: Any?

    override init() {}

    init(controller: BrowserWindowController, id: UUID, container: NSScriptObjectSpecifier?, key: String) {
        super.init()
        attach(controller: controller, id: id, container: container, key: key)
    }

    func attach(controller: BrowserWindowController, id: UUID, container: NSScriptObjectSpecifier?, key: String) {
        self.controller = controller
        self.id = id
        self.container = container
        self.key = key
    }

    /// The URL `make new tab` needs, or Arc's error for the script.
    static func requireURL(_ value: Any?) -> URL? {
        if let url = AppleScripting.newTabURL(value) { return url }
        fail(Int(errAEParamMissed), AppleScripting.invalidNewTabURLMessage)
        return nil
    }

    static func fail(_ number: Int, _ message: String, _ command: NSScriptCommand? = NSScriptCommand.current()) {
        command?.scriptErrorNumber = number
        command?.scriptErrorString = message
    }

    private var tab: BrowserTab? { id.flatMap { controller?.store.state.tab($0) } }
    private var livePage: WebPage? { id.flatMap { controller?.pool.loadedPage($0) } }

    @objc var uniqueID: String { id?.uuidString ?? "" }
    @objc var title: String { tab?.displayTitle ?? "" }
    @objc var loading: Bool { livePage?.isLoading ?? false }
    @objc var location: String {
        guard let id, let section = controller?.store.state.location(of: id)?.section else { return "" }
        return AppleScripting.location(section)
    }

    @objc var URL: String {
        get { tab?.url?.absoluteString ?? (newURL as? String) ?? "" }
        set {
            guard let controller, let id else { return newURL = newValue }
            guard let url = Foundation.URL(string: newValue), url.scheme != nil else {
                return Self.fail(Int(errAEParamMissed), "Not a URL: \(newValue)")
            }
            controller.store.mutate { $0.update(tab: id) { $0.url = url } }
            livePage?.load(url)
        }
    }

    @objc func handleSelectScriptCommand(_ command: NSScriptCommand) -> Any? {
        if let id { controller?.store.mutate { $0.select(tab: id) } }
        return nil
    }

    @objc func handleGoBackScriptCommand(_ command: NSScriptCommand) -> Any? {
        livePage?.goBack()
        return nil
    }

    @objc func handleGoForwardScriptCommand(_ command: NSScriptCommand) -> Any? {
        livePage?.goForward()
        return nil
    }

    @objc func handleReloadScriptCommand(_ command: NSScriptCommand) -> Any? {
        livePage?.reload()
        return nil
    }

    @objc func handleStopScriptCommand(_ command: NSScriptCommand) -> Any? {
        livePage?.stopLoading()
        return nil
    }

    /// `execute tab … javascript "…"`: refused unless View › Developer › Allow JavaScript from
    /// Apple Events is on, as in Arc. Waits for the page's answer without blocking Kite.
    @objc func handleExecuteScriptCommand(_ command: NSScriptCommand) -> Any? {
        guard (NSApp.delegate as? AppDelegate)?.allowsJavaScriptFromAppleEvents == true else {
            Self.fail(Int(errAEEventNotPermitted), AppleScripting.javaScriptDisabledMessage, command)
            return nil
        }
        guard let script = command.evaluatedArguments?["javascript"] as? String else {
            Self.fail(Int(errAEParamMissed), "Give the JavaScript to run: execute … javascript \"…\".", command)
            return nil
        }
        guard let controller, let tab else {
            Self.fail(Int(errAENoSuchObject), "The tab is gone.", command)
            return nil
        }
        let page = livePage ?? controller.automationPage(for: tab)
        command.suspendExecution()
        page.evaluateJavaScript(script) { result in
            command.resumeExecution(withResult: AppleScripting.text(fromJavaScriptResult: result))
        }
        return nil
    }

    @objc func handleCloseScriptCommand(_ command: NSScriptCommand) -> Any? {
        if let id { controller?.close(tab: id) }
        return nil
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let id, let container, let description = container.keyClassDescription else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: description, containerSpecifier: container, key: key, uniqueID: id.uuidString)
    }
}

/// A space, read only (the sdef's `space`).
@MainActor
@objc(KiteScriptSpace)
final class ScriptSpace: NSObject {
    private weak var controller: BrowserWindowController?
    private let id: UUID
    private let windowSpecifier: NSScriptObjectSpecifier?

    init(controller: BrowserWindowController, id: UUID, window: ScriptWindow) {
        self.controller = controller
        self.id = id
        self.windowSpecifier = window.objectSpecifier
    }

    private var space: Space? { controller?.store.state.spaces.first { $0.id == id } }

    @objc var uniqueID: String { id.uuidString }
    @objc var title: String { space?.name ?? "" }

    @objc var appleScriptTabs: [ScriptTab] {
        guard let controller, let space else { return [] }
        return AppleScripting.spaceTabs(space).map { ScriptTab(controller: controller, id: $0.id, container: objectSpecifier, key: "appleScriptTabs") }
    }

    @objc func valueInAppleScriptTabsWithUniqueID(_ id: String) -> ScriptTab? {
        appleScriptTabs.first { $0.uniqueID == id }
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let windowSpecifier, let description = windowSpecifier.keyClassDescription else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: description, containerSpecifier: windowSpecifier, key: "appleScriptSpaces", uniqueID: id.uuidString)
    }
}
