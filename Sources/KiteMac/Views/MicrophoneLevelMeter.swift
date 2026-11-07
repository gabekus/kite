import AppKit
import AVFoundation

/// The live input level of the Mac's default microphone, as a few small bars: Site Controls shows it in an allowed
/// Microphone row so you can talk and see the mic Kite will hand the site is the one picking you up.
///
/// It listens only while it's in a window (the popover is open), and only when macOS already lets Kite use the
/// microphone: opening Site Controls never asks for access. Chromium gives a site the system default input unless
/// the site picks another, so that's the device it meters.
final class MicrophoneLevelMeter: NSView {
    static let barCount = 5
    static let size = CGSize(width: 5 * 3 + 4 * 2, height: 14)

    private var bars: [CALayer] = []
    private var capture: MicrophoneLevelCapture?
    /// 0…1, smoothed: quick to rise, slower to fall, like a VU meter.
    private var level: Float = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<Self.barCount {
            let bar = CALayer()
            bar.cornerRadius = 1
            bar.cornerCurve = .circular
            layer?.addSublayer(bar)
            bars.append(bar)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel("Microphone input level")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { start() } else { stop() }
    }

    override func layout() {
        super.layout()
        draw()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        draw()
    }

    private func start() {
        guard capture == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        capture = MicrophoneLevelCapture { [weak self] power in
            self?.show(power)
        }
    }

    private func stop() {
        capture?.stop()
        capture = nil
        level = 0
        draw()
    }

    private func show(_ power: Float) {
        level = power > level ? power : max(power, level - 0.06)
        setAccessibilityValue(Int((level * 100).rounded()))
        draw()
    }

    private func draw() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let unlit = (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.15).cgColor
        var lit = NSColor.controlAccentColor.cgColor
        // The accent colour resolves against the appearance it's read in.
        effectiveAppearance.performAsCurrentDrawingAppearance { lit = NSColor.controlAccentColor.cgColor }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width: CGFloat = 3, gap: CGFloat = 2
        let heights: [CGFloat] = [0.35, 0.55, 0.75, 0.9, 1].map { $0 * bounds.height }
        for (index, bar) in bars.enumerated() {
            let height = heights[index % heights.count]
            bar.frame = CGRect(x: CGFloat(index) * (width + gap), y: bounds.height - height, width: width, height: height)
            let threshold = Float(index) / Float(Self.barCount) + 0.02
            bar.backgroundColor = level > threshold ? lit : unlit
        }
        CATransaction.commit()
    }
}

/// The default microphone's level, read off an `AVCaptureSession` on a queue of its own.
private final class MicrophoneLevelCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "dev.gabek.Kite.microphone-level")
    private let onLevel: @MainActor (Float) -> Void
    private var lastSent = DispatchTime(uptimeNanoseconds: 0)

    init(onLevel: @escaping @MainActor (Float) -> Void) {
        self.onLevel = onLevel
        super.init()
        queue.async { [self] in configureAndStart() }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configureAndStart() {
        guard let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.beginConfiguration()
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        session.startRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // About 30 updates a second is plenty for a meter.
        let now = DispatchTime.now()
        guard now.uptimeNanoseconds - lastSent.uptimeNanoseconds > 33_000_000,
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer, length >= 4 else { return }
        let count = length / MemoryLayout<Float>.size
        var sum: Float = 0
        pointer.withMemoryRebound(to: Float.self, capacity: count) { samples in
            for i in 0..<count { sum += samples[i] * samples[i] }
        }
        let rms = (sum / Float(count)).squareRoot()
        let level = Self.normalized(decibels: 20 * log10(max(rms, 1e-7)))
        lastSent = now
        let onLevel = onLevel
        DispatchQueue.main.async { MainActor.assumeIsolated { onLevel(level) } }
    }

    /// -55 dBFS (room quiet) to -10 dBFS (talking close up) as 0…1.
    static func normalized(decibels: Float) -> Float {
        min(1, max(0, (decibels + 55) / 45))
    }
}
