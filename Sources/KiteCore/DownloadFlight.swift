import Foundation

/// The arrow that flies into the sidebar's Library button when a download starts (Arc's
/// `DownloadsUI.DownloadToLibrary`, `animateDownload(source:destination:)`).
///
/// Arc throws it as a projectile and samples the throw at 60 fps into keyframes
/// (`ProjectileIconKeyframeAnimation`). The numbers are Arc 1.169's (decompiled
/// `DownloadToLibrary.DownloadViewModel`):
/// - Points are window points from the window's bottom-left corner, y up.
/// - It starts 15pt right of and 15pt below where the download started (the pointer).
/// - With the sidebar showing it lands on (32, 40), at the Library button, with gravity 2648.7 pt/s² and
///   an upward launch speed of 1600 - 1100 × (start height / window height) pt/s, so a throw from low in
///   the window arcs higher. The horizontal speed is constant, so it lands exactly on time.
/// - It stretches from 0.8 × 1.2 at launch to 1.6 at the top of the arc, then shrinks evenly to 0.3
///   as it lands, and keeps falling (and shrinking) for 0.1333 s more, sinking into the button.
/// - With the sidebar hidden it's thrown into the `DownloadBin` instead (see `DownloadBin`): it lands on
///   (62, 70), shrinking only to 0.7, doesn't sink, and bounces on a spring (damping 0.48, response 0.72)
///   from there to (70, 70), carrying the speed it landed with. It stays in the bin at 0.7.
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

    /// Where the arrow goes: the sidebar's Library button, or Arc's `DownloadBin` while the sidebar is hidden.
    public enum Target: Equatable, Sendable {
        case libraryButton
        case bin
    }

    public static let gravity = 2648.7
    public static let frameInterval = 1.0 / 60
    /// Where it lands: the Library button, in window points from the bottom-left corner.
    public static let destination = Point(x: 32, y: 40)
    /// Arc's destination for the bin, (70, 70): it lands 8pt short of it and bounces the rest of the way.
    public static let binDestination = Point(x: 70, y: 70)
    public static let binLandingOffsetX = -8.0
    /// From the pointer to where the arrow starts.
    public static let startOffset = Point(x: 15, y: -15)
    /// It keeps falling this long after it lands (Arc: 0.13333 s when the sidebar shows, none into the bin).
    public static let sinkDuration = 0.13333333333333333
    /// The arrow's size before scaling.
    public static let iconSize = 30.0
    /// The spring it bounces on in the bin (Arc's `iconBounceAnimator`).
    public static let binBounce = DampedSpring(dampingRatio: 0.48, response: 0.72)

    public let target: Target
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
    public init?(pointer: Point, windowHeight: Double, target: Target = .libraryButton) {
        // Arc falls back to (70, 70) when the pointer isn't a finite point.
        let pointer = pointer.x.isFinite && pointer.y.isFinite ? pointer : Point(x: 70, y: 70)
        let start = Point(x: pointer.x + Self.startOffset.x, y: pointer.y + Self.startOffset.y)
        let destination = switch target {
        case .libraryButton: Self.destination
        case .bin: Point(x: Self.binDestination.x + Self.binLandingOffsetX, y: Self.binDestination.y)
        }
        let vy = windowHeight == 0 ? 1600 : 1600 - 1100 * (start.y / windowHeight)
        // destination.y - start.y = vy·t - g/2·t², the later root (on the way down).
        let rise = destination.y - start.y
        let discriminant = vy * vy - 2 * Self.gravity * rise
        guard discriminant >= 0 else { return nil }
        let landing = (vy + discriminant.squareRoot()) / Self.gravity
        guard landing > 0 else { return nil }
        self.target = target
        self.start = start
        self.destination = destination
        launchSpeedY = vy
        landingTime = landing
        speedX = (destination.x - start.x) / landing
        apexTime = vy / Self.gravity
    }

    /// How long the throw keeps sampling past the landing.
    public var sink: Double { target == .bin ? 0 : Self.sinkDuration }

    /// The throw, sink included (the bin's bounce comes after it, see `frames`).
    public var duration: Double { landingTime + sink }

    public func position(at t: Double) -> Point {
        Point(x: start.x + speedX * t, y: start.y + launchSpeedY * t - Self.gravity / 2 * t * t)
    }

    /// Velocity at `t` (pt/s).
    public func velocity(at t: Double) -> Point {
        Point(x: speedX, y: launchSpeedY - Self.gravity * t)
    }

    /// Horizontal and vertical scale at `t`; never below 0.
    public func scale(at t: Double) -> (x: Double, y: Double) {
        if t < apexTime {
            let progress = apexTime == 0 ? 0 : t / apexTime
            return (0.8 + 0.8 * progress, 1.2 + 0.4 * progress)
        }
        // 1 at the top of the arc, 0 on landing, below 0 while it sinks.
        let left = landingTime == apexTime ? 1 : 1 - (t - apexTime) / (landingTime - apexTime)
        // Arc: 1.6 at the top to 0.3 on landing (Library button) or 0.7 (bin).
        let shrink = target == .bin ? 0.9 : 1.3
        let scale = max(0, 1.6 + shrink * (left - 1))
        return (scale, scale)
    }

    /// Arc's keyframes: one every 1/60 s from launch until the throw ends; into the bin, then the bounce
    /// from the landing point to (70, 70), one sample every 1/60 s until the spring settles, at the
    /// landing scale.
    public var frames: [Frame] {
        var frames: [Frame] = []
        var t = 0.0
        while t < duration {
            let scale = scale(at: t)
            frames.append(Frame(time: t, position: position(at: t), scaleX: scale.x, scaleY: scale.y))
            t += Self.frameInterval
        }
        guard target == .bin, let last = frames.last else { return frames }
        let landed = velocity(at: landingTime)
        let offset = Point(x: destination.x - Self.binDestination.x, y: destination.y - Self.binDestination.y)
        for (index, point) in Self.binBounce.samples(offset: offset, velocity: landed).enumerated() {
            frames.append(Frame(time: last.time + Double(index + 1) * Self.frameInterval,
                                position: Point(x: Self.binDestination.x + point.x, y: Self.binDestination.y + point.y),
                                scaleX: last.scaleX, scaleY: last.scaleY))
        }
        return frames
    }

    /// The whole animation, the bin's bounce included.
    public var totalDuration: Double {
        guard target == .bin, let last = frames.last else { return duration }
        return last.time + Self.frameInterval
    }
}

/// A damped spring by damping ratio and response (SwiftUI's convention: stiffness (2π / response)², damping
/// 4π × ratio / response, unit mass).
public struct DampedSpring: Equatable, Sendable {
    public var dampingRatio: Double
    public var response: Double

    public init(dampingRatio: Double, response: Double) {
        self.dampingRatio = dampingRatio
        self.response = response
    }

    public var stiffness: Double { pow(2 * .pi / response, 2) }
    public var damping: Double { 4 * .pi * dampingRatio / response }

    /// Displacement from the target and velocity at `t`, starting `x0` from it with velocity `v0`.
    public func state(at t: Double, x0: Double, v0: Double) -> (x: Double, v: Double) {
        let omega = 2 * .pi / response
        let zeta = dampingRatio
        if zeta < 1 {
            let wd = omega * (1 - zeta * zeta).squareRoot()
            let decay = exp(-zeta * omega * t)
            let b = (v0 + zeta * omega * x0) / wd
            let x = decay * (x0 * cos(wd * t) + b * sin(wd * t))
            let v = decay * ((b * wd - zeta * omega * x0) * cos(wd * t) - (x0 * wd + zeta * omega * b) * sin(wd * t))
            return (x, v)
        }
        // Critically damped (Kite's springs are all under-damped; this keeps any ratio ≥ 1 sensible).
        let decay = exp(-omega * t)
        let b = v0 + omega * x0
        return ((x0 + b * t) * decay, (b - omega * (x0 + b * t)) * decay)
    }

    /// Displacements every 1/60 s from `t = 0` until the spring is within 0.01pt of the target and slower
    /// than 0.1 pt/s on both axes (at most `limit` seconds).
    public func samples(offset: DownloadFlight.Point, velocity: DownloadFlight.Point,
                        limit: Double = 5) -> [DownloadFlight.Point] {
        var points: [DownloadFlight.Point] = []
        var t = 0.0
        while t <= limit {
            let x = state(at: t, x0: offset.x, v0: velocity.x)
            let y = state(at: t, x0: offset.y, v0: velocity.y)
            points.append(.init(x: x.x, y: y.x))
            if t > 0, abs(x.x) < 0.01, abs(y.x) < 0.01, abs(x.v) < 0.1, abs(y.v) < 0.1 { break }
            t += DownloadFlight.frameInterval
        }
        return points
    }
}

/// Arc's `DownloadsUI.DownloadToLibrary.DownloadBin`, where downloads fly while the sidebar is hidden
/// (Arc 1.169, decompiled; see docs/arc-visual-spec.md): a 46pt tile (62pt frame, 8pt padding) whose centre
/// sits 53pt above the window's bottom edge. It slides in from x -80 to 53 on a spring (damping 0.9,
/// response 0.82) as the first arrow is thrown, stays until 1 s after the last one lands, then slides back
/// to -80 on the same spring, the arrows in it riding along (-133pt).
public enum DownloadBin {
    /// The tile's centre, in window points from the bottom-left corner.
    public static let shownX = 53.0
    public static let hiddenX = -80.0
    public static let centerY = 53.0
    public static let frameSize = 62.0
    public static let padding = 8.0
    public static var tileSize: Double { frameSize - 2 * padding }
    public static let cornerRadius = 12.0
    public static let shadowRadius = 12.0
    /// Shadow colour: white at 0.15 in dark mode, black at 0.3 in light mode.
    public static func shadowOpacity(dark: Bool) -> Double { dark ? 0.15 : 0.3 }
    public static let slide = DampedSpring(dampingRatio: 0.9, response: 0.82)
    /// How long the bin stays after an arrow lands.
    public static let linger = 1.0
}

/// What Arc's `DownloadProgressBadge` does when its progress reaches 1 (Arc 1.169, decompiled
/// `FUN_1025d6a2c`): the arrow turns into a 9pt `checkmark` and the ring dims to 0.5 at once, the badge
/// dips to 0.9 (SwiftUI's default animation), springs back to 1 (response 0.5, no bounce) after 0.15 s,
/// swells to 1.03 (ease out 0.15 s) at 1.15 s, then shrinks to 0.97 and fades out (ease in 0.15 s) at 1.3 s.
public enum DownloadBadgeCompletion {
    public enum Curve: Equatable, Sendable {
        /// SwiftUI's `Animation.default`.
        case standard
        case easeOut(duration: Double)
        case easeIn(duration: Double)
        case spring(response: Double, dampingRatio: Double)
    }

    public struct Step: Equatable, Sendable {
        public var curve: Curve
        public var delay: Double
        public var scale: Double
        /// Nil leaves the opacity alone.
        public var opacity: Double?
    }

    public static let iconName = "checkmark"
    public static let iconSize = 9.0
    public static let ringOpacity = 0.5
    public static let steps: [Step] = [
        Step(curve: .standard, delay: 0, scale: 0.9, opacity: nil),
        Step(curve: .spring(response: 0.5, dampingRatio: 1), delay: 0.15, scale: 1, opacity: nil),
        Step(curve: .easeOut(duration: 0.15), delay: 1.15, scale: 1.03, opacity: nil),
        Step(curve: .easeIn(duration: 0.15), delay: 1.3, scale: 0.97, opacity: 0),
    ]
    /// When the badge has faded out: the last step's end.
    public static var duration: Double {
        steps.map { step in
            switch step.curve {
            case .easeOut(let duration), .easeIn(let duration): step.delay + duration
            case .standard, .spring: step.delay
            }
        }.max() ?? 0
    }
}
