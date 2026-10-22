import Foundation
import Metal

/// Loads Kite's Metal library once and caches pipelines.
///
/// Release builds ship a precompiled `Kite.metallib` (see scripts/bundle-app.sh),
/// so launch never pays for shader compilation. `swift run` falls back to
/// compiling the source at startup.
@MainActor
final class ShaderLibrary {
    static let shared = ShaderLibrary()

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let library: MTLLibrary?
    private var pipelines: [String: MTLRenderPipelineState] = [:]

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Kite needs a Metal device")
        }
        self.device = device
        self.commandQueue = queue
        self.library = Self.loadLibrary(device)
    }

    func pipeline(fragment: String, pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        let key = "\(fragment)/\(pixelFormat.rawValue)"
        if let cached = pipelines[key] { return cached }
        guard let library else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "kite_fullscreen_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        do {
            let state = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelines[key] = state
            return state
        } catch {
            NSLog("Kite: pipeline \(fragment) failed: \(error)")
            return nil
        }
    }

    private static func loadLibrary(_ device: MTLDevice) -> MTLLibrary? {
        if let url = Bundle.main.url(forResource: "Kite", withExtension: "metallib"),
           let library = try? device.makeLibrary(URL: url) {
            return library
        }
        guard let source = shaderSource() else {
            NSLog("Kite: no shaders found")
            return nil
        }
        do {
            return try device.makeLibrary(source: source, options: MTLCompileOptions())
        } catch {
            NSLog("Kite: shader compile failed: \(error)")
            return nil
        }
    }

    private static func shaderSource() -> String? {
        // The .app copies sources to Resources/Shaders. Only fall back to the SwiftPM
        // bundle (which traps if missing) when that copy isn't there, i.e. `swift run`.
        let url = Bundle.main.url(forResource: "Kite", withExtension: "metal", subdirectory: "Shaders")
            ?? Bundle.module.url(forResource: "Kite", withExtension: "metal", subdirectory: "Shaders")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}
