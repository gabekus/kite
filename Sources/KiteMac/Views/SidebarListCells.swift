import AppKit
import KiteCore
import SwiftUI

private typealias M = ArcMetrics.Sidebar

/// Arc's folder nesting per level (see `ArcMetrics.Sidebar.nestingIndent`).
private func rowIndent(_ depth: Int) -> CGFloat { CGFloat(depth) * M.nestingIndent }

/// A row of the space list. Subclasses lay out their own views; this handles hover, presses, taps,
/// double-clicks, drags and the context menu, so every row behaves alike.
@MainActor
class SidebarRowCell: NSView {
    private(set) var model: SidebarRowModel?
    weak var list: SidebarSpaceList?
    private(set) var isHovered = false
    private var tracking: NSTrackingArea?
    private var pressStart: CGPoint?
    private var dragging = false

    static func make(kind: String) -> SidebarRowCell {
        switch kind {
        case "tab": TabRowCell()
        case "folder": FolderRowCell()
        case "split": SplitRowCell()
        case "newTab": NewTabRowCell()
        case "header": SpaceHeaderRowCell()
        case "divider": TodayDividerRowCell()
        default: InstantLinksRowCell()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func configure(_ model: SidebarRowModel, list: SidebarSpaceList) {
        self.list = list
        let changed = model != self.model
        self.model = model
        if changed { update() }
    }

    /// Shows `model`. Subclasses override.
    func update() { needsLayout = true }

    /// Where the row's pill sits: 2.5pt from the top (under a Tidy Tabs header), 36pt high.
    var pillRect: CGRect {
        let header = model?.headerHeight ?? 0
        return CGRect(x: 0, y: header + (M.rowPitch - M.pillHeight) / 2, width: bounds.width, height: M.pillHeight)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: hoverRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    /// The area whose hover the row shows: its pill (rows with a header track that separately).
    var hoverRect: CGRect { model?.isPill == true ? pillRect : bounds }

    override func layout() {
        super.layout()
        updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        hoverChanged()
    }

    func hoverChanged() { needsLayout = true }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
        pressStart = nil
        dragging = false
    }

    // MARK: Presses

    /// A click on the row (SwiftUI's tap gesture: on release, without waiting for a second click).
    func tapped(at point: CGPoint) {}
    /// A second click (SwiftUI's simultaneous double-tap).
    func doubleTapped() {}

    /// Whether a press at `point` (row coordinates) belongs to the row at all.
    func acceptsPress(at point: CGPoint) -> Bool {
        model?.isPill == true ? pillRect.contains(point) : true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let view = super.hitTest(point) else { return nil }
        if view === self, !acceptsPress(at: convert(point, from: superview)) { return nil }
        return view
    }

    override func mouseDown(with event: NSEvent) {
        guard let list else { return }
        // ⌃-click is a right-click.
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        pressStart = list.sidebarPoint(event)
        dragging = false
        if event.clickCount == 2 { doubleTapped() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let list, let start = pressStart, let model, model.isDraggable else { return }
        let point = list.sidebarPoint(event)
        if !dragging {
            // SwiftUI's DragGesture(minimumDistance: 4).
            guard hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
            dragging = true
            list.beginDrag(model, at: start)
        }
        list.moveDrag(to: point)
    }

    override func mouseUp(with event: NSEvent) {
        guard let list, pressStart != nil else { return }
        pressStart = nil
        if dragging {
            dragging = false
            list.endDrag(at: list.sidebarPoint(event))
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point), event.clickCount <= 1 { tapped(at: point) }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        showSidebarMenu(menu, with: event, for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard acceptsPress(at: point) else { return nil }
        return contextMenu(at: point)
    }

    func contextMenu(at point: CGPoint) -> NSMenu? { nil }
}

// MARK: - Shared pieces

/// A 24pt slot with a dot in it: a live folder's unread dot (6pt, primary) or Claude's needs-you dot
/// (7pt, Claude's orange).
private final class DotView: NSView {
    private let dot = FillView()
    var diameter: CGFloat = 6 { didSet { needsLayout = true } }
    var color: (Bool) -> NSColor = { _ in .labelColor } { didSet { dot.fill = color } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(dot)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        dot.cornerRadius = diameter / 2
        dot.frame = CGRect(x: (bounds.width - diameter) / 2, y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
    }
}

extension NSColor {
    /// Claude's orange.
    static let claude = NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)
}

/// Claude's mark in Claude's orange: the Claude folder's icon, and a session folder's while Claude works
/// in it, when it turns slowly (once every 6 s, on the render server: no work on the main thread).
private final class ClaudeMarkView: NSView {
    private let mark = CAShapeLayer()
    var turning = false { didSet { if turning != oldValue { applyTurning() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        mark.fillColor = NSColor.claude.cgColor
        layer?.addSublayer(mark)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Claude")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side: CGFloat = 13
        mark.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        mark.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // The shape's own y runs down; the layer's runs up.
        var flip = CGAffineTransform(translationX: 0, y: side).scaledBy(x: 1, y: -1)
        mark.path = ClaudeMark().path(in: CGRect(x: 0, y: 0, width: side, height: side)).cgPath.copy(using: &flip)
        CATransaction.commit()
        applyTurning()
    }

    private func applyTurning() {
        setAccessibilityLabel(turning ? "Claude is working" : "Claude")
        guard turning else {
            mark.removeAnimation(forKey: "turn")
            return
        }
        guard mark.animation(forKey: "turn") == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        // Clockwise, in step with the wall clock like the SwiftUI timeline was.
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi
        turn.duration = 6
        turn.repeatCount = .infinity
        turn.timeOffset = Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6)
        mark.add(turn, forKey: "turn")
    }
}

/// A ring in Claude's orange around a tab's favicon while Claude drives the tab, breathing gently (period
/// 2.4 s, opacity 0.1 to 1 of 0.55 + 0.45, on the render server).
private final class ClaudeRingView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 5
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor.claude.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.unknown)
        setAccessibilityLabel("Claude is controlling this tab")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let layer, layer.animation(forKey: "breathe") == nil else { return }
        // opacity = 0.55 + 0.45 · (sin(t·π/1.2) + 1) / 2
        let breathe = CAKeyframeAnimation(keyPath: "opacity")
        let steps = 48
        breathe.values = (0...steps).map { i -> Double in
            let t = Double(i) / Double(steps) * 2.4
            return 0.55 + 0.45 * (sin(t * .pi / 1.2) + 1) / 2
        }
        breathe.duration = 2.4
        breathe.repeatCount = .infinity
        breathe.calculationMode = .linear
        breathe.timeOffset = Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4)
        layer.add(breathe, forKey: "breathe")
    }
}

/// A Peek open over the tab (Arc's `ModalV2SidebarBadgeView`): its icon on a faint rounded square.
private final class PeekBadgeView: NSView {
    private typealias B = LinkPeek.Badge
    private let fill = FillView()
    private let icon = FaviconImageView(side: B.iconSize)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fill.cornerRadius = B.cornerRadius
        fill.fill = { dark in dark ? NSColor.white.withAlphaComponent(B.fillOpacityDark) : NSColor.black.withAlphaComponent(B.fillOpacityLight) }
        addSubview(fill)
        icon.layer?.cornerRadius = B.iconCornerRadius
        addSubview(icon)
        setAccessibilityElement(true)
        setAccessibilityIdentifier("sidebarTabCellPeekBadge")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // It takes no clicks of its own: clicking it is clicking the row.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ badge: LinkPeekBadge) { icon.show(page: badge.page, icon: badge.icon) }

    override func layout() {
        super.layout()
        fill.frame = bounds
        icon.frame = CGRect(x: (bounds.width - B.iconSize) / 2, y: (bounds.height - B.iconSize) / 2, width: B.iconSize, height: B.iconSize)
    }
}

/// An in-place rename field (Arc's EditableTextFieldWithCompletionHandler): Return commits, Escape
/// cancels, and leaving the field commits.
private final class RenameField: NSTextField, NSTextFieldDelegate {
    var onCommit: (String) -> Void = { _ in }
    var onCancel: () -> Void = {}
    private var finished = false

    init(size: CGFloat, weight: NSFont.Weight, placeholder: String) {
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: size, weight: weight)
        textColor = .labelColor
        placeholderString = placeholder
        lineBreakMode = .byClipping
        cell?.isScrollable = true
        cell?.wraps = false
        delegate = self
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func begin(with text: String) {
        finished = false
        stringValue = text
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
            self.currentEditor()?.selectAll(nil)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            finish { onCommit(stringValue) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finish { onCancel() }
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        finish { onCommit(stringValue) }
    }

    private func finish(_ body: () -> Void) {
        guard !finished else { return }
        finished = true
        body()
    }
}

/// A SwiftUI view inside an AppKit row, for the rare animated states (the speaker, a Tidy Tab Titles
/// rename) that exist only while they play.
private final class Island<Content: View>: NSHostingView<Content> {
    /// False for what only draws (the rename's title and sparks): presses go to the row.
    var takesPresses = true
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { takesPresses ? super.hitTest(point) : nil }
}

// MARK: - Tab rows

/// A tab's row (SwiftUI's `TabRow`): favicon, speaker, title, then the needs-you dot, unread dot, Back to
/// Pinned URL, close and the Peek badge, on Arc's pill. With a Tidy Tabs header above it when it heads a
/// group, and a split preview beside it while a drag offers one.
final class TabRowCell: SidebarRowCell {
    private let content = SidebarPassthroughView()
    private let pill = FillView()
    private let favicon = FaviconImageView(side: M.iconSize)
    private let title = SidebarLabel(size: M.tabFontSize)
    private let close = SymbolButton(symbol: "xmark", pointSize: 9, weight: .bold)
    private let reset = SymbolButton(symbol: "arrow.uturn.backward", pointSize: 10, weight: .semibold, label: "Back to Pinned URL")
    private let unread = DotView()
    private let needsYou = DotView()
    /// Claude is done here: green (`ClaudeTabState`).
    private let finished = DotView()
    private let peek = PeekBadgeView()
    private let splitPreview = FillView()
    private var ring: ClaudeRingView?
    private var speaker: Island<TabAudioButtonView>?
    private var aiTitle: Island<AIRenameTitle>?
    private var sparks: Island<AIRenameSparks>?
    private var renameField: RenameField?
    private let header = GroupHeaderView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        splitPreview.cornerRadius = M.cornerRadius
        splitPreview.fill = { _ in NSColor(srgbRed: 0.98, green: 0.984, blue: 1, alpha: SplitDropPreview.fill) }
        splitPreview.isHidden = true
        addSubview(splitPreview)
        addSubview(content)
        content.addSubview(pill)
        content.addSubview(favicon)
        content.addSubview(title)
        unread.diameter = 6
        unread.alphaValue = M.tabTextOpacity
        unread.color = { _ in .labelColor }
        unread.setAccessibilityElement(true)
        unread.setAccessibilityLabel("Unread")
        needsYou.diameter = 7
        needsYou.color = { _ in .claude }
        needsYou.setAccessibilityElement(true)
        needsYou.setAccessibilityLabel("Claude needs you")
        finished.diameter = 7
        finished.color = { _ in .systemGreen }
        finished.setAccessibilityElement(true)
        finished.setAccessibilityLabel("Claude is done")
        for view in [finished, needsYou, unread, reset, close, peek] as [NSView] { content.addSubview(view) }
        reset.toolTip = "Back to Pinned URL"
        addSubview(header)
        title.setAccessibilityElement(true)
    }

    private var tab: SidebarRowModel.Tab? {
        if case .tab(let t)? = model { return t }
        return nil
    }

    override func update() {
        guard let t = tab, let list else { return }
        let store = list.store, actions = list.actions
        let id = t.tab.id
        let liveIcon = t.liveIconTab ? LiveFolderIcons.pullRequest(t.tab, dark: isDarkAppearance) : nil
        favicon.show(page: t.tab.url, icon: liveIcon ?? t.tab.faviconURL)
        title.stringValue = t.tab.displayTitle
        title.setAccessibilityValue(t.tab.displayTitle)
        close.toolTip = t.isPinned ? "Unload" : "Close Tab"
        close.setAccessibilityLabel(nil)
        close.action = { actions.closeTab(id) }
        reset.action = { actions.resetTab(id) }
        needsYou.toolTip = t.claudeNeedsYou
        finished.toolTip = t.claudeDone
        finished.setAccessibilityHelp(t.claudeDone)
        needsYou.setAccessibilityHelp(t.claudeNeedsYou)
        // One of three states: needs you (orange title and dot), working (the title shimmers), done (green dot).
        title.shimmers = t.claudeControl != nil && t.claudeNeedsYou == nil
        if !title.shimmers { title.textColor = t.claudeNeedsYou != nil ? .claude : .labelColor }
        if let badge = t.peek { peek.show(badge) }

        // Claude's ring around the favicon.
        if let help = t.claudeControl {
            let ring = self.ring ?? ClaudeRingView()
            if self.ring == nil {
                ring.alphaValue = 0
                content.addSubview(ring)
                self.ring = ring
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    ring.animator().alphaValue = 1
                }
            }
            ring.toolTip = help
        } else if let ring {
            self.ring = nil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                ring.animator().alphaValue = 0
            } completionHandler: { ring.removeFromSuperview() }
        }

        // The speaker, while the tab plays or is muted: SwiftUI's animated speaker in a small host.
        if TabAudioButton.isShown(isAudible: t.isAudible, isMuted: t.isMuted) {
            let view = TabAudioButtonView(isMuted: t.isMuted) { actions.toggleMute(id) }
            if let speaker {
                speaker.rootView = view
            } else {
                let island = Island(rootView: view)
                island.sizingOptions = []
                content.addSubview(island)
                speaker = island
            }
        } else if let speaker {
            speaker.removeFromSuperview()
            self.speaker = nil
        }

        // A Tidy Tab Titles rename: the title wipes over from the old one, with sparks.
        if let rename = t.aiRename, !t.isRenaming {
            let titleView = AIRenameTitle(oldTitle: rename.oldTitle, newTitle: t.tab.displayTitle, start: rename.start)
            if let aiTitle { aiTitle.rootView = titleView } else {
                let island = Island(rootView: titleView)
                island.takesPresses = false
                island.sizingOptions = []
                content.addSubview(island)
                aiTitle = island
            }
            if sparks == nil {
                let island = Island(rootView: AIRenameSparks(start: rename.start, titleWidth: 0))
                island.takesPresses = false
                island.sizingOptions = []
                content.addSubview(island)
                sparks = island
            }
        } else {
            aiTitle?.removeFromSuperview()
            aiTitle = nil
            sparks?.removeFromSuperview()
            sparks = nil
        }

        // Renaming in place.
        if t.isRenaming {
            if renameField == nil {
                let field = RenameField(size: M.tabFontSize, weight: .regular, placeholder: "Keep it short and sweet!")
                field.onCommit = { name in
                    guard store.renamingTabID == id else { return }
                    store.mutate { $0.renameTab(id, to: name) }
                    store.endRenamingTab()
                }
                field.onCancel = { store.endRenamingTab() }
                content.addSubview(field)
                renameField = field
                field.begin(with: t.tab.displayTitle)
            }
        } else if let field = renameField {
            renameField = nil
            field.removeFromSuperview()
        }

        if let group = t.groupHeader {
            header.isHidden = false
            header.show(group, onClose: { actions.closeTabs(group.tabIDs) },
                        onRemove: { actions.removeTabGroupHeader(group.id) })
        } else {
            header.isHidden = true
        }
        super.update()
    }

    override func hoverChanged() { needsLayout = true }

    override func layout() {
        super.layout()
        guard let t = tab else { return }
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: M.dividerRowHeight)
        let rowPill = pillRect
        // A split preview takes half the row, 12pt from the tab's half.
        var contentRect = rowPill
        splitPreview.isHidden = t.splitSide == nil
        if let side = t.splitSide {
            let gap = SplitDropPreview.gap
            let half = (rowPill.width - gap) / 2
            let left = CGRect(x: rowPill.minX, y: rowPill.minY, width: half, height: rowPill.height)
            let right = CGRect(x: rowPill.minX + half + gap, y: rowPill.minY, width: half, height: rowPill.height)
            splitPreview.frame = side == .left ? left : right
            contentRect = side == .left ? right : left
        }
        content.frame = contentRect
        let w = contentRect.width, h = contentRect.height
        pill.frame = CGRect(x: 0, y: 0, width: w, height: h)
        pill.fill = tabPillFill(selected: t.isSelected, hovered: isHovered)

        // Leading: favicon, the speaker, then the title.
        var x = M.iconInset + rowIndent(t.depth)
        favicon.frame = CGRect(x: x, y: (h - M.iconSize) / 2, width: M.iconSize, height: M.iconSize)
        ring?.frame = favicon.frame.insetBy(dx: -3, dy: -3)
        x += M.iconSize + M.iconTextGap
        if let speaker {
            let side = TabAudioButton.side
            speaker.frame = CGRect(x: x, y: (h - side) / 2, width: side, height: side)
            x += side + TabAudioButton.spacingAfter
        }

        // Trailing, right to left: the Peek badge, close, Back to Pinned URL, unread, needs-you.
        let renaming = t.isRenaming
        var end = w - 6
        var trailing: [NSView] = []
        func place(_ view: NSView, width: CGFloat, height: CGFloat, shown: Bool) {
            view.isHidden = !shown
            guard shown else { return }
            end -= width
            view.frame = CGRect(x: end, y: (h - height) / 2, width: width, height: height)
            end -= M.iconTextGap
            trailing.append(view)
        }
        place(peek, width: LinkPeek.Badge.side, height: LinkPeek.Badge.side, shown: t.peek != nil && !renaming)
        place(close, width: 24, height: 24, shown: isHovered && !renaming && t.showsClose)
        place(reset, width: 24, height: 24, shown: isHovered && t.canReset && !renaming)
        place(unread, width: 24, height: 24, shown: t.isUnread && !isHovered)
        place(needsYou, width: 24, height: 24, shown: t.claudeNeedsYou != nil && !renaming)
        place(finished, width: 24, height: 24, shown: t.claudeDone != nil && t.claudeNeedsYou == nil && !renaming)
        // The spacer after the title keeps the HStack's gap on both sides of it.
        let titleEnd = trailing.isEmpty ? w - 6 - M.iconTextGap : end - M.iconTextGap
        let room = max(titleEnd - x, 0)

        let lineHeight = title.lineHeight
        let textY = ((h - lineHeight) / 2).rounded(.down) + (h - lineHeight).truncatingRemainder(dividingBy: 2) / 2
        if let field = renameField {
            title.isHidden = true
            field.frame = CGRect(x: x, y: textY, width: room, height: lineHeight)
        } else if let aiTitle {
            title.isHidden = true
            aiTitle.frame = CGRect(x: x, y: textY, width: room, height: lineHeight)
        } else {
            title.isHidden = false
            title.place(textRect: CGRect(x: x, y: textY, width: min(title.naturalWidth, room), height: lineHeight))
        }
        if let sparks, case .tab(let t)? = model, let rename = t.aiRename {
            let spill: CGFloat = 60
            sparks.frame = CGRect(x: -spill, y: -spill, width: w + 2 * spill, height: h + 2 * spill)
            sparks.rootView = AIRenameSparks(start: rename.start, titleWidth: room)
        }
    }

    override func tapped(at point: CGPoint) {
        guard let t = tab, let store = list?.store, !t.isRenaming else { return }
        store.mutate { $0.select(tab: t.tab.id) }
    }

    override func doubleTapped() {
        guard let t = tab else { return }
        list?.actions.renameTab(t.tab.id)
    }

    override var hoverRect: CGRect { pillRect }

    override func contextMenu(at point: CGPoint) -> NSMenu? {
        guard let t = tab, let list else { return nil }
        if point.y < pillRect.minY { return header.isHidden ? nil : header.groupMenu }
        let store = list.store, actions = list.actions, id = t.tab.id
        let menu = NSMenu()
        if t.claudeControl != nil {
            menu.add("Stop Claude") { list.claude.automation?.stop(tabs: [id]) }
            menu.addSeparator()
        } else if t.claudeDone != nil || t.claudeNeedsYou?.hasPrefix(ClaudeTabState.stoppedHere) == true {
            menu.add("Clear Claude's Mark") { list.claude.automation?.clearTabMark(id) }
            menu.addSeparator()
        }
        menu.add("Add to Favorites") { store.mutate { $0.toggleFavorite(tab: id) } }
        menu.add(t.isPinned ? "Unpin Tab" : "Pin Tab") { store.mutate { $0.togglePin(tab: id) } }
        if t.canReset {
            menu.add("Back to Pinned URL") { actions.resetTab(id) }
            menu.add("Separate From Pinned Tab") { actions.separateFromPinnedTab(id) }
        }
        if t.isPinned && t.tab.pinnedURL != nil {
            menu.addEditPinnedPage(onEdit: { actions.editPinnedURL(id) }, onReplace: { actions.replacePinnedURL(id) })
        }
        menu.addCopyLinkItems(t.tab)
        menu.add("Rename…") { actions.renameTab(id) }
        if TabAudioButton.isShown(isAudible: t.isAudible, isMuted: t.isMuted) {
            menu.add(TabAudioButton.menuTitle(isMuted: t.isMuted)) { actions.toggleMute(id) }
        }
        menu.addSeparator()
        // Arc's PlatformGeneration items: Add Split View ("Add a new split view") on the tab that's on
        // screen, Open in Split View ("Open item in split view") on one that isn't.
        let state = store.state
        if state.visibleTabs.contains(where: { $0.id == id }) {
            menu.add("Add Split View", enabled: (state.selectedSplit?.tabIDs.count ?? 0) < SplitView.maxPanes) {
                actions.addSplitViewWith(id)
            }
        } else {
            let canOpen = state.selectedTab.map { state.canDropSidebarItems([state.sidebarDragID(for: id)], besidePane: $0.id) } ?? false
            menu.add("Open in Split View", enabled: canOpen) { actions.openInSplitView(id) }
        }
        menu.add("Duplicate") { store.mutate { _ = $0.duplicate(tab: id) } }
        // SidebarMenu+MoveMenu: the root spaces. "New Folder with N Items" is only built for two or more
        // selected items, which Kite's sidebar can't select.
        menu.addSubmenu("Move to") { sub in
            for space in state.spaces {
                sub.add(space.labelWithIcon, enabled: space.id != t.space) { actions.moveTab(id, space.id) }
            }
        }
        menu.addSeparator()
        menu.add(t.isPinned ? "Unload Tab" : "Close Tab") { actions.closeTab(id) }
        menu.addArchiveTabsItems(state: state, relativeTo: id, actions: actions)
        return menu
    }

    override func acceptsPress(at point: CGPoint) -> Bool {
        pillRect.contains(point) || (!header.isHidden && point.y < pillRect.minY)
    }

    override func accessibilityChildren() -> [Any]? { super.accessibilityChildren() }
}

@MainActor
extension NSMenu {
    /// Copy Link and Copy link as Markdown, greyed out for a tab with no page yet.
    func addCopyLinkItems(_ tab: BrowserTab) {
        let url = tab.url, markdown = LinkFormat.markdown(tab)
        add("Copy Link", enabled: url != nil) { if let url { copyToPasteboard(url.absoluteString) } }
        add("Copy link as Markdown", enabled: markdown != nil) { if let markdown { copyToPasteboard(markdown) } }
    }

    /// Archive Other Tabs, Archive Tabs Below and Archive Tabs Above for a Today row (a tab, or a split by
    /// any of its panes), each greyed out when there's nothing on that side. Nothing for pinned rows.
    func addArchiveTabsItems(state: BrowserState, relativeTo id: UUID, actions: SidebarActions) {
        guard state.location(of: id)?.section == .unpinned else { return }
        for (title, which) in [("Archive Other Tabs", ArchiveTabsRelative.others), ("Archive Tabs Below", .below),
                               ("Archive Tabs Above", .above)] {
            add(title, enabled: !state.tabsToArchive(which, relativeTo: id).isEmpty) { actions.archiveTabs(id, which) }
        }
    }

    /// Arc's "Edit Pinned Page" submenu on a pinned tab or favorite (SidebarMenu+TabContextMenu).
    func addEditPinnedPage(onEdit: @escaping () -> Void, onReplace: @escaping () -> Void) {
        addSubmenu("Edit Pinned Page") { menu in
            menu.add("Edit…", onEdit)
            menu.add("Replace Pinned URL with Current", onReplace)
        }
    }
}

/// Arc's tab group header (TabGroupHeaderCellView) above a Tidy Tabs group: its name, a close button on
/// hover ("Close tab group") and Remove Header in its menu.
private final class GroupHeaderView: SidebarFlippedView {
    private let title = SidebarLabel(size: 11, weight: .semibold, opacity: 0.55)
    private let close = SymbolButton(symbol: "xmark", pointSize: 9, weight: .bold, label: "Close tab group")
    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { close.opacity = hovering ? 0.55 : 0 } }
    private var onRemove: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(title)
        close.opacity = 0
        close.toolTip = "Close tab group"
        addSubview(close)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    func show(_ group: TodayTabGroup, onClose: @escaping () -> Void, onRemove: @escaping () -> Void) {
        title.stringValue = group.title
        setAccessibilityLabel(group.title)
        close.action = onClose
        self.onRemove = onRemove
        needsLayout = true
    }

    var groupMenu: NSMenu {
        let menu = NSMenu()
        menu.add("Remove header", onRemove)
        return menu
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        close.frame = CGRect(x: bounds.width - M.iconInset - 16, y: (h - 16) / 2, width: 16, height: 16)
        let room = max(close.frame.minX - 4 - M.iconInset, 0)
        let line = title.lineHeight
        title.place(textRect: CGRect(x: M.iconInset, y: ((h - line) / 2).rounded(.down), width: min(title.naturalWidth, room), height: line))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    // Presses fall through to the row (the header rides on its tab).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        return view === self ? nil : view
    }
}

// MARK: - Folder rows

/// A folder's row (SwiftUI's `FolderRow`): the folder icon (or Claude's mark), the name, Claude's dot and
/// Stop, and a chevron on hover.
final class FolderRowCell: SidebarRowCell {
    private let pill = FillView()
    private let icon = SidebarImageView()
    private let mark = ClaudeMarkView()
    private let title = SidebarLabel(size: M.tabFontSize, weight: .semibold)
    private let needsYou = DotView()
    private let stop = SymbolButton(symbol: "stop.fill", pointSize: 8, weight: .bold, label: "Stop Claude")
    private let chevron = SidebarImageView()
    private var renameField: RenameField?
    private var popover: NSPopover?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(pill)
        icon.imageScaling = .scaleNone
        icon.contentTintColor = .labelColor
        icon.alphaValue = 0.75
        addSubview(icon)
        addSubview(mark)
        addSubview(title)
        needsYou.diameter = 7
        needsYou.color = { _ in .claude }
        addSubview(needsYou)
        stop.tint = .claude
        stop.opacity = 1
        stop.toolTip = "Stop Claude"
        addSubview(stop)
        // An un-framed symbol: its frame is the symbol image's own size, the glyph where the image puts it.
        chevron.image = rawSymbol("chevron.right", pointSize: 9, weight: .bold)
        chevron.imageScaling = .scaleNone
        chevron.contentTintColor = .labelColor
        chevron.wantsLayer = true
        addSubview(chevron)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    private var folderModel: SidebarRowModel.Folder? {
        if case .folder(let f)? = model { return f }
        return nil
    }

    override func update() {
        guard let f = folderModel, let list else { return }
        let store = list.store, actions = list.actions, folder = f.folder
        icon.image = symbolImage(folder.isExpanded ? "folder" : "folder.fill", pointSize: 14, box: NSSize(width: M.iconSize, height: M.iconSize),
                                 placement: .center)
        let claude = f.claudeActive || folder.ephemeral == true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            mark.animator().alphaValue = claude ? 1 : 0
            icon.animator().alphaValue = claude ? 0 : 0.75
        }
        mark.turning = f.claudeActive
        title.stringValue = folder.name
        setAccessibilityLabel(folder.name)
        setAccessibilityValue(folder.isExpanded ? "Expanded" : "Collapsed")
        toolTip = f.claudeActive ? "Claude is working in “\(folder.name)”" : nil
        needsYou.toolTip = f.claudeNeedsYou == 1 ? "Claude needs you in a tab here" : "Claude needs you in \(f.claudeNeedsYou) tabs here"
        stop.action = { [weak self] in self?.stopClaude() }

        if f.isRenaming {
            if renameField == nil {
                let field = RenameField(size: M.tabFontSize, weight: .semibold, placeholder: "")
                let id = folder.id
                field.onCommit = { name in
                    guard store.renamingFolderID == id else { return }
                    store.mutate { $0.renameFolder(id, to: name) }
                    store.endRenamingFolder()
                }
                field.onCancel = { store.endRenamingFolder() }
                addSubview(field)
                renameField = field
                field.begin(with: folder.name)
            }
        } else if let field = renameField {
            renameField = nil
            field.removeFromSuperview()
        }

        // A live folder's intro popover (Arc's LiveItemIntroPopover), to the folder's right.
        if f.showsIntro, popover == nil, let live = folder.live {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, self.popover == nil else { return }
                let popover = NSPopover()
                popover.behavior = .transient
                popover.contentViewController = NSHostingController(rootView: LiveFolderIntro(source: live.source))
                popover.delegate = self
                self.popover = popover
                WindowPresenter.show(popover, relativeTo: self.pillRect, of: self, preferredEdge: .maxX)
            }
        } else if !f.showsIntro, let popover {
            self.popover = nil
            popover.close()
        }
        _ = actions
        super.update()
    }

    private func stopClaude() {
        guard let f = folderModel, let automation = list?.claude.automation else { return }
        let tabs = Set(f.folder.items.tabs.map(\.id)).intersection(automation.controlledTabIDs)
        if !tabs.isEmpty { automation.stop(tabs: tabs) }
    }

    override func layout() {
        super.layout()
        guard let f = folderModel else { return }
        let p = pillRect, h = p.height
        pill.frame = p
        pill.fill = chromeFill(isHovered ? M.hoverFill : 0)
        var x = M.iconInset + rowIndent(f.depth)
        let iconRect = CGRect(x: x, y: p.minY + (h - M.iconSize) / 2, width: M.iconSize, height: M.iconSize)
        icon.frame = iconRect
        mark.frame = iconRect
        x += M.iconSize + M.iconTextGap

        let renaming = f.isRenaming
        // Trailing, right to left: chevron, Stop, Claude's dot.
        var end = p.width - M.iconInset
        let chevronSize = chevron.image?.size ?? .zero
        end -= chevronSize.width
        chevron.frame = CGRect(x: end, y: p.minY + (h - chevronSize.height) / 2, width: chevronSize.width, height: chevronSize.height)
        chevron.alphaValue = isHovered ? 0.5 : 0
        setRotation(f.folder.isExpanded ? 90 : 0)
        end -= M.iconTextGap
        let showsStop = f.claudeActive && isHovered && !renaming
        stop.isHidden = !showsStop
        if showsStop {
            end -= 24
            stop.frame = CGRect(x: end, y: p.minY + (h - 24) / 2, width: 24, height: 24)
            end -= M.iconTextGap
        }
        let showsDot = f.claudeNeedsYou > 0 && !renaming
        needsYou.isHidden = !showsDot
        if showsDot {
            end -= 24
            needsYou.frame = CGRect(x: end, y: p.minY + (h - 24) / 2, width: 24, height: 24)
            end -= M.iconTextGap
        }
        let room = max(end - M.iconTextGap - x, 0)
        let line = title.lineHeight
        let textY = p.minY + ((h - line) / 2).rounded(.down) + (h - line).truncatingRemainder(dividingBy: 2) / 2
        if let field = renameField {
            title.isHidden = true
            field.frame = CGRect(x: x, y: textY, width: room, height: line)
        } else {
            title.isHidden = false
            title.place(textRect: CGRect(x: x, y: textY, width: min(title.naturalWidth, room), height: line))
        }
    }

    /// The chevron turns about its centre (SwiftUI's `rotationEffect`); a flipped view's layer turns clockwise for a positive angle.
    private func setRotation(_ degrees: CGFloat) {
        guard let layer = chevron.layer else { return }
        let b = chevron.bounds
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: chevron.frame.midX, y: chevron.frame.midY)
        layer.bounds = b
        layer.setAffineTransform(CGAffineTransform(rotationAngle: degrees * .pi / 180))
    }

    override func tapped(at point: CGPoint) {
        guard let f = folderModel, !f.isRenaming, let store = list?.store else { return }
        store.mutate { $0.setFolderExpanded(f.folder.id, !f.folder.isExpanded) }
    }

    override func accessibilityPerformPress() -> Bool {
        tapped(at: .zero)
        return true
    }

    // Arc's folder menu (SidebarMenu+ListContextMenu), in its order, with the items Kite has.
    override func contextMenu(at point: CGPoint) -> NSMenu? {
        guard let f = folderModel, let list else { return nil }
        let folder = f.folder, actions = list.actions, store = list.store
        let menu = NSMenu()
        if let live = folder.live {
            menu.addLiveFolderItems(folder: folder, live: live) { actions.deleteFolder(folder.id) }
        } else {
            if f.claudeActive {
                menu.add("Stop Claude") { [weak self] in self?.stopClaude() }
                menu.addSeparator()
            }
            let state = store.state
            // Claude's folders are never copied or turned into a space (Kite never makes a Claude space).
            let claudeFolder = folder.ephemeral == true || f.claudeActive
            if !claudeFolder {
                menu.add("Duplicate", enabled: state.canDuplicateFolder(folder.id)) {
                    store.mutate { _ = $0.duplicateFolder(folder.id) }
                }
                menu.addSeparator()
            }
            // Arc builds Archive Folder or Delete (`canArchiveFolders`); Kite's archive holds tabs, not
            // folders, so it's Delete, which archives the tabs inside.
            menu.add("Delete") { actions.deleteFolder(folder.id) }
            menu.addSeparator()
            menu.add("New Nested Folder…") {
                guard let nested = store.mutate({ $0.createNestedFolder(in: folder.id) }) else { return }
                store.beginRenaming(folder: nested)
            }
            if !claudeFolder && BrowserState.claudeMayCreateSpace(named: folder.name) {
                menu.add("Turn \u{201C}\(folder.name)\u{201D} into Space", enabled: state.canTurnFolderIntoSpace(folder.id)) {
                    store.mutate { _ = $0.turnFolderIntoSpace(folder.id) }
                }
            }
            let tabs = folder.items.tabs.filter { $0.url != nil }
            menu.add("Copy All Links", enabled: !tabs.isEmpty) {
                copyToPasteboard(tabs.compactMap(\.url?.absoluteString).joined(separator: "\n"))
            }
            menu.add("Copy All Links as Markdown", enabled: !tabs.isEmpty) {
                copyToPasteboard(LinkFormat.markdownList(tabs))
            }
            // Arc's builder has no separator marker here; Kite keeps the one it had (inferred from grouping).
            menu.addSeparator()
            menu.add("Rename…") { actions.renameFolder(folder.id) }
        }
        return menu
    }
}

extension FolderRowCell: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        popover = nil
        if let store = list?.store, case .folder(let f)? = model, store.liveFolderIntroID == f.folder.id {
            store.liveFolderIntroID = nil
        }
    }
}

@MainActor
extension NSMenu {
    /// A live folder's right-click menu (SwiftUI's `LiveFolderMenu`).
    func addLiveFolderItems(folder: TabFolder, live: LiveFolder, onDelete: @escaping () -> Void) {
        let controller = LiveFoldersController.shared
        add("Refresh", enabled: !(controller?.isRefreshing(folder.id) ?? true)) { controller?.refresh(folder.id, force: true) }
        addLabel(LiveFolderMenu.status(live))
        if let error = live.lastError { addLabel(error) }
        addSeparator()
        for item in LiveFolder.Filter.all {
            add(item.title, checked: live.filter.contains(item.filter)) { controller?.toggleFilter(folder.id, item.filter) }
        }
        addSubmenu("Repositories") { menu in
            for repository in LiveFolderMenu.repositories(live) {
                menu.add(repository, checked: !live.hiddenRepositories.contains(repository)) {
                    controller?.toggleRepository(folder.id, repository)
                }
            }
            menu.addSeparator()
            menu.addLabel("This list is generated based on your currently active pull requests.")
        }
        addSeparator()
        add("Delete Live Folder", onDelete)
    }
}

// MARK: - Split rows

/// A split view's row (SwiftUI's `SplitRow`): its panes side by side, 4pt apart and equally wide, each a
/// favicon and title (only the favicon when it gets 60pt or narrower), like Arc's.
final class SplitRowCell: SidebarRowCell {
    private typealias S = ArcMetrics.Split

    private final class Pane: SidebarPassthroughView {
        let fill = FillView()
        let favicon = FaviconImageView(side: M.iconSize)
        let title = SidebarLabel(size: M.tabFontSize)
        let button = SymbolButton(symbol: "xmark", pointSize: ArcMetrics.Split.rowCloseGlyphSize, weight: .semibold)
        var tabID: UUID?

        override init(frame: NSRect) {
            super.init(frame: frame)
            addSubview(fill)
            addSubview(favicon)
            addSubview(title)
            button.opacity = ArcMetrics.Split.rowButtonOpacity
            button.setAccessibilityIdentifier("splitTabTrailingButton")
            addSubview(button)
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
        }

    }

    private let pill = FillView()
    private var panes: [Pane] = []
    private let header = GroupHeaderView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(pill)
        addSubview(header)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Split View")
    }

    private var split: SidebarRowModel.Split? {
        if case .split(let s)? = model { return s }
        return nil
    }

    override func update() {
        guard let s = split, let list else { return }
        let actions = list.actions, store = list.store
        while panes.count < s.tabs.count {
            let pane = Pane()
            addSubview(pane)
            panes.append(pane)
        }
        while panes.count > s.tabs.count { panes.removeLast().removeFromSuperview() }
        let state = SplitTabButton.state(isPinned: s.isPinned, modifiers: s.optionHeld ? .alt : [])
        for (pane, tab) in zip(panes, s.tabs) {
            pane.tabID = tab.id
            pane.favicon.show(tab: tab)
            pane.title.stringValue = tab.displayTitle
            pane.toolTip = tab.displayTitle
            pane.setAccessibilityLabel(tab.displayTitle)
            pane.setAccessibilityValue(tab.id == s.focusedID ? "selected" : nil)
            pane.fill.fill = { _ in NSColor.white.withAlphaComponent(tab.id == s.focusedID ? M.hoverFill : 0) }
            // Arc's per-pane trailing button: × closes the pane's tab; while ⌥ alone is held it separates.
            // Arc's icon-separate-from-split: an arrow pointing out of a split box, from SF Symbols.
            pane.button.customImage = state == .separate ? symbolRow([
                ("arrow.down.left", S.rowSeparateGlyphSize * 0.55, .bold),
                ("square.split.2x1", S.rowSeparateGlyphSize * 0.95, .medium),
            ], spacing: -1) : nil
            pane.button.toolTip = state.title
            pane.button.setAccessibilityLabel(state.title)
            let id = tab.id
            pane.button.action = {
                if state == .separate { store.mutate { $0.separateFromSplit(tab: id) } } else { actions.closeTab(id) }
            }
        }
        if let group = s.groupHeader {
            header.isHidden = false
            header.show(group, onClose: { actions.closeTabs(group.tabIDs) }, onRemove: { actions.removeTabGroupHeader(group.id) })
        } else {
            header.isHidden = true
        }
        super.update()
    }

    override func layout() {
        super.layout()
        guard let s = split else { return }
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: M.dividerRowHeight)
        let p = pillRect
        pill.frame = p
        pill.fill = tabPillFill(selected: s.focusedID != nil, hovered: isHovered)
        let inner = CGRect(x: p.minX + rowIndent(s.depth), y: p.minY, width: p.width - rowIndent(s.depth), height: p.height)
        let count = CGFloat(max(s.tabs.count, 1))
        let width = (inner.width - S.rowItemSpacing * (count - 1)) / count
        for (i, pane) in panes.enumerated() {
            pane.frame = CGRect(x: inner.minX + CGFloat(i) * (width + S.rowItemSpacing), y: inner.minY, width: width, height: inner.height)
            layoutPane(pane, width: width)
        }
    }

    private func layoutPane(_ pane: Pane, width: CGFloat) {
        let h = M.pillHeight
        let compact = width <= S.rowCompactWidth
        // A title with 20pt or less to show is hidden rather than cut to a letter and an ellipsis.
        let titleWidth = width - 2 * M.iconInset - M.iconSize - 2 * M.iconTextGap
        let showsTitle = !compact && titleWidth > S.rowTitleMinWidth
        // Arc shows every pane's button while the row is hovered, not just the hovered pane's.
        let showsButton = showsTitle && isHovered
        pane.fill.cornerRadius = min(width / 2, S.rowItemMaxCornerRadius)
        pane.fill.frame = pane.bounds
        let leading = compact ? 0 : M.iconInset
        let trailing = compact ? 0 : showsButton ? S.rowButtonTrailingInset : M.iconInset
        let iconX = compact ? (width - M.iconSize) / 2 : leading
        pane.favicon.frame = CGRect(x: iconX, y: (h - M.iconSize) / 2, width: M.iconSize, height: M.iconSize)
        pane.button.isHidden = !showsButton
        var end = width - trailing
        if showsButton {
            end -= S.rowButtonSize
            pane.button.frame = CGRect(x: end, y: (h - S.rowButtonSize) / 2, width: S.rowButtonSize, height: S.rowButtonSize)
            end -= M.iconTextGap
        }
        pane.title.isHidden = !showsTitle
        if showsTitle {
            let x = iconX + M.iconSize + M.iconTextGap
            let room = max(end - M.iconTextGap - x, 0)
            let line = pane.title.lineHeight
            let y = ((h - line) / 2).rounded(.down) + (h - line).truncatingRemainder(dividingBy: 2) / 2
            pane.title.place(textRect: CGRect(x: x, y: y, width: min(pane.title.naturalWidth, room), height: line))
        }
    }

    override func tapped(at point: CGPoint) {
        guard let s = split, let store = list?.store else { return }
        let paneID = panes.first { $0.frame.contains(point) }?.tabID
        let split = s.split
        store.mutate { state in
            if let target = paneID ?? state.focusTarget(of: split) { state.select(tab: target) }
        }
    }

    override func acceptsPress(at point: CGPoint) -> Bool {
        pillRect.contains(point) || (!header.isHidden && point.y < pillRect.minY)
    }

    /// Arc's "Split View Context Menu", as Arc 1.171 shows it (see SwiftUI's `SplitRow`).
    override func contextMenu(at point: CGPoint) -> NSMenu? {
        guard let s = split, let list else { return nil }
        if point.y < pillRect.minY { return header.isHidden ? nil : header.groupMenu }
        let store = list.store, actions = list.actions, split = s.split
        let menu = NSMenu()
        menu.add("Separate All Tabs") { store.mutate { $0.separateAllTabs(split: split.id) } }
        menu.add("Add Tab…", enabled: s.tabs.count < SplitView.maxPanes) {
            store.mutate { state in
                if let target = state.focusTarget(of: split) { state.select(tab: target) }
            }
            actions.addSplitView()
        }
        menu.add(split.orientation == .horizontal ? "Convert to Vertical Split View" : "Convert to Horizontal Split View") {
            store.mutate { $0.setSplitOrientation(split.id, split.orientation == .horizontal ? .vertical : .horizontal) }
        }
        menu.addSeparator()
        menu.addSectionHeader("Tab Options")
        for (tab, sound) in zip(s.tabs, s.audio) {
            let id = tab.id
            menu.addSubmenu(tab.displayTitle) { sub in
                sub.add("Separate from Split View") { store.mutate { $0.separateFromSplit(tab: id) } }
                sub.addSeparator()
                // Arc shows Mute greyed out for a pane that isn't playing anything.
                sub.add(TabAudioButton.menuTitle(isMuted: sound.muted), enabled: sound.audible || sound.muted) { actions.toggleMute(id) }
                sub.addCopyLinkItems(tab)
                sub.addSeparator()
                sub.add("Archive Item") { actions.closeTab(id) }
            }
        }
        menu.addSeparator()
        menu.add("Archive Item") { actions.closeTabs(s.tabs.map(\.id)) }
        if let first = split.tabIDs.first { menu.addArchiveTabsItems(state: store.state, relativeTo: first, actions: actions) }
        return menu
    }
}

// MARK: - New Tab

/// The New Tab row: a plus and "New Tab", a little fainter than tabs, on the field's wash when hovered.
final class NewTabRowCell: SidebarRowCell {
    private let pill = FillView()
    private let plus = SidebarImageView()
    private let title = SidebarLabel(size: M.tabFontSize, opacity: 1)
    private let content = SidebarPassthroughView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(pill)
        content.alphaValue = M.tabTextOpacity * 0.75
        addSubview(content)
        plus.image = symbolImage("plus", pointSize: 14, weight: .medium, box: NSSize(width: M.iconSize, height: M.iconSize), placement: .center)
        plus.imageScaling = .scaleNone
        plus.contentTintColor = .labelColor
        content.addSubview(plus)
        title.stringValue = "New Tab"
        title.setAccessibilityElement(false)
        content.addSubview(title)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("New Tab")
    }

    override func layout() {
        super.layout()
        let p = pillRect
        pill.frame = p
        pill.fill = chromeFill(isHovered ? M.hoverFill : 0)
        content.frame = p
        plus.frame = CGRect(x: M.iconInset, y: (p.height - M.iconSize) / 2, width: M.iconSize, height: M.iconSize)
        let x = M.iconInset + M.iconSize + M.iconTextGap
        let line = title.lineHeight
        let y = ((p.height - line) / 2).rounded(.down) + (p.height - line).truncatingRemainder(dividingBy: 2) / 2
        title.place(textRect: CGRect(x: x, y: y, width: min(title.naturalWidth, p.width - x - M.iconInset), height: line))
    }

    override func tapped(at point: CGPoint) { list?.store.showCommandBar(.newTab) }

    override func accessibilityPerformPress() -> Bool {
        list?.store.showCommandBar(.newTab)
        return true
    }
}
