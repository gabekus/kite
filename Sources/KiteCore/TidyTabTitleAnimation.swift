import Foundation

/// Arc's animation when Tidy Tab Titles lands a name (TabCellView.isAnimatingAiRename): nothing
/// shows while the model works; when the name arrives the title row hides and an
/// AnimatedGradientView wipes the old title out and the new one in, left to right, while a
/// SparksView emitter runs across the row. Numbers from Arc 1.171's disassembly; see
/// docs/arc-visual-spec.md → "Tidy Tab Titles: the rename animation".
public enum TidyTabTitleAnimation {
    /// AnimatedGradientView's defaults, which the tab cell keeps: 0.5 s, no delay, 70 pt fade.
    public static let duration: Double = 0.5
    public static let fadeWidth: Double = 70

    /// Both masks are linear gradients from (-1.5, 0.5) to (1.5, 0.5) in the title's unit
    /// space; `startPoint.x` animates to 1 and `endPoint.x` to 3 (linear, fill forwards).
    public static let startX: (from: Double, to: Double) = (-1.5, 1)
    public static let endX: (from: Double, to: Double) = (1.5, 3)

    /// The masks' colour stops for a title `width` points wide: [0, w/(2w+f), (w+f)/(2w+f), 1].
    /// The new title's mask is opaque, opaque, clear, clear; the old title's the reverse.
    public static func stops(width: Double) -> [Double] {
        let w = max(width, 1), span = 2 * w + fadeWidth
        return [0, w / span, (w + fadeWidth) / span, 1]
    }

    /// The gradient's start and end x at `progress` (0…1, clamped).
    public static func gradientX(progress: Double) -> (start: Double, end: Double) {
        let p = min(max(progress, 0), 1)
        return (startX.from + (startX.to - startX.from) * p, endX.from + (endX.to - endX.from) * p)
    }

    /// How opaque the new title is at `x` (0…1 across the title) and `progress`; the old title
    /// is the rest (1 − this). The same CAGradientLayer maths, padded past both ends.
    public static func newTitleOpacity(at x: Double, progress: Double, width: Double) -> Double {
        let (start, end) = gradientX(progress: progress)
        let t = (x - start) / (end - start)
        let s = stops(width: width)
        if t <= s[1] { return 1 }
        if t >= s[2] { return 0 }
        return 1 - (t - s[1]) / (s[2] - s[1])
    }

    // MARK: Sparks (SparksView, a CAEmitterLayer over the whole tab cell)

    /// The emitter runs from the row's left edge to its right edge over `duration` (the
    /// gradient's), linear, at the row's mid-height; then births stop (fadeout 0 for a tab cell)
    /// and the last particles live out their lifetime.
    public static let sparkLifetime: Double = 1
    public static let sparkVelocity: Double = 100
    public static let sparkVelocityRange: Double = 30
    /// Points per second², downward (Arc's yAcceleration −200 in a y-up layer).
    public static let sparkGravity: Double = 200
    public static let sparkScale: Double = 0.09
    public static let sparkScaleRange: Double = 0.05
    public static let sparkScaleSpeed: Double = -0.2
    public static let sparkAlphaSpeed: Double = -1
    /// Arc's spark image ("Spark" in Assets.car) is 18 pt, 36 px at 2x. An emitter cell scales
    /// its image's pixels (contentsScale 1), so a spark starts about 36 × 0.09 ≈ 3 pt across
    /// (which rendition Arc's CGImage picks is unverified).
    public static let sparkImagePixels: Double = 36

    /// Particles per second: 75 × the row's width over the title's.
    public static func sparkBirthRate(rowWidth: Double, titleWidth: Double) -> Double {
        75 * rowWidth / max(titleWidth, 1)
    }

    /// When the whole thing is over: the wipe, then the last sparks' lifetime.
    public static let totalDuration: Double = duration + sparkLifetime

    /// One spark, worked out from its birth: position relative to the emitter's track and its
    /// look at `age` seconds. `seed` values are 0…1 random numbers fixed per spark.
    public struct Spark: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var size: Double
        public var opacity: Double
    }

    /// Spark `index` of a row `rowWidth` × `rowHeight` at time `time` since the wipe began, or
    /// nil when it isn't born yet or has died. y grows downward.
    public static func spark(index: Int, time: Double, rowWidth: Double, rowHeight: Double, titleWidth: Double) -> Spark? {
        let rate = sparkBirthRate(rowWidth: rowWidth, titleWidth: titleWidth)
        let birth = Double(index) / rate
        guard birth < duration else { return nil }
        let age = time - birth
        guard age >= 0, age < sparkLifetime else { return nil }
        var rng = SplitMix(seed: UInt64(index) &* 0x9E37_79B9_7F4A_7C15 &+ 1)
        // Emitted from inside a circle a quarter of the row's height across (Arc: circle shape,
        // emitterSize h/2, so radius h/4), centred on the emitter.
        let r = rowHeight / 4 * rng.next().squareRoot(), a = 2 * Double.pi * rng.next()
        let speed = sparkVelocity + sparkVelocityRange * (2 * rng.next() - 1)
        let direction = 2 * Double.pi * rng.next()
        let scale = sparkScale + sparkScaleRange * (2 * rng.next() - 1)
        let originX = rowWidth * birth / duration + r * cos(a)
        let originY = rowHeight / 2 + r * sin(a)
        let size = max(0, scale + sparkScaleSpeed * age) * sparkImagePixels
        let opacity = max(0, 1 + sparkAlphaSpeed * age)
        guard size > 0, opacity > 0 else { return nil }
        return Spark(
            x: originX + speed * cos(direction) * age,
            y: originY + speed * sin(direction) * age + sparkGravity * age * age / 2,
            size: size,
            opacity: opacity)
    }

    /// How many sparks a row can have in all.
    public static func sparkCount(rowWidth: Double, titleWidth: Double) -> Int {
        Int((sparkBirthRate(rowWidth: rowWidth, titleWidth: titleWidth) * duration).rounded(.up))
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
    }
}
