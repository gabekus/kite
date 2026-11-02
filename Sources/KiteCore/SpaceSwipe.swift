import Foundation

/// The two-finger swipe between spaces in the sidebar: Arc pages its sidebar horizontally, one page per
/// space, under the fixed favorites (see docs/arc-visual-spec.md, "Spaces"). This is the platform-free
/// part: where the pages sit for a given finger travel, and which space a release lands on.
public struct SpaceSwipe: Equatable, Sendable {
    /// One page: the sidebar's width.
    public var pageWidth: Double
    /// Finger travel since the swipe began, in points. Positive moves the pages right, towards the
    /// previous space.
    public private(set) var travel: Double = 0
    /// Points per second, smoothed over the last few events.
    public private(set) var velocity: Double = 0
    public let hasPrevious: Bool
    public let hasNext: Bool
    private var lastTime: Double?

    public init(pageWidth: Double, hasPrevious: Bool, hasNext: Bool, travel: Double = 0) {
        self.pageWidth = max(pageWidth, 1)
        self.travel = travel
        self.hasPrevious = hasPrevious
        self.hasNext = hasNext
    }

    /// AppKit's rubber band: past the last page the pages follow the fingers ever more stiffly,
    /// approaching but never reaching a further page width.
    public static func rubberBand(_ overshoot: Double, dimension: Double) -> Double {
        let c = 0.55
        return (1 - 1 / (abs(overshoot) * c / dimension + 1)) * dimension * (overshoot < 0 ? -1 : 1)
    }

    /// Where the pages sit, in points from rest: free towards a neighbouring space, rubber-banded where
    /// there is none, and never more than a page either way.
    public var offset: Double {
        if travel > 0, !hasPrevious { return Self.rubberBand(travel, dimension: pageWidth) }
        if travel < 0, !hasNext { return Self.rubberBand(travel, dimension: pageWidth) }
        return min(max(travel, -pageWidth), pageWidth)
    }

    /// How far the swipe is towards the neighbouring space, 0...1, for crossfading the themes.
    public var progress: Double {
        let neighbour = offset > 0 ? hasPrevious : hasNext
        return neighbour ? min(abs(offset) / pageWidth, 1) : 0
    }

    /// The neighbour the pages are moving towards: -1 previous, +1 next, 0 none.
    public var direction: Int {
        if offset > 0, hasPrevious { return -1 }
        if offset < 0, hasNext { return 1 }
        return 0
    }

    public mutating func move(by delta: Double, at time: Double) {
        travel += delta
        if let last = lastTime, time > last {
            let instant = delta / (time - last)
            velocity = velocity * 0.6 + instant * 0.4
        }
        lastTime = time
    }

    /// Velocity past which a flick changes space however short it was.
    public static let flickVelocity: Double = 300

    /// The space a release lands on, relative to the current one: -1, 0 or +1. Past half a page it
    /// goes; short of it, a flick towards the neighbour still goes, and a flick back stays.
    public var landing: Int {
        let d = direction
        guard d != 0 else { return 0 }
        let towards = d == -1 ? velocity : -velocity
        if towards > Self.flickVelocity { return d }
        if towards < -Self.flickVelocity { return 0 }
        return abs(offset) >= pageWidth / 2 ? d : 0
    }

    /// Where the pages sit `elapsed` seconds into a settle that started `from` points off rest: a critically
    /// damped spring with this response, as SwiftUI's `.spring(response:dampingFraction: 1)` draws it. The
    /// controller steps it once a frame, so a swipe that catches the pages mid-settle starts from where
    /// they really are.
    public static func settle(from: Double, elapsed: Double, response: Double) -> Double {
        guard elapsed > 0 else { return from }
        let omega = 2 * Double.pi / max(response, 0.001)
        let x = from * (1 + omega * elapsed) * exp(-omega * elapsed)
        // Under a tenth of a point is on screen as at rest.
        return abs(x) < 0.1 ? 0 : x
    }

    /// The spaces whose pages are built, by index: the selected one and its neighbours, so a swipe has
    /// both sides ready the moment it starts (Arc's collection view keeps them too: its list is three
    /// pages wide). While the pages settle after a switch they stay those of `anchor`, the space the
    /// switch left, plus the new one, so no page is built mid-slide; a far jump shows just the two.
    public static func builtPages(selected: Int, anchor: Int?, count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let centre = anchor ?? selected
        var pages = Array(max(centre - 1, 0)...min(centre + 1, count - 1))
        if !pages.contains(selected) { pages.append(selected) }
        return pages.sorted()
    }

    /// How lit space `index`'s icon in the bar is, 0...1, with the pages `offset` points from rest: each built
    /// page counts by how much of the sidebar it covers, shared out so the lit amounts add up to one. The
    /// selected space's icon hands over to the neighbour's as the pages slide, in a swipe, its settle and a
    /// switch from the keyboard alike; rubber-banding past the last space leaves it fully lit.
    public static func highlight(of index: Int, selected: Int, built: [Int], offset: Double, pageWidth: Double) -> Double {
        guard pageWidth > 0 else { return index == selected ? 1 : 0 }
        func cover(_ i: Int) -> Double {
            max(0, 1 - abs(Double(i - selected) * pageWidth + offset) / pageWidth)
        }
        let total = built.reduce(0) { $0 + cover($1) }
        guard total > 0 else { return index == selected ? 1 : 0 }
        return built.contains(index) ? cover(index) / total : 0
    }
}
