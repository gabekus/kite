import AppKit
import KiteCore

/// Drop a link dragged from a page on an outer edge of the content area to open it in a new split pane,
/// like Arc's window-contents split view (`onDropURL`, `allowInteractivePaneInsertion`).
/// Sits over the pages; only its edge strips take part, and only in a drag, so clicks, hovers and
/// drags that start in a page still reach the page.
@MainActor
final class SplitDropZonesView: NSView {
    private typealias M = ArcMetrics.Split

    /// A link dropped on an edge.
    var onDrop: ((URL, SplitEdge) -> Void)?

    /// The edges that take a drop right now; the others are hidden and take nothing.
    var edges: Set<SplitEdge> = [] {
        didSet {
            guard edges != oldValue else { return }
            for strip in strips { strip.isHidden = !edges.contains(strip.edge) }
            if let shown = placeholderEdge, !edges.contains(shown) { showPlaceholder(nil) }
        }
    }
    /// Panes on screen now: the placeholder shows the new pane's equal share, 1/(n+1).
    var paneCount = 1

    private lazy var strips: [SplitDropStrip] = SplitEdge.allCases.map { edge in
        let strip = SplitDropStrip(edge: edge)
        strip.isHidden = true
        strip.zones = self
        addSubview(strip)
        return strip
    }
    private let placeholder = NSView()
    private var placeholderEdge: SplitEdge?

    override init(frame: NSRect) {
        super.init(frame: frame)
        placeholder.wantsLayer = true
        placeholder.layer?.borderWidth = M.dropBorderWidth
        placeholder.layer?.cornerRadius = M.dropCornerRadius
        placeholder.layer?.cornerCurve = .continuous
        placeholder.isHidden = true
        placeholder.setAccessibilityElement(true)
        placeholder.setAccessibilityRole(.group)
        placeholder.setAccessibilityIdentifier("SplitDropPlaceholder")
        addSubview(placeholder)
        _ = strips
        setAccessibilityIdentifier("SplitDropZones")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Never takes ordinary mouse events; a strip answers only while a drag is over it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for strip in strips where !strip.isHidden {
            if let hit = strip.hitTest(local) { return hit }
        }
        return nil
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutStrips()
    }

    override func layout() {
        super.layout()
        layoutStrips()
    }

    private func layoutStrips() {
        let d = min(M.dropEdge, bounds.width / 4, bounds.height / 4)
        for strip in strips {
            strip.frame = switch strip.edge {
            case .leading: CGRect(x: 0, y: d, width: d, height: max(bounds.height - 2 * d, 0))
            case .trailing: CGRect(x: bounds.width - d, y: d, width: d, height: max(bounds.height - 2 * d, 0))
            case .top: CGRect(x: 0, y: 0, width: bounds.width, height: d)
            case .bottom: CGRect(x: 0, y: bounds.height - d, width: bounds.width, height: d)
            }
        }
        if let placeholderEdge { placeholder.frame = placeholderFrame(placeholderEdge) }
    }

    /// A sidebar tab dragged over the pages: the new pane's slot, in this view's points, or nil.
    /// The tab drag is the sidebar's own (not an AppKit drag), so it reports here directly.
    func showTabPlaceholder(_ slot: CGRect?) {
        placeholderEdge = nil
        guard let slot else {
            placeholder.isHidden = true
            return
        }
        let accent = NSColor.controlAccentColor
        placeholder.layer?.borderColor = accent.cgColor
        placeholder.layer?.backgroundColor = accent.withAlphaComponent(0.12).cgColor
        placeholder.frame = slot
        placeholder.isHidden = false
    }

    /// The new pane's slot at `edge`: an equal share of the content, as Arc proposes it.
    private func placeholderFrame(_ edge: SplitEdge) -> CGRect {
        let n = CGFloat(max(paneCount, 1) + 1)
        let inset = M.gap / 2
        let width = (bounds.width / n).rounded()
        let height = (bounds.height / n).rounded()
        let slot = switch edge {
        case .leading: CGRect(x: 0, y: 0, width: width, height: bounds.height)
        case .trailing: CGRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
        case .top: CGRect(x: 0, y: 0, width: bounds.width, height: height)
        case .bottom: CGRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
        }
        return slot.insetBy(dx: inset, dy: inset)
    }

    fileprivate func showPlaceholder(_ edge: SplitEdge?) {
        placeholderEdge = edge
        guard let edge else {
            placeholder.isHidden = true
            return
        }
        let accent = NSColor.controlAccentColor
        placeholder.layer?.borderColor = accent.cgColor
        placeholder.layer?.backgroundColor = accent.withAlphaComponent(0.12).cgColor
        placeholder.frame = placeholderFrame(edge)
        placeholder.isHidden = false
    }

    fileprivate func drop(_ url: URL, on edge: SplitEdge) {
        showPlaceholder(nil)
        onDrop?(url, edge)
    }

    /// The web link on a drag's pasteboard, if it has one. Files stay with the page.
    nonisolated static func link(on pasteboard: NSPasteboard) -> URL? {
        guard let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first,
              !url.isFileURL, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        return url
    }
}

/// One edge of the drop zones: a drag destination for web links.
@MainActor
private final class SplitDropStrip: NSView {
    let edge: SplitEdge
    weak var zones: SplitDropZonesView?

    init(edge: SplitEdge) {
        self.edge = edge
        super.init(frame: .zero)
        registerForDraggedTypes([.URL])
        setAccessibilityIdentifier("SplitDropZone.\(edge.rawValue)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A drag is in progress: the button is held, and this isn't the click that starts it.
    private static var isDragging: Bool {
        NSEvent.pressedMouseButtons & 1 != 0 && NSApp.currentEvent?.type != .leftMouseDown
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        Self.isDragging && frame.contains(point) ? self : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard SplitDropZonesView.link(on: sender.draggingPasteboard) != nil else { return [] }
        zones?.showPlaceholder(edge)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        zones?.showPlaceholder(nil)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        zones?.showPlaceholder(nil)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = SplitDropZonesView.link(on: sender.draggingPasteboard) else { return false }
        zones?.drop(url, on: edge)
        return true
    }
}
