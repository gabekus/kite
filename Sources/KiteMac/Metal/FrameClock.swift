import AppKit
import QuartzCore

/// Calls `tick` once per refresh of the screen the view is on, and only while running.
///
/// It asks for the screen's full rate: 120Hz on ProMotion, whatever an external
/// panel supports (240Hz, 500Hz), 60Hz on a 60Hz display. The view's display link
/// retargets by itself when the window moves to another screen; the rate request
/// is refreshed on every tick so it follows too. Stopped, it costs nothing.
@MainActor
final class FrameClock: NSObject {
    /// When the frame being drawn will reach the screen; nil while stopped.
    private(set) var targetTimestamp: CFTimeInterval?
    var isRunning: Bool { link != nil }

    private weak var view: NSView?
    private let tick: @MainActor () -> Void
    private var link: CADisplayLink?
    private var requestedRate = 0

    init(view: NSView, tick: @escaping @MainActor () -> Void) {
        self.view = view
        self.tick = tick
    }

    func start() {
        guard link == nil, let view else { return }
        let link = view.displayLink(target: self, selector: #selector(step))
        requestedRate = 0
        updateRate(link)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        targetTimestamp = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard view != nil else { return stop() }
        updateRate(link)
        targetTimestamp = link.targetTimestamp
        tick()
    }

    private func updateRate(_ link: CADisplayLink) {
        let rate = Self.maximumRate(of: view?.window?.screen)
        guard rate != requestedRate else { return }
        requestedRate = rate
        let max = Float(rate)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, max), maximum: max, preferred: max)
    }

    /// The screen's top refresh rate, as set in System Settings (a ProMotion
    /// display pinned to 60Hz reports 60).
    static func maximumRate(of screen: NSScreen?) -> Int {
        let rate = (screen ?? NSScreen.main)?.maximumFramesPerSecond ?? 60
        return rate > 0 ? rate : 60
    }
}
