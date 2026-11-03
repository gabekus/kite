import KiteCore
import MetalKit
import QuartzCore

/// Must match `ThemeUniforms` in Kite.metal (176 bytes). ThemeShaderGoldenTests builds the
/// same bytes the same way (uniforms(size:progress:)); change both together.
private struct ThemeUniforms {
    typealias Palette = (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    var fromLab: Palette
    var toLab: Palette
    var size: SIMD2<Float>
    var fromGrain: Float
    var toGrain: Float
    var progress: Float
    var fromCount: UInt32
    var toCount: UInt32
    var fromTint: Float
    var toTint: Float
}

private func palette(_ theme: Theme) -> ThemeUniforms.Palette {
    let lab = theme.labColors.map { SIMD4<Float>($0, 0) }
    func at(_ i: Int) -> SIMD4<Float> { lab[min(i, lab.count - 1)] }
    return (at(0), at(1), at(2), at(3))
}

/// The space's gradient backdrop behind the sidebar and web content.
///
/// It draws under the whole window, page card included: drawing around the card instead left
/// the old card's outline as untinted material whenever a redraw after a sidebar resize was missed.
/// It only draws when something changes (theme, size). The frame clock runs
/// only during the space-switch crossfade, at the screen's full refresh rate, then
/// stops again.
@MainActor
final class ThemeView: MTKView, MTKViewDelegate {
    private var from: Theme
    private var to: Theme
    private var transitionStart: CFTimeInterval?
    /// Where a transition starts from: 0 for a switch, the swipe's progress when a swipe is let go.
    private var startProgress: Float = 0
    /// Set while fingers are swiping between spaces: the crossfade follows them instead of the clock.
    private var interactiveProgress: Float?
    /// Long enough for Arc's space-switch spring to settle within half a percent.
    private let transitionDuration: CFTimeInterval = 0.3
    private let commandQueue = ShaderLibrary.shared.commandQueue
    private lazy var pipeline = ShaderLibrary.shared.pipeline(fragment: "kite_theme_fragment", pixelFormat: colorPixelFormat)
    private lazy var clock = FrameClock(view: self) { [unowned self] in draw() }

    init(theme: Theme = Theme.presets[0]) {
        from = theme
        to = theme
        super.init(frame: .zero, device: ShaderLibrary.shared.device)
        assert(MemoryLayout<ThemeUniforms>.stride == 176)
        colorPixelFormat = .bgra8Unorm
        // The tint is translucent: the window's material shows through it.
        layer?.isOpaque = false
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        framebufferOnly = true
        autoResizeDrawable = true
        delegate = self
        // On demand only; `clock` drives the crossfade.
        enableSetNeedsDisplay = true
        isPaused = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    private var occlusionObserver: NSObjectProtocol?

    /// A covered window's display link stops, so a crossfade started while it was covered stays on its
    /// first frame: uncovered, the window would show the old space's colours until something redrew it,
    /// and the next space swipe would then jump from them. Catch up as soon as it's on screen again.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        guard let window else { return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowVisibilityChanged() }
        }
    }

    private func windowVisibilityChanged() {
        guard window?.occlusionState.contains(.visible) == true else { return }
        if transitionStart != nil {
            clock.stop()
            clock.start()
        }
        needsDisplay = true
    }

    func setTheme(_ theme: Theme, animated: Bool) {
        guard interactiveProgress == nil else { return }
        guard theme != to else { return }
        startProgress = 0
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

    /// Mid-swipe: shows `from` crossfaded towards `to` by `progress`, held until the swipe moves again.
    func setInteractiveTheme(from: Theme, to: Theme, progress: Float) {
        self.from = from
        self.to = to
        interactiveProgress = min(max(progress, 0), 1)
        transitionStart = nil
        needsDisplay = true
    }

    /// The swipe was let go: settles on `theme`, which is either side of the crossfade, with the
    /// space-switch spring from wherever the fingers left it.
    func finishInteractiveTheme(landingOn theme: Theme) {
        let p = interactiveProgress ?? 1
        interactiveProgress = nil
        if theme == to {
            startProgress = p
        } else {
            // Back where it started: the same mix, read from the other end.
            swap(&from, &to)
            startProgress = 1 - p
        }
        transitionStart = CACurrentMediaTime()
        clock.start()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsDisplay = true
    }

    /// Step response of SwiftUI's `spring(response:dampingFraction:)` with Arc's space-switch values.
    private static func spring(_ t: CFTimeInterval) -> Double {
        let zeta = ArcMetrics.Motion.spaceSwitchDamping
        let omega = 2 * Double.pi / ArcMetrics.Motion.spaceSwitchResponse
        let omegaD = omega * (1 - zeta * zeta).squareRoot()
        return 1 - exp(-zeta * omega * t) * (cos(omegaD * t) + zeta * omega / omegaD * sin(omegaD * t))
    }

    func draw(in view: MTKView) {
        var progress: Float = interactiveProgress ?? 1
        if let start = transitionStart {
            let now = clock.targetTimestamp ?? CACurrentMediaTime()
            let elapsed = max(now - start, 0)
            if elapsed >= transitionDuration {
                transitionStart = nil
                from = to
            } else {
                progress = startProgress + (1 - startProgress) * Float(min(Self.spring(elapsed), 1))
            }
        }

        if transitionStart == nil { clock.stop() }

        guard pipeline != nil,
              let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let commands = commandQueue.makeCommandBuffer()
        else { return }
        let uniforms = uniforms(size: drawableSize, progress: progress)
        guard encode(into: pass, uniforms: uniforms, commands: commands) else { return }
        commands.present(drawable)
        commands.commit()
        lastDrawn = uniforms
    }

    /// What the last frame drew, for `snapshot`.
    private var lastDrawn: ThemeUniforms?

    private func uniforms(size: CGSize, progress: Float) -> ThemeUniforms {
        ThemeUniforms(
            fromLab: palette(from),
            toLab: palette(to),
            size: SIMD2(Float(size.width), Float(size.height)),
            fromGrain: from.grain,
            toGrain: to.grain,
            progress: progress,
            fromCount: UInt32(from.colors.count),
            toCount: UInt32(to.colors.count),
            fromTint: from.tint,
            toTint: to.tint
        )
    }

    private func encode(into pass: MTLRenderPassDescriptor, uniforms: ThemeUniforms, commands: MTLCommandBuffer) -> Bool {
        guard let pipeline, let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ThemeUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    /// The theme as the last frame drew it, rendered again off screen (`ui capture`'s in-process path: a Metal
    /// layer's drawable can't be read back, and drawing the view's layer leaves it blank). Premultiplied BGRA.
    func snapshot() -> CGImage? {
        let size = drawableSize
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0, let device else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: colorPixelFormat, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor), let commands = commandQueue.makeCommandBuffer() else {
            return nil
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = clearColor
        pass.colorAttachments[0].storeAction = .store
        // Exactly the last frame on screen (a covered window's crossfade can stand still part way); before any frame, the
        // theme as it rests.
        guard encode(into: pass, uniforms: lastDrawn ?? uniforms(size: size, progress: 1), commands: commands) else { return nil }
        commands.commit()
        commands.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let space = (layer as? CAMetalLayer)?.colorspace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
