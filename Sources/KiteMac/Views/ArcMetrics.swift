import CoreGraphics

/// Arc 1.169's window chrome, measured from its accessibility tree and
/// screenshots (see docs/arc-visual-spec.md). Points at 1x, from the window's
/// top-left or the named container's edge.
enum ArcMetrics {
    enum Window {
        /// Close button's centre: Arc's 16pt buttons sit at x 12/32/52, y 16.
        static let trafficLightCenter = CGPoint(x: 20, y: 24)
        /// Centre to centre, close to minimize to zoom.
        static let trafficLightPitch: CGFloat = 20
        /// Pointing anywhere in here colours all three lights (gaps included); measured in Arc 1.169
        /// with 1pt pointer sweeps: colour from x 12 to 72 and y 17 to 30 inclusive.
        static let trafficLightHoverArea = CGRect(x: 12, y: 17, width: 61, height: 14)
    }

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
        /// A tab pill's fill on a light theme (Arc's TabCellBackgroundCurrent and
        /// SidebarItemBackground assets): near-opaque white when selected, and a faint
        /// dark wash, not white, on hover. Dark themes use selectedFill and hoverFill.
        static let selectedFillLight: Double = 0.85
        static let hoverFillLight: Double = 0.05
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

        /// A peeking (hover-revealed) sidebar stays out until the pointer is 75pt right of the card's edge.
        static let peekHoverMargin: CGFloat = 75
    }

    enum Content {
        /// Gap around the web content card; it starts right at the sidebar's edge.
        static let inset: CGFloat = 10
        static let cornerRadius: CGFloat = 6
        /// The sidebar's resize zone: 8pt centred on the card's leading edge (4pt over the sidebar,
        /// 4pt over the page), from 1pt below the card's top to 1pt above its bottom. While the hidden
        /// sidebar peeks, the same 8pt straddles the floating card's right edge, at the same height.
        static let resizeZoneHalfWidth: CGFloat = 4
        static let resizeZoneVerticalInset: CGFloat = 1
    }

    /// Split view. From Arc's binary (`SplitViewDraggerHandleView`, the sidebar's split row);
    /// values marked unverified still need a live measurement.
    enum Split {
        /// Gap between two panes. Unverified: the same as the card's inset for now.
        static let gap: CGFloat = Content.inset
        /// The divider's grip: a 2×24pt pill, corner 1, centred in the gap.
        static let gripSize = CGSize(width: 2, height: 24)
        static let gripCornerRadius: CGFloat = 1
        /// Arc's `DragHint` asset: black (white in dark mode) at 20%, 50% on hover.
        static let gripOpacity: Double = 0.20
        static let gripHoverOpacity: Double = 0.50
        static let gripFadeDuration: Double = 0.16
        /// Narrowest a pane can be dragged. Unverified.
        static let minimumPaneWidth: CGFloat = 200

        // The sidebar row: one item per pane, side by side.
        static let rowItemSpacing: CGFloat = 4
        /// An item this narrow or narrower shows only its favicon.
        static let rowCompactWidth: CGFloat = 60
        /// Each item's corner is min(width / 2, this).
        static let rowItemMaxCornerRadius: CGFloat = 8
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
        /// A tint over the HUD material: Arc's dark panel shows the page under it blurred
        /// (about a 25pt Gaussian) at roughly 11% strength over a near-black base, about
        /// 21 + 0.106 × page per channel: 48 over white, 48/21/20 over red. From screen captures.
        /// Light mode keeps the same mix over a light material; not checked against Arc.
        static let darkTint: Double = 0.06
        static let lightTint: Double = 0.98
        static let tintOpacity: Double = 0.765
        /// A large soft drop shadow: it darkens the page 35% under the bottom edge, 25% at the
        /// sides and 16% at the top, fading out about 100pt away.
        static let shadowOpacity: Double = 0.9
        static let shadowRadius: CGFloat = 45
        static let shadowY: CGFloat = 16
        /// 0.5pt of black just outside the 1pt border (outside the 765).
        static let outlineWidth: CGFloat = 0.5
        static let placeholderOpacity: Double = 0.25
        static let fieldHeight: CGFloat = 63.5
        static let iconX: CGFloat = 22.5
        static let iconSize: CGFloat = 18
        /// The magnifier, drawn in the 18pt icon frame: its ring's centre is 30.6, 30.75 from the
        /// panel's top-left; ring and handle are 1.4 wide, the handle runs at 45° and its round end reaches 8.6 from the centre.
        static let magnifierCenter = CGPoint(x: 8.35, y: 8)
        static let magnifierRadius: CGFloat = 4.65
        static let magnifierStroke: CGFloat = 1.4
        static let magnifierHandleEnd: CGFloat = 8.1
        /// Placeholder ink starts at 52 (the caret at 51.5); 18pt medium, 179pt wide.
        static let textX: CGFloat = 51.5
        static let fieldFontSize: CGFloat = 18
        /// Raises the field's text off the row's centre: its baseline sits at 38.5.
        static let fieldTextLift: CGFloat = 0.5
        static let dividerInset: CGFloat = 11.5
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
        /// Kite's own, for ⌘J's Claude bar (Arc has no equivalent): the border in Claude's
        /// colour instead of white, and a faint glow of it around the panel.
        static let accentBorderOpacity: Double = 0.55
        static let accentGlowOpacity: Double = 0.22
        static let accentGlowRadius: CGFloat = 14
    }
}
