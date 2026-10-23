import CoreGraphics

/// Arc 1.169's window chrome, measured from its accessibility tree and
/// screenshots (see docs/arc-visual-spec.md). Points at 1x, from the window's
/// top-left or the named container's edge.
enum ArcMetrics {
    enum Sidebar {
        /// Leading and trailing padding of the URL field, favorites, tab pills and bottom bar.
        static let padding: CGFloat = 8

        // Top row: sidebar toggle on the left, back/forward/reload on the right.
        static let topRowY: CGFloat = 7.5
        static let topRowHeight: CGFloat = 32
        static let navButtonSize: CGFloat = 32
        static let navButtonSpacing: CGFloat = 2
        /// Back/forward/reload end 6pt short of the sidebar's edge, 2pt past the padding.
        static let navTrailing: CGFloat = 6
        /// The sidebar toggle's x, just right of the traffic lights.
        static let toggleX: CGFloat = 71

        // URL field.
        static let urlFieldTopGap: CGFloat = 6.5
        static let urlFieldHeight: CGFloat = 36
        static let urlFieldTextInset: CGFloat = 12
        static let urlFieldFontSize: CGFloat = 13
        static let urlFieldTextOpacity: Double = 0.6

        // Favorites grid.
        static let favoritesTopGap: CGFloat = 8
        static let favoritesBottomGap: CGFloat = 8
        static let favoriteColumns = 4
        static let favoriteHeight: CGFloat = 47
        static let favoriteSpacing: CGFloat = 8
        static let favoriteIconSize: CGFloat = 18

        /// URL field, favorite tiles and tab pills share one corner.
        static let cornerRadius: CGFloat = 11
        /// White over the tint, for the URL field and favorite tiles.
        static let fieldFill: Double = 0.10

        // Space header above the pinned tabs.
        static let headerHeight: CGFloat = 36
        static let headerIconSize: CGFloat = 26
        static let headerIconX: CGFloat = 13
        /// Icon's top inside the header (y 205 in a header starting at 200).
        static let headerIconTop: CGFloat = 5
        static let headerTextX: CGFloat = 41
        static let headerFontSize: CGFloat = 13
        static let headerTextOpacity: Double = 0.45

        // Tab rows.
        static let rowPitch: CGFloat = 41
        static let pillHeight: CGFloat = 36
        static let iconSize: CGFloat = 18
        /// Favicon's leading edge inside the pill (x 17 in the window).
        static let iconInset: CGFloat = 9
        static let iconTextGap: CGFloat = 8
        static let tabFontSize: CGFloat = 14
        static let tabTextOpacity: Double = 0.865
        static let selectedFill: Double = 0.20
        static let hoverFill: Double = 0.10
        /// Pinned tabs and folders start 3pt below the header.
        static let listTopSpacer: CGFloat = 3

        // Divider between pinned and today's tabs.
        static let dividerRowHeight: CGFloat = 25
        static let dividerInset: CGFloat = 10
        static let dividerThickness: CGFloat = 0.5
        static let dividerOpacity: Double = 0.08

        // Bottom bar: library button, spaces, new space.
        static let bottomBarHeight: CGFloat = 50
        static let bottomButtonSize: CGFloat = 32
    }

    enum Content {
        /// Gap around the web content card; it starts right at the sidebar's edge.
        static let inset: CGFloat = 10
        static let cornerRadius: CGFloat = 6
    }

    /// Arc's timings: from its binary where it names them, else fitted from 60fps recordings.
    enum Motion {
        /// Space switch: the theme settles like `spring(response: 0.15, dampingFraction: 0.95)`.
        static let spaceSwitchResponse: Double = 0.15
        static let spaceSwitchDamping: Double = 0.95
        /// Sidebar hide and show: 0.08s on a cubic Bézier through these control points, for both
        /// directions. Arc sets the sidebar's and the content's frames once in an implicit
        /// animation group and lets Core Animation draw the frames between.
        static let sidebarToggleDuration: Double = 0.08
        static let sidebarToggleCurve: (x1: Float, y1: Float, x2: Float, y2: Float) = (0.25, 0.46, 0.45, 0.94)
    }

    enum CommandBar {
        static let width: CGFloat = 765
        /// Top edge as a share of the window's height, centred horizontally on the window.
        static let topFraction: CGFloat = 0.369
        /// Arc's command bar layer uses a 12pt circular corner (it sets no corner curve).
        static let cornerRadius: CGFloat = 12
        static let borderOpacity: Double = 0.22
        /// A large soft drop shadow: it darkens the page 35% under the bottom edge, 25% at the
        /// sides and 16% at the top, fading out about 100pt away.
        static let shadowOpacity: Double = 0.9
        static let shadowRadius: CGFloat = 45
        static let shadowY: CGFloat = 16
        static let placeholderOpacity: Double = 0.25
        static let fieldHeight: CGFloat = 63.5
        static let iconX: CGFloat = 22.5
        static let iconSize: CGFloat = 18
        static let textX: CGFloat = 52.5
        static let fieldFontSize: CGFloat = 18
        static let dividerInset: CGFloat = 11
        static let dividerOpacity: Double = 0.10
        static let listTopGap: CGFloat = 4.5
        static let listBottomGap: CGFloat = 9.5
        /// Rows are 750 wide inside the 765 panel; their fill is inset 2pt more, and 2pt from the row's top.
        static let rowInset: CGFloat = 7.5
        static let rowPitch: CGFloat = 50
        static let rowFillInset: CGFloat = 2
        static let rowFillHeight: CGFloat = 44.5
        static let rowCornerRadius: CGFloat = 8
        static let rowIconTileSize: CGFloat = 24
        static let rowIconSize: CGFloat = 16
        /// Icon tile's leading edge inside the row fill, then the title's.
        static let rowIconX: CGFloat = 10
        static let rowTitleX: CGFloat = 41
        static let rowFontSize: CGFloat = 13
        static let rowTextOpacity: Double = 0.8
        static let rowDetailOpacity: Double = 0.33
        static let actionBoxSize: CGFloat = 24
        static let actionBoxTrailing: CGFloat = 13
        static let actionGap: CGFloat = 7
    }
}
