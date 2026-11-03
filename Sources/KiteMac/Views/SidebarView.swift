import AppKit
import KiteCore
import SwiftUI

struct SidebarActions {
    var goBack: () -> Void
    var goForward: () -> Void
    var reload: () -> Void
    var forceReload: () -> Void
    /// The reload button: on a Developer Mode site it does what `devModeReloadState` says.
    var reloadButton: () -> Void
    /// Developer Mode's reload options: remembers the choice for the button, then does it.
    var developerReload: (DeveloperTabReloadSetting) -> Void
    var clearCookiesAndRefresh: () -> Void
    var toggleSidebar: () -> Void
    var closeTab: (UUID) -> Void
    var addSplitView: () -> Void
    /// A space's context menu in the strip.
    var editTheme: (UUID) -> Void
    var changeSpaceIcon: (UUID) -> Void
    var deleteSpace: (UUID) -> Void
    /// A folder's context menu.
    var renameFolder: (UUID) -> Void
    var deleteFolder: (UUID) -> Void
    /// A pinned tab that left its pinned page: "Back to Pinned URL" and "Separate From Pinned Tab".
    var resetTab: (UUID) -> Void = { _ in }
    var separateFromPinnedTab: (UUID) -> Void = { _ in }
    /// A pinned tab's or favorite's "Edit Pinned Page" submenu: Edit… and Replace Pinned URL with Current.
    var editPinnedURL: (UUID) -> Void = { _ in }
    var replacePinnedURL: (UUID) -> Void = { _ in }
    /// A tab's Rename…: in place in its row, or Arc's dialog where there's no row.
    var renameTab: (UUID) -> Void
    /// Tidy Tabs: the Today divider's Tidy button, and a tab group header's context menu.
    var tidyTabs: (UUID) -> Void = { _ in }
    /// What the space is for, which Claude reads to pick the space a tab goes in (Space.about).
    var describeSpace: (UUID) -> Void = { _ in }
    /// The Today divider's Clear button: Clear Today for that space.
    var clearToday: (UUID) -> Void = { _ in }
    var removeTabGroupHeader: (UUID) -> Void = { _ in }
    /// A tab row's speaker button and Mute / Unmute menu item.
    var toggleMute: (UUID) -> Void = { _ in }
    /// A space's Set Profile (space id, profile folder) and its New Profile….
    var setProfile: (UUID, String) -> Void = { _, _ in }
    var newProfile: (UUID) -> Void = { _ in }
    /// False in incognito windows, which have no profiles.
    var showsProfiles = true
    /// Instant Links' loading row's close button.
    var dismissInstantLinks: (UUID) -> Void = { _ in }
    /// After a drag drops something in the sidebar: Arc's move toasts.
    var didDrop: (SidebarDropOutcome) -> Void = { _ in }
    /// The pointer moved onto a favorite's tile (with the tile's view), or off it (nil): its preview card.
    var previewFavorite: (BrowserTab?, NSView?) -> Void = { _, _ in }
}

/// Set from a tracking area over the sidebar's host (`BrowserWindowController`).
@MainActor
@Observable
final class SidebarHoverModel {
    var isHovered = false
}

/// Arc's sidebar, top to bottom: navigation, address pill, favorites grid,
/// the space's pinned items (with folders), new tab and today's tabs, spaces.
struct SidebarView: View {
    let store: BrowserStore
    /// Live folder rows show GitHub's mark in the sidebar's appearance.
    @Environment(\.colorScheme) private var colorScheme
    let actions: SidebarActions
    /// False on WebKit, which can't force pages dark.
    let supportsDarkPages: Bool
    let claude: ClaudeButtonModel
    /// The window's Library, which the bottom bar's Library button opens.
    let library: LibraryModel
    /// Opens the extensions popover from the address field's hover button; nil where
    /// extensions don't run (incognito, WebKit).
    var showExtensions: ((NSView) -> Void)?
    /// Always shown at the address field's right end (the password manager's key); hides itself when
    /// there's nothing to show.
    var fieldAccessory: AnyView?
    /// Opens Site Controls from the address field's hover button.
    var showSiteControls: ((NSView) -> Void)?
    /// Chrome's install icon, shown while the tab's page has an installable manifest; nil in incognito.
    var installApp: ((NSView) -> Void)?
    /// Where a two-finger swipe between spaces has the pages.
    var swipe = SpaceSwipeModel()
    /// The Mini Player's buttons; nil shows no Mini Player.
    var miniPlayer: MiniPlayerActions?
    /// The sidebar's drags; the AppKit pages and the overlay share it.
    var drag = SidebarDragModel()
    /// The AppKit parts' sizes the SwiftUI chrome lays out around.
    var chromeMetrics = SidebarChromeMetrics()
    /// Where the space pages go (an AppKit view the column lays over this placeholder), in sidebar points.
    var pagesFrame: (CGRect) -> Void = { _ in }
    /// Whether the pointer is over the sidebar: Arc's URL row reads `sidebarHovered` for its buttons.
    var hover = SidebarHoverModel()

    var body: some View {
        // The host's width, not the column's: the column must never be wider than the sidebar, or
        // SwiftUI centres it and everything spills off both edges.
        GeometryReader { proxy in
            column(width: proxy.size.width)
        }
        .coordinateSpace(.named(Self.space))
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func column(width: CGFloat) -> some View {
        let state = store.state
        let space = state.selectedSpace
        let selectedID = space.selectedTabID

        VStack(alignment: .leading, spacing: 0) {
            // The header row and the address field: AppKit (`SidebarHeaderView`), laid over these placeholders.
            Color.clear.frame(height: M.topRowY + M.topRowHeight)

            // + › New Space: Arc's Create a Space page takes the place of everything under the top row.
            if let creation = store.spaceCreation, creation.spaceID == space.id {
                SpaceCreationView(store: store, actions: actions, creation: creation)
            } else {
                if !state.showsToolbar {
                    Color.clear.frame(height: M.urlFieldTopGap + M.urlFieldHeight)
                }

                // The favorites tray: AppKit (`FavoritesTrayView`), laid over this placeholder.
                if chromeMetrics.favoritesHeight > 0 {
                    Color.clear.frame(height: chromeMetrics.favoritesHeight)
                }

                // The space pages: AppKit (`SidebarPagesView`), laid over this by the column.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { pagesFrame($0) }

                if let miniPlayer, let id = store.miniPlayerTabID, let tab = state.tab(id), let page = store.pages[id],
                   page.media != nil || page.capturingSince != nil {
                    MiniPlayerView(
                        tab: tab, media: page.media?.state, isRecording: page.capturingSince != nil, call: page.callControls,
                        isMuted: page.isAudioMuted, volume: page.tabVolume, actions: miniPlayer
                    )
                        .id(id)
                        .padding(.top, M.padding)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }

            SpaceBar(store: store, actions: actions, claude: claude, library: library, swipe: swipe)
                .frame(height: M.bottomBarHeight)
        }
        .padding(.horizontal, M.padding)
        .frame(width: width, alignment: .leading)
        .foregroundStyle(.primary)
        .onAppear { drag.store = store }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { drag.bounds = $0 }
        .environment(\.sidebarDrag, drag)
    }

    private static let space = "sidebar"

}

private typealias M = ArcMetrics.Sidebar

/// Translucent white reads well on any theme. `strength` is Arc's opacity over
/// a dark tint; light tints need about three times as much to show.
private struct ChromeFill: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let strength: Double
    var cornerRadius: CGFloat = M.cornerRadius

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(scheme == .dark ? strength : min(strength * 3.5, 0.7)))
        )
    }
}

/// A tab or split row's pill. Arc's colours for these come in light and dark pairs
/// rather than one white scaled up, so on a light theme a hovered tab gets a faint
/// dark wash instead of a white haze.
struct TabPillFill: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let isSelected: Bool
    let isHovered: Bool

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous).fill(fill)
        )
    }

    private var fill: Color {
        let dark = scheme == .dark
        if isSelected { return .white.opacity(dark ? M.selectedFill : M.selectedFillLight) }
        if isHovered { return dark ? .white.opacity(M.hoverFill) : Color(red: 0.055, green: 0.059, blue: 0.063).opacity(M.hoverFillLight) }
        return .clear
    }
}

/// Arc's header layouts by sidebar width (see `ArcMetrics.Sidebar.headerCompactBelow`).
struct HeaderLayout: Equatable {
    let isCompact: Bool
    let buttonSize: CGFloat
    let spacing: CGFloat

    init(sidebarWidth: CGFloat) {
        isCompact = sidebarWidth < M.headerCompactBelow
        buttonSize = isCompact ? M.compactNavButtonSize : M.navButtonSize
        spacing = isCompact ? M.compactNavButtonSpacing : M.navButtonSpacing
    }
}

/// Chrome's install icon (a monitor with a down arrow, kInstallDesktopIcon), tooltip "Install <app>"
/// (IDS_OMNIBOX_PWA_INSTALL_ICON_TOOLTIP). The address field's other buttons' size and hover.
struct InstallAppFieldButton: View {
    let appName: String
    var size: CGFloat = 30
    var opacity: (normal: Double, hovered: Double) = (0.6, 0.9)
    let action: (NSView) -> Void
    @State private var anchor: NSView?
    @State private var hovering = false

    var body: some View {
        Button { if let anchor { action(anchor) } } label: {
            Image(systemName: "desktopcomputer.and.arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: size, height: size)
                .modifier(ChromeFill(strength: hovering ? M.hoverFill : 0, cornerRadius: 6))
                .background(AnchorView(view: $anchor))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(hovering ? opacity.hovered : opacity.normal)
        .onHover { hovering = $0 }
        .help("Install \(appName)")
        .accessibilityLabel("Install \(appName)")
    }
}

/// Arc's `AppTrayCollectionViewLayout` for favorites (Arc 1.169's binary): tiles 47pt high, 8pt
/// apart, at most 4 a row. It fits as many columns as square tiles would allow, then balances
/// the rows: 5 favorites are 3 + 2, 7 are 4 + 3, 9 are 3 × 3.
struct FavoritesTrayLayout: Layout {
    static func columns(count n: Int, width: CGFloat) -> Int {
        guard n > 0 else { return 1 }
        let h = M.favoriteHeight, gap = M.favoriteSpacing
        let fit = max(Int(((width + gap) / (h + gap)).rounded(.down)), 1)
        let c = min(n, M.favoriteColumns, fit)
        let rows = (n + c - 1) / c
        return (n + rows - 1) / rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? CGFloat(M.favoriteColumns) * (M.favoriteHeight + M.favoriteSpacing)
        let cols = Self.columns(count: subviews.count, width: width)
        let rows = (subviews.count + cols - 1) / cols
        return CGSize(width: width, height: CGFloat(rows) * M.favoriteHeight + CGFloat(max(rows - 1, 0)) * M.favoriteSpacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cols = Self.columns(count: subviews.count, width: bounds.width)
        let width = (bounds.width - M.favoriteSpacing * CGFloat(cols - 1)) / CGFloat(cols)
        for (i, view) in subviews.enumerated() {
            let x = bounds.minX + CGFloat(i % cols) * (width + M.favoriteSpacing)
            let y = bounds.minY + CGFloat(i / cols) * (M.favoriteHeight + M.favoriteSpacing)
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: width, height: M.favoriteHeight))
        }
    }
}

/// A favorite's tile as it follows the pointer.
struct FavoriteGhost: View {
    let tabs: [BrowserTab]

    var body: some View {
        HStack(spacing: M.favoriteSplitSpacing) {
            ForEach(tabs) { tab in
                FaviconView(tab: tab, size: M.favoriteIconSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .modifier(ChromeFill(strength: M.fieldFill + M.selectedFill, cornerRadius: M.favoriteCornerRadius))
            }
        }
    }
}

/// A sidebar row as it follows the pointer: the pill with its icon and title.
struct DragGhost: View {
    enum Icon {
        case tabs([BrowserTab])
        case symbol(String)
    }

    let icon: Icon
    let title: String
    var depth = 0

    var body: some View {
        HStack(spacing: M.iconTextGap) {
            switch icon {
            case .tabs(let tabs):
                ForEach(tabs) { FaviconView(tab: $0, size: M.iconSize) }
            case .symbol(let name):
                Image(systemName: name).font(.system(size: 14)).frame(width: M.iconSize, height: M.iconSize)
            }
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: M.tabFontSize))
                    .opacity(M.tabTextOpacity)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, M.iconInset + indent(depth))
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(TabPillFill(isSelected: true, isHovered: false))
    }
}

/// Arc's folder nesting per level (see `ArcMetrics.Sidebar.nestingIndent`).
private func indent(_ depth: Int) -> CGFloat {
    CGFloat(depth) * M.nestingIndent
}

private func copyLink(_ url: URL?) {
    guard let url else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
}

private typealias TitleAnimation = TidyTabTitleAnimation

/// Arc's AnimatedGradientView on a tab row: the old title fades out and the new one in behind a
/// soft edge that sweeps left to right (0.5 s, linear). Each is masked by a linear gradient from
/// (-1.5, 0.5) to (1.5, 0.5) whose start and end x move to 1 and 3; stops at
/// [0, w/(2w+70), (w+70)/(2w+70), 1], opaque-to-clear for the new title, the reverse for the old.
struct AIRenameTitle: View {
    let oldTitle: String
    let newTitle: String
    let start: Date

    var body: some View {
        TimelineView(.animation) { context in
            let progress = context.date.timeIntervalSince(start) / TitleAnimation.duration
            ZStack(alignment: .leading) {
                // Both masks span the whole title area, as Arc's one gradient view does.
                label(oldTitle).frame(maxWidth: .infinity, alignment: .leading)
                    .mask { mask(progress, newTitle: false) }
                label(newTitle).frame(maxWidth: .infinity, alignment: .leading)
                    .mask { mask(progress, newTitle: true) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(newTitle)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: M.tabFontSize))
            .opacity(M.tabTextOpacity)
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func mask(_ progress: Double, newTitle: Bool) -> some View {
        GeometryReader { geometry in
            let s = TitleAnimation.stops(width: geometry.size.width)
            let x = TitleAnimation.gradientX(progress: progress)
            let on = Color.white, off = Color.white.opacity(0)
            LinearGradient(
                stops: [
                    .init(color: newTitle ? on : off, location: s[0]),
                    .init(color: newTitle ? on : off, location: s[1]),
                    .init(color: newTitle ? off : on, location: s[2]),
                    .init(color: newTitle ? off : on, location: s[3]),
                ],
                startPoint: UnitPoint(x: x.start, y: 0.5),
                endPoint: UnitPoint(x: x.end, y: 0.5))
        }
    }
}

/// Arc's SparksView over a renamed tab's row: an emitter runs along the row's middle from left
/// to right during the wipe, throwing small sparks every way that fall, shrink and fade
/// (lifetime 1 s, 100 ± 30 pt/s, gravity 200 pt/s², 75 × row/title width per second).
struct AIRenameSparks: View {
    let start: Date
    let titleWidth: CGFloat

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSince(start)
            Canvas { canvas, size in
                // Arc's sparks aren't clipped to the cell; the canvas reaches `spill` past the row.
                let rowWidth = Double(size.width - 2 * Self.spill), rowHeight = Double(size.height - 2 * Self.spill)
                let title = Double(titleWidth > 0 ? titleWidth : size.width)
                let count = TitleAnimation.sparkCount(rowWidth: rowWidth, titleWidth: title)
                for index in 0..<count {
                    guard let spark = TitleAnimation.spark(
                        index: index, time: time, rowWidth: rowWidth, rowHeight: rowHeight, titleWidth: title)
                    else { continue }
                    let rect = CGRect(
                        x: spark.x - spark.size / 2 + Self.spill, y: spark.y - spark.size / 2 + Self.spill,
                        width: spark.size, height: spark.size)
                    canvas.fill(Path(ellipseIn: rect), with: .color(.primary.opacity(spark.opacity * M.tabTextOpacity)))
                }
            }
        }
        .padding(-Self.spill)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static let spill: CGFloat = 60
}

/// Arc's "Edit Pinned Page" submenu on a pinned tab or favorite (SidebarMenu+TabContextMenu,
/// SidebarMenu+MoveMenu): "Edit…" opens the Edit Pinned URL dialog, and "Replace Pinned URL
/// with Current" pins the page the tab is on. Arc builds both items unconditionally.
private struct EditPinnedPageMenu: View {
    let onEdit: () -> Void
    let onReplace: () -> Void

    var body: some View {
        Menu("Edit Pinned Page") {
            Button("Edit…", action: onEdit)
            Button("Replace Pinned URL with Current", action: onReplace)
        }
    }
}

/// Arc's audibility button (TabCellView.audibilityButton): a 24pt speaker that mutes or
/// unmutes the tab, drawn as Arc's animated speaker (`TabSpeakerIcon`: waves, slash).
struct TabAudioButtonView: View {
    let isMuted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TabSpeakerIcon(isMuted: isMuted)
                .frame(width: TabAudioButton.side, height: TabAudioButton.side)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(0.6)
        .help(TabAudioButton.tooltip(isMuted: isMuted))
        .accessibilityLabel(TabAudioButton.tooltip(isMuted: isMuted))
        .accessibilityIdentifier("sidebarTabCellMuteButton")
    }
}

private struct SpaceBar: View {
    @Environment(\.sidebarDrag) private var drag
    let store: BrowserStore
    let actions: SidebarActions
    let claude: ClaudeButtonModel
    let library: LibraryModel
    let swipe: SpaceSwipeModel
    @State private var iconRoom: CGFloat = .infinity
    /// A space icon being dragged to a new place in the strip, and the strip's frame (bar points).
    @State private var iconDrag: SpaceIconDrag?
    /// The pointer during that drag, apart from `iconDrag` so a move redraws the dragged icon and nothing else.
    @State private var pointer = SpaceIconPointer()
    @State private var stripFrame: CGRect = .zero
    @State private var roomFrame: CGRect = .zero

    var body: some View {
        let state = store.state
        // On Create a Space Arc leaves only the spaces in the bar.
        let creating = store.spaceCreation != nil
        HStack(spacing: Self.buttonGap) {
            // Arc's Library button sits at the bar's leading end and carries download progress.
            LibrarySidebarButton(library: library, size: M.bottomButtonSize)
                .opacity(creating ? 0 : 1)
                .disabled(creating)
            // Arc centres the spaces in the room between its end buttons. Too many to fit scroll rather
            // than widen the bar: an over-wide bar pushes the whole sidebar off its left edge. Worked out
            // from the room rather than with `ViewThatFits`, which measures both again whenever an icon's
            // highlight changes, every frame of a swipe.
            Group {
                if fits(state) {
                    // Centred between Library and +, like Arc's strip between its end buttons.
                    spaceIcons(state)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        spaceIcons(state)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
                roomFrame = $0
                iconRoom = $0.width
            }
            Group {
                // Arc's + opens a menu of new things, not a new space straight away.
                AnchoredButton { view in
                    NewItemMenu.present(from: view, store: store, actions: actions)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .regular))
                        .frame(width: M.bottomButtonSize, height: M.bottomButtonSize)
                        .contentShape(Rectangle())
                }
                .opacity(0.7)
                .help("New…")
            }
            .opacity(creating ? 0 : 1)
            .disabled(creating)
        }
        .overlay(alignment: .topLeading) { dragGhost(state) }
        .coordinateSpace(.named(Self.space))
    }

    private static let space = "spaceBar"

    private func fits(_ state: BrowserState) -> Bool {
        CGFloat(SpaceReorder.width(slots: state.spaces.count, pitch: M.spaceCellPitch, cellWidth: M.spaceCellSize.width)) <= iconRoom
    }

    /// Arc's cells are 36×34 on a 34pt pitch (accessibility tree, 1 Nov 2026), centred. From Gabe's
    /// screenshots: the space you're in shows its icon in colour, the others are small dots, and an icon
    /// stays grey until its space is the active one.
    ///
    /// While an icon is dragged it leaves its cell (kept, invisible, so its gesture carries on) and the
    /// others take the slots `SpaceReorder.slots` gives: an open one where it would land, none off the strip.
    private func spaceIcons(_ state: BrowserState) -> some View {
        let ids = state.spaces.map(\.id)
        let slots = iconDrag.map { SpaceReorder.slots(ids, dragging: $0.id, target: $0.target) } ?? ids
        return ZStack(alignment: .leading) {
            ForEach(state.spaces) { space in
                let slot = slots.firstIndex(of: space.id) ?? slots.firstIndex(of: nil) ?? max(slots.count - 1, 0)
                let dragged = iconDrag?.id == space.id
                SpaceCell(space: space, highlight: SpaceCellHighlight(store: store, swipe: swipe, spaceID: space.id),
                          number: (state.spaceIndex(space.id) ?? 0) + 1,
                          profileName: actions.showsProfiles ? state.profile(space.profile).name : nil,
                          dragging: iconDrag != nil) {
                    store.mutate { $0.selectSpace(space.id) }
                }
                .opacity(dragged ? 0 : 1)
                .highPriorityGesture(reorderGesture(space.id, state: state))
                .contextMenu { SpaceContextMenu(store: store, actions: actions, space: space) }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { drag?.reportSpaceIcon(space.id, frame: $0) }
                .onDisappear { drag?.reportSpaceIcon(space.id, frame: nil) }
                // Last, so the frame reported for tab drops onto the icon is where it's drawn.
                .offset(x: CGFloat(slot) * M.spaceCellPitch)
            }
        }
        .frame(width: CGFloat(SpaceReorder.width(slots: slots.count, pitch: M.spaceCellPitch, cellWidth: M.spaceCellSize.width)),
               height: M.spaceCellSize.height, alignment: .leading)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { stripFrame = $0 }
    }

    /// Where the strip's first cell starts when it has `slots` cells: centred in the room, or from the
    /// scroll view's leading edge when the spaces overflow it.
    private func stripMinX(slots: Int, state: BrowserState) -> CGFloat {
        guard fits(state) else { return stripFrame.minX }
        return roomFrame.midX - CGFloat(SpaceReorder.width(slots: slots, pitch: M.spaceCellPitch, cellWidth: M.spaceCellSize.width)) / 2
    }

    /// The bar's spacing between its buttons and the strip.
    private static let buttonGap: CGFloat = 4

    /// The centre of slot `index` in a strip of `slots` cells.
    private func slotCenter(_ index: Int, slots: Int, state: BrowserState) -> CGPoint {
        CGPoint(x: stripMinX(slots: slots, state: state) + M.spaceCellSize.width / 2 + CGFloat(index) * M.spaceCellPitch,
                y: roomFrame.midY)
    }

    /// Arc's dock takes the drop anywhere over the strip's scroll view, which spans the bar's height
    /// between its end buttons; off it the open slot closes.
    private func target(at point: CGPoint, state: BrowserState) -> Int? {
        let zone = CGRect(x: roomFrame.minX, y: roomFrame.midY - M.bottomBarHeight / 2,
                          width: roomFrame.width, height: M.bottomBarHeight)
        guard zone.contains(point) else { return nil }
        let count = state.spaces.count
        return SpaceReorder.dropIndex(pointerX: point.x, stripMinX: stripMinX(slots: count, state: state), count: count,
                                      pitch: M.spaceCellPitch, cellWidth: M.spaceCellSize.width)
    }

    private func reorderGesture(_ id: UUID, state: BrowserState) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let state = store.state
                guard state.spaces.count > 1, let index = state.spaceIndex(id), iconDrag?.landing == nil else { return }
                pointer.location = value.location
                if iconDrag == nil {
                    // Picked up where it sat: its open slot is its own until the pointer says otherwise.
                    iconDrag = SpaceIconDrag(id: id, start: value.startLocation,
                                             pickedUp: slotCenter(index, slots: state.spaces.count, state: state),
                                             target: index)
                }
                let aim = target(at: value.location, state: state)
                if aim != iconDrag?.target {
                    withAnimation(Self.slide) { iconDrag?.target = aim }
                }
            }
            .onEnded { value in
                guard var moving = iconDrag, moving.landing == nil else { return }
                let state = store.state
                let count = state.spaces.count
                // Dropped off the strip: back to where it came from (unverified in Arc: a refused
                // `NSDraggingSession` drop slides its image home).
                let slot = target(at: value.location, state: state) ?? state.spaceIndex(moving.id) ?? 0
                moving.landing = slotCenter(slot, slots: count, state: state)
                iconDrag = moving
                withAnimation(Self.slide) {
                    iconDrag?.target = slot
                } completion: {
                    if store.state.spaceIndex(moving.id) != slot {
                        store.mutate { $0.moveSpace(moving.id, to: slot) }
                    }
                    iconDrag = nil
                }
            }
    }

    /// Unverified: Arc's collection view animates the slide and the landing; its duration isn't measured.
    private static let slide = Animation.easeInOut(duration: 0.2)

    @ViewBuilder
    private func dragGhost(_ state: BrowserState) -> some View {
        if let iconDrag, let space = state.spaces.first(where: { $0.id == iconDrag.id }) {
            SpaceDragGhost(drag: iconDrag, pointer: pointer, space: space,
                           highlight: SpaceCellHighlight(store: store, swipe: swipe, spaceID: space.id))
        }
    }
}

/// The dragged icon, following the pointer from where it was picked up, then settling into its slot.
/// Its own view, reading the pointer, so a move redraws it alone and not the bar.
private struct SpaceDragGhost: View {
    let drag: SpaceIconDrag
    let pointer: SpaceIconPointer
    let space: Space
    let highlight: SpaceCellHighlight

    var body: some View {
        let center = drag.landing ?? CGPoint(x: drag.pickedUp.x + pointer.location.x - drag.start.x,
                                             y: drag.pickedUp.y + pointer.location.y - drag.start.y)
        // Arc's drag image is the cell with its rounded backing (dock-region capture, 1 Nov 2026).
        SpaceCellIcon(space: space, highlight: highlight)
            .frame(width: M.spaceCellSize.width, height: M.spaceCellSize.height)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.primary.opacity(0.08))
                .frame(width: M.bottomButtonSize, height: M.bottomButtonSize))
            .offset(x: center.x - M.spaceCellSize.width / 2, y: center.y - M.spaceCellSize.height / 2)
            .allowsHitTesting(false)
    }
}

@MainActor
@Observable
private final class SpaceIconPointer {
    var location: CGPoint = .zero
}

/// A space icon on its way to a new place in the strip.
private struct SpaceIconDrag {
    var id: UUID
    /// Where the pointer went down (bar points).
    var start: CGPoint
    /// The centre of the icon's cell when it was picked up.
    var pickedUp: CGPoint
    /// The open slot, nil while the pointer is off the strip.
    var target: Int?
    /// Once dropped: the centre of the slot the icon settles into.
    var landing: CGPoint?
}

/// One space in the strip. Arc (1 Nov 2026): the current space shows its icon in colour, other spaces
/// their icon greyed, and a space without an icon an 8pt dot at about 23% white; under the pointer a cell gets a rounded backing and, after a moment, a
/// pill above it with the space's name, its profile and its ⌃-number shortcut.
/// How lit a space's icon in the bar is: its share of the sidebar while the pages slide
/// (`SpaceSwipe.highlight`), so the icons hand over with the swipe as the theme does. Read in the cell's
/// icon only, so a frame of a swipe redraws the icons and nothing else of the bar.
@MainActor
private struct SpaceCellHighlight {
    let store: BrowserStore
    let swipe: SpaceSwipeModel
    let spaceID: UUID

    var value: Double {
        let state = store.state
        guard let index = state.spaceIndex(spaceID) else { return 0 }
        let selected = state.selectedSpaceIndex
        let built = SpaceSwipe.builtPages(selected: selected, anchor: swipe.anchor.flatMap(state.spaceIndex), count: state.spaces.count)
        return SpaceSwipe.highlight(of: index, selected: selected, built: built, offset: Double(swipe.offset),
                                    pageWidth: Double(swipe.pageWidth))
    }
}

private struct SpaceCell: View {
    let space: Space
    let highlight: SpaceCellHighlight
    let number: Int
    let profileName: String?
    /// Some icon in the strip is being dragged: no hover backing or name pill meanwhile.
    var dragging = false
    let action: () -> Void
    @State private var hovering = false
    @State private var anchor: NSView?

    var body: some View {
        Button(action: action) {
            SpaceCellIcon(space: space, highlight: highlight)
            .frame(width: M.spaceCellSize.width, height: M.spaceCellSize.height)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.primary.opacity(hovering && !dragging && space.id != highlight.store.state.selectedSpaceID ? 0.08 : 0))
                .frame(width: M.bottomButtonSize, height: M.bottomButtonSize))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(AnchorView(view: $anchor))
        .onHover { inside in
            hovering = inside
            if inside {
                DispatchQueue.main.asyncAfter(deadline: .now() + M.spaceTipDelay) { if hovering && !dragging { showTip() } }
            } else {
                SpaceTipWindow.shared.hide(space.id)
            }
        }
        .onChange(of: dragging) { _, dragging in if dragging { SpaceTipWindow.shared.hide(space.id) } }
        .onDisappear { SpaceTipWindow.shared.hide(space.id) }
        .accessibilityLabel(space.name)
    }

    private func showTip() {
        guard let anchor else { return }
        SpaceTipWindow.shared.show(SpaceTip(space: space, number: number, profileName: profileName),
                                   for: space.id, above: anchor, gap: M.spaceTipGap)
    }
}

/// A space's icon in the bar, crossfading from grey to colour as its space comes in. Other spaces' icons are
/// greyed until you're in them; icon-less spaces are dots.
private struct SpaceCellIcon: View {
    private typealias M = ArcMetrics.Sidebar
    let space: Space
    let highlight: SpaceCellHighlight

    var body: some View {
        let lit = highlight.value
        if !space.icon.isEmpty {
            ZStack {
                SpaceIconView(icon: space.icon, theme: space.theme, size: M.spaceIconFontSize, greyed: true)
                    .opacity(1 - lit)
                SpaceIconView(icon: space.icon, theme: space.theme, size: M.spaceIconFontSize, greyed: false)
                    .opacity(lit)
            }
        } else {
            Circle()
                .fill(.primary.opacity(M.spaceDotOpacity + (1 - M.spaceDotOpacity) * lit))
                .frame(width: M.spaceDotSize, height: M.spaceDotSize)
        }
    }
}

/// Arc's space tooltip: a dark pill tinted by the theme with the name, a profile chip and keycaps.
private struct SpaceTip: View {
    let space: Space
    let number: Int
    let profileName: String?

    var body: some View {
        let accent = Color(theme: space.theme.accent)
        HStack(spacing: 8) {
            Text(space.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            if let profileName {
                HStack(spacing: 4) {
                    Image(systemName: "face.smiling").font(.system(size: 11, weight: .semibold))
                    Text(profileName).font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(accent)
                .padding(.horizontal, 7)
                .frame(height: 21)
                .background(Capsule().fill(.white.opacity(0.9)))
            }
            if number <= 9 {
                HStack(spacing: 3) {
                    keycap("⌃")
                    keycap("\(number)")
                }
                .foregroundStyle(accent)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Capsule().fill(Color(theme: tipFill)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
    }

    /// The accent darkened to about 30%, like Arc's navy pill over an indigo theme.
    private var tipFill: ThemeColor {
        var lab = space.theme.accent.lab
        lab.x *= 0.45
        return OKLab.toSRGB(lab)
    }

    private func keycap(_ key: String) -> some View {
        Text(key).font(.system(size: 12, weight: .bold))
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.white.opacity(0.85)))
    }
}

/// The space's icon and name above its pinned tabs, Arc's small semibold caption.
/// Arc's space context menu, shared by the space's icon in the strip and its header. Arc's
/// `SidebarSpaceState+SpaceContextMenu` also has Share, Manage Spaces, Show/Hide Space Header, live folders,
/// profile and Turn into Folder, which Kite doesn't have yet.
private struct SpaceContextMenu: View {
    let store: BrowserStore
    let actions: SidebarActions
    let space: Space

    // Arc's order and titles, from its menu on 1 Nov 2026. Its Live Folders, Share Space…, Export into
    // Folder and Manage Spaces… are left out: Kite has none of those.
    var body: some View {
        Button("Change Space Icon…") { actions.changeSpaceIcon(space.id) }
        Button("Rename Space…") { store.beginRenaming(space: space.id) }
        // Kite's own (Arc has no such field): what belongs here, so Claude opens tabs in the right space.
        Button("What's This Space For?…") { actions.describeSpace(space.id) }
        Button("Edit Theme Color…") { actions.editTheme(space.id) }
        if actions.showsProfiles { SetProfileMenu(store: store, actions: actions, space: space) }
        Divider()
        Button("New Folder") {
            guard let index = store.state.spaceIndex(space.id) else { return }
            store.mutate { _ = $0.createFolder(name: "New Folder", inSpace: index) }
        }
        // Arc's binary lists Live Folders right after New Folder.
        LiveFoldersSpaceMenu(store: store, space: space)
        Divider()
        Button("Delete Space") { actions.deleteSpace(space.id) }
            .disabled(store.state.spaces.count < 2)
    }
}

