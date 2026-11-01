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
}
