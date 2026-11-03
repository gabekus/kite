#if canImport(CEFBridge)
import AppKit
import Combine
import KiteCore
import SwiftUI

/// Pinned extension icons and the extensions button, on the right of the page toolbar,
/// as in Arc 1.169's content toolbar (measured on the Mac with the masked probe):
/// 16pt icons on a 36pt pitch, 8pt below the bar's top, then a 32×28 button 2pt below
/// the top, 12pt after the last icon. Its menu is a 262pt popover hanging from it.
@MainActor
final class ToolbarExtensionItems: NSView {
    enum Metrics {
        static let iconSize: CGFloat = 16
        static let iconPitch: CGFloat = 36
        static let buttonSize = CGSize(width: 32, height: 28)
        /// From the last icon's right edge to the button's left edge.
        static let buttonGap: CGFloat = 12
        /// From the button's right edge to Site Controls' 16pt icon (Arc: 1973 → 1985).
        static let siteControlsGap: CGFloat = 12
    }

    /// The width changed (an extension pinned or unpinned, a button hidden).
    var onSizeChange: () -> Void = {}

    private let selection: ExtensionsSelection
    private let button = SymbolButton(symbol: "puzzlepiece.extension", pointSize: 13, weight: .medium, label: "Extensions")
    private var icons: [PinnedExtensionIcon] = []
    private var selectionChange: AnyCancellable?
    private var modelChange: AnyCancellable?
    private var defaultsObserver: NSObjectProtocol?
    private var hidesPinned = false
    private var hidesButton = false
    private var updateScheduled = false

    init(selection: ExtensionsSelection) {
        self.selection = selection
        super.init(frame: .zero)
        button.opacity = 1
        button.tint = PageToolbar.Metrics.enabled
        button.toolTip = "Extensions"
        button.action = { [weak self] in
            guard let self else { return }
            ExtensionsMenu.toggle(model: self.selection.model, from: self.button)
        }
        addSubview(button)
        selectionChange = selection.$model.sink { [weak self] model in
            // objectWillChange: read the model once the change is in.
            self?.modelChange = model.objectWillChange.sink { [weak self] in self?.scheduleUpdate() }
            self?.scheduleUpdate()
        }
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

    func refresh() { selection.model.refresh() }

    private var pinned: [InstalledExtension] { hidesPinned ? [] : selection.model.pinned }

    /// Settings → Advanced → Toolbar can hide the pinned icons and the button.
    var fittingWidth: CGFloat {
        let count = CGFloat(pinned.count)
        var width = count * Metrics.iconPitch
        if !hidesButton {
            // The pinned icons' 36pt slots leave 10pt after the last icon.
            width += (count == 0 ? 0 : Metrics.buttonGap - (Metrics.iconPitch - Metrics.iconSize) / 2) + Metrics.buttonSize.width
        }
        return width
    }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.updateScheduled = false
                self?.update()
            }
        }
    }

    /// Rebuilds the icons and resizes only when the pins, the profile or the hidden buttons changed.
    private func update() {
        let defaults = UserDefaults.standard
        let hidesPinned = defaults.bool(forKey: ChromeButton.pinnedExtensions.hiddenKey)
        let hidesButton = defaults.bool(forKey: ChromeButton.extensions.hiddenKey)
        let model = selection.model
        let items = hidesPinned ? [] : model.pinned
        let iconsChanged = icons.map(\.item) != items || icons.contains { $0.model !== model }
        guard iconsChanged || hidesPinned != self.hidesPinned || hidesButton != self.hidesButton else { return }
        self.hidesPinned = hidesPinned
        self.hidesButton = hidesButton
        if iconsChanged {
            icons.forEach { $0.removeFromSuperview() }
            icons = items.map { PinnedExtensionIcon(item: $0, model: model) }
            icons.forEach { addSubview($0) }
        }
        button.isHidden = hidesButton
        needsLayout = true
        onSizeChange()
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        var x: CGFloat = 0
        for icon in icons {
            icon.frame = CGRect(x: x, y: 0, width: Metrics.iconPitch, height: h)
            x += Metrics.iconPitch
        }
        if !icons.isEmpty { x += Metrics.buttonGap - (Metrics.iconPitch - Metrics.iconSize) / 2 }
        button.frame = CGRect(x: x, y: (h - Metrics.buttonSize.height) / 2,
                              width: Metrics.buttonSize.width, height: Metrics.buttonSize.height)
    }

}

/// One pinned extension: clicking opens its popup under the icon; the right-click menu pins, turns off or removes it.
@MainActor
private final class PinnedExtensionIcon: NSView {
    let item: InstalledExtension
    let model: ExtensionsModel
    private let image = SidebarImageView()
    private var pressed = false

    init(item: InstalledExtension, model: ExtensionsModel) {
        self.item = item
        self.model = model
        super.init(frame: .zero)
        let size = ToolbarExtensionItems.Metrics.iconSize
        if let file = item.iconFile, let icon = NSImage(contentsOf: file) {
            image.imageScaling = .scaleProportionallyUpOrDown
            image.image = icon
        } else {
            image.imageScaling = .scaleNone
            image.contentTintColor = .labelColor
            image.image = symbolImage("puzzlepiece.extension", pointSize: size * 0.75, box: NSSize(width: size, height: size),
                                      placement: .center)
        }
        addSubview(image)
        toolTip = item.name
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.name)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let size = ToolbarExtensionItems.Metrics.iconSize
        image.frame = CGRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
        pressed = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        open()
    }

    override func accessibilityPerformPress() -> Bool {
        open()
        return true
    }

    private func open() {
        guard let url = item.popupURL ?? item.optionsURL else { return }
        ExtensionPopover.show(url, engine: model.engine, relativeTo: bounds, of: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? { ExtensionActions.menu(item: item, model: model) }

    override func rightMouseDown(with event: NSEvent) {
        // Through the sidebar's menu hook, so KITE_TEST_CONTEXT_MENU can read it from the background.
        showSidebarMenu(ExtensionActions.menu(item: item, model: model), with: event, for: self)
    }
}

/// The extensions popover: every extension as a tile (click opens its popup; the
/// right-click menu pins, turns off or removes it), as in Arc's: 13pt inset, a section
/// header, then 48×32 tiles in four columns on a 56 × 40 pitch, pinned ones badged.
struct ExtensionsMenu: View {
    @ObservedObject var model: ExtensionsModel
    let dismiss: () -> Void

    enum Metrics {
        static let width: CGFloat = 262
        static let inset: CGFloat = 13
        static let tileSize = CGSize(width: 48, height: 32)
        static let columnPitch: CGFloat = 56
        static let rowPitch: CGFloat = 40
        static let badgeSize: CGFloat = 14
        static let iconSize: CGFloat = 20
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Extensions")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.extensions.isEmpty {
                Text("Extensions you add from the Chrome Web Store show up here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(Metrics.tileSize.width), spacing: Metrics.columnPitch - Metrics.tileSize.width,
                                                       alignment: .leading), count: 4),
                    alignment: .leading,
                    spacing: Metrics.rowPitch - Metrics.tileSize.height
                ) {
                    ForEach(model.extensions) { item in
                        ExtensionTile(item: item, model: model, dismiss: dismiss)
                    }
                }
            }
            Button("Chrome Web Store") {
                if let url = URL(string: "https://chromewebstore.google.com/") {
                    NSApp.sendAction(#selector(AppDelegate.openURLFromExtensionsMenu(_:)), to: nil, from: url as NSURL)
                }
                dismiss()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(Metrics.inset)
        .frame(width: Metrics.width, alignment: .leading)
    }
}

private struct ExtensionTile: View {
    let item: InstalledExtension
    let model: ExtensionsModel
    let dismiss: () -> Void
    @State private var anchor: NSView?
    @State private var hovering = false

    var body: some View {
        Button { open() } label: {
            ExtensionIcon(file: item.iconFile, size: ExtensionsMenu.Metrics.iconSize)
                .opacity(item.enabled ? 1 : 0.35)
                .frame(width: ExtensionsMenu.Metrics.tileSize.width, height: ExtensionsMenu.Metrics.tileSize.height)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hovering ? 0.1 : 0.05)))
                .background(AnchorView(view: $anchor))
                .overlay(alignment: .bottomTrailing) {
                    if model.isPinned(item.id) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 7, weight: .semibold))
                            .frame(width: ExtensionsMenu.Metrics.badgeSize, height: ExtensionsMenu.Metrics.badgeSize)
                            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                            // Arc's badge sits at the tile's (37, 21): 3pt in from its right and bottom.
                            .offset(x: -3, y: -(ExtensionsMenu.Metrics.tileSize.height - 21 - ExtensionsMenu.Metrics.badgeSize))
                            .accessibilityLabel("Pinned")
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.enabled ? item.name : "\(item.name) (off)")
        .accessibilityLabel(item.name)
        .contextMenu { ExtensionActions(item: item, model: model) }
    }

    private func open() {
        guard item.enabled, let anchor, let url = item.popupURL ?? item.optionsURL else { return }
        dismiss()
        ExtensionPopover.show(url, engine: model.engine, relativeTo: anchor.bounds, of: anchor)
    }
}

/// Pin, turn on or off, options and remove: the tile's and pinned icon's right-click menu.
private struct ExtensionActions: View {
    /// The same items as an `NSMenu`, for the toolbar's pinned icons.
    @MainActor static func menu(item: InstalledExtension, model: ExtensionsModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let pinned = model.isPinned(item.id)
        menu.add(pinned ? "Unpin" : "Pin to Toolbar", enabled: item.enabled || pinned) { model.setPinned(item.id, !pinned) }
        menu.add(item.enabled ? "Turn Off" : "Turn On", enabled: item.mayDisable) { model.setEnabled(item.id, !item.enabled) }
        if let options = item.optionsURL {
            menu.add("Options") {
                NSApp.sendAction(#selector(AppDelegate.openURLFromExtensionsMenu(_:)), to: nil, from: options as NSURL)
            }
        }
        menu.addSeparator()
        menu.add("Remove…") { model.remove(item.id) }
        return menu
    }

    let item: InstalledExtension
    let model: ExtensionsModel

    var body: some View {
        Button(model.isPinned(item.id) ? "Unpin" : "Pin to Toolbar") { model.setPinned(item.id, !model.isPinned(item.id)) }
            .disabled(!item.enabled && !model.isPinned(item.id))
        Button(item.enabled ? "Turn Off" : "Turn On") { model.setEnabled(item.id, !item.enabled) }
            .disabled(!item.mayDisable)
        if let options = item.optionsURL {
            Button("Options") {
                NSApp.sendAction(#selector(AppDelegate.openURLFromExtensionsMenu(_:)), to: nil, from: options as NSURL)
            }
        }
        Divider()
        Button("Remove…") { model.remove(item.id) }
    }
}

/// An extension's icon from its folder, or a puzzle piece.
private struct ExtensionIcon: View {
    let file: URL?
    let size: CGFloat

    var body: some View {
        if let file, let image = NSImage(contentsOf: file) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: "puzzlepiece.extension").font(.system(size: size * 0.75)).frame(width: size, height: size)
        }
    }
}

/// The password manager's key in the sidebar's address field (1Password or Bitwarden,
/// chosen in Settings): part of Kite, always shown while it's installed and on. Sized like
/// Arc's buttons at the field's right end (30pt). Without the password manager in this profile
/// (each profile has its own extensions), the key adds it. No size while there's neither.
@MainActor
final class PasswordManagerFieldButton: NSView {
    /// Set by the password manager integration to open it its own way, given the popup
    /// its manifest names; returns false to fall back to ExtensionPopover.
    static var open: ((NSView, URL?) -> Bool)?

    private let button = SymbolButton(symbol: "key.fill", pointSize: 11, weight: .semibold)
    private let selection: ExtensionsSelection
    private var selectionChange: AnyCancellable?
    private var modelChange: AnyCancellable?
    private var isShown = false

    init(selection: ExtensionsSelection) {
        self.selection = selection
        super.init(frame: .zero)
        button.hoverWash = (0.1, 6)
        // SwiftUI's `Color.primary.opacity(0.1)`: the label colour (alpha 216/255) at a tenth.
        button.hoverWashFill = { dark in (dark ? NSColor.white : NSColor.black).withAlphaComponent(216.0 / 255 / 10) }
        button.opacity = 0.6
        button.hoverOpacity = 0.9
        button.action = { [weak self] in self?.press() }
        addSubview(button)
        selectionChange = selection.$model.sink { [weak self] model in
            self?.modelChange = model.objectWillChange.sink { [weak self] in
                // objectWillChange: read the model once the change is in.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }
        }
        update()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { isShown ? NSSize(width: 30, height: 30) : .zero }

    override func layout() {
        super.layout()
        button.frame = bounds
    }

    private func update() {
        let model = selection.model
        let label: String? = if let manager = model.passwordManager {
            manager.name
        } else if PasswordManagerIntegration.canInstall(in: model.engine) {
            "Add \(PasswordManagerIntegration.current.name) to this profile"
        } else {
            nil
        }
        button.toolTip = label
        button.setAccessibilityLabel(label)
        guard (label != nil) != isShown else { return }
        isShown = label != nil
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }

    private func press() {
        let model = selection.model
        if UIDiagnostics.enabledByEnvironment {
            // A test profile's run neither opens the password manager nor installs it; the log says which it would do.
            let name = model.passwordManager?.name ?? PasswordManagerIntegration.current.name
            NSLog("Kite: diagnostics: the password manager key would %@ %@", model.passwordManager == nil ? "add" : "open", name)
            return
        }
        guard let manager = model.passwordManager else {
            if PasswordManagerIntegration.canInstall(in: model.engine) { PasswordManagerIntegration.install(in: model.engine) }
            return
        }
        if Self.open?(button, manager.popupURL) == true { return }
        if let popup = manager.popupURL {
            ExtensionPopover.show(popup, engine: model.engine, relativeTo: button.bounds, of: button)
        }
    }
}

extension ExtensionsMenu {
    private static weak var shown: NSPopover?
    private static weak var shownAnchor: NSView?
    /// A transient popover closes on the mouse-down on its own button, before the button acts: that click
    /// mustn't open it again.
    private static var closed: (anchor: ObjectIdentifier, at: Date)?

    /// The extensions popover hanging from `view`, from places that aren't SwiftUI
    /// popovers already (the sidebar's address field, the toolbar, the menu bar).
    static func present(model: ExtensionsModel, from view: NSView, rect: NSRect? = nil) {
        shown?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ExtensionsMenu(model: model) { [weak popover] in popover?.close() })
        let anchor = ObjectIdentifier(view)
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover, queue: .main) { _ in
            MainActor.assumeIsolated {
                closed = (anchor, Date())
                if let token { NotificationCenter.default.removeObserver(token) }
            }
        }
        popover.show(relativeTo: rect ?? view.bounds, of: view, preferredEdge: ExtensionPopover.belowEdge(of: view))
        shown = popover
        shownAnchor = view
        model.refresh()
    }

    /// The toolbar's button: opens the popover, or closes it when it hangs from this button.
    static func toggle(model: ExtensionsModel, from view: NSView) {
        if let shown, shown.isShown, shownAnchor === view { return shown.close() }
        if let closed, closed.anchor == ObjectIdentifier(view), Date().timeIntervalSince(closed.at) < 0.3 { return }
        present(model: model, from: view)
    }
}
#endif
