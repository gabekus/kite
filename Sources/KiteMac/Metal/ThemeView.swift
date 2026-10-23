import KiteCore
import MetalKit
import QuartzCore

/// Must match `ThemeUniforms` in Kite.metal (176 bytes).
private struct ThemeUniforms {
    typealias Palette = (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    var fromLab: Palette
    var toLab: Palette
    var cutout: SIMD4<Float>
    var size: SIMD2<Float>
    var fromGrain: Float
    var toGrain: Float
    var progress: Float
    var fromCount: UInt32
    var toCount: UInt32
    var cutoutRadius: Float
}

private func palette(_ theme: Theme) -> ThemeUniforms.Palette {
    let lab = theme.labColors.map { SIMD4<Float>($0, 0) }
    func at(_ i: Int) -> SIMD4<Float> { lab[min(i, lab.count - 1)] }
    return (at(0), at(1), at(2), at(3))
}

/// The space's gradient backdrop behind the sidebar and web content.
///
/// It only draws when something changes (theme, size, cutout). The frame clock
/// runs only during the space-switch crossfade, at the screen's full refresh
/// rate, then stops again.
@MainActor
final class ThemeView: MTKView, MTKViewDelegate {
    var cutoutRect: CGRect = .zero {
        didSet { if cutoutRect != oldValue { needsDisplay = true } }
    }
    var cutoutCornerRadius: CGFloat = 10

    private var from: Theme
    private var to: Theme
    private var transitionStart: CFTimeInterval?
    private let transitionDuration: CFTimeInterval = 0.4
    private let commandQueue = ShaderLibrary.shared.commandQueue
    private lazy var pipeline = ShaderLibrary.shared.pipeline(fragment: "kite_theme_fragment", pixelFormat: colorPixelFormat)
    private lazy var clock = FrameClock(view: self) { [unowned self] in draw() }

    init(theme: Theme = Theme.presets[0]) {
        from = theme
        to = theme
        super.init(frame: .zero, device: ShaderLibrary.shared.device)
        assert(MemoryLayout<ThemeUniforms>.stride == 176)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        autoResizeDrawable = true
        delegate = self
        // On demand only; `clock` drives the crossfade.
        enableSetNeedsDisplay = true
        isPaused = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    func setTheme(_ theme: Theme, animated: Bool) {
        guard theme != to else { return }
        if animated {
            // Interrupted mid-fade: continue from whichever side was showing more.
            if let start = transitionStart, CACurrentMediaTime() - start < transitionDuration / 2 {
                to = from
            }
            from = to
            to = theme
            transitionStart = CACurrentMediaTime()
            clock.start()
        } else {
            from = theme
            to = theme
            transitionStart = nil
            clock.stop()
            needsDisplay = true
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsDisplay = true
    }

    func draw(in view: MTKView) {
        var progress: Float = 1
        if let start = transitionStart {
            let now = clock.targetTimestamp ?? CACurrentMediaTime()
            let t = max(now - start, 0) / transitionDuration
            if t >= 1 {
                transitionStart = nil
                from = to
                clock.stop()
            } else {
                progress = Float(t * t * (3 - 2 * t))
            }
        }

        guard let pipeline,
              let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let commands = commandQueue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        let scale = Float(bounds.width > 0 ? drawableSize.width / bounds.width : 1)
        var uniforms = ThemeUniforms(
            fromLab: palette(from),
            toLab: palette(to),
            cutout: SIMD4(Float(cutoutRect.minX), Float(cutoutRect.minY), Float(cutoutRect.width), Float(cutoutRect.height)) * scale,
            size: SIMD2(Float(drawableSize.width), Float(drawableSize.height)),
            fromGrain: from.grain,
            toGrain: to.grain,
            progress: progress,
            fromCount: UInt32(from.colors.count),
            toCount: UInt32(to.colors.count),
            cutoutRadius: Float(cutoutCornerRadius) * scale
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ThemeUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}
