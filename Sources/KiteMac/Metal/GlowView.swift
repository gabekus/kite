import KiteCore
import MetalKit
import QuartzCore

/// Must match `GlowUniforms` in Kite.metal (80 bytes with padding).
private struct GlowUniforms {
    var rect: SIMD4<Float>
    var primary: SIMD4<Float>
    var secondary: SIMD4<Float>
    var size: SIMD2<Float>
    var radius: Float
    var time: Float
    var progress: Float
    var intensity: Float
}

/// The glow that runs around the web content while a page loads.
///
/// It's a transparent overlay that ignores clicks, and it only exists while
/// it's visible: when loading ends it fades out, then stops its frame clock and
/// hides so it costs nothing at rest. While it runs it draws at the screen's full
/// refresh rate.
///
/// A `GlowSurface` made when loading starts does the drawing. Its drawables are the
/// page card plus margins (14.5 MB each for a 1030×804 pt card on Retina), and a
/// Metal layer keeps several for as long as it lives, hidden or not; so the surface
/// goes `surfaceLinger` after the glow has faded out, and a later load makes another.
@MainActor
final class GlowView: NSView {
    /// How far the glow reaches past the content edge, in points.
    let margin: CGFloat
    var cornerRadius: CGFloat = 10 {
        didSet { surface?.cornerRadius = cornerRadius }
    }
    /// Long enough that the loads of one visit (a redirect, the next click) reuse the surface.
    static let surfaceLinger: TimeInterval = 10

    private var primary = SIMD4<Float>(1, 1, 1, 1)
    private var secondary = SIMD4<Float>(1, 1, 1, 1)
    /// The colour waves' clock, kept across surfaces so each carries on where the last one was.
    private let startTime = CACurrentMediaTime()
    private var surface: GlowSurface?
    private var dropSurface: DispatchWorkItem?

    init(margin: CGFloat) {
        self.margin = margin
        super.init(frame: .zero)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setTheme(_ theme: Theme) {
        let (a, b) = theme.glowColors
        primary = SIMD4(a.r, a.g, a.b, 1)
        secondary = SIMD4(b.r, b.g, b.b, 1)
        surface?.setColors(primary, secondary)
    }

    func setLoading(_ loading: Bool, progress: Double) {
        if loading {
            dropSurface?.cancel()
            dropSurface = nil
            if surface == nil { makeSurface() }
            isHidden = false
        }
        surface?.setLoading(loading, progress: progress)
    }

    private func makeSurface() {
        let surface = GlowSurface(margin: margin, startTime: startTime)
        surface.cornerRadius = cornerRadius
        surface.setColors(primary, secondary)
        surface.frame = bounds
        surface.autoresizingMask = [.width, .height]
        surface.onRest = { [weak self] in self?.surfaceRested() }
        addSubview(surface)
        self.surface = surface
    }

    private func surfaceRested() {
        isHidden = true
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.surface?.removeFromSuperview()
            self.surface = nil
            self.dropSurface = nil
        }
        dropSurface = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.surfaceLinger, execute: work)
    }
}

/// The Metal view that draws `GlowView`'s glow, from the first frame of a load to the end of its fade.
@MainActor
final class GlowSurface: MTKView, MTKViewDelegate {
    let margin: CGFloat
    var cornerRadius: CGFloat = 10
    /// The glow has faded out and the clock has stopped.
    var onRest: (() -> Void)?

    private var primary = SIMD4<Float>(1, 1, 1, 1)
    private var secondary = SIMD4<Float>(1, 1, 1, 1)
    private var isLoading = false
    private var progress: Float = 0
    private var intensity: Float = 0
    private var lastFrame: CFTimeInterval = 0
    private let startTime: CFTimeInterval
    private let commandQueue = ShaderLibrary.shared.commandQueue
    private lazy var pipeline = ShaderLibrary.shared.pipeline(fragment: "kite_glow_fragment", pixelFormat: colorPixelFormat)
    private lazy var clock = FrameClock(view: self) { [unowned self] in draw() }

    init(margin: CGFloat, startTime: CFTimeInterval) {
        self.margin = margin
        self.startTime = startTime
        super.init(frame: .zero, device: ShaderLibrary.shared.device)
        assert(MemoryLayout<GlowUniforms>.stride == 80)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        layer?.isOpaque = false
        delegate = self
        // MTKView's own timer stays off; `clock` drives frames.
        enableSetNeedsDisplay = false
        isPaused = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setColors(_ primary: SIMD4<Float>, _ secondary: SIMD4<Float>) {
        self.primary = primary
        self.secondary = secondary
    }

    func setLoading(_ loading: Bool, progress: Double) {
        isLoading = loading
        self.progress = Float(progress)
        if loading && !clock.isRunning {
            lastFrame = CACurrentMediaTime()
            clock.start()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Pixels further than this inside the content edge come out 0 anyway: there the glow's
    /// rim + bloom is at most 1.2 · (e^−12.8 + 0.2 · e^−8) ≈ 8e−5, under half an 8-bit step.
    static let zeroDepth: Float = 16

    /// The band the glow can reach, as scissor rects in drawable pixels: everything but a box `inset` in
    /// from each side. Inside that box the rounded-rect distance is at most −`zeroDepth` (the corner radius
    /// is part of `inset`), so the pass's clear already holds the right pixels and shading them is skipped:
    /// most of the page area. A drawable too small for a box gets one full rect.
    static func strips(size: CGSize, inset: Float) -> [MTLScissorRect] {
        let width = Int(size.width), height = Int(size.height)
        let x0 = Int(inset.rounded(.up)), y0 = x0
        let x1 = width - x0, y1 = height - y0
        guard x1 > x0, y1 > y0 else { return [MTLScissorRect(x: 0, y: 0, width: width, height: height)] }
        return [
            MTLScissorRect(x: 0, y: 0, width: width, height: y0),
            MTLScissorRect(x: 0, y: y1, width: width, height: height - y1),
            MTLScissorRect(x: 0, y: y0, width: x0, height: y1 - y0),
            MTLScissorRect(x: x1, y: y0, width: width - x1, height: y1 - y0),
        ]
    }

    func draw(in view: MTKView) {
        let now = clock.targetTimestamp ?? CACurrentMediaTime()
        let dt = Float(min(now - lastFrame, 0.1))
        lastFrame = now
        intensity += (isLoading ? 4 : -2.5) * dt
        intensity = min(max(intensity, 0), 1)
        if !isLoading && intensity == 0 {
            clock.stop()
            onRest?()
            return
        }

        guard let pipeline,
              let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let commands = commandQueue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        let scale = Float(bounds.width > 0 ? drawableSize.width / bounds.width : 1)
        let m = Float(margin) * scale
        var uniforms = GlowUniforms(
            rect: SIMD4(m, m, Float(drawableSize.width) - 2 * m, Float(drawableSize.height) - 2 * m),
            primary: primary,
            secondary: secondary,
            size: SIMD2(Float(drawableSize.width), Float(drawableSize.height)),
            radius: Float(cornerRadius) * scale,
            time: Float(now - startTime),
            progress: progress,
            intensity: intensity
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GlowUniforms>.stride, index: 0)
        for strip in Self.strips(size: drawableSize, inset: m + Self.zeroDepth + uniforms.radius) {
            encoder.setScissorRect(strip)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}
