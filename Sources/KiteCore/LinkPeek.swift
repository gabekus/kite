import Foundation

/// Arc's Peek: a link opened in a card floating over the current page, with buttons to close it, expand it
/// into a tab, or add it to a split. Not to be confused with the sidebar peek (the hidden sidebar sliding in).
///
/// Numbers come from Arc 1.171's `ModalContent.ModalV2HostView` in the `popover` layout mode (decompiled);
/// see docs/arc-visual-spec.md "Peek".
public enum LinkPeek {
    /// Arc's Links settings: "Open a Peek window when clicking on links to other sites" (Favorites and
    /// Pinned tabs only), and "… on links with Shift held" (any tab).
    public static func opensInPeek(section: TabSection?, from source: URL?, to target: URL, shift: Bool) -> Bool {
        guard let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https",
              target.host() != nil else { return false }
        if shift { return true }
        guard section == .pinned || section == .favorite else { return false }
        guard let sourceSite = SignInHandoff.site(source?.host()) else { return false }
        return sourceSite != SignInHandoff.site(target.host())
    }

    /// A frame in the host view's flipped coordinates (origin top left).
    public struct Frame: Equatable, Sendable {
        public var x, y, width, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// The card is 80% of the host's width, centred, 12pt below its top and 12pt above its bottom.
    public static let widthFraction = 0.8
    public static let verticalInset = 12.0
    public static let cornerRadius = 8.0
    /// The buttons' column sits this far right of the card, top-aligned with it.
    public static let controlsGap = 13.0
    public static let controlsWidth = 120.0
    /// Each button's row; the column is 90pt with two buttons, 135pt with three (split).
    public static let controlRowHeight = 45.0

    public static func cardFrame(hostWidth: Double, hostHeight: Double) -> Frame {
        let width = (hostWidth * widthFraction).rounded()
        return Frame(
            x: ((hostWidth - width) / 2).rounded(),
            y: verticalInset,
            width: width,
            height: max(0, hostHeight - 2 * verticalInset)
        )
    }

    public static func controlsFrame(card: Frame, buttons: Int) -> Frame {
        Frame(x: card.x + card.width + controlsGap, y: card.y, width: controlsWidth, height: Double(buttons) * controlRowHeight)
    }

    /// Card shadow: black, 30% opacity, 4pt blur, 1pt down.
    public static let shadowOpacity = 0.3
    public static let shadowRadius = 4.0
    public static let shadowOffsetY = 1.0
    /// A hairline outside the card: black at 25%, 0.5pt.
    public static let borderOpacity = 0.25
    public static let borderWidth = 0.5

    /// Arc's spring for the card (`CASpringAnimation` from a damping ratio and a response in seconds).
    public struct Spring: Equatable, Sendable {
        public var dampingRatio: Double
        public var response: Double
        /// Stiffness and damping for unit mass, as Arc derives them.
        public var stiffness: Double { pow(2 * Double.pi / response, 2) }
        public var damping: Double { 4 * Double.pi * dampingRatio / response }
    }

    public static let openSpring = Spring(dampingRatio: 0.865, response: 0.245)
    public static let closeSpring = Spring(dampingRatio: 0.895, response: 0.225)
}
