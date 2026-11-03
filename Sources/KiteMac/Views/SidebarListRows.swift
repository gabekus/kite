import AppKit
import KiteCore
import SwiftUI

private typealias M = ArcMetrics.Sidebar

// MARK: - Space icons

/// A space's icon (SwiftUI's `SpaceIconView`): an emoji at `size` points, an SF Symbol in the theme's accent,
/// or a picture 1.2 times the size with continuous corners; greyed, it loses its colour and fades to 45%.
final class SpaceIconImageView: NSView {
    private let label = CenteredTextView()
    private let image = SidebarImageView()
    private(set) var icon = ""
    private var theme: Theme?
    var size: CGFloat = 15 { didSet { needsLayout = true } }
    var greyed = false { didSet { if greyed != oldValue { applyIcon() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.wantsLayer = true
        addSubview(label)
        image.imageScaling = .scaleNone
        image.wantsLayer = true
        addSubview(image)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(icon: String, theme: Theme) {
        guard icon != self.icon || theme != self.theme else { return }
        self.icon = icon
        self.theme = theme
        applyIcon()
    }

    private func applyIcon() {
        label.isHidden = true
        image.isHidden = true
        image.layer?.filters = nil
        label.layer?.filters = nil
        alphaValue = 1
        if icon.hasPrefix(Space.imagePrefix) {
            image.isHidden = false
            image.contentTintColor = nil
            image.layer?.cornerCurve = .continuous
            image.layer?.masksToBounds = true
            if greyed { image.layer?.filters = [Self.greyscale()].compactMap { $0 } }
            alphaValue = greyed ? 0.45 : 1
        } else if icon.hasPrefix(Space.symbolPrefix) {
            image.isHidden = false
            image.layer?.masksToBounds = false
            let accent = theme?.accent ?? ThemeColor(r: 1, g: 1, b: 1)
            image.contentTintColor = greyed ? NSColor.labelColor.withAlphaComponent(0.45)
                : NSColor(srgbRed: CGFloat(accent.r), green: CGFloat(accent.g), blue: CGFloat(accent.b), alpha: 1)
        } else {
            label.isHidden = false
            label.text = icon
            if greyed { label.layer?.filters = [Self.greyscale()].compactMap { $0 } }
            alphaValue = greyed ? 0.45 : 1
        }
        needsLayout = true
    }

    private static func greyscale() -> CIFilter? {
        let filter = CIFilter(name: "CIColorControls")
        filter?.setValue(0, forKey: kCIInputSaturationKey)
        return filter
    }

    override func layout() {
        super.layout()
        if icon.hasPrefix(Space.imagePrefix) {
            let side = SpaceIconView.imageSide(for: size)
            image.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
            image.layer?.cornerRadius = side * 0.22
            if let picture = SpaceIconImages.image(for: icon) {
                image.image = fill(picture, side: side)
            } else {
                // The file is gone (a profile copied without its SpaceIcons folder): a placeholder, not a blank.
                image.contentTintColor = .secondaryLabelColor
                image.image = symbolImage("photo", pointSize: size * 0.8, box: NSSize(width: side, height: side), placement: .center)
            }
        } else if icon.hasPrefix(Space.symbolPrefix) {
            image.frame = bounds
            image.image = symbolImage(String(icon.dropFirst(Space.symbolPrefix.count)), pointSize: size, weight: .semibold,
                                      box: bounds.size, placement: .center)
        } else {
            label.font = .systemFont(ofSize: size)
            label.frame = bounds
        }
    }

    /// `.resizable().aspectRatio(contentMode: .fill)` into a square, high-quality interpolation.
    private func fill(_ picture: NSImage, side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let s = picture.size
            guard s.width > 0, s.height > 0 else { return true }
            let scale = max(side / s.width, side / s.height)
            let w = s.width * scale, h = s.height * scale
            NSGraphicsContext.current?.imageInterpolation = .high
            picture.draw(in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
            return true
        }
    }
}

/// A string drawn at its own size, centred exactly in the view: how SwiftUI places a `Text` in a larger frame
/// (measured against ImageRenderer: an emoji at 15pt in 26pt lands at (2.5, 3.5), to anti-aliasing).
final class CenteredTextView: NSView {
    var text = "" { didSet { if text != oldValue { needsDisplay = true } } }
    var font = NSFont.systemFont(ofSize: 15) { didSet { if font != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let size = string.size()
        string.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

// MARK: - Space header

/// The space's icon and name above its pinned tabs, Arc's small semibold caption (SwiftUI's `SpaceHeader`).
/// As in Arc, the name is renamed in place, the icon is a button that changes it, a click on the current
/// space's name renames it, a chevron collapses the pinned tabs, and a right-click gives the space's menu.
final class SpaceHeaderRowCell: SidebarRowCell {
    private let iconButton = SidebarPassthroughButton()
    private let icon = SpaceIconImageView()
    private let placeholder = CAShapeLayer()
    private let name = SidebarLabel(size: M.headerFontSize, weight: .semibold, opacity: M.headerTextOpacity)
    private let chevron = SymbolButton(symbol: "chevron.right", pointSize: 9, weight: .bold)
    private let done = SidebarDoneButton()
    private var renameField: SpaceRenameField?
    private var pickerOpen = false { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        iconButton.toolTip = "Change Space Icon"
        iconButton.setAccessibilityRole(.button)
        iconButton.action = { [weak self] in self?.openPicker() }
        addSubview(iconButton)
        iconButton.addSubview(icon)
        placeholder.fillColor = nil
        placeholder.lineWidth = 1
        placeholder.lineDashPattern = [3, 2]
        iconButton.layer?.addSublayer(placeholder)
        name.setAccessibilityElement(true)
        addSubview(name)
        chevron.wantsLayer = true
        addSubview(chevron)
        done.action = { [weak self] in self?.renameField?.commit() }
        addSubview(done)
    }

    private var header: SidebarRowModel.Header? {
        if case .header(let h)? = model { return h }
        return nil
    }

    override func update() {
        guard let h = header, let list else { return }
        let store = list.store
        icon.size = 15
        icon.show(icon: h.icon, theme: h.theme)
        iconButton.setAccessibilityLabel(h.icon.isEmpty ? "Change Space Icon" : h.icon)
        name.stringValue = h.name
        name.setAccessibilityValue(h.name)
        chevron.toolTip = h.pinnedCollapsed ? "Expand Pinned Tabs" : "Collapse Pinned Tabs"
        chevron.setAccessibilityLabel(chevron.toolTip)
        let id = h.spaceID
        chevron.action = { store.mutate { $0.togglePinnedSection(id) } }
        if h.isRenaming {
            if renameField == nil {
                let field = SpaceRenameField()
                field.onCommit = { [weak self] text in self?.commitRename(text) }
                field.onCancel = { store.endRenaming() }
                addSubview(field)
                renameField = field
                field.begin(with: h.name)
            }
        } else if let field = renameField {
            renameField = nil
            field.removeFromSuperview()
        }
        super.update()
    }

    private func commitRename(_ text: String) {
        guard let h = header, let store = list?.store, store.renamingSpaceID == h.spaceID else { return }
        store.mutate { $0.renameSpace(h.spaceID, to: text) }
        store.endRenaming()
    }

    override func layout() {
        super.layout()
        guard let h = header else { return }
        let iconSide = M.headerIconSize
        let top = M.headerIconTop
        let rowHeight = iconSide
        var x = M.headerIconX - M.padding
        // An icon-less space has no icon slot: its name starts at the icon's place (Arc, 1 Nov 2026). While
        // the picker is open Arc shows a dashed square there for it to hang from.
        let showsIcon = !h.icon.isEmpty || pickerOpen
        iconButton.isHidden = !showsIcon
        if showsIcon {
            iconButton.frame = CGRect(x: x, y: top, width: iconSide, height: iconSide)
            icon.frame = iconButton.bounds
            icon.isHidden = h.icon.isEmpty
            placeholder.isHidden = !h.icon.isEmpty
            let square = CGRect(x: (iconSide - 24) / 2, y: (iconSide - 24) / 2, width: 24, height: 24).insetBy(dx: 0.5, dy: 0.5)
            placeholder.path = CGPath(roundedRect: square, cornerWidth: 4.5, cornerHeight: 4.5, transform: nil)
            placeholder.strokeColor = NSColor.labelColor.withAlphaComponent(0.35).cgColor
            x += iconSide + (M.headerTextX - M.headerIconX - M.headerIconSize)
        }
        // SwiftUI's HStack(spacing: 2) puts its gap on both sides of the Spacer too.
        let gap = M.headerTextX - M.headerIconX - M.headerIconSize
        var end = bounds.width
        let showsChevron = h.hasPinned && !h.isRenaming
        chevron.isHidden = !showsChevron
        if showsChevron {
            end -= M.iconInset - M.padding
            end -= iconSide
            chevron.frame = CGRect(x: end, y: top, width: iconSide, height: iconSide)
            chevron.opacity = h.pinnedCollapsed ? 0.5 : (isHovered ? 0.5 : 0)
            setChevron(rotated: !h.pinnedCollapsed)
            end -= gap
        }
        let line = name.lineHeight
        let textY = top + ((rowHeight - line) / 2).rounded(.down)
        done.isHidden = renameField == nil
        if let field = renameField {
            // Field, Done (1pt trailing padding), then the Spacer: the field takes the room.
            name.isHidden = true
            end -= gap + (M.iconInset - M.padding)
            let doneWidth = done.fittingWidth
            end -= doneWidth
            done.frame = CGRect(x: end, y: top, width: doneWidth, height: rowHeight)
            end -= gap
            field.frame = CGRect(x: x, y: textY, width: max(end - x, 0), height: line)
        } else {
            name.isHidden = false
            end -= gap
            name.place(textRect: CGRect(x: x, y: textY, width: min(name.naturalWidth, max(end - x, 0)), height: line))
        }
    }

    private func setChevron(rotated: Bool) {
        guard let layer = chevron.layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: chevron.frame.midX, y: chevron.frame.midY)
        layer.bounds = CGRect(origin: .zero, size: chevron.frame.size)
        layer.setAffineTransform(CGAffineTransform(rotationAngle: rotated ? .pi / 2 : 0))
    }

    override var hoverRect: CGRect { bounds }

    override func tapped(at point: CGPoint) {
        // A click on the current space's name renames it in place, as in Arc.
        guard let h = header, let store = list?.store, !h.isRenaming, name.frame.contains(point),
              store.state.selectedSpaceID == h.spaceID else { return }
        store.beginRenaming(space: h.spaceID)
    }

    /// From the context menu: wait for the menu to finish closing, or the popover won't show.
    func openPicker(after delay: Double = 0) {
        guard let h = header, let store = list?.store else { return }
        pickerOpen = true
        // Next turn at the earliest, so the placeholder it hangs from exists.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.window != nil else { return }
            self.layoutSubtreeIfNeeded()
            SpaceIconPicker.present(store: store, spaceID: h.spaceID, from: self.iconButton) { [weak self] in
                self?.pickerOpen = false
            }
        }
    }

    override func contextMenu(at point: CGPoint) -> NSMenu? {
        guard let h = header, let list else { return nil }
        return SpaceContextMenus.menu(store: list.store, actions: list.actions, spaceID: h.spaceID)
    }
}

/// The space's context menu, shared by its header and (later) its icon in the strip (SwiftUI's
/// `SpaceContextMenu`). Arc's order and titles, from its menu on 1 Nov 2026.
@MainActor
enum SpaceContextMenus {
    static func menu(store: BrowserStore, actions: SidebarActions, spaceID: UUID) -> NSMenu {
        let menu = NSMenu()
        menu.add("Change Space Icon…") { actions.changeSpaceIcon(spaceID) }
        menu.add("Rename Space…") { store.beginRenaming(space: spaceID) }
        // Kite's own (Arc has no such field): what belongs here, so Claude opens tabs in the right space.
        menu.add("What's This Space For?…") { actions.describeSpace(spaceID) }
        menu.add("Edit Theme Color…") { actions.editTheme(spaceID) }
        if actions.showsProfiles, let index = store.state.spaceIndex(spaceID) {
            let current = store.state.profileDirectory(ofSpace: index)
            menu.addSubmenu("Set Profile") { sub in
                for profile in store.state.allProfiles {
                    sub.add(profile.name, checked: profile.directory == current) { actions.setProfile(spaceID, profile.directory) }
                }
                sub.addSeparator()
                sub.add("New Profile…") { actions.newProfile(spaceID) }
            }
        }
        menu.addSeparator()
        menu.add("New Folder") {
            guard let index = store.state.spaceIndex(spaceID) else { return }
            store.mutate { _ = $0.createFolder(name: "New Folder", inSpace: index) }
        }
        // Arc's binary lists Live Folders right after New Folder.
        if let controller = LiveFoldersController.shared, let index = store.state.spaceIndex(spaceID) {
            menu.addSubmenu("Live Folders") { sub in
                for source in LiveFolder.Source.allCases {
                    sub.add(source.displayName, checked: store.state.liveFolder(source, inSpace: index) != nil) {
                        controller.toggle(source, inSpace: spaceID)
                    }
                }
            }
        }
        menu.addSeparator()
        menu.add("Delete Space", enabled: store.state.spaces.count >= 2) { actions.deleteSpace(spaceID) }
        return menu
    }
}

/// A clickable area that draws nothing itself (the header's icon button).
final class SidebarPassthroughButton: SidebarFlippedView {
    var action: () -> Void = {}
    private var pressed = false
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        if pressed, bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}

/// The header's Done while renaming: 12pt semibold text at 60%.
private final class SidebarDoneButton: SidebarFlippedView {
    var action: () -> Void = {}
    private let label = SidebarLabel(size: M.headerFontSize - 1, weight: .semibold, opacity: 0.6)

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.stringValue = "Done"
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Done")
    }

    var fittingWidth: CGFloat { label.naturalWidth }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let line = label.lineHeight
        label.place(textRect: CGRect(x: 0, y: ((bounds.height - line) / 2).rounded(.down), width: bounds.width, height: line))
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
    override func mouseDown(with event: NSEvent) {}
}

/// The header's name field: Return commits, Escape cancels, leaving it commits.
private final class SpaceRenameField: NSTextField, NSTextFieldDelegate {
    var onCommit: (String) -> Void = { _ in }
    var onCancel: () -> Void = {}
    private var finished = false

    init() {
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: M.headerFontSize, weight: .semibold)
        textColor = .labelColor
        placeholderString = "Space Name"
        cell?.isScrollable = true
        cell?.wraps = false
        delegate = self
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func begin(with text: String) {
        stringValue = text
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
            self.currentEditor()?.selectAll(nil)
        }
    }

    func commit() { finish { onCommit(stringValue) } }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finish { onCancel() }
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) { commit() }

    private func finish(_ body: () -> Void) {
        guard !finished else { return }
        finished = true
        body()
    }
}

// MARK: - Today divider

/// The line between pinned and Today tabs, with Arc's Tidy and Clear buttons at its right end
/// (UnpinnedSectionDividerCellView, SwiftUI's `TodayDivider`). Both fade in while the pointer is on the row
/// (Arc: ease-out 0.1 s alpha). Tidy turns while Claude works; Clear runs Clear Today for this space, or keeps
/// the selected tab when it's one of several (no arrow then).
final class TodayDividerRowCell: SidebarRowCell {
    private let line = FillView()
    private let tidy = TidyButton()
    private let clear = ClearButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        line.cornerRadius = 0
        addSubview(line)
        addSubview(tidy)
        addSubview(clear)
        tidy.alphaValue = 0
        clear.alphaValue = 0
        setAccessibilityElement(false)
    }

    private var divider: SidebarRowModel.Divider? {
        if case .divider(let d)? = model { return d }
        return nil
    }

    override func update() {
        guard let d = divider, let list else { return }
        let actions = list.actions, id = d.spaceID
        line.fill = { _ in NSColor.labelColor.withAlphaComponent(d.showsLine ? M.dividerOpacity : 0) }
        tidy.isTidying = d.isTidying
        tidy.action = { actions.tidyTabs(id) }
        clear.showsArrow = d.clearAction == .clearAll
        clear.toolTip = d.clearAction == .clearAll ? "Clear Today tabs" : "Clear unselected Today tabs"
        clear.action = { actions.clearToday(id) }
        applyVisibility(animated: true)
        super.update()
    }

    override var hoverRect: CGRect { bounds }

    override func hoverChanged() {
        applyVisibility(animated: true)
        needsLayout = true
    }

    private func applyVisibility(animated: Bool) {
        guard let d = divider else { return }
        let showsTidy = d.canTidy && (isHovered || d.isTidying)
        let showsClear = d.canClear && isHovered
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.1 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            tidy.animator().alphaValue = showsTidy ? 1 : 0
            clear.animator().alphaValue = showsClear ? 1 : 0
        }
        tidy.isEnabled = showsTidy
        clear.isEnabled = showsClear
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        line.frame = CGRect(x: M.dividerInset, y: (h - M.dividerThickness) / 2, width: bounds.width - 2 * M.dividerInset,
                            height: M.dividerThickness)
        guard let d = divider else { return }
        var end = bounds.width - M.dividerInset
        // The HStack holds only what shows; a hidden Tidy leaves no gap.
        let showsTidy = d.canTidy && (isHovered || d.isTidying)
        let showsClear = d.canClear && isHovered
        if showsClear || clear.alphaValue > 0 {
            let w = clear.fittingWidth
            end -= w
            clear.frame = CGRect(x: end, y: 0, width: w, height: h)
            end -= 6
        }
        if showsTidy || tidy.alphaValue > 0 {
            let w = tidy.fittingWidth
            end -= w
            tidy.frame = CGRect(x: end, y: (h - 18) / 2, width: w, height: 18)
        }
    }
}

/// Tidy: a turning wand and "Tidy" on the field's wash (a capsule), 75% (60% while tidying).
private final class TidyButton: SidebarFlippedView {
    var action: () -> Void = {}
    var isEnabled = true
    var isTidying = false { didSet { if isTidying != oldValue { applyTidying() } } }
    private let fill = FillView()
    private let wand = SidebarImageView()
    private let label = SidebarLabel(size: 11, weight: .semibold, opacity: 1)
    private let content = SidebarPassthroughView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        // SwiftUI clamps ChromeFill's 11pt corners to half the 18pt height (a capsule), which the 5pt clip
        // over it doesn't cut into.
        fill.cornerRadius = 9
        fill.fill = chromeFill(M.hoverFill)
        addSubview(content)
        content.addSubview(fill)
        wand.image = rawSymbol("wand.and.stars", pointSize: 10, weight: .semibold)
        wand.contentTintColor = .labelColor
        wand.wantsLayer = true
        content.addSubview(wand)
        label.stringValue = "Tidy"
        content.addSubview(label)
        content.alphaValue = 0.75
        toolTip = "Organize Today Tabs"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Tidy")
    }

    private var wandSize: NSSize {
        NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))?.size ?? NSSize(width: 12, height: 12)
    }

    var fittingWidth: CGFloat { 6 + wandSize.width + 3 + label.naturalWidth + 6 }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        content.frame = bounds
        fill.frame = content.bounds
        let ws = wandSize
        wand.frame = CGRect(x: 6, y: (bounds.height - ws.height) / 2, width: ws.width, height: ws.height)
        let line = label.lineHeight
        label.place(textRect: CGRect(x: wand.frame.maxX + 3, y: ((bounds.height - line) / 2).rounded(.down), width: label.naturalWidth, height: line))
        applyTidying()
    }

    private func applyTidying() {
        content.alphaValue = isTidying ? 0.6 : 0.75
        guard let layer = wand.layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: wand.frame.midX, y: wand.frame.midY)
        if isTidying {
            guard layer.animation(forKey: "turn") == nil else { return }
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = 2 * Double.pi
            turn.duration = 1
            turn.repeatCount = .infinity
            layer.add(turn, forKey: "turn")
        } else {
            layer.removeAnimation(forKey: "turn")
        }
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard isEnabled, !isTidying, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action()
    }
}

/// Arc's SidebarClearButton: a bold arrow 2pt left of "Clear", no background. Pressing dims it and drops the
/// arrow 3pt (0.175 s); the click counts only if the pointer is still on the button when it's let go.
private final class ClearButton: SidebarFlippedView {
    var action: () -> Void = {}
    var isEnabled = true
    var showsArrow = true { didSet { needsLayout = true } }
    private let arrow = SidebarImageView()
    private let label = SidebarLabel(size: 11, weight: .semibold, opacity: 1)
    private let content = SidebarPassthroughView()
    private var pressed = false { didSet { applyPressed() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(content)
        arrow.image = rawSymbol("arrow.down", pointSize: 11, weight: .bold)
        arrow.contentTintColor = .labelColor
        arrow.wantsLayer = true
        content.addSubview(arrow)
        label.stringValue = "Clear"
        content.addSubview(label)
        content.alphaValue = 0.75
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Clear")
    }

    private var arrowSize: NSSize {
        NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))?.size ?? NSSize(width: 10, height: 12)
    }

    var fittingWidth: CGFloat { (showsArrow ? arrowSize.width + 2 : 0) + label.naturalWidth }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        content.frame = bounds
        var x: CGFloat = 0
        arrow.isHidden = !showsArrow
        if showsArrow {
            let s = arrowSize
            arrow.frame = CGRect(x: 0, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
            x = s.width + 2
        }
        let line = label.lineHeight
        // Half a point above plain centring in the 25pt row: where SwiftUI's button put it (measured, 3 Nov 2026).
        label.place(textRect: CGRect(x: x, y: (bounds.height - line) / 2 - 0.5, width: label.naturalWidth, height: line))
    }

    private func applyPressed() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.175
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            content.animator().alphaValue = pressed ? 0.5 : 0.75
            arrow.layer?.setAffineTransform(pressed ? CGAffineTransform(translationX: 0, y: 3) : .identity)
        }
    }

    override func mouseDown(with event: NSEvent) { if isEnabled { pressed = true } }
    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if pressed != inside, isEnabled { pressed = inside }
    }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside, isEnabled { action() }
    }
}

// MARK: - Instant Links

/// Arc's `InstantLinksCellView` (SwiftUI's `InstantLinksRow`): the Today row that stands in for Instant Links'
/// results while they're found. The Arc Max flower in the favicon's place (spinning while it loads), Arc's
/// title, and a close button on hover that cancels it.
final class InstantLinksRowCell: SidebarRowCell {
    private let pill = FillView()
    private let flower = MaxFlowerView()
    private let title = SidebarLabel(size: M.tabFontSize)
    private let close = SymbolButton(symbol: "xmark", pointSize: 9, weight: .bold, label: "Close")

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(pill)
        flower.alphaValue = M.tabTextOpacity
        addSubview(flower)
        addSubview(title)
        addSubview(close)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("InstantLinksRow")
    }

    override func update() {
        guard case .instantLinks(let pending)? = model, let list else { return }
        flower.spinning = pending.status == .loading
        title.stringValue = pending.title
        let actions = list.actions
        close.action = { actions.dismissInstantLinks(pending.id) }
        super.update()
    }

    override func layout() {
        super.layout()
        let p = pillRect, h = p.height
        pill.frame = p
        pill.fill = tabPillFill(selected: false, hovered: isHovered)
        let side = MaxFlowerView.size
        flower.frame = CGRect(x: M.iconInset + (M.iconSize - side) / 2, y: p.minY + (h - side) / 2, width: side, height: side)
        // Arc: the title stack starts 6pt after the icon's container.
        let x = M.iconInset + M.iconSize + 6
        close.isHidden = !isHovered
        var end = p.width - 6
        if isHovered {
            end -= 24
            close.frame = CGRect(x: end, y: p.minY + (h - 24) / 2, width: 24, height: 24)
        }
        let line = title.lineHeight
        let y = p.minY + ((h - line) / 2).rounded(.down) + (h - line).truncatingRemainder(dividingBy: 2) / 2
        // The HStack's Spacer has no spacing of its own (spacing 0).
        title.place(textRect: CGRect(x: x, y: y, width: min(title.naturalWidth, max(end - x, 0)), height: line))
    }
}

/// The Arc Max flower, drawn once; while loading it turns clockwise once a second and
/// bobs 1.5pt down and up over 2 s (Arc's `AnimatedFlowerView`), on the render server.
final class MaxFlowerView: NSView {
    /// `AnimatedFlowerView`'s size.
    static let size: CGFloat = 16
    var spinning = false { didSet { if spinning != oldValue { applySpinning() } } }
    private let flower = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(flower)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() { needsLayout = true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flower.bounds = bounds
        flower.position = CGPoint(x: bounds.midX, y: bounds.midY)
        flower.contentsScale = window?.backingScaleFactor ?? 2
        var color = NSColor.labelColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor.labelColor.cgColor }
        flower.contents = Self.image(side: bounds.width, scale: flower.contentsScale, color: color)
        CATransaction.commit()
        applySpinning()
    }

    private func applySpinning() {
        guard spinning else {
            flower.removeAllAnimations()
            return
        }
        guard flower.animation(forKey: "turn") == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi
        turn.duration = 1
        turn.repeatCount = .infinity
        flower.add(turn, forKey: "turn")
        // position.y: 0, −1.5, 0, +1.5, 0 at quarters; ease-out away from the middle, ease-in back. The
        // layer's y points up, so Arc's −1.5 is down.
        let bob = CAKeyframeAnimation(keyPath: "position.y")
        let y = bounds.midY
        bob.values = [y, y - 1.5, y, y + 1.5, y]
        bob.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        bob.timingFunctions = [.init(name: .easeOut), .init(name: .easeIn), .init(name: .easeOut), .init(name: .easeIn)]
        bob.duration = 2
        bob.repeatCount = .infinity
        flower.add(bob, forKey: "bob")
    }

    /// Drawn by Kite from measurements of Arc's 22pt `MaxFlowerIcon` template: the outline of four overlapping
    /// round petals around a hollow diamond, with a stalk from the diamond into each petal (units of 1/22).
    static func image(side: CGFloat, scale: CGFloat, color: CGColor) -> CGImage? {
        let px = Int((side * scale).rounded())
        guard px > 0, let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        // Flip so the drawing reads top-down like the Canvas it copies.
        ctx.translateBy(x: 0, y: side)
        ctx.scaleBy(x: 1, y: -1)
        let unit = side / 22
        let center = CGPoint(x: side / 2, y: side / 2)
        let offsets = [CGPoint(x: 0, y: -1), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: -1, y: 0)]
        func petals(radius: CGFloat) -> CGPath {
            let path = CGMutablePath()
            for o in offsets {
                let c = CGPoint(x: center.x + o.x * 5.5 * unit, y: center.y + o.y * 5.5 * unit)
                path.addEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
            }
            return path
        }
        ctx.setFillColor(color)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(petals(radius: (4.35 + 0.65) * unit))
        ctx.fillPath()
        ctx.setBlendMode(.destinationOut)
        ctx.addPath(petals(radius: (4.35 - 0.65) * unit))
        ctx.fillPath()
        ctx.endTransparencyLayer()
        ctx.setBlendMode(.normal)
        let corner = 2.7 * unit
        let diamond = CGMutablePath(), stalks = CGMutablePath()
        for (i, o) in offsets.enumerated() {
            let point = CGPoint(x: center.x + o.x * corner, y: center.y + o.y * corner)
            if i == 0 { diamond.move(to: point) } else { diamond.addLine(to: point) }
            stalks.move(to: point)
            stalks.addLine(to: CGPoint(x: center.x + o.x * 6.9 * unit, y: center.y + o.y * 6.9 * unit))
        }
        diamond.closeSubpath()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(1.3 * unit)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(diamond)
        ctx.addPath(stalks)
        ctx.strokePath()
        return ctx.makeImage()
    }
}
