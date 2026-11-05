import AppKit
import KiteCore
import Observation

/// What Site Controls shows for the current page, read from the window when it opens and
/// again after every change. Nil rows are ones this engine or build can't offer.
@MainActor
@Observable
final class SiteControlsModel {
    struct Actions {
        var copyURL: () -> Void
        var share: (NSView) -> Void
        var toggleAdblock: () -> Void
        var clearCache: () -> Void
        var clearCookies: () -> Void
        var setPermission: (SitePermission, SitePermissionValue) -> Void
        var removeMailHandler: () -> Void
        var toggleDeveloperMode: () -> Void
        /// "All Site Settings…" and the Settings header: the site's settings page in a new tab.
        var openSiteSettings: () -> Void
        /// New Boost (the action button and the footer item): a Boost for this site, in its editor.
        var newBoost: () -> Void
        /// A Boost row's edit button: that Boost in its editor.
        var editBoost: (UUID) -> Void
        var setBoostEnabled: (UUID, Bool) -> Void
        /// The Boosts header and "Manage Boosts…": Window › View Boosts….
        var manageBoosts: () -> Void
        /// The capture buttons: File › Capture…, Capture Full Page and Capture in Portrait Mode.
        var capture: () -> Void = {}
        var captureFullPage: () -> Void = {}
        var capturePortraitMode: () -> Void = {}
        /// An extension tile: the extension's popup (or options page).
        var openExtension: (InstalledExtension) -> Void = { _ in }
        var setExtensionPinned: (String, Bool) -> Void = { _, _ in }
        var setExtensionEnabled: (String, Bool) -> Void = { _, _ in }
        var openExtensionOptions: (InstalledExtension) -> Void = { _ in }
        var removeExtension: (String) -> Void = { _ in }
        /// The Extensions header and "Manage Extensions…": Kite's extensions popover.
        var manageExtensions: () -> Void = {}
        /// The plus tile and "Add Extension…": the Chrome Web Store in a new tab.
        var addExtension: () -> Void = {}
    }

    let url: URL
    var blocksAds: Bool?
    /// True while this site is the default mail app (MailHandlers); nil hides the row.
    var isMailHandler: Bool?
    /// The site's Developer Mode switch (View › Developer, ⌃D).
    var isInDeveloperMode = false
    /// Nil on WebKit, which keeps no per-site permissions Kite can read.
    var permissions: [SitePermission: SitePermissionValue]?
    /// This site's Boosts; nil where Boosts can't run (incognito, or a page with no domain).
    var boosts: [Boost]?
    /// Arc's `captureEnabled`: the capture buttons show while the page can be captured.
    var captureEnabled = false
    /// ⌥ is held: Capture Full Page's button becomes Capture in Portrait Mode (Arc's `_optionKeyDown`).
    var optionKeyDown = false
    /// The extensions the tiles show, in Kite's order; nil where extensions don't run (WebKit,
    /// no Chromium build). Arc hides the section when there are none.
    var extensions: [InstalledExtension]?
    var pinnedExtensionIDs: [String] = []
    /// The action row, as Arc builds it (`SiteControls.actions`).
    var actionList: [SiteControlsAction] {
        SiteControls.actions(boostsEnabled: boosts != nil, captureEnabled: captureEnabled, optionKeyDown: optionKeyDown)
    }
    @ObservationIgnored var subscriptions: [Any] = []
    @ObservationIgnored var actions: Actions
    @ObservationIgnored var read: (SiteControlsModel) -> Void
    @ObservationIgnored var dismiss: () -> Void = {}

    init(url: URL, actions: Actions, read: @escaping (SiteControlsModel) -> Void) {
        self.url = url
        self.actions = actions
        self.read = read
        read(self)
    }

    func refresh() { read(self) }

    /// Runs a change, then re-reads the page so the rows show it.
    func perform(_ change: () -> Void) {
        change()
        refresh()
    }
}

/// Arc 1.169's Site Control Center, from its binary and the masked probe (docs/arc-visual-spec.md):
/// a 262pt popover; a row of 48.75×32.75 action buttons; a "Settings" section of 208×33 rows
/// (icon, title, and an On/Off or Allowed/Blocked subtitle; a click flips it) on a 43pt pitch;
/// and a footer with the 82×32 security button on the left and a 32×32 "…" menu (Clear Cache,
/// Clear Cookies, Manage Boosts… / New Boost…, All Site Settings…) on the right. Between the
/// actions and Settings, the Boosts section lists the site's Boosts (Enabled / Disabled), then the
/// Extensions section tiles the extensions (pin buttons, a plus tile to add one). The action row
/// is Arc's: Share, New Boost or Copy URL, Capture, Capture Full Page (⌥: Portrait Mode).
///
/// Laid out as the SwiftUI view it replaces was: each frame from the running total of the sizes and
/// gaps above it, rounded to the pixel grid. It's rebuilt when the model changes (a click on a row),
/// keeping the hover under the pointer.
final class SiteControlsView: SidebarFlippedView {
    let model: SiteControlsModel
    /// The content's height, unrounded (the popover's content size).
    private(set) var contentHeight: CGFloat = 0
    var onSizeChange: (() -> Void)?
    private var generation = 0
    /// The controls the last rebuild made, by what each shows.
    private var controls: [String: NSView] = [:]

    enum Metrics {
        static let popoverWidth: CGFloat = 262
        /// The content sits 13pt inside the popover's frame; sections another 10pt in.
        static let popoverInset: CGFloat = 13
        static let inset: CGFloat = 10
        static var width: CGFloat { popoverWidth - 2 * popoverInset }
        static let actionSize = CGSize(width: 48.75, height: 32.75)
        static let actionPitch: CGFloat = 56
        static let headerHeight: CGFloat = 17
        static let sectionGap: CGFloat = 9.65
        static let headerToRows: CGFloat = 10
        static let rowSize = CGSize(width: 208, height: 33)
        static let rowPitch: CGFloat = 43
        static let rowsToFooter: CGFloat = 26
        static let securitySize = CGSize(width: 82, height: 32)
        static let menuSize: CGFloat = 32
        /// Extension tiles (probe, 25 Oct 2026): 48×32 in four columns on a 56 × 40 pitch, the next
        /// header 15 below the last row; the pin button 14×14 at the tile's (37, 21), past its corner.
        static let tileSize = CGSize(width: 48, height: 32)
        static let tilePitch = CGSize(width: 56, height: 40)
        static let tilesToNext: CGFloat = 15
        static let pinSize: CGFloat = 14
        static let pinOrigin = CGPoint(x: 37, y: 21)
        /// The rows' leading edge, centring them in the section.
        static var rowX: CGFloat { inset + (width - 2 * inset - rowSize.width) / 2 }
    }

    init(model: SiteControlsModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.width, height: 0))
        observe(generation)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A closed popover stops following the model; shown again, it picks up from there.
        guard window != nil else {
            generation += 1
            observing = false
            return
        }
        if !observing { observe(generation) }
        window?.recalculateKeyViewLoop()
        restoreHover()
    }

    /// What the controls show. The window re-reads every property after each change, so a rebuild waits for a change
    /// to what the controls show.
    private struct Shown: Equatable {
        var blocksAds: Bool?
        var isMailHandler: Bool?
        var isInDeveloperMode: Bool
        var permissions: [SitePermission: SitePermissionValue]?
        var boosts: [Boost]?
        var captureEnabled: Bool
        var optionKeyDown: Bool
        var extensions: [InstalledExtension]?
        var pinnedExtensionIDs: [String]
    }
    private var shown: Shown?
    private var observing = false

    /// Re-renders whenever something the model shows changes.
    private func observe(_ generation: Int) {
        guard generation == self.generation else { return }
        observing = true
        withObservationTracking {
            let now = Shown(blocksAds: model.blocksAds, isMailHandler: model.isMailHandler, isInDeveloperMode: model.isInDeveloperMode,
                            permissions: model.permissions, boosts: model.boosts, captureEnabled: model.captureEnabled,
                            optionKeyDown: model.optionKeyDown, extensions: model.extensions, pinnedExtensionIDs: model.pinnedExtensionIDs)
            if now != shown {
                shown = now
                rebuild()
            }
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.observe(generation) } }
        }
    }

    private func perform(_ action: SiteControlsAction, from view: NSView) {
        switch action {
        case .share: model.actions.share(view)
        case .copyURL: model.actions.copyURL()
        case .newBoost: model.actions.newBoost()
        case .capture: model.actions.capture()
        case .captureFullPage: model.actions.captureFullPage()
        case .capturePortraitMode: model.actions.capturePortraitMode()
        }
    }

    // MARK: Layout

    private func rebuild() {
        // A keyboard press can rebuild the controls; when the focused one is made again, the new one in its place
        // takes the focus.
        let focusedFrame = (window?.firstResponder as? NSView).flatMap { responder in
            subviews.first { responder === $0 || responder.isDescendant(of: $0) }?.frame
        }
        defer {
            if let focusedFrame, (window?.firstResponder as? NSView)?.isDescendant(of: self) != true,
               let replacement = subviews.first(where: { $0.canBecomeKeyView && $0.frame.contains(NSPoint(x: focusedFrame.midX, y: focusedFrame.midY)) }) {
                window?.makeFirstResponder(replacement)
            }
            window?.recalculateKeyViewLoop()
        }
        // A control that's still there keeps its view, found by what it shows (a click that flips a row changes only
        // that row): making them all again costs more than SwiftUI's diff did. Its closures are set again below.
        var reusable = controls
        var built: [String: NSView] = [:]
        func reuse<V: NSView>(_ key: String, _ make: () -> V) -> V {
            assert(built[key] == nil, "two Site Controls controls share the key \(key)")
            let view = reusable.removeValue(forKey: key) as? V ?? make()
            built[key] = view
            return view
        }
        defer {
            // Whatever wasn't built this time goes, whatever the keys did.
            let kept = Set(built.values.map(ObjectIdentifier.init))
            subviews.filter { !kept.contains(ObjectIdentifier($0)) }.forEach { $0.removeFromSuperview() }
            controls = built
        }
        func makeRow(key: String, symbol: String, title: String, subtitle: String, isOn: Bool, trailingPadding: CGFloat = 0) -> SiteControlsRow {
            let row = reuse(key) {
                SiteControlsRow(symbol: symbol, title: title, subtitle: subtitle, isOn: isOn, trailingPadding: trailingPadding)
            }
            row.subtitle = subtitle
            row.isOn = isOn
            row.contextMenu = nil
            return row
        }
        let model = model
        typealias M = Metrics
        var y = M.inset

        for (index, action) in model.actionList.enumerated() {
            let button = reuse("action|\(index)|\(action)") {
                SiteControlsTile(symbol: action.symbol, pointSize: 14, weight: .medium, title: action.title)
            }
            button.action = { [weak self, weak button] in
                guard let self, let button else { return }
                if action.dismissesPopover { self.model.dismiss() }
                self.perform(action, from: button)
            }
            add(button, CGRect(x: M.inset + CGFloat(index) * M.actionPitch, y: y, width: M.actionSize.width, height: M.actionSize.height))
        }
        y += M.actionSize.height + M.sectionGap

        if let boosts = model.boosts, !boosts.isEmpty {
            y = addHeader(SiteControls.boostsTitle, hoverText: SiteControls.boostsHoverText, hint: SiteControls.manageBoostsMenuTitle, y: y,
                          reuse: reuse) {
                model.dismiss(); model.actions.manageBoosts()
            }
            for (index, boost) in boosts.enumerated() {
                if index > 0 { y += M.rowPitch - M.rowSize.height }
                let row = makeRow(key: "boost|\(boost.id)|\(boost.name)", symbol: "wand.and.stars", title: boost.name, subtitle: SiteControls.boostSubtitle(boost.isEnabled),
                                          isOn: boost.isEnabled, trailingPadding: 32)
                row.action = { model.perform { model.actions.setBoostEnabled(boost.id, !boost.isEnabled) } }
                row.edit = { model.dismiss(); model.actions.editBoost(boost.id) }
                add(row, CGRect(x: M.rowX, y: y, width: M.rowSize.width, height: M.rowSize.height))
                y += M.rowSize.height
            }
            y += M.sectionGap
        }

        if let extensions = model.extensions, !extensions.isEmpty {
            y = addHeader(SiteControls.extensionsTitle, hoverText: SiteControls.extensionsHoverText, hint: SiteControls.manageExtensionsMenuTitle,
                          y: y, reuse: reuse) {
                model.dismiss(); model.actions.manageExtensions()
            }
            var tiles: [SiteControlsTile] = extensions.map { item in
                let pinned = model.pinnedExtensionIDs.contains(item.id)
                let tile = reuse("extension|\(item.id)|\(item.name)|\(item.iconFile?.path ?? "")|\(pinned)") {
                    SiteControlsTile(image: Self.extensionIcon(item.iconFile), title: item.name)
                }
                tile.action = { model.dismiss(); model.actions.openExtension(item) }
                tile.pin = (pinned, { model.perform { model.actions.setExtensionPinned(item.id, !pinned) } })
                tile.contextMenu = { Self.extensionMenu(item, pinned: pinned, model: model) }
                return tile
            }
            let add = reuse("addExtension") {
                SiteControlsTile(symbol: "plus", pointSize: 13, weight: .semibold, title: SiteControls.addExtensionTitle)
            }
            add.action = { model.dismiss(); model.actions.addExtension() }
            tiles.append(add)
            for (index, tile) in tiles.enumerated() {
                let column = index % 4, row = index / 4
                self.add(tile, CGRect(x: M.inset + CGFloat(column) * M.tilePitch.width, y: y + CGFloat(row) * M.tilePitch.height,
                                      width: M.tileSize.width, height: M.tileSize.height))
            }
            let rows = (tiles.count + 3) / 4
            y += CGFloat(rows) * M.tileSize.height + CGFloat(rows - 1) * (M.tilePitch.height - M.tileSize.height) + M.tilesToNext
        }

        y = addHeader(SiteControls.settingsTitle, hoverText: SiteControls.settingsHoverText, hint: SiteControls.allSiteSettingsTitle, y: y, reuse: reuse) {
            model.dismiss(); model.actions.openSiteSettings()
        }
        var rows: [SiteControlsRow] = []
        if let blocksAds = model.blocksAds {
            let row = makeRow(key: "adblock", symbol: "shield.fill", title: SiteControls.adblockTitle, subtitle: SiteControls.onOff(blocksAds), isOn: blocksAds)
            row.action = { model.perform(model.actions.toggleAdblock) }
            rows.append(row)
        }
        let developer = makeRow(key: "developer", symbol: "hammer.fill", title: SiteControls.developerModeTitle,
                                        subtitle: SiteControls.onOff(model.isInDeveloperMode), isOn: model.isInDeveloperMode)
        developer.action = { model.perform(model.actions.toggleDeveloperMode) }
        rows.append(developer)
        if model.isMailHandler == true {
            let row = makeRow(key: "mail", symbol: "envelope.fill", title: "Default Mail App", subtitle: SiteControls.onOff(true), isOn: true)
            row.action = { model.perform(model.actions.removeMailHandler) }
            rows.append(row)
        }
        if let permissions = model.permissions {
            for permission in SitePermission.allCases {
                let value = permissions[permission] ?? .ask
                let row = makeRow(key: "permission|\(permission.rawValue)", symbol: permission.symbol, title: permission.title, subtitle: value.subtitle, isOn: value == .allow)
                row.action = { model.perform { model.actions.setPermission(permission, value.toggled) } }
                row.contextMenu = {
                    let menu = NSMenu()
                    menu.add("Allow") { model.perform { model.actions.setPermission(permission, .allow) } }
                    menu.add("Block") { model.perform { model.actions.setPermission(permission, .block) } }
                    menu.add("Ask (Default)") { model.perform { model.actions.setPermission(permission, .ask) } }
                    return menu
                }
                rows.append(row)
            }
        }
        for (index, row) in rows.enumerated() {
            if index > 0 { y += M.rowPitch - M.rowSize.height }
            add(row, CGRect(x: M.rowX, y: y, width: M.rowSize.width, height: M.rowSize.height))
            y += M.rowSize.height
        }
        if model.permissions == nil {
            if !rows.isEmpty { y += M.rowPitch - M.rowSize.height }
            let note: SiteControlsLabel = reuse("note") {
                let note = SiteControlsLabel(size: 11, weight: .regular, secondary: true)
                note.stringValue = "Camera, microphone, location and notification permissions need the Chromium engine."
                note.wraps = true
                return note
            }
            let height = note.height(forWidth: M.rowSize.width)
            note.place(textRect: CGRect(x: M.rowX, y: y, width: M.rowSize.width, height: height))
            if note.superview !== self { addSubview(note) }
            y += height
        }

        y += M.rowsToFooter
        let securityTitle = SiteControls.securityTitle(for: model.url) ?? ""
        let security = reuse("security|\(securityTitle)") { SiteControlsSecurity(title: securityTitle) }
        add(security, CGRect(x: M.inset, y: y, width: M.securitySize.width, height: M.securitySize.height))
        let more = reuse("more") { SiteControlsTile(symbol: "ellipsis", pointSize: 13, weight: .semibold, title: "More") }
        more.deepensOnHover = false
        more.pressesOnMouseDown = true
        more.action = { [weak self, weak more] in
            guard let self, let more else { return }
            self.showFooterMenu(from: more)
        }
        add(more, CGRect(x: M.width - M.inset - M.menuSize, y: y, width: M.menuSize, height: M.menuSize))
        y += M.securitySize.height + M.inset

        let height = y
        if height != contentHeight {
            contentHeight = height
            setFrameSize(NSSize(width: M.width, height: height.pixelRounded))
            onSizeChange?()
        }
        restoreHover()
    }

    /// A section header at `y`; returns where its rows start.
    private func addHeader(_ title: String, hoverText: String, hint: String, y: CGFloat,
                           reuse: (String, () -> SiteControlsHeader) -> SiteControlsHeader, action: @escaping () -> Void) -> CGFloat {
        let header = reuse("header|\(title)") { SiteControlsHeader(title: title, hoverText: hoverText, hint: hint) }
        header.action = action
        add(header, CGRect(x: Metrics.inset, y: y, width: Metrics.width - 2 * Metrics.inset, height: Metrics.headerHeight))
        return y + Metrics.headerHeight + Metrics.headerToRows
    }

    private func add(_ view: NSView, _ rect: CGRect) {
        view.frame = rect.pixelRounded
        (view as? SiteControlsPlaced)?.exactY = rect.minY
        // A reused row stays where it is: adding it again would take it out first, and its focus with it.
        if view.superview !== self { addSubview(view) }
    }

    /// After a rebuild the new controls don't know the pointer is already over one of them.
    private func restoreHover() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        for case let control as SiteControlsControl in subviews {
            control.setHovered(control.frame.contains(point))
        }
    }

    // MARK: Menus

    /// The footer's "…": Arc's menu has Clear Cache, Clear Cookies, Manage Boosts…, New Boost… (only
    /// some of the time: `includeBoostsInContextMenu`), the extensions items, and All Site Settings…
    /// last. Clear Cache and Clear Cookies are Kite's clear-and-refresh, as in the View menu.
    private var footerItems: [(title: String, run: () -> Void)] {
        let actions = model.actions
        var items: [(title: String, run: () -> Void)] = [("Clear Cache", actions.clearCache), ("Clear Cookies", actions.clearCookies)]
        if SiteControls.includesBoostsInMenu(siteBoostCount: model.boosts?.count ?? 0, boostsAvailable: model.boosts != nil) {
            items += [(SiteControls.manageBoostsMenuTitle, actions.manageBoosts), (SiteControls.newBoostMenuTitle, actions.newBoost)]
        }
        if model.extensions != nil {
            items += [(SiteControls.manageExtensionsMenuTitle, actions.manageExtensions),
                      (SiteControls.addExtensionMenuTitle, actions.addExtension)]
        }
        items.append((SiteControls.allSiteSettingsTitle, actions.openSiteSettings))
        return items
    }

    private func showFooterMenu(from button: NSView) {
        let items = footerItems
        let model = model
        // KITE_TEST_CONTEXT_MENU: a menu is modal and can't be read from the background, so a click logs the
        // items (and runs the one the test picked) instead of opening it.
        if PageContextMenuItems.testMode != nil {
            guard let index = PageContextMenuItems.logForTest(items.map { ($0.title, true) }) else { return }
            model.dismiss()
            return items[index].run()
        }
        let menu = NSMenu()
        for item in items {
            menu.add(item.title) { model.dismiss(); item.run() }
        }
        // A pull-down below the button, as SwiftUI's button-style Menu opens. The 4pt gap is the draft's estimate: a menu is
        // modal and can't be captured headlessly, so its position against main's isn't measured.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private static func extensionMenu(_ item: InstalledExtension, pinned: Bool, model: SiteControlsModel) -> NSMenu {
        let menu = NSMenu()
        menu.add(pinned ? "Unpin" : "Pin to Toolbar") { model.perform { model.actions.setExtensionPinned(item.id, !pinned) } }
        menu.add("Turn Off", enabled: item.mayDisable) { model.perform { model.actions.setExtensionEnabled(item.id, false) } }
        if item.optionsURL != nil {
            menu.add("Options") { model.dismiss(); model.actions.openExtensionOptions(item) }
        }
        menu.addItem(.separator())
        menu.add("Remove…") { model.dismiss(); model.actions.removeExtension(item.id) }
        return menu
    }

    /// An extension's icon from its folder at 20pt, or a puzzle piece.
    private static func extensionIcon(_ file: URL?) -> NSImage? {
        let box = NSSize(width: 20, height: 20)
        if let file, let image = NSImage(contentsOf: file) {
            let out = NSImage(size: box, flipped: false) { rect in
                NSGraphicsContext.current?.imageInterpolation = .high
                image.draw(in: rect)
                return true
            }
            return out
        }
        return symbolImage("puzzlepiece.extension", pointSize: 15, box: box, placement: .center)
    }
}

private extension CGFloat {
    /// Rounded to the 2x pixel grid as SwiftUI rounds a frame (halves up).
    var pixelRounded: CGFloat { (self * 2).rounded(.toNearestOrAwayFromZero) / 2 }
}

private extension CGRect {
    /// Edges rounded to the pixel grid, as SwiftUI places a view.
    var pixelRounded: CGRect {
        let x0 = minX.pixelRounded, y0 = minY.pixelRounded
        return CGRect(x: x0, y: y0, width: maxX.pixelRounded - x0, height: maxY.pixelRounded - y0)
    }
}

/// `Color.primary.opacity(alpha)`: white over dark, black over light.
private func primaryFill(_ alpha: Double) -> (Bool) -> NSColor {
    { dark in (dark ? NSColor.white : NSColor.black).withAlphaComponent(alpha) }
}

/// A view that knows its unrounded top (SwiftUI rounds each piece from its exact position, not from its
/// rounded container's).
private protocol SiteControlsPlaced: AnyObject {
    var exactY: CGFloat { get set }
}

/// The height SwiftUI centres a symbol by: its glyph's content height, in half points. NSImage reports it rounded up to
/// the whole point, with the extra at the image's top. Read from CoreUI's vector glyphs (`contentBounds`, macOS 15.6)
/// for the symbols Site Controls places this way; others fall back to the image's height.
private struct SymbolKey: Hashable {
    let name: String
    let pointSize: CGFloat
    let weight: NSFont.Weight
}

private let symbolContentHeights: [SymbolKey: CGFloat] = {
    let semibold11: [String: CGFloat] = [
        "shield.fill": 13, "hammer.fill": 15.5, "envelope.fill": 12, "video.fill": 11, "mic.fill": 14.5,
        "location.fill": 13.5, "bell.fill": 14, "wand.and.stars": 13.5, "pencil": 11.5, "lock.fill": 13, "lock.slash.fill": 14.5,
    ]
    var heights = Dictionary(uniqueKeysWithValues: semibold11.map { (SymbolKey(name: $0.key, pointSize: 11, weight: .semibold), $0.value) })
    heights[SymbolKey(name: "pin.fill", pointSize: 8, weight: .black)] = 11.5
    return heights
}()

/// A symbol centred in `box` as SwiftUI draws one in a fixed frame whose unrounded top is `exactTop`: across, its glyph
/// box centred and rounded up to the half point; down, its content height centred and rounded to the half point from
/// its exact position (checked on every Settings row, in the default layout and below Boosts and extensions).
/// nil when there's no such symbol.
@MainActor private func symbolImage(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, box: NSSize,
                                    exactTop: CGFloat) -> NSImage? {
    guard let symbol = rawSymbol(name, pointSize: pointSize, weight: weight) else { return nil }
    let size = symbol.size
    var align = symbol.alignmentRect
    if align.isEmpty { align = NSRect(origin: .zero, size: size) }
    let x = ((box.width - align.width) / 2 * 2).rounded(.up) / 2 - align.minX
    let measured = symbolContentHeights[SymbolKey(name: name, pointSize: pointSize, weight: weight)]
    assert(measured != nil, "\(name) at \(pointSize)pt has no content height: measure it (see symbolContentHeights)")
    let content = measured ?? size.height
    let top = (exactTop + (box.height - content) / 2).pixelRounded - exactTop.pixelRounded - (size.height - content)
    // Drawn once per placement: a rebuild lays every control out again.
    let key = "\(name)|\(pointSize)|\(weight.rawValue)|\(box.width)x\(box.height)|\(x),\(top)"
    if let cached = placedSymbolImages[key] { return cached }
    let out = NSImage(size: box, flipped: false) { _ in
        symbol.draw(in: NSRect(x: x, y: box.height - top - size.height, width: size.width, height: size.height))
        return true
    }
    out.isTemplate = true
    placedSymbolImages[key] = out
    return out
}

@MainActor private var placedSymbolImages: [String: NSImage] = [:]

/// Text in Site Controls: one line cut off at the end (or wrapped), primary or secondary. Secondary text
/// is vibrant, as SwiftUI's `.secondary` is over the popover's material.
final class SiteControlsLabel: NSTextField {
    private let secondary: Bool
    var wraps = false {
        didSet {
            lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
            maximumNumberOfLines = wraps ? 0 : 1
            cell?.wraps = wraps
        }
    }

    init(size: CGFloat, weight: NSFont.Weight, secondary: Bool) {
        self.secondary = secondary
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = .systemFont(ofSize: size, weight: weight)
        textColor = secondary ? .secondaryLabelColor : .labelColor
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        cell?.truncatesLastVisibleLine = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var allowsVibrancy: Bool { secondary }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    /// SwiftUI's line height for this font: ascent plus descent plus leading, rounded up.
    var lineHeight: CGFloat {
        guard let font else { return 15 }
        return ceil(font.ascender - font.descender + font.leading)
    }

    /// The height SwiftUI gives a line in a VStack of lines: the ascent and the descent, each rounded up.
    var stackedLineHeight: CGFloat {
        guard let font else { return 15 }
        return ceil(font.ascender) + ceil(-font.descender)
    }

    var naturalWidth: CGFloat { ceil(attributedStringValue.size().width) }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard wraps else { return lineHeight }
        let bounds = attributedStringValue.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                        options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(bounds.height)
    }

    /// Lays the label out with its text box (not the cell) at `rect`: the cell draws 2pt in from each side.
    func place(textRect rect: CGRect) {
        frame = rect.insetBy(dx: -SidebarLabel.cellInset, dy: 0)
    }
}

/// A symbol in Site Controls, placed as SwiftUI's `Image(systemName:)` in its frame; vibrant while secondary.
private final class SiteControlsSymbol: NSImageView {
    var vibrant = false

    override var allowsVibrancy: Bool { vibrant }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ symbol: String, pointSize: CGFloat, weight: NSFont.Weight, tint: NSColor) {
        imageScaling = .scaleNone
        image = symbolImage(symbol, pointSize: pointSize, weight: weight, box: bounds.size, placement: .center)
        contentTintColor = tint
    }

    /// As SwiftUI places it in a frame whose unrounded top is `exactTop`.
    func show(_ symbol: String, pointSize: CGFloat, weight: NSFont.Weight, tint: NSColor, exactTop: CGFloat) {
        imageScaling = .scaleNone
        let placed = symbolImage(symbol, pointSize: pointSize, weight: weight, box: bounds.size, exactTop: exactTop)
        if image !== placed { image = placed }
        if contentTintColor != tint { contentTintColor = tint }
    }
}

/// The base of Site Controls' buttons (SwiftUI's `.buttonStyle(.plain)` buttons): a press runs `action`,
/// the pointer over it sets `isHovered`, a right-click shows `contextMenu`.
class SiteControlsControl: SidebarFlippedView, SiteControlsPlaced {
    var action: () -> Void = {}
    var exactY: CGFloat = 0 { didSet { if exactY != oldValue { needsLayout = true } } }
    var contextMenu: (() -> NSMenu)?
    /// Runs on mouse-down (a Menu's button), not on release.
    var pressesOnMouseDown = false
    private(set) var isHovered = false
    private var tracking: NSTrackingArea?
    private var pressed = false

    init(title: String) {
        super.init(frame: .zero)
        toolTip = title
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Keyboard navigation (System Settings › Keyboard navigation), as SwiftUI's buttons take it: Tab moves
    // between the controls, Space presses the focused one (once, not on key repeat), and a focus ring follows its wash.
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var focusRingMaskBounds: NSRect { bounds }
    /// The focus ring's corner radius: the control's wash.
    var focusRingRadius: CGFloat { 8 }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: focusRingRadius, yRadius: focusRingRadius).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard event.charactersIgnoringModifiers == " " else { return super.keyDown(with: event) }
        if !event.isARepeat { action() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        hoverChanged()
    }

    func hoverChanged() {}

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), contextMenu != nil { return rightMouseDown(with: event) }
        if pressesOnMouseDown { return action() }
        pressed = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenu?() else { return super.rightMouseDown(with: event) }
        showSidebarMenu(menu, with: event, for: self)
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }

    /// VoiceOver's Show Menu, as SwiftUI's `.contextMenu` offered it.
    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu = contextMenu?() else { return false }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height), in: self)
        return true
    }

    /// The control is one element, as a SwiftUI button is: its label and image aren't read out on their own, only the
    /// controls inside it (a Boost's pencil, a tile's pin).
    override func accessibilityChildren() -> [Any]? {
        subviews.filter { $0 is SiteControlsControl }
    }
}

/// An action button, an extension tile or the plus tile: a symbol or image on a rounded wash that
/// deepens on hover; an extension's tile has a pin button at its bottom-right corner while it's pinned
/// or hovered.
private final class SiteControlsTile: SiteControlsControl {
    /// Whether the extension is pinned, and what its pin button does.
    var pin: (isPinned: Bool, toggle: () -> Void)? { didSet { updatePin() } }
    private let wash = FillView()
    private let icon = SiteControlsSymbol()
    private let symbol: (name: String, pointSize: CGFloat, weight: NSFont.Weight)?
    private let picture: NSImage?
    /// `picture` drawn into the tile once: layout runs again on every hover that shows or hides the pin.
    private var placedPicture: NSImage?
    private var pinButton: SiteControlsPin?
    /// The wash deepens on hover, except on the footer's "…", whose wash main never changed.
    var deepensOnHover = true

    init(symbol: String, pointSize: CGFloat, weight: NSFont.Weight, title: String) {
        self.symbol = (symbol, pointSize, weight)
        picture = nil
        super.init(title: title)
        setUp()
    }

    init(image: NSImage?, title: String) {
        symbol = nil
        picture = image
        super.init(title: title)
        setUp()
    }

    private func setUp() {
        wash.cornerRadius = 8
        wash.fill = primaryFill(0.05)
        addSubview(wash)
        addSubview(icon)
    }

    override func layout() {
        super.layout()
        wash.frame = bounds
        icon.frame = bounds
        if let symbol {
            icon.show(symbol.name, pointSize: symbol.pointSize, weight: symbol.weight, tint: .labelColor)
        } else if let picture, placedPicture?.size != bounds.size {
            icon.imageScaling = .scaleNone
            // An extension's own icon keeps its colours; only the puzzle piece in its place is tinted.
            let placed = place(picture, in: bounds.size, placement: .center)
            placed.isTemplate = picture.isTemplate
            placedPicture = placed
            icon.image = placed
            icon.contentTintColor = picture.isTemplate ? .labelColor : nil
        }
        pinButton?.frame = CGRect(x: SiteControlsView.Metrics.pinOrigin.x, y: SiteControlsView.Metrics.pinOrigin.y,
                                  width: SiteControlsView.Metrics.pinSize, height: SiteControlsView.Metrics.pinSize)
        pinButton?.exactY = exactY + SiteControlsView.Metrics.pinOrigin.y
    }

    override func hoverChanged() {
        wash.fill = primaryFill(isHovered && deepensOnHover ? 0.1 : 0.05)
        updatePin()
    }

    private func updatePin() {
        guard let pin, SiteControls.showsPinButton(isPinned: pin.isPinned, isHovered: isHovered) else {
            pinButton?.removeFromSuperview()
            pinButton = nil
            return
        }
        pinButton?.action = pin.toggle
        if pinButton == nil {
            let button = SiteControlsPin(title: SiteControls.pinButtonTitle(isPinned: pin.isPinned))
            button.action = pin.toggle
            addSubview(button)
            pinButton = button
            needsLayout = true
        }
    }

    // The pin button hangs past the tile's corner, so it takes clicks outside the tile's bounds.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let pinButton, let hit = pinButton.hitTest(convert(point, from: superview)) { return hit }
        return super.hitTest(point)
    }
}

/// The pin on an extension's tile: a pin on a window-coloured circle.
private final class SiteControlsPin: SiteControlsControl {
    private let circle = FillView()
    private let icon = SiteControlsSymbol()

    override init(title: String) {
        super.init(title: title)
        circle.cornerRadius = SiteControlsView.Metrics.pinSize / 2
        // SwiftUI's `Color(nsColor: .windowBackgroundColor)` resolves in plain dark or light, not the popover's vibrant
        // appearance (#323232 rather than #212121 in dark).
        circle.fill = { dark in
            var color = NSColor.windowBackgroundColor
            NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                color = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? color
            }
            return color
        }
        addSubview(circle)
        addSubview(icon)
    }

    override var focusRingRadius: CGFloat { SiteControlsView.Metrics.pinSize / 2 }

    override func layout() {
        super.layout()
        circle.frame = bounds
        icon.frame = bounds
        icon.show("pin.fill", pointSize: 8, weight: .black, tint: .labelColor, exactTop: exactY)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return local.x >= 0 && local.y >= 0 && local.x < bounds.width && local.y < bounds.height ? self : nil
    }
}

/// A section's header: the title, and a word shown at its right on hover. Arc's Settings header shows
/// "More" and opens the site's settings (`onSiteSettingsTitleClick`); its Boosts header shows "Manage"
/// and manages Boosts (`onManageBoostsClick`).
private final class SiteControlsHeader: SiteControlsControl {
    private let titleLabel = SiteControlsLabel(size: 13, weight: .semibold, secondary: true)
    private let hoverLabel = SiteControlsLabel(size: 13, weight: .semibold, secondary: true)

    init(title: String, hoverText: String, hint: String) {
        super.init(title: title)
        toolTip = nil
        setAccessibilityHelp(hint)
        titleLabel.stringValue = title
        hoverLabel.stringValue = hoverText
        hoverLabel.isHidden = true
        addSubview(titleLabel)
        addSubview(hoverLabel)
    }

    override func layout() {
        super.layout()
        let height = titleLabel.lineHeight
        let y = (bounds.height - height) / 2
        titleLabel.place(textRect: CGRect(x: 0, y: y, width: titleLabel.naturalWidth, height: height))
        // Trailing-aligned from the text's exact width, rounded down to the pixel, where SwiftUI's Spacer leaves it.
        let exactWidth = hoverLabel.attributedStringValue.size().width
        hoverLabel.place(textRect: CGRect(x: ((bounds.width - exactWidth) * 2).rounded(.down) / 2, y: y, width: hoverLabel.naturalWidth, height: height))
    }

    override func hoverChanged() { hoverLabel.isHidden = !isHovered }
}

/// A Settings or Boosts row: an icon on a circle (the accent colour while on), the title, and its
/// subtitle; a hover wash. A Boost's row also shows a pencil on hover that opens it in the editor.
private final class SiteControlsRow: SiteControlsControl {
    var edit: (() -> Void)? {
        didSet {
            updateEdit()
            // The pencil shows only under the pointer; VoiceOver reaches it from the row.
            setAccessibilityCustomActions(edit.map { edit in [NSAccessibilityCustomAction(name: "Edit Boost") { edit(); return true }] })
        }
    }
    private let wash = FillView()
    private let circle = FillView()
    private let icon = SiteControlsSymbol()
    private let titleLabel = SiteControlsLabel(size: 12, weight: .medium, secondary: false)
    private let subtitleLabel = SiteControlsLabel(size: 11, weight: .regular, secondary: true)
    private let symbol: String
    private let trailingPadding: CGFloat
    private var editButton: SiteControlsEdit?
    var isOn: Bool { didSet { if isOn != oldValue { icon.vibrant = !isOn; needsLayout = true } } }
    var subtitle: String {
        didSet {
            guard subtitle != oldValue else { return }
            subtitleLabel.stringValue = subtitle
            setAccessibilityValue(subtitle)
            needsLayout = true
        }
    }

    init(symbol: String, title: String, subtitle: String, isOn: Bool, trailingPadding: CGFloat = 0) {
        self.symbol = symbol
        self.isOn = isOn
        self.subtitle = subtitle
        self.trailingPadding = trailingPadding
        super.init(title: title)
        setAccessibilityValue(subtitle)
        wash.cornerRadius = 8
        circle.cornerRadius = 12
        circle.layer?.cornerCurve = .circular
        circle.fill = primaryFill(0.08)
        icon.vibrant = !isOn
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        [wash, circle, icon, titleLabel, subtitleLabel].forEach(addSubview)
    }

    override func layout() {
        super.layout()
        wash.frame = bounds
        let circleTop = exactY + (bounds.height - 24) / 2
        let circleFrame = CGRect(x: 4, y: circleTop.pixelRounded - frame.minY, width: 24, height: 24)
        circle.frame = circleFrame
        icon.frame = circleFrame
        icon.show(symbol, pointSize: 11, weight: .semibold, tint: isOn ? .controlAccentColor : .secondaryLabelColor, exactTop: circleTop)
        let x = circleFrame.maxX + 8
        let width = max(0, bounds.width - trailingPadding - x)
        let titleHeight = titleLabel.stackedLineHeight, subtitleHeight = subtitleLabel.stackedLineHeight
        let top = (bounds.height - titleHeight - subtitleHeight) / 2
        titleLabel.place(textRect: CGRect(x: x, y: top, width: min(width, titleLabel.naturalWidth), height: titleHeight))
        subtitleLabel.place(textRect: CGRect(x: x, y: top + titleHeight, width: min(width, subtitleLabel.naturalWidth), height: subtitleHeight))
        editButton?.frame = CGRect(x: bounds.width - 4 - 24, y: circleFrame.minY, width: 24, height: 24)
        editButton?.exactY = circleTop
    }

    override func hoverChanged() {
        wash.fill = isHovered ? primaryFill(0.08) : { _ in .clear }
        updateEdit()
    }

    private func updateEdit() {
        guard let edit, isHovered else {
            editButton?.removeFromSuperview()
            editButton = nil
            return
        }
        // A rebuild sets `edit` again: the shown pencil takes the new closure rather than being made again.
        editButton?.action = edit
        if editButton == nil {
            let button = SiteControlsEdit(title: "Edit Boost")
            button.action = edit
            addSubview(button)
            editButton = button
            needsLayout = true
        }
    }
}

/// A Boost row's pencil.
private final class SiteControlsEdit: SiteControlsControl {
    private let icon = SiteControlsSymbol()

    override init(title: String) {
        super.init(title: title)
        icon.vibrant = true
        addSubview(icon)
    }

    override func layout() {
        super.layout()
        icon.frame = bounds
        icon.show("pencil", pointSize: 11, weight: .semibold, tint: .secondaryLabelColor, exactTop: exactY)
    }
}

/// Arc's footer button: "Secure" with a lock, "Insecure" with a struck-through one.
private final class SiteControlsSecurity: SidebarFlippedView, SiteControlsPlaced {
    var exactY: CGFloat = 0 { didSet { if exactY != oldValue { needsLayout = true } } }
    private let wash = FillView()
    private let icon = SiteControlsSymbol()
    private let label = SiteControlsLabel(size: 12, weight: .medium, secondary: true)
    private let symbol: String

    init(title: String) {
        symbol = title == "Secure" ? "lock.fill" : "lock.slash.fill"
        super.init(frame: .zero)
        wash.cornerRadius = 8
        wash.fill = primaryFill(0.05)
        icon.vibrant = true
        label.stringValue = title
        [wash, icon, label].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityChildren() -> [Any]? { [] }

    override func layout() {
        super.layout()
        wash.frame = bounds
        guard let lock = rawSymbol(symbol, pointSize: 11, weight: .semibold) else { return }
        // An HStack(spacing: 5) of the lock and the title, centred.
        let lockWidth = lock.alignmentRect.width
        let textWidth = label.naturalWidth, textHeight = label.lineHeight
        let total = lockWidth + 5 + textWidth
        let x = ((bounds.width - total) / 2).pixelRounded
        icon.frame = CGRect(x: x, y: 0, width: lockWidth, height: bounds.height)
        icon.show(symbol, pointSize: 11, weight: .semibold, tint: .secondaryLabelColor, exactTop: exactY)
        label.place(textRect: CGRect(x: x + lockWidth + 5, y: ((bounds.height - textHeight) / 2).pixelRounded,
                                     width: textWidth, height: textHeight))
    }
}

private extension SiteControlsAction {
    /// Kite's symbols. Arc draws its own `copy-url`, `window-screenshot-icon`, `capture-full-page`
    /// and `boost.sparkle` images; Share is `square.and.arrow.up` and Portrait Mode `camera` there too.
    var symbol: String {
        switch self {
        case .share: "square.and.arrow.up"
        case .copyURL: "link"
        case .newBoost: "wand.and.stars"
        case .capture: "viewfinder"
        case .captureFullPage: "rectangle.expand.vertical"
        case .capturePortraitMode: "camera"
        }
    }
}

/// Site Controls' content, sized to its view.
private final class SiteControlsViewController: NSViewController {
    private let content: SiteControlsView

    init(model: SiteControlsModel) {
        content = SiteControlsView(model: model)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = content
        content.onSizeChange = { [weak self] in self?.updateSize() }
        updateSize()
    }

    private func updateSize() {
        preferredContentSize = NSSize(width: SiteControlsView.Metrics.width, height: content.contentHeight)
    }
}

/// The popover itself, hanging from the button that opened it. One per app: opening it from
/// another window closes the first, and clicking its button again closes it.
@MainActor
enum SiteControlsPopover {
    private static weak var shown: NSPopover?
    private static weak var shownAnchor: NSView?
    /// A transient popover closes on the mouse-down that lands on its own button, before the
    /// button acts; that click mustn't open it again.
    private static var closed: (anchor: ObjectIdentifier, at: Date)?
    private static var observer: NSObjectProtocol?
    /// Watches ⌥ while the popover is shown, as Arc's view controller does (a flagsChanged monitor).
    private static var optionMonitor: Any?

    /// Observable, so the address field keeps its hover button while the popover hangs from it.
    @Observable final class Presence { var isShown = false }
    static let presence = Presence()
    static var isShown: Bool { presence.isShown }

    /// `overlap` raises the popover over the button's bottom edge (Arc's toolbar popover starts
    /// 4pt above the bar's bottom). The popover stays inside the window: Arc's toolbar popover
    /// ends at the window's right edge rather than centring on its button.
    static func toggle(_ model: @autoclosure () -> SiteControlsModel?, from view: NSView, overlap: CGFloat = 0) {
        if let shown, shown.isShown {
            let sameButton = shownAnchor === view
            shown.close()
            if sameButton { return }
        } else if let closed, closed.anchor == ObjectIdentifier(view), Date().timeIntervalSince(closed.at) < 0.3 {
            return
        }
        guard let model = model() else { return NSSound.beep() }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = SiteControlsViewController(model: model)
        model.dismiss = { [weak popover] in popover?.close() }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        let anchor = ObjectIdentifier(view)
        observer = NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover, queue: .main) { _ in
            MainActor.assumeIsolated {
                closed = (anchor, Date())
                presence.isShown = false
                if let optionMonitor { NSEvent.removeMonitor(optionMonitor) }
                optionMonitor = nil
            }
        }
        if let optionMonitor { NSEvent.removeMonitor(optionMonitor) }
        model.optionKeyDown = NSEvent.modifierFlags.contains(.option)
        optionMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak model] event in
            let down = event.modifierFlags.contains(.option)
            if model?.optionKeyDown != down { model?.optionKeyDown = down }
            return event
        }
        var rect = view.bounds
        if overlap > 0 {
            rect.size.height -= overlap
            if !view.isFlipped { rect.origin.y += overlap }
        }
        // Positioned against the window's content view, so the popover can sit off-centre
        // from a button near the window's right edge.
        var positioning = view
        if let content = view.window?.contentView {
            rect = view.convert(rect, to: content)
            let half = SiteControlsView.Metrics.popoverWidth / 2
            if rect.midX + half > content.bounds.maxX {
                rect.origin.x = content.bounds.maxX - half - rect.width / 2
            }
            positioning = content
        }
        WindowPresenter.show(popover, relativeTo: rect, of: positioning, preferredEdge: positioning.isFlipped ? .maxY : .minY)
        shown = popover
        shownAnchor = view
        presence.isShown = true
    }
}
