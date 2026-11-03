import AppKit
import KiteCore
import SwiftUI

/// Where the sidebar's space pages sit while two fingers swipe between spaces. The window controller
/// moves it from scroll events; `SidebarPagesView` draws from it.
@MainActor
@Observable
final class SpaceSwipeModel {
    /// Points from rest; positive shows the previous space coming in from the left.
    var offset: CGFloat = 0
    /// While the pages settle after a switch, the space the switch left: its neighbours stay built
    /// until the pages come to rest (`SpaceSwipe.builtPages`).
    var anchor: UUID?
    /// The page width last laid out: the swipe's whole travel.
    var pageWidth: CGFloat = 0
}

/// The sidebar: an AppKit column holding the space pages (`SidebarPagesView`), the chrome still drawn by
/// SwiftUI around them (header row, address field, favorites, Mini Player, space bar; one hosting view the
/// sidebar's size), and the drag overlay over everything.
///
/// It clips what it draws to its bounds with a layer mask rather than `clipsToBounds`: clipping would bound
/// the pages' visible rect, so a neighbouring page's list would drop its rows while it sits off to the side
/// and build them all again on the first frame of a swipe. Masked, the neighbouring pages keep their rows
/// and draw nothing outside the sidebar.
@MainActor
final class SidebarColumnView: NSView {
    let chrome: NSHostingView<SidebarView>
    let pages: SidebarPagesView
    private let overlay: SidebarOverlayHost
    private let clip = CALayer()
    /// The pages' frame in the chrome, from its placeholder.
    private var pagesFrame: CGRect = .zero

    init(sidebar: SidebarView, store: BrowserStore, swipe: SpaceSwipeModel) {
        var sidebar = sidebar
        let drag = sidebar.drag
        pages = SidebarPagesView(store: store, swipe: swipe, drag: drag, actions: sidebar.actions, claude: sidebar.claude,
                                 supportsDarkPages: sidebar.supportsDarkPages)
        overlay = SidebarOverlayHost(rootView: SidebarDragOverlay(drag: drag))
        chrome = NSHostingView(rootView: sidebar)
        super.init(frame: .zero)
        sidebar.pagesFrame = { [weak self] frame in self?.setPagesFrame(frame) }
        chrome.rootView = sidebar
        chrome.sizingOptions = []
        overlay.sizingOptions = []
        wantsLayer = true
        addSubview(chrome)
        addSubview(pages)
        addSubview(overlay)
        overlay.isHidden = true
        watchDrag(drag)
    }

    /// The overlay is there only while something is being dragged.
    private func watchDrag(_ drag: SidebarDragModel) {
        withObservationTracking {
            overlay.isHidden = !drag.isDragging
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.watchDrag(drag) } }
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func setPagesFrame(_ frame: CGRect) {
        guard frame != pagesFrame else { return }
        pagesFrame = frame
        needsLayout = true
    }

    override func layout() {
        super.layout()
        chrome.frame = bounds
        overlay.frame = bounds
        // The pages span the whole sidebar, not just its padded column.
        pages.frame = CGRect(x: 0, y: pagesFrame.minY, width: bounds.width, height: max(pagesFrame.height, 0))
        guard let layer else { return }
        if layer.mask !== clip {
            clip.backgroundColor = NSColor.black.cgColor
            layer.mask = clip
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = layer.bounds
        CATransaction.commit()
    }
}

/// The drag overlay (the dragged row, the insertion line), drawn over the sidebar; it takes no clicks.
private final class SidebarOverlayHost: NSHostingView<SidebarDragOverlay> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Arc pages its sidebar horizontally, one page per space, under the favorites, which stay put
/// (`SidebarPagingContainerViewController`; docs/arc-visual-spec.md "Spaces"). Pages are a full sidebar wide.
///
/// Like Arc's clip view, the pages move as one strip: a swipe's frame moves one layer and builds nothing.
/// Pages are built for the space in front and its neighbours (`SpaceSwipe.builtPages`), and kept as their
/// spaces stay built.
@MainActor
final class SidebarPagesView: NSView {
    private typealias M = ArcMetrics.Sidebar

    private let store: BrowserStore
    private let swipe: SpaceSwipeModel
    private let drag: SidebarDragModel
    var actions: SidebarActions { didSet { lists.values.forEach { $0.actions = actions } } }
    private let claude: ClaudeButtonModel
    private let supportsDarkPages: Bool
    /// The strip the pages sit in; a swipe offsets it.
    private let strip = SidebarFlippedView()
    private var lists: [UUID: SidebarSpaceList] = [:]
    private var built: [UUID] = []
    private var updateScheduled = false

    init(store: BrowserStore, swipe: SpaceSwipeModel, drag: SidebarDragModel, actions: SidebarActions,
         claude: ClaudeButtonModel, supportsDarkPages: Bool) {
        self.store = store
        self.swipe = swipe
        self.drag = drag
        self.actions = actions
        self.claude = claude
        self.supportsDarkPages = supportsDarkPages
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(strip)
        update()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Builds the pages the store calls for and places them, watching what that read.
    private func update() {
        withObservationTracking {
            let state = store.state
            let selected = state.selectedSpaceIndex
            let indexes = SpaceSwipe.builtPages(selected: selected, anchor: swipe.anchor.flatMap(state.spaceIndex),
                                                count: state.spaces.count)
            let ids = indexes.map { state.spaces[$0].id }
            if ids != built { rebuild(ids) }
            placePages(selected: selected)
            placeStrip()
        } onChange: { [weak self] in
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

    private func rebuild(_ ids: [UUID]) {
        built = ids
        for (id, list) in lists where !ids.contains(id) {
            list.removeFromSuperview()
            lists[id] = nil
        }
        for id in ids where lists[id] == nil {
            let list = SidebarSpaceList(store: store, spaceID: id, actions: actions, claude: claude, drag: drag,
                                        supportsDarkPages: supportsDarkPages)
            strip.addSubview(list)
            lists[id] = list
        }
    }

    /// Each page at its space's place in the strip: the selected one at rest, the others a page to each side.
    private func placePages(selected: Int) {
        let width = bounds.width, height = bounds.height
        let state = store.state
        for (id, list) in lists {
            let index = state.spaceIndex(id) ?? selected
            list.frame = CGRect(x: CGFloat(index - selected) * width + M.padding, y: 0, width: width - 2 * M.padding, height: height)
        }
    }

    /// The swipe moves the strip, nothing else.
    private func placeStrip() {
        let offset = swipe.offset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.frame = CGRect(x: offset, y: 0, width: bounds.width, height: bounds.height)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        if swipe.pageWidth != bounds.width { swipe.pageWidth = bounds.width }
        placePages(selected: store.state.selectedSpaceIndex)
        placeStrip()
    }
}
