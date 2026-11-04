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
    /// A drag dropped items in the sidebar: the move (after Arc's warning when it changes their
    /// profile), then Arc's move toasts.
    var drop: ([UUID], SidebarDropTarget) -> Void = { _, _ in }
    /// The pointer moved onto a favorite's tile (with the tile's view), or off it (nil): its preview card.
    var previewFavorite: (BrowserTab?, NSView?) -> Void = { _, _ in }
}

/// Set from a tracking area over the sidebar's host (`BrowserWindowController`).
@MainActor
@Observable
final class SidebarHoverModel {
    var isHovered = false
}

/// What the sidebar (`SidebarColumnView`) is built from: the window's store, its actions, and the models
/// and callbacks the window controller hands it.
@MainActor
struct SidebarConfiguration {
    let store: BrowserStore
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
    var fieldAccessory: NSView?
    /// Opens Site Controls from the address field's hover button.
    var showSiteControls: ((NSView) -> Void)?
    /// Chrome's install icon, shown while the tab's page has an installable manifest; nil in incognito.
    var installApp: ((NSView) -> Void)?
    /// Where a two-finger swipe between spaces has the pages.
    var swipe = SpaceSwipeModel()
    /// The Mini Player's buttons; nil shows no Mini Player.
    var miniPlayer: MiniPlayerActions?
    /// The sidebar's drags; the pages, the tray, the space bar and the overlay share it.
    var drag = SidebarDragModel()
    /// Whether the pointer is over the sidebar: Arc's URL row reads `sidebarHovered` for its buttons.
    var hover = SidebarHoverModel()
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

/// Arc's space tooltip: a dark pill tinted by the theme with the name, a profile chip and keycaps.
struct SpaceTip: View {
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

