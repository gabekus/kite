import AppKit
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

        /// How far the sidebar can be dragged. From Arc 1.169's binary (the resize pan handler):
        /// 164 to 500. Arc also hides the sidebar when dragged below 82; Kite doesn't yet.
        static let widths: ClosedRange<CGFloat> = 164...500
        /// Arc's `SidebarHeaderWidthLayout`, from the header's width (Arc 1.169's binary): compact
        /// under 212, medium from 212 to under 228 (four 47pt favorite tiles with 8pt gaps and
        /// padding), regular from 228. Compact shrinks the navigation buttons to 28pt with no gap
        /// and hides the sidebar toggle and reload behind a More menu.
        static let headerCompactBelow: CGFloat = 212
        static let headerMediumBelow: CGFloat = 228
        static let compactNavButtonSize: CGFloat = 28
        static let compactNavButtonSpacing: CGFloat = 0

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
        /// A favorite split's panes inside its tile (Arc 1.169's binary, `AppTrayItemChildStack`).
        static let favoriteSplitSpacing: CGFloat = 2

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
        /// Each folder level indents its rows this much. Arc 1.169's binary: the tab list's
        /// outline view sets indentationPerLevel 16, and its cell frame override only shifts every
        /// level by the same constant; tab cells add no depth term of their own.
        static let nestingIndent: CGFloat = 16
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
        /// The space strip's cells, centred between the bar's end buttons (Arc's tree: 36×34 at x 92.5,
        /// 126.5, 160.5 in a strip from 42 to 247, y 1243 in a bar from 1235).
        static let spaceCellSize = CGSize(width: 36, height: 34)
        static let spaceCellPitch: CGFloat = 34
        /// An inactive space's dot: 8pt, (78,73,89) over a (24,16,42) tint, so white at about 23% (screen
        /// capture, 1 Nov 2026; Arc draws the strip in its own window, which window captures miss).
        static let spaceDotSize: CGFloat = 8
        static let spaceDotOpacity: Double = 0.23
        /// The current space's icon is about 14pt tall.
        static let spaceIconFontSize: CGFloat = 14
        /// The hover pill sits just above the cells. Unmeasured: its delay.
        static let spaceTipGap: CGFloat = 2
        static let spaceTipDelay: Double = 0.4

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

    /// Split view. From Arc's binary (`ARCUI.SplitViewController`, `SplitViewDraggerHandleView`, the sidebar's
    /// split row) and an incognito capture of Arc 1.171 (docs/arc-visual-spec.md, "Split View: geometry and motion").
    enum Split {
        /// The gap between two panes is the divider: `draggerHandleWidth` 10, with a hit-target outset of 0,
        /// so the resize zone is exactly the gap. Measured 10pt in Arc, the same as the card's inset.
        static let gap: CGFloat = 10
        /// The divider's grip: a 2×24pt pill, corner 1, centred in the gap.
        static let gripSize = CGSize(width: 2, height: 24)
        static let gripCornerRadius: CGFloat = 1
        /// Arc's `DragHint` asset: black (white in dark mode) at 20%, 50% on hover.
        static let gripOpacity: Double = 0.20
        static let gripHoverOpacity: Double = 0.50
        static let gripFadeDuration: Double = 0.16
        /// Narrowest a pane can be dragged: `minimumPaneWidth` 220.
        static let minimumPaneWidth: CGFloat = 220
        /// A dragged divider snaps to the middle of its two panes within this distance.
        static let centerSnapDistance: Double = 14
        /// Double-clicking a divider evens out its two panes, animated: 0.2s ease-out.
        /// Adding and closing panes isn't animated (add: measured; close: not recorded yet).
        static let equalizeDuration: Double = 0.2
        /// How far in from each outer edge of the content area a dragged link counts as "open in a split".
        /// Not measured: Arc's drop regions aren't traced.
        static let dropEdge: CGFloat = 64
        /// The drop placeholder's outline (`SplitViewContentPlaceholderView.BorderView`, Arc 1.169 binary).
        static let dropBorderWidth: CGFloat = 2
        static let dropCornerRadius: CGFloat = 6

        // The sidebar row: one item per pane, side by side.
        static let rowItemSpacing: CGFloat = 4
        /// An item this narrow or narrower shows only its favicon.
        static let rowCompactWidth: CGFloat = 60
        /// A title gets 20pt or less after the favicon: hidden, leaving just the favicon
        /// (`SplitViewCellChildItemView.layout` in Arc 1.169's binary).
        static let rowTitleMinWidth: CGFloat = 20
        /// Each item's corner is min(width / 2, this).
        static let rowItemMaxCornerRadius: CGFloat = 8
    }

    /// Arc's timings: from its binary where it names them, else fitted from 60fps recordings.
    enum Motion {
        /// Space switch: the theme settles like `spring(response: 0.15, dampingFraction: 0.95)`.
        static let spaceSwitchResponse: Double = 0.15
        static let spaceSwitchDamping: Double = 0.95
        /// Space switch, the pages' slide: a critically damped spring of about this response.
        static let spacePageResponse: Double = 0.1
        /// Sidebar hide and show: 0.08s on a cubic Bézier through these control points, for both
        /// directions. Arc sets the sidebar's and the content's frames once in an implicit
        /// animation group and lets Core Animation draw the frames between.
        static let sidebarToggleDuration: Double = 0.08
        static let sidebarToggleCurve: (x1: Float, y1: Float, x2: Float, y2: Float) = (0.25, 0.46, 0.45, 0.94)
        /// Sidebar rows coming and going (a new tab, a closed or archived one, a move): Arc applies its
        /// outline's snapshot inside an `NSAnimationContext` group of 0.12s with the default timing
        /// function, (0.25, 0.1, 0.25, 1). New rows fade in, removed rows fade out in place, and the
        /// rows below slide to their new places.
        static let sidebarRowsDuration: Double = 0.12
        static let sidebarRowsCurve: (x1: Float, y1: Float, x2: Float, y2: Float) = (0.25, 0.1, 0.25, 1)
    }

    /// Arc's Edit Theme popover (Arc 1.169 accessibility tree and one capture, 31 Oct 2026). Points
    /// from the content's top-left: the popover is 382×534 with its content inset 13, and the dot grid
    /// sits 8 inside that.
    /// Arc's Create a Space page (+ › New Space), from its accessibility tree and captures on a 289pt
    /// sidebar, 1 Nov 2026. Vertical numbers run from the top row's bottom (y 39.5) down; rows are 261
    /// wide, 14 in from the sidebar's edges.
    enum SpaceCreation {
        static let illustrationTop: CGFloat = 46.5
        static let illustrationHeight: CGFloat = 33
        static let titleTop: CGFloat = 21
        static let titleFontSize: CGFloat = 17
        static let subtitleTop: CGFloat = 11
        static let subtitleFontSize: CGFloat = 14
        static let subtitleOpacity: Double = 0.85
        /// The name field's top, under the subtitle (y 237).
        static let fieldsTop: CGFloat = 32
        static let profileGap: CGFloat = 6
        static let themeGap: CGFloat = 8
        static let inset: CGFloat = 14
        static let rowHeight: CGFloat = 36
        static let rowIconX: CGFloat = 22
        static let rowTextX: CGFloat = 48
        static let iconSize: CGFloat = 18
        static let rowFontSize: CGFloat = 15
        /// White over the tint: #2C2B40 over #131029.
        static let rowFill: Double = 0.095
        /// Estimated from the capture.
        static let cornerRadius: CGFloat = 8
        /// Create Space: #2C4AFC once there's a name, about half that over the tint before.
        static let createColor = NSColor(srgbRed: 0x2C / 255, green: 0x4A / 255, blue: 0xFC / 255, alpha: 1)
        static let createDisabledOpacity: Double = 0.5
        static let cancelTop: CGFloat = 14.5
        static let cancelFontSize: CGFloat = 13
        static let cancelOpacity: Double = 0.68
        /// From Cancel's bottom (y 1218.5) to the bottom bar (y 1235).
        static let cancelBottom: CGFloat = 16.5
    }

    /// Arc's + menu: the popover is 222 wide with its rows inset 14 (so 194 wide) and 40 tall; icons
    /// around 11 into a row, titles at 39; a 17pt gap with a line between groups.
    enum NewItemMenu {
        static let width: CGFloat = 222
        static let inset: CGFloat = 14
        static let rowHeight: CGFloat = 40
        static let iconX: CGFloat = 8
        static let iconWidth: CGFloat = 22
        static let textX: CGFloat = 39
        static let dividerHeight: CGFloat = 17
        static let dividerInset: CGFloat = 8
    }

    /// Arc's Change Space Icon popover (captures, 1 Nov 2026).
    enum SpaceIconPicker {
        static let width: CGFloat = 272
        static let inset: CGFloat = 12
        static let emojiColumns = 7
        static let emojiPitch: CGFloat = 33.5
        static let rowPitch: CGFloat = 33
        static let emojiGridHeight: CGFloat = 165
        static let iconColumns = 8
        static let iconPitch: CGFloat = 31
    }

    enum ThemeEditor {
        static let popoverSize = CGSize(width: 382, height: 534)
        static let contentSize = CGSize(width: 356, height: 508)
        static let inset: CGFloat = 8
        static let fieldSize: CGFloat = 340
        /// Estimated from the capture.
        static let fieldCornerRadius: CGFloat = 8
        static let dotPitch: CGFloat = 5
        static let buttonSize: CGFloat = 32
        /// Auto, light and dark, from the grid's corner.
        static let modeX: CGFloat = 114
        static let modeY: CGFloat = 24
        static let modeSpacing: CGFloat = 8
        /// − and +, from the grid's corner.
        static let countX: CGFloat = 134
        static let countY: CGFloat = 292
        static let countSpacing: CGFloat = 8
        /// About 45pt across with a 5pt white ring, from the capture.
        static let handleSize: CGFloat = 45
        static let handleRing: CGFloat = 5
        /// "Tap to pick a color for this space": centred, its top 162 down the grid (Arc's tree).
        static let hintFontSize: CGFloat = 13
        static let hintY: CGFloat = 162
        /// Unmeasured: the most colours Kite lets a theme have in the editor.
        static let maxColors = 3
        /// The preset row's top, from the grid's top: arrows 32×32 at the ends, 24pt swatches 29.5 apart
        /// starting 40 in.
        static let presetsTop: CGFloat = 356
        static let swatchButton: CGFloat = 32
        static let swatchesX: CGFloat = 40
        static let swatchSize: CGFloat = 24
        static let swatchPitch: CGFloat = 29.5
        /// The intensity slider (224×56) and grain dial (80×80, 12pt higher) row, from the grid's top.
        static let controlsTop: CGFloat = 416
        static let sliderX: CGFloat = 10
        static let sliderTop: CGFloat = 0
        static let sliderSize = CGSize(width: 224, height: 56)
        static let trackHeight: CGFloat = 15
        static let thumbSize = CGSize(width: 24, height: 55)
        static let dialSize: CGFloat = 80
        static let dialY: CGFloat = -12
        static let dialTrailing: CGFloat = 10
    }

    enum CommandBar {
        static let width: CGFloat = 765
        /// Kite's own: in a window too narrow for 765, the bar keeps this much from each edge.
        static let minimumWindowMargin: CGFloat = 20
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

    /// Arc 1.171's Little Arc window, measured from its accessibility tree (`kite probe Arc tree`)
    /// and a background capture at 2x (see docs/arc-visual-spec.md, "Little Arc"). Window points
    /// from the top-left. No sidebar; the page runs edge to edge under a 47pt toolbar.
    enum LittleWindow {
        /// The only size Arc has stored for it (`LittleBrowserWindow_size` in Arc's defaults).
        static let defaultSize = CGSize(width: 1495, height: 1245)
        static let minSize = CGSize(width: 480, height: 320)
        /// The page's top edge.
        static let toolbarHeight: CGFloat = 47
        /// 16pt buttons at x 9/29/49, y 15.5: 3pt left of and 0.5pt above the main window's.
        static let trafficLightCenter = CGPoint(x: 17, y: 23.5)
        /// Unmeasured (needs a pointer sweep on Arc): the main window's area, moved with the lights.
        static let trafficLightHoverArea = Window.trafficLightHoverArea.offsetBy(dx: -3, dy: -0.5)
        /// Back button: 16×16 at x 79.5, y 15.5.
        static let backButton = CGRect(x: 79.5, y: 15.5, width: 16, height: 16)

        // The URL pill (Arc's command bar placeholder): x 107 to 7.5pt short of the Open In button.
        static let pillX: CGFloat = 107
        static let pillY: CGFloat = 8
        static let pillHeight: CGFloat = 31
        /// From the antialiased corner in the 2x capture (about 10px); approximate.
        static let pillCornerRadius: CGFloat = 5
        /// Arc's `LittleBrowserCommandBarPlaceholderBackground(Hovered)` colour assets.
        static let pillFillDark: Double = 0.10
        static let pillFillDarkHovered: Double = 0.15
        static let pillFillLight: Double = 0.06
        static let pillFillLightHovered: Double = 0.10
        static let hostFontSize: CGFloat = 13
        /// Copy-link button: 16×16, its right edge 7.5pt inside the pill (with the extensions
        /// button, in `LittleKite.pillButtons`).
        static let pillButtonSize: CGFloat = 16
        static let pillLeadingInset: CGFloat = 14

        // "Open in <Space> ⌘O" plus the chevron, in one bordered box.
        static let openInGap: CGFloat = 7.5
        static let openInY: CGFloat = 7.5
        static let openInHeight: CGFloat = 30.5
        static let openInTrailing: CGFloat = 7
        static let openInCornerRadius: CGFloat = 6.5
        /// Title from 6.5pt in; the chevron's 16pt button 6pt from the right edge.
        static let openInLeadingInset: CGFloat = 6.5
        static let openInChevronTrailing: CGFloat = 6
        static let openInFontSize: CGFloat = 13
        /// "Open in" in #9495A4 on Arc's dark box: about 55% white.
        static let openInDimOpacity: Double = 0.55
        /// The ⌘O keycap: 15.5pt tall.
        static let keycapHeight: CGFloat = 15.5
    }
}
