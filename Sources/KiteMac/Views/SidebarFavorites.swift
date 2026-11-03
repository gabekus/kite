import AppKit
import KiteCore
import SwiftUI

private typealias M = ArcMetrics.Sidebar

/// The column's measurements that the SwiftUI chrome still lays out around: the favorites tray's height, so
/// its placeholder keeps everything under it where it was.
@MainActor
@Observable
final class SidebarChromeMetrics {
    /// The tray with its gaps above and below; 0 when it isn't shown.
    var favoritesHeight: CGFloat = 0
}

/// Arc's favorites tray (`AppTray`): square tiles of favicons shared by every space, 47pt high, 8pt apart, at
/// most four a row (`FavoritesTrayLayout`), with 8pt above and below. It shows while dragging even when there
/// are no favorites (Arc's `AppTrayDisplayMode.onDrag`), and otherwise until its empty state is dismissed.
/// A press anywhere on it, insets and gaps included, is the tray's, never a window move.
@MainActor
final class FavoritesTrayView: SidebarFlippedView {
    private let store: BrowserStore
    private let actions: SidebarActions
    private let drag: SidebarDragModel
    let metrics: SidebarChromeMetrics
    private var tiles: [String: FavoriteTileView] = [:]
    private var slots: [Slot] = []
    private let empty = FavoritesEmptyStateView()
    private var showsEmpty = false
    private var updateScheduled = false
    private var flagsObserver: NSObjectProtocol?

    /// The tray's slots: each favorite or favorite split, and the drop gap while a drag aims between them.
    enum Slot: Equatable {
        case tile(BrowserTab)
        case split(SplitView, [BrowserTab])
        case gap

        var key: String {
            switch self {
            case .tile(let tab): tab.id.uuidString
            case .split(let split, _): split.id.uuidString
            case .gap: "gap"
            }
        }

        var dragID: UUID? {
            switch self {
            case .tile(let tab): tab.id
            case .split(let split, _): split.id
            case .gap: nil
            }
        }
    }

    private static let emptyStateDismissedKey = "favoritesEmptyStateDismissed"
    /// The empty state's Dismiss: read at first and again whenever it's set (in any window).
    private var emptyStateDismissed = OneShotFlags.standard.bool(forKey: FavoritesTrayView.emptyStateDismissedKey)

    init(store: BrowserStore, actions: SidebarActions, drag: SidebarDragModel, metrics: SidebarChromeMetrics) {
        self.store = store
        self.actions = actions
        self.drag = drag
        self.metrics = metrics
        super.init(frame: .zero)
        empty.onDismiss = { OneShotFlags.standard.set(true, forKey: Self.emptyStateDismissedKey) }
        addSubview(empty)
        // Every window's tray follows a Dismiss in any of them.
        flagsObserver = NotificationCenter.default.addObserver(forName: OneShotFlags.didChange, object: nil,
                                                                  queue: .main) { [weak self] note in
            guard note.userInfo?["key"] as? String == Self.emptyStateDismissedKey else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.emptyStateDismissed = OneShotFlags.standard.bool(forKey: Self.emptyStateDismissedKey)
                self.scheduleUpdate()
            }
        }
        update()
    }

    isolated deinit {
        if let flagsObserver { NotificationCenter.default.removeObserver(flagsObserver) }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    /// The columns follow the width, and the tray's height the columns.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { scheduleUpdate() }
    }

    // MARK: Observing

    private func update() {
        withObservationTracking { rebuild() } onChange: { [weak self] in
            MainActor.assumeIsolated { self?.scheduleUpdate() }
        }
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

    private func rebuild() {
        let state = store.state
        let favorites = state.favorites
        let dragging = drag.isDragging
        let dismissed = emptyStateDismissed
        let creating = store.spaceCreation.map { $0.spaceID == state.selectedSpaceID } ?? false
        let shown = !creating && (!favorites.isEmpty || dragging || !dismissed)
        var slots = SidebarGroup.group(favorites.map(\.id), splits: state.favoriteSplits).map { group -> Slot in
            if let split = group.split { return .split(split, group.indices.map { favorites[$0] }) }
            return .tile(favorites[group.indices[0]])
        }
        // Arc's tray counts one more item while a drag aims at it and leaves `dropGapFrame` empty.
        if !favorites.isEmpty, case .favorites(let before)? = drag.session?.target {
            let at = before.flatMap { id in slots.firstIndex { $0.dragID == id } } ?? slots.count
            slots.insert(.gap, at: at)
        }
        let selectedID = state.selectedSpace.selectedTabID
        let hidden = Set(drag.session?.ids ?? [])
        self.slots = slots
        showsEmpty = shown && slots.isEmpty && (!dismissed || dragging)
        empty.isHidden = !showsEmpty
        empty.dismissable = !dragging

        var keep = Set<String>()
        for slot in slots {
            switch slot {
            case .tile(let tab):
                tile(for: tab.id.uuidString).show([tab], split: nil, selectedID: selectedID, hidden: hidden.contains(tab.id))
                keep.insert(slot.key)
            case .split(let split, let tabs):
                tile(for: split.id.uuidString).show(tabs, split: split, selectedID: selectedID, hidden: hidden.contains(split.id))
                keep.insert(slot.key)
            case .gap:
                break
            }
        }
        for (key, view) in tiles where !keep.contains(key) {
            view.removeFromSuperview()
            tiles[key] = nil
            if let id = UUID(uuidString: key) { drag.reportTile(id, frame: nil) }
        }
        let height = shown ? M.favoritesTopGap + contentHeight(width: bounds.width - 2 * M.padding) + M.favoritesBottomGap : 0
        isHidden = !shown
        if metrics.favoritesHeight != height { metrics.favoritesHeight = height }
        if !shown { drag.favoritesArea = nil }
        needsLayout = true
    }

    private func tile(for key: String) -> FavoriteTileView {
        if let view = tiles[key] { return view }
        let view = FavoriteTileView(store: store, actions: actions, drag: drag)
        addSubview(view)
        tiles[key] = view
        return view
    }

    private func contentHeight(width: CGFloat) -> CGFloat {
        if slots.isEmpty { return showsEmpty ? FavoritesEmptyStateView.height : 0 }
        let cols = FavoritesTrayLayout.columns(count: slots.count, width: width)
        let rows = (slots.count + cols - 1) / cols
        return CGFloat(rows) * M.favoriteHeight + CGFloat(max(rows - 1, 0)) * M.favoriteSpacing
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let width = bounds.width - 2 * M.padding
        let content = CGRect(x: M.padding, y: M.favoritesTopGap, width: width, height: contentHeight(width: width))
        empty.frame = content
        // No animation as the slot opens or moves: Arc's tray sets its drag info and invalidates the layout
        // outside any animation context (decompiled), so its tiles jump to their new places.
        let cols = FavoritesTrayLayout.columns(count: max(slots.count, 1), width: width)
        let tileWidth = (width - M.favoriteSpacing * CGFloat(cols - 1)) / CGFloat(cols)
        drag.dropGap = nil
        for (i, slot) in slots.enumerated() {
            let frame = CGRect(x: content.minX + CGFloat(i % cols) * (tileWidth + M.favoriteSpacing),
                               y: content.minY + CGFloat(i / cols) * (M.favoriteHeight + M.favoriteSpacing),
                               width: tileWidth, height: M.favoriteHeight)
            if slot == .gap {
                drag.dropGap = sidebarRect(frame)
            } else if let view = tiles[slot.key] {
                view.frame = frame
            }
        }
        reportFrames()
    }

    /// Where the tray and its tiles are, for drags (sidebar points: window points from the top-left).
    func reportFrames() {
        guard window != nil, !isHidden else { return }
        let width = bounds.width - 2 * M.padding
        drag.favoritesArea = sidebarRect(CGRect(x: M.padding, y: M.favoritesTopGap, width: width, height: contentHeight(width: width)))
        for view in tiles.values { view.reportFrames() }
    }

    private func sidebarRect(_ rect: CGRect) -> CGRect {
        let r = convert(rect, to: nil)
        let height = window?.contentView?.bounds.height ?? 0
        return CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }
}

/// A favorite's tile (or a favorite split's, its panes side by side 2pt apart, stacked for a top/bottom split).
@MainActor
final class FavoriteTileView: SidebarFlippedView {
    private let store: BrowserStore
    private let actions: SidebarActions
    private let drag: SidebarDragModel
    private var panes: [FavoritePaneView] = []
    private var tabs: [BrowserTab] = []
    private var split: SplitView?
    private var pressStart: CGPoint?
    private var dragging = false

    init(store: BrowserStore, actions: SidebarActions, drag: SidebarDragModel) {
        self.store = store
        self.actions = actions
        self.drag = drag
        super.init(frame: .zero)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    func show(_ tabs: [BrowserTab], split: SplitView?, selectedID: UUID?, hidden: Bool) {
        self.tabs = tabs
        self.split = split
        while panes.count < tabs.count {
            let pane = FavoritePaneView(actions: actions, drag: drag)
            pane.store = store
            addSubview(pane)
            panes.append(pane)
        }
        while panes.count > tabs.count { panes.removeLast().removeFromSuperview() }
        for (pane, tab) in zip(panes, tabs) { pane.show(tab, selected: tab.id == selectedID) }
        // Tiles being dragged out of the tray keep their place, invisible (Arc: alpha 0).
        alphaValue = hidden ? 0 : 1
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let vertical = split?.orientation == .vertical
        let n = CGFloat(max(panes.count, 1))
        let gap = M.favoriteSplitSpacing
        for (i, pane) in panes.enumerated() {
            if vertical {
                let h = (bounds.height - gap * (n - 1)) / n
                pane.frame = CGRect(x: 0, y: CGFloat(i) * (h + gap), width: bounds.width, height: h)
            } else {
                let w = (bounds.width - gap * (n - 1)) / n
                pane.frame = CGRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: bounds.height)
            }
        }
    }

    func reportFrames() {
        guard let id = split?.id ?? tabs.first?.id, let window else { return }
        let r = convert(bounds, to: nil)
        let height = window.contentView?.bounds.height ?? 0
        drag.reportTile(id, frame: CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height))
    }

    // MARK: Dragging (the panes forward presses here)

    func paneMouseDown(_ event: NSEvent) {
        pressStart = sidebarPoint(event)
        dragging = false
    }

    /// True once the press became a drag.
    func paneMouseDragged(_ event: NSEvent) -> Bool {
        guard let start = pressStart, let id = split?.id ?? tabs.first?.id else { return false }
        let point = sidebarPoint(event)
        if !dragging {
            guard hypot(point.x - start.x, point.y - start.y) >= 4 else { return false }
            dragging = true
            reportFrames()
            let frame = drag.tileFrame(id) ?? .zero
            let row = SidebarDragModel.Row(id: id, kind: .tab, space: store.state.selectedSpaceID, pinned: false,
                                           folder: nil, depth: 0, frame: frame)
            drag.begin([id], row: row, at: start, ghost: AnyView(FavoriteGhost(tabs: tabs)))
            actions.previewFavorite(nil, nil)
        }
        drag.move(to: point, in: store.state)
        return true
    }

    /// True when the press was a drag (and has now dropped).
    func paneMouseUp(_ event: NSEvent) -> Bool {
        defer { pressStart = nil; dragging = false }
        guard dragging else { return false }
        guard let drop = drag.end(at: sidebarPoint(event), in: store.state) else { return true }
        var outcome: SidebarDropOutcome?
        store.mutate { outcome = $0.dropSidebarItems(drop.ids, on: drop.target) }
        if let outcome { actions.didDrop(outcome) }
        return true
    }

    private func sidebarPoint(_ event: NSEvent) -> CGPoint {
        let p = event.locationInWindow
        return CGPoint(x: p.x, y: (window?.contentView?.bounds.height ?? 0) - p.y)
    }
}

/// One favorite in a tile (SwiftUI's `FavoriteTile` with `FavoriteFill`). Unselected it's the field's white wash
/// (brighter hovered). Selected, Arc fills it white (0.45 dark, 0.8 light), lays the favicon's colour over that
/// (0.2, 0.3 hovered; on a light theme only when hovered, 0.1), and strokes a 2pt ring of the colour on the tile
/// inset by 1. With no colour (a grey or missing favicon) the tile is just white.
@MainActor
final class FavoritePaneView: SidebarFlippedView {
    private let actions: SidebarActions
    private let drag: SidebarDragModel
    weak var store: BrowserStore?
    private let fill = FillView()
    private let tint = FillView()
    /// The ring: a 2pt border with continuous corners covers the band a 2pt stroke on the shape inset by 1 does.
    private let ringView = SidebarRingView()
    private let favicon = FaviconImageView(side: M.favoriteIconSize)
    private var tab: BrowserTab?
    private var selected = false
    private var hovered = false
    private var highlight: NSColor?
    private var highlightURL: URL?
    private var tracking: NSTrackingArea?

    init(actions: SidebarActions, drag: SidebarDragModel) {
        self.actions = actions
        self.drag = drag
        super.init(frame: .zero)
        fill.cornerRadius = M.favoriteCornerRadius
        tint.cornerRadius = M.favoriteCornerRadius
        addSubview(fill)
        addSubview(tint)
        // Its own view, so AppKit keeps it above the fills (it re-orders a view's sublayers to match its subviews).
        addSubview(ringView)
        addSubview(favicon)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    func show(_ tab: BrowserTab, selected: Bool) {
        self.tab = tab
        self.selected = selected
        favicon.show(tab: tab)
        toolTip = tab.displayTitle
        setAccessibilityLabel(tab.displayTitle)
        setAccessibilitySelected(selected)
        let url = FaviconSource(page: tab.url, icon: tab.faviconURL).url
        if url != highlightURL {
            highlightURL = url
            highlight = nil
            if let url {
                if let image = FaviconCache.shared.cached(url) {
                    highlight = image.dominantColor
                } else {
                    Task { [weak self] in
                        guard let image = await FaviconCache.shared.image(for: url), let self, self.highlightURL == url else { return }
                        self.highlight = image.dominantColor
                        self.applyFill()
                    }
                }
            }
        }
        applyFill()
    }

    /// The favicon's colour, lightened like Arc's ring (fitted, see `favoriteHighlightWhiten`).
    private var color: NSColor? { highlight?.blended(withFraction: M.favoriteHighlightWhiten, of: .white) }

    private func applyFill() {
        let selected = self.selected, hovered = self.hovered, color = self.color
        if selected {
            fill.fill = { dark in NSColor.white.withAlphaComponent(dark ? M.favoriteSelectedFill : M.favoriteSelectedFillLight) }
            tint.fill = { dark in
                guard let color else { return .clear }
                let alpha = dark ? (hovered ? M.favoriteTintHovered : M.favoriteTint) : (hovered ? M.favoriteTintHoveredLight : 0)
                return color.withAlphaComponent(alpha)
            }
            ringView.color = color
            ringView.isHidden = color == nil
        } else {
            fill.fill = chromeFill(hovered ? M.fieldFill + M.hoverFill : M.fieldFill)
            tint.fill = { _ in .clear }
            ringView.isHidden = true
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        fill.frame = bounds
        tint.frame = bounds
        let side = M.favoriteIconSize
        favicon.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        ringView.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() { applyFill() }

    // MARK: Hover and presses

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        applyFill()
        if !drag.isDragging { actions.previewFavorite(tab, self) }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        applyFill()
        actions.previewFavorite(nil, nil)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, hovered { actions.previewFavorite(nil, nil) }
    }

    private var tile: FavoriteTileView? { superview as? FavoriteTileView }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
        tile?.paneMouseDown(event)
    }

    override func mouseDragged(with event: NSEvent) { _ = tile?.paneMouseDragged(event) }

    override func mouseUp(with event: NSEvent) {
        if tile?.paneMouseUp(event) == true { return }
        guard let tab, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        store?.mutate { $0.select(tab: tab.id) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let tab else { return false }
        store?.mutate { $0.select(tab: tab.id) }
        return true
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        showSidebarMenu(menu, with: event, for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let tab, let store else { return nil }
        let actions = self.actions, id = tab.id
        let menu = NSMenu()
        menu.add("Remove from Favorites") { store.mutate { $0.toggleFavorite(tab: id) } }
        if tab.pinnedURL != nil {
            menu.addEditPinnedPage(onEdit: { actions.editPinnedURL(id) }, onReplace: { actions.replacePinnedURL(id) })
        }
        let url = tab.url
        menu.add("Copy Link") { if let url { copyToPasteboard(url.absoluteString) } }
        menu.addSeparator()
        menu.add("Unload Tab") { actions.closeTab(id) }
        return menu
    }
}

/// Arc's empty favorites tray (`AppTrayEmptyStateView`): its title and subtitle from Arc's strings on a dashed
/// outline, with a close button on hover that hides it until a drag needs somewhere to drop.
@MainActor
final class FavoritesEmptyStateView: SidebarFlippedView {
    /// 47pt at least, 6pt above and below.
    static let height: CGFloat = M.favoriteHeight + 12
    var onDismiss: () -> Void = {}
    var dismissable = true { didSet { updateClose() } }
    private let outline = CAShapeLayer()
    private let title = CenteredLabel(size: 12, weight: .semibold, opacity: 0.7)
    private let subtitle = CenteredLabel(size: 11, weight: .regular, opacity: 0.45)
    private let close = SymbolButton(symbol: "xmark", pointSize: 8, weight: .bold, label: "Dismiss")
    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { updateClose() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        outline.fillColor = nil
        outline.lineWidth = 1.5
        outline.lineDashPattern = [5, 4]
        layer?.addSublayer(outline)
        title.text = "Drag to add Favorites"
        subtitle.text = "Favorites keep your most used sites and apps close"
        addSubview(title)
        addSubview(subtitle)
        close.opacity = 0.5
        close.toolTip = "Dismiss"
        close.action = { [weak self] in self?.onDismiss() }
        addSubview(close)
        updateClose()
    }

    override var mouseDownCanMoveWindow: Bool { false }

    private func updateClose() { close.isHidden = !(hovering && dismissable) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.frame = layer?.bounds ?? bounds
        // strokeBorder on the background after the vertical padding: the 1.5pt line inside the whole box.
        let r = bounds.insetBy(dx: 0.75, dy: 0.75)
        outline.path = SwiftUI.Path(roundedRect: r, cornerRadius: M.cornerRadius - 0.75, style: .continuous).cgPath
        effectiveAppearance.performAsCurrentDrawingAppearance {
            outline.strokeColor = NSColor.labelColor.withAlphaComponent(0.2).cgColor
        }
        CATransaction.commit()
        // Title and subtitle 2pt apart, centred in the 47pt box between the 6pt insets.
        let box = CGRect(x: 16, y: 6, width: bounds.width - 32, height: bounds.height - 12)
        let th = title.lineHeight, sh = subtitle.lineHeight
        let top = box.minY + ((box.height - th - 2 - sh) / 2).rounded(.down)
        title.frame = CGRect(x: box.minX, y: top, width: box.width, height: th)
        subtitle.frame = CGRect(x: box.minX, y: top + th + 2, width: box.width, height: sh)
        close.frame = CGRect(x: bounds.width - 4 - 18, y: 6 + 4, width: 18, height: 18)
    }

    override func viewDidChangeEffectiveAppearance() { needsLayout = true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

/// A line of text centred across its frame, its line box at the frame's top (SwiftUI's `Text` in a VStack with
/// centred alignment).
@MainActor
final class CenteredLabel: NSView {
    var text = "" { didSet { needsDisplay = true } }
    var color: NSColor = .labelColor { didSet { needsDisplay = true } }
    private let font: NSFont
    init(size: CGFloat, weight: NSFont.Weight, opacity: Double) {
        font = .systemFont(ofSize: size, weight: weight)
        super.init(frame: .zero)
        alphaValue = opacity
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) }

    override func accessibilityValue() -> Any? { text }

    override func draw(_ dirtyRect: NSRect) {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = string.size()
        // Centred, its origin on the pixel grid like SwiftUI's.
        string.draw(at: NSPoint(x: ((bounds.width - size.width) / 2 * 2).rounded() / 2, y: 0))
    }
}

/// A view drawn by one shape layer, taking no clicks.
final class SidebarShapeView: NSView {
    let shape = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(shape)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = layer?.bounds ?? bounds
        CATransaction.commit()
    }
}

/// A favorite's selected ring: Arc's 2pt stroke of the favicon's colour on the tile inset by 1, as a border.
final class SidebarRingView: NSView {
    var color: NSColor? { didSet { layer?.borderColor = color?.cgColor } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = ArcMetrics.Sidebar.favoriteCornerRadius
        layer?.borderWidth = ArcMetrics.Sidebar.favoriteRingWidth + 2 * (ArcMetrics.Sidebar.favoriteRingInset - 1)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
