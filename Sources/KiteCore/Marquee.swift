import Foundation

/// The Mini Player's scrolling title (Arc's `ARCUI.MarqueeText`, which `MiniPlayerView` uses
/// when `miniPlayerMarqueeTitleEnabled`). A title that doesn't fit waits, then scrolls left
/// forever as two copies a gap apart, with soft edges. Numbers are from Arc 1.171's binary; see
/// docs/arc-visual-spec.md ("Mini Player marquee title").
public enum Marquee {
    /// Arc's MiniPlayerView builds `MarqueeText(title, leadingFade: 4, trailingFade: 8,
    /// gap: 32, delay: 3, speed: 1)` (constants at `0x1024924b4`–`0x1024924cc`).
    public static let leadingFade: Double = 4
    public static let trailingFade: Double = 8
    /// Space between the end of one copy and the start of the next.
    public static let gap: Double = 32
    /// Seconds the title rests before it starts to move (`onAppear` sets `startAt = now + 3`, and
    /// while the title fits, each frame pushes `startAt` to `now + 3` again).
    public static let startDelay: Double = 3
    public static let speed: Double = 1
    /// At speed 1 one full loop (title width + gap) takes this long, whatever the title's length:
    /// the draw closure computes `fmod(cycle * elapsed * speed / 20, cycle)` (`0x100a9f35c`).
    public static let secondsPerLoop: Double = 20

    /// Whether a title this wide scrolls in a frame this wide. Arc compares the title's
    /// unconstrained width with the frame (the canvas less both fades).
    public static func overflows(textWidth: Double, availableWidth: Double) -> Bool {
        availableWidth < textWidth
    }

    /// How far left the first copy has moved, `elapsed` seconds after the title started
    /// moving (negative elapsed, during the start delay, is 0). The second copy sits
    /// `textWidth + gap` to the right of the first. Always 0 for a title that fits.
    public static func offset(textWidth: Double, availableWidth: Double, elapsed: Double,
                              speed: Double = speed, gap: Double = gap) -> Double {
        guard overflows(textWidth: textWidth, availableWidth: availableWidth) else { return 0 }
        let cycle = textWidth + gap
        guard cycle > 0 else { return 0 }
        let progress = cycle * (max(0, elapsed) / secondsPerLoop) * speed
        return progress.truncatingRemainder(dividingBy: cycle)
    }

    /// The points per second a title of this width scrolls at.
    public static func pointsPerSecond(textWidth: Double, speed: Double = speed, gap: Double = gap) -> Double {
        (textWidth + gap) * speed / secondsPerLoop
    }
}
