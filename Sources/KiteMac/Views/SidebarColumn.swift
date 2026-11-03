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

/// The sidebar, top to bottom: the header row and address field (`SidebarHeaderView`), the favorites tray
/// (`FavoritesTrayView`), the space pages (`SidebarPagesView`), the Mini Player while something plays, and the
/// space bar (`SpaceBarView`); on + › New Space, Arc's Create a Space page takes the place of everything between
/// the top row and the space bar. The drag overlay sits over everything while something is dragged. The Mini
/// Player and Create a Space are still SwiftUI, each in a hosting view that exists only while it shows.
///
/// It clips what it draws to its bounds with a layer mask rather than `clipsToBounds`: clipping would bound
/// the pages' visible rect, so a neighbouring page's list would drop its rows while it sits off to the side
/// and build them all again on the first frame of a swipe. Masked, the neighbouring pages keep their rows
/// and draw nothing outside the sidebar.
@MainActor
final class SidebarColumnView: NSView {
    private typealias M = ArcMetrics.Sidebar

    let header: SidebarHeaderView
    let favorites: FavoritesTrayView
    let spaceBar: SpaceBarView
    let pages: SidebarPagesView
    private let overlay: SidebarOverlayHost
    private let clip = CALayer()
    private let configuration: SidebarConfiguration
    private let metrics = SidebarChromeMetrics()
    private var miniPlayer: SidebarIslandHost?
    private var miniPlayerTab: UUID?
    private var creation: SidebarIslandHost?
    private var updateScheduled = false
    /// What the last pass laid out for: a page loading changes none of it.
    private var laidOutFor: (creating: Bool, miniPlayer: UUID?, favorites: CGFloat)?

    init(configuration: SidebarConfiguration) {
        self.configuration = configuration
        let store = configuration.store, drag = configuration.drag
        pages = SidebarPagesView(store: store, swipe: configuration.swipe, drag: drag, actions: configuration.actions,
                                 claude: configuration.claude, supportsDarkPages: configuration.supportsDarkPages)
        overlay = SidebarOverlayHost(rootView: SidebarDragOverlay(drag: drag))
        header = SidebarHeaderView(store: store, actions: configuration.actions, hover: configuration.hover,
                                   supportsDarkPages: configuration.supportsDarkPages, accessory: configuration.fieldAccessory)
        favorites = FavoritesTrayView(store: store, actions: configuration.actions, drag: drag, metrics: metrics)
        spaceBar = SpaceBarView(store: store, actions: configuration.actions, swipe: configuration.swipe, drag: drag,
                                library: configuration.library)
        header.showExtensions = configuration.showExtensions
        header.showSiteControls = configuration.showSiteControls
        header.installApp = configuration.installApp
        super.init(frame: .zero)
        drag.store = store
        overlay.sizingOptions = []
        wantsLayer = true
        addSubview(header)
        addSubview(favorites)
        addSubview(spaceBar)
        addSubview(pages)
        addSubview(overlay)
        overlay.isHidden = true
        header.onHeightChange = { [weak self] in self?.needsLayout = true }
        watchDrag(drag)
        update()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// The overlay is there only while something is being dragged.
    private func watchDrag(_ drag: SidebarDragModel) {
        withObservationTracking {
            overlay.isHidden = !drag.isDragging
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.watchDrag(drag) } }
        }
    }

    // MARK: Observing

    /// Which of Create a Space and the Mini Player show, and the tray's height.
    private func update() {
        withObservationTracking {
            let store = configuration.store
            let state = store.state
            _ = metrics.favoritesHeight
            // + › New Space: Arc's Create a Space page takes the place of everything under the top row.
            if let spaceCreation = store.spaceCreation, spaceCreation.spaceID == state.selectedSpaceID {
                if creation == nil {
                    let host = SidebarIslandHost(rootView: AnyView(CreateSpaceSlot(store: store, actions: configuration.actions)
                        .foregroundStyle(.primary)))
                    host.onSizeChange = { [weak self] in self?.needsLayout = true }
                    addSubview(host, positioned: .below, relativeTo: overlay)
                    creation = host
                }
            } else if let creation {
                creation.removeFromSuperview()
                self.creation = nil
            }
            // The Mini Player, while the tab it follows plays or records.
            var playing: UUID?
            if configuration.miniPlayer != nil, store.spaceCreation == nil || creation == nil, let id = store.miniPlayerTabID,
               state.tab(id) != nil, let page = store.pages[id], page.media != nil || page.capturingSince != nil {
                playing = id
            }
            if playing != miniPlayerTab {
                miniPlayer?.removeFromSuperview()
                miniPlayer = nil
                miniPlayerTab = playing
                if playing != nil, let actions = configuration.miniPlayer {
                    let host = SidebarIslandHost(rootView: AnyView(MiniPlayerSlot(store: store, actions: actions)
                        .foregroundStyle(.primary)))
                    host.onSizeChange = { [weak self] in self?.needsLayout = true }
                    addSubview(host, positioned: .below, relativeTo: overlay)
                    miniPlayer = host
                }
            }
            let now = (creating: creation != nil, miniPlayer: miniPlayerTab, favorites: metrics.favoritesHeight)
            if laidOutFor.map({ $0 != now }) ?? true {
                laidOutFor = now
                needsLayout = true
            }
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

    // MARK: Layout

    override func layout() {
        super.layout()
        let width = bounds.width
        overlay.frame = bounds
        let headerHeight = header.height
        header.frame = CGRect(x: 0, y: 0, width: width, height: headerHeight)
        let barTop = bounds.height - M.bottomBarHeight
        spaceBar.frame = CGRect(x: 0, y: barTop, width: width, height: M.bottomBarHeight)
        let column = CGRect(x: M.padding, y: 0, width: width - 2 * M.padding, height: bounds.height)
        if let creation {
            favorites.frame = CGRect(x: 0, y: headerHeight, width: width, height: 0)
            pages.isHidden = true
            let top = M.topRowY + M.topRowHeight
            // The page fills the room between the top row and the space bar (its stack has a Spacer).
            creation.frame = CGRect(x: column.minX, y: top, width: column.width, height: max(barTop - top, 0))
        } else {
            pages.isHidden = false
            let favoritesHeight = metrics.favoritesHeight
            favorites.frame = CGRect(x: 0, y: headerHeight, width: width, height: favoritesHeight)
            var bottom = barTop
            if let miniPlayer {
                let height = miniPlayer.fittingHeight(width: column.width)
                miniPlayer.frame = CGRect(x: column.minX, y: barTop - height, width: column.width, height: height)
                bottom = barTop - height - M.padding
            }
            let top = headerHeight + favoritesHeight
            // The pages span the whole sidebar, not just its padded column.
            pages.frame = CGRect(x: 0, y: top, width: width, height: max(bottom - top, 0))
        }
        if let window, let content = window.contentView {
            // The drag's bounds: the sidebar in window points from the top-left.
            let r = convert(bounds, to: nil)
            configuration.drag.bounds = CGRect(x: r.minX, y: content.bounds.height - r.maxY, width: r.width, height: r.height)
        }
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

/// A SwiftUI view that sizes itself inside the AppKit sidebar (the Mini Player, Create a Space).
final class SidebarIslandHost: NSHostingView<AnyView> {
    var onSizeChange: () -> Void = {}

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = [.intrinsicContentSize]
    }

    @available(*, unavailable) @MainActor required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onSizeChange()
    }

    /// Its height: the Mini Player's rows and Create a Space's stack don't depend on the width.
    func fittingHeight(width: CGFloat) -> CGFloat { ceil(intrinsicContentSize.height) }
}

/// The Mini Player for the tab it follows, reading the store itself.
private struct MiniPlayerSlot: View {
    let store: BrowserStore
    let actions: MiniPlayerActions

    var body: some View {
        if let id = store.miniPlayerTabID, let tab = store.state.tab(id), let page = store.pages[id],
           page.media != nil || page.capturingSince != nil {
            MiniPlayerView(
                tab: tab, media: page.media?.state, isRecording: page.capturingSince != nil, call: page.callControls,
                isMuted: page.isAudioMuted, volume: page.tabVolume, actions: actions
            )
            .id(id)
        }
    }
}

/// Arc's Create a Space page for the space being made.
private struct CreateSpaceSlot: View {
    let store: BrowserStore
    let actions: SidebarActions

    var body: some View {
        if let creation = store.spaceCreation {
            SpaceCreationView(store: store, actions: actions, creation: creation)
        }
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
