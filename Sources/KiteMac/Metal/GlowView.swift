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
@MainActor
final class GlowView: MTKView, MTKViewDelegate {
    /// How far the glow reaches past the content edge, in points.
    let margin: CGFloat
    var cornerRadius: CGFloat = 10

    private var primary = SIMD4<Float>(1, 1, 1, 1)
    private var secondary = SIMD4<Float>(1, 1, 1, 1)
    private var isLoading = false
    private var progress: Float = 0
    private var intensity: Float = 0
    private var lastFrame: CFTimeInterval = 0
    private let startTime = CACurrentMediaTime()
    private let commandQueue = ShaderLibrary.shared.commandQueue
    private lazy var pipeline = ShaderLibrary.shared.pipeline(fragment: "kite_glow_fragment", pixelFormat: colorPixelFormat)
    private lazy var clock = FrameClock(view: self) { [unowned self] in draw() }

    init(margin: CGFloat) {
        self.margin = margin
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
        isHidden = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setTheme(_ theme: Theme) {
        let (a, b) = theme.glowColors
        primary = SIMD4(a.r, a.g, a.b, 1)
        secondary = SIMD4(b.r, b.g, b.b, 1)
    }

    func setLoading(_ loading: Bool, progress: Double) {
        isLoading = loading
        self.progress = Float(progress)
        if loading && !clock.isRunning {
            lastFrame = CACurrentMediaTime()
            isHidden = false
            clock.start()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = clock.targetTimestamp ?? CACurrentMediaTime()
        let dt = Float(min(now - lastFrame, 0.1))
        lastFrame = now
        intensity += (isLoading ? 4 : -2.5) * dt
        intensity = min(max(intensity, 0), 1)
        if !isLoading && intensity == 0 {
            clock.stop()
            isHidden = true
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
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}
