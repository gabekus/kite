import AppKit
import KiteCore
import SwiftUI

private typealias M = ArcMetrics.Sidebar

/// The sidebar's top: the row beside the traffic lights (the sidebar toggle; back, forward and reload at the
/// far end, or Arc's compact layout with a More menu) and, under it, the address field. With View → Show
/// Toolbar both navigation and the address move to the bar over the page; on Create a Space the field goes.
@MainActor
final class SidebarHeaderView: NSView {
    struct Model: Equatable {
        var compact = false
        var showsToolbar = false
        var showsField = true
        var canGoBack = false
        var canGoForward = false
        var isLoading = false
        var hasTab = false
        var developerReload: DeveloperTabReloadSetting?
        var field = AddressFieldView.Model()
    }

    private let store: BrowserStore
    private let actions: SidebarActions
    private let hover: SidebarHoverModel
    private let supportsDarkPages: Bool
    var showExtensions: ((NSView) -> Void)? { didSet { field.showExtensions = showExtensions } }
    var showSiteControls: ((NSView) -> Void)?
    var installApp: ((NSView) -> Void)?

    private let toggle = SymbolButton(symbol: "sidebar.left", pointSize: 15, label: "Toggle Sidebar")
    private let back = SymbolButton(symbol: "arrow.left", pointSize: 15, label: "Back")
    private let forward = SymbolButton(symbol: "arrow.right", pointSize: 15, label: "Forward")
    private let reload = SymbolButton(symbol: "arrow.clockwise", pointSize: 15, label: "Reload")
    private let developer = SymbolButton(symbol: "chevron.down", pointSize: 9, weight: .semibold, label: "Refresh options")
    private let more = SymbolButton(symbol: "ellipsis", pointSize: 15, label: "More")
    let field: AddressFieldView
    private(set) var model = Model()
    private var updateScheduled = false
    private var defaultsObserver: NSObjectProtocol?

    /// The header's height: the top row, and the field under it when it shows.
    var height: CGFloat {
        M.topRowY + M.topRowHeight + (model.showsField ? M.urlFieldTopGap + M.urlFieldHeight : 0)
    }

    var onHeightChange: () -> Void = {}

    init(store: BrowserStore, actions: SidebarActions, hover: SidebarHoverModel, supportsDarkPages: Bool, accessory: NSView?) {
        self.store = store
        self.actions = actions
        self.hover = hover
        self.supportsDarkPages = supportsDarkPages
        field = AddressFieldView(accessory: accessory)
        super.init(frame: .zero)
        wantsLayer = true
        for button in [toggle, back, forward, reload, more] {
            button.opacity = 0.6
            addSubview(button)
        }
        developer.opacity = 0.6
        addSubview(developer)
        // SwiftUI halves a disabled plain button on top of its own opacity (0.25 for a disabled toolbar button).
        for button in [back, forward, reload] { button.disabledOpacity = 0.25 * 0.5 }
        developer.disabledOpacity = 0.6 * 0.5
        toggle.toolTip = "Toggle Sidebar"
        toggle.action = { actions.toggleSidebar() }
        back.toolTip = "Back"
        back.action = { actions.goBack() }
        forward.toolTip = "Forward"
        forward.action = { actions.goForward() }
        reload.action = { actions.reloadButton() }
        developer.toolTip = "Refresh options"
        developer.action = { [weak self] in self?.showDeveloperMenu() }
        more.toolTip = "More"
        more.action = { [weak self] in self?.showMoreMenu() }
        addSubview(field)
        field.action = { [weak self] in
            guard let self else { return }
            store.showCommandBar(self.store.state.selectedTab == nil ? .newTab : .editCurrent)
        }
        field.toggleDark = {
            // Read first: reading store.state inside store.mutate is an exclusivity trap.
            let url = store.state.selectedTab?.url
            store.mutate { $0.toggleDarkPage(for: url) }
        }
        field.showSiteControls = { [weak self] view in self?.showSiteControls?(view) }
        field.installApp = { [weak self] view in self?.installApp?(view) }
        // Settings → Advanced → Toolbar can hide each field button.
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                                  queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleUpdate() }
        }
        update()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    override var isFlipped: Bool { true }

    // MARK: Observing

    private func update() {
        let next = withObservationTracking { readModel() } onChange: { [weak self] in
            MainActor.assumeIsolated { self?.scheduleUpdate() }
        }
        guard next != model else { return }
        let heightChanged = next.showsField != model.showsField
        model = next
        apply()
        if heightChanged { onHeightChange() }
    }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            self.update()
        }
    }

    private func readModel() -> Model {
        let state = store.state
        let space = state.selectedSpace
        let selectedID = space.selectedTabID
        let page = selectedID.flatMap { store.pages[$0] } ?? PageStatus()
        let selectedTab = state.selectedTab
        let defaults = UserDefaults.standard
        var model = Model()
        model.compact = HeaderLayout(sidebarWidth: bounds.width).isCompact
        model.showsToolbar = state.showsToolbar
        model.showsField = !state.showsToolbar && !(store.spaceCreation.map { $0.spaceID == space.id } ?? false)
        model.canGoBack = page.canGoBack
        model.canGoForward = page.canGoForward
        model.isLoading = page.isLoading
        model.hasTab = selectedID != nil
        model.developerReload = state.isInDeveloperMode(selectedTab?.url) ? state.devModeReloadState : nil
        var field = AddressFieldView.Model()
        field.text = selectedTab?.url?.host() ?? "Search or enter URL"
        // Nil hides the moon: nothing to darken, or the engine can't.
        if supportsDarkPages, let url = selectedTab?.url, url.host() != nil, !defaults.bool(forKey: ChromeButton.darkPage.hiddenKey) {
            field.isDark = state.wantsDarkPage(for: url, systemIsDark: store.systemIsDark)
        }
        field.showsSiteControls = showSiteControls != nil && SiteControls.applies(to: selectedTab?.url)
            && !defaults.bool(forKey: ChromeButton.siteControls.hiddenKey)
        field.installAppName = installApp == nil ? nil : WebAppInstallOffers.shared.offer(for: selectedID)?.name
        field.showsAccessory = !defaults.bool(forKey: ChromeButton.passwordManager.hiddenKey)
        field.showsExtensions = showExtensions != nil && !defaults.bool(forKey: ChromeButton.extensions.hiddenKey)
        // Arc shows the field's buttons only while the sidebar is hovered (its URL row's `sidebarHovered`).
        field.revealed = hover.isHovered || SiteControlsPopover.isShown
        model.field = field
        return model
    }

    private func apply() {
        let m = model
        back.isEnabled = m.canGoBack
        forward.isEnabled = m.canGoForward
        reload.isEnabled = m.hasTab
        reload.symbol = m.isLoading ? "xmark" : m.developerReload == .forceReload ? "arrow.clockwise.circle" : "arrow.clockwise"
        reload.toolTip = m.developerReload == .forceReload ? "Refresh (Ignore Cache)" : "Reload"
        reload.setAccessibilityLabel(reload.toolTip)
        developer.isEnabled = m.hasTab
        field.isHidden = !m.showsField
        field.model = m.field
        needsLayout = true
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let layout = HeaderLayout(sidebarWidth: bounds.width)
        if layout.isCompact != model.compact { scheduleUpdate() }
        let m = model
        let size = layout.buttonSize
        let rowY = M.topRowY
        // Arc's compact header drops the toggle into the More menu.
        toggle.isHidden = layout.isCompact
        toggle.frame = CGRect(x: M.toggleX, y: rowY, width: M.navButtonSize, height: M.navButtonSize)
        // Navigation at the far end, 6pt in.
        var end = bounds.width - M.navTrailing
        let y = rowY + (M.topRowHeight - size) / 2
        func place(_ button: SymbolButton, width: CGFloat, shown: Bool) {
            button.isHidden = !shown
            guard shown else { return }
            end -= width
            button.frame = CGRect(x: end, y: y, width: width, height: size)
            end -= layout.spacing
        }
        let showsNavigation = !m.showsToolbar
        if layout.isCompact {
            place(developer, width: size / 2, shown: false)
            place(reload, width: size, shown: false)
            place(more, width: size, shown: showsNavigation || m.showsToolbar)
        } else {
            place(more, width: size, shown: false)
            place(developer, width: size / 2, shown: showsNavigation && m.developerReload != nil)
            place(reload, width: size, shown: showsNavigation)
        }
        place(forward, width: size, shown: showsNavigation)
        place(back, width: size, shown: showsNavigation)
        field.frame = CGRect(x: M.padding, y: rowY + M.topRowHeight + M.urlFieldTopGap, width: bounds.width - 2 * M.padding,
                             height: M.urlFieldHeight)
    }

    // MARK: Menus

    /// Arc's `reloadOptionsButton`, beside reload on a Developer Mode site.
    private func showDeveloperMenu() {
        guard let setting = model.developerReload else { return }
        let menu = NSMenu()
        let actions = self.actions
        menu.add("Reload this page", checked: setting == .reload) { actions.developerReload(.reload) }
        menu.add("Refresh (Ignore Cache)", checked: setting == .forceReload) { actions.developerReload(.forceReload) }
        menu.addSeparator()
        menu.add("Clear Cookies and Refresh") { actions.clearCookiesAndRefresh() }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: developer.bounds.height), in: developer)
    }

    /// Arc's `navigationButtonsMore`: reload, the sidebar toggle and force reload.
    private func showMoreMenu() {
        let menu = NSMenu()
        let actions = self.actions
        let showsReload = !model.showsToolbar
        if showsReload {
            menu.add(model.isLoading ? "Stop" : "Reload", enabled: model.hasTab) { actions.reload() }
        }
        menu.add("Toggle Sidebar") { actions.toggleSidebar() }
        if showsReload {
            menu.add("Force Reload", enabled: model.hasTab) { actions.forceReload() }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height), in: more)
    }
}

/// The sidebar's address field (SwiftUI's `AddressPill`): the page's host on the field's wash, and at its right
/// end the dark-page moon, Site Controls and the install icon (shown while the sidebar is hovered), the password
/// manager's key and the extensions button. Arc's buttons are 30pt wide on a 28pt pitch.
@MainActor
final class AddressFieldView: SidebarFlippedView {
    struct Model: Equatable {
        var text = ""
        /// Whether the page is shown dark; nil hides the moon.
        var isDark: Bool?
        var showsSiteControls = false
        var installAppName: String?
        var showsAccessory = true
        var showsExtensions = false
        var revealed = false
    }

    var model = Model() { didSet { if model != oldValue { apply(from: oldValue) } } }
    var action: () -> Void = {}
    var toggleDark: () -> Void = {}
    var showSiteControls: (NSView) -> Void = { _ in }
    var installApp: (NSView) -> Void = { _ in }
    var showExtensions: ((NSView) -> Void)?

    private let fill = FillView()
    private let text = SidebarLabel(size: M.urlFieldFontSize, opacity: M.urlFieldTextOpacity)
    private let revealGroup = SidebarPassthroughView()
    private let dark = SymbolButton(symbol: "moon", pointSize: 11, weight: .semibold, label: "Dark page")
    private let siteControls = SymbolButton(symbol: "slider.horizontal.3", pointSize: 12, weight: .semibold, label: "Site Control Center")
    private let install = SymbolButton(symbol: "desktopcomputer.and.arrow.down", pointSize: 12, weight: .semibold)
    private let extensions = SymbolButton(symbol: "puzzlepiece.extension", pointSize: 12, weight: .semibold, label: "Extensions")
    /// The password manager's key: sized by its intrinsic size, zero while it's not shown.
    private let accessory: NSView?
    private var pressed = false

    static let buttonSize: CGFloat = 30

    init(accessory: NSView?) {
        self.accessory = accessory
        super.init(frame: .zero)
        fill.cornerRadius = M.cornerRadius
        fill.fill = chromeFill(M.fieldFill)
        addSubview(fill)
        text.setAccessibilityElement(false)
        addSubview(text)
        addSubview(revealGroup)
        dark.hoverWash = (M.hoverFill, 6)
        dark.toolTip = "Show This Site Dark"
        dark.action = { [weak self] in self?.toggleDark() }
        siteControls.hoverWash = (M.hoverFill, 6)
        siteControls.opacity = 0.6
        siteControls.hoverOpacity = 0.9
        siteControls.toolTip = "Site Control Center"
        siteControls.action = { [weak self] in
            guard let self else { return }
            self.showSiteControls(self.siteControls)
        }
        install.hoverWash = (M.hoverFill, 6)
        install.opacity = 0.6
        install.hoverOpacity = 0.9
        install.action = { [weak self] in
            guard let self else { return }
            self.installApp(self.install)
        }
        for button in [dark, siteControls, install] { revealGroup.addSubview(button) }
        if let accessory = self.accessory { addSubview(accessory) }
        extensions.hoverWash = (M.hoverFill, 6)
        extensions.opacity = 0.6
        extensions.hoverOpacity = 0.9
        extensions.toolTip = "Extensions"
        extensions.action = { [weak self] in
            guard let self else { return }
            self.showExtensions?(self.extensions)
        }
        addSubview(extensions)
        revealGroup.alphaValue = 0
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        apply(from: Model())
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func apply(from old: Model) {
        let m = model
        text.stringValue = m.text
        setAccessibilityLabel(m.text)
        if let isDark = m.isDark {
            dark.symbol = isDark ? "moon.fill" : "moon"
            dark.opacity = isDark ? 0.9 : 0.5
            dark.hoverOpacity = 0.9
            dark.toolTip = isDark ? "Show This Site Light" : "Show This Site Dark"
            dark.setAccessibilityValue(isDark ? "On" : "Off")
        }
        if let name = m.installAppName {
            install.toolTip = "Install \(name)"
            install.setAccessibilityLabel("Install \(name)")
        }
        if m.revealed != old.revealed {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = M.urlFieldButtonsFade
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                revealGroup.animator().alphaValue = m.revealed ? 1 : 0
            }
        }
        revealGroup.setAccessibilityHidden(!m.revealed)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let m = model
        fill.frame = bounds
        let h = bounds.height
        // The buttons from the right, 2pt overlapping, 4pt in from the end when there are any.
        let accessoryWidth = m.showsAccessory ? (accessory?.intrinsicContentSize.width ?? 0) : 0
        let anyButton = m.isDark != nil || m.showsSiteControls || m.installAppName != nil || m.showsExtensions || accessoryWidth > 0
        var end = bounds.width - (anyButton ? 4 : 0)
        func place(_ view: NSView, width: CGFloat, height: CGFloat, shown: Bool, in parent: NSView? = nil) {
            view.isHidden = !shown
            guard shown else { return }
            end -= width
            let frame = CGRect(x: end, y: (h - height) / 2, width: width, height: height)
            view.frame = parent.map { convert(frame, to: $0) } ?? frame
            end += 2
        }
        let size = Self.buttonSize
        place(extensions, width: size, height: size, shown: m.showsExtensions)
        if let accessory {
            let accessoryHeight = accessory.intrinsicContentSize.height
            place(accessory, width: accessoryWidth, height: max(accessoryHeight, 0), shown: accessoryWidth > 0)
        }
        revealGroup.frame = bounds
        place(install, width: size, height: size, shown: m.installAppName != nil, in: revealGroup)
        place(siteControls, width: size, height: size, shown: m.showsSiteControls, in: revealGroup)
        place(dark, width: 24, height: 24, shown: m.isDark != nil, in: revealGroup)
        let textEnd = end - 2
        let line = text.lineHeight
        let textRoom = max(textEnd - M.urlFieldTextInset, 0)
        text.place(textRect: CGRect(x: M.urlFieldTextInset, y: ((h - line) / 2).rounded(.down), width: min(text.naturalWidth, textRoom), height: line))
        textArea = CGRect(x: 0, y: 0, width: max(textEnd, 0), height: h)
    }

    /// The part of the field that opens the command bar (SwiftUI's text button).
    private var textArea: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard var view = super.hitTest(point) else { return nil }
        // The hover buttons take no clicks while they're faded out (SwiftUI's allowsHitTesting(revealed)).
        if !model.revealed, view.isDescendant(of: revealGroup) { view = self }
        if view === self || view === revealGroup {
            return textArea.contains(convert(point, from: superview)) ? self : nil
        }
        return view
    }

    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        if pressed, textArea.contains(convert(event.locationInWindow, from: nil)) { action() }
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}
