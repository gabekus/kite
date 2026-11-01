import Foundation

/// The arrow that flies into the sidebar's Library button when a download starts (Arc's
/// `DownloadsUI.DownloadToLibrary`, `animateDownload(source:destination:)`).
///
/// Arc throws it as a projectile and samples the throw at 60 fps into keyframes
/// (`ProjectileIconKeyframeAnimation`). The numbers are Arc 1.169's (decompiled
/// `DownloadToLibrary.DownloadViewModel`):
/// - Points are window points from the window's bottom-left corner, y up.
/// - It starts 15pt right of and 15pt below where the download started (the pointer).
/// - It lands on (32, 40), at the Library button, with gravity 2648.7 pt/s² and an upward launch
///   speed of 1600 - 1100 × (start height / window height) pt/s, so a throw from low in the
///   window arcs higher. The horizontal speed is constant, so it lands exactly on time.
/// - It stretches from 0.8 × 1.2 at launch to 1.6 at the top of the arc, then shrinks evenly to 0.3
///   as it lands, and keeps falling (and shrinking) for 0.1333 s more, sinking into the button.
public struct DownloadFlight: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// One 60 fps sample.
    public struct Frame: Equatable, Sendable {
        public var time: Double
        public var position: Point
        public var scaleX: Double
        public var scaleY: Double
    }

    public static let gravity = 2648.7
    public static let frameInterval = 1.0 / 60
    /// Where it lands: the Library button, in window points from the bottom-left corner.
    public static let destination = Point(x: 32, y: 40)
    /// From the pointer to where the arrow starts.
    public static let startOffset = Point(x: 15, y: -15)
    /// It keeps falling this long after it lands (Arc: 0.13333 s when the sidebar shows).
    public static let sinkDuration = 0.13333333333333333
    /// The arrow's size before scaling.
    public static let iconSize = 30.0

    public let start: Point
    public let destination: Point
    /// Upward launch speed (pt/s).
    public let launchSpeedY: Double
    /// Constant horizontal speed (pt/s).
    public let speedX: Double
    /// When it reaches the top of the arc.
    public let apexTime: Double
    /// When it reaches the destination.
    public let landingTime: Double

    /// `pointer`: where the download started, in window points from the bottom-left corner.
    /// Nil when the arc can't reach the destination.
    public init?(pointer: Point, windowHeight: Double, destination: Point = DownloadFlight.destination) {
        // Arc falls back to (70, 70) when the pointer isn't a finite point.
        let pointer = pointer.x.isFinite && pointer.y.isFinite ? pointer : Point(x: 70, y: 70)
        let start = Point(x: pointer.x + Self.startOffset.x, y: pointer.y + Self.startOffset.y)
        let vy = windowHeight == 0 ? 1600 : 1600 - 1100 * (start.y / windowHeight)
        // destination.y - start.y = vy·t - g/2·t², the later root (on the way down).
        let rise = destination.y - start.y
        let discriminant = vy * vy - 2 * Self.gravity * rise
        guard discriminant >= 0 else { return nil }
        let landing = (vy + discriminant.squareRoot()) / Self.gravity
        guard landing > 0 else { return nil }
        self.start = start
        self.destination = destination
        launchSpeedY = vy
        landingTime = landing
        speedX = (destination.x - start.x) / landing
        apexTime = vy / Self.gravity
    }

    /// Everything, sink included.
    public var duration: Double { landingTime + Self.sinkDuration }

    public func position(at t: Double) -> Point {
        Point(x: start.x + speedX * t, y: start.y + launchSpeedY * t - Self.gravity / 2 * t * t)
    }

    /// Horizontal and vertical scale at `t`; never below 0.
    public func scale(at t: Double) -> (x: Double, y: Double) {
        if t < apexTime {
            let progress = apexTime == 0 ? 0 : t / apexTime
            return (0.8 + 0.8 * progress, 1.2 + 0.4 * progress)
        }
        // 1 at the top of the arc, 0 on landing, below 0 while it sinks.
        let left = landingTime == apexTime ? 1 : 1 - (t - apexTime) / (landingTime - apexTime)
        let scale = max(0, 1.6 + 1.3 * (left - 1))
        return (scale, scale)
    }

    /// Arc's keyframes: one every 1/60 s from launch until the sink ends.
    public var frames: [Frame] {
        var frames: [Frame] = []
        var t = 0.0
        while t < duration {
            let scale = scale(at: t)
            frames.append(Frame(time: t, position: position(at: t), scaleX: scale.x, scaleY: scale.y))
            t += Self.frameInterval
        }
        return frames
    }
}
