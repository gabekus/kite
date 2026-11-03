#if canImport(Metal)
import Foundation
import Metal
import Testing
@testable import KiteCore

/// Kite.metal's theme backdrop against Tests/Fixtures/theme-backdrop.json, the values Kite for
/// Windows' CPU reference of this shader gives (windows/src/core/ThemeBackdrop.cpp, written out
/// by windows/tests/GenThemeGolden.cpp). Windows checks its HLSL port against that reference on
/// its own GPU, so this is the link that ties Kite for Windows' backdrop to the Mac's shader.
///
/// The shader is compiled from source with default options (fast math), like ShaderLibrary and
/// bundle-app.sh, and drawn into a 32-bit float target so small differences show. Fast math can
/// round the grain hash a little differently, so a few samples may be off; the averages may not.
@Suite struct ThemeShaderGoldenTests {
    struct Fixture: Decodable { let cases: [Case] }

    struct Case: Decodable {
        let name: String
        let from: FixtureTheme
        let to: FixtureTheme
        let progress: Float
        let size: [Int]
        let samples: [[Double]]  // x, y, r, g, b, a
    }

    struct FixtureTheme: Decodable {
        let colors: [[Float]]
        let grain: Float
        let tint: Float
        var theme: Theme { Theme(colors: colors.map { ThemeColor(r: $0[0], g: $0[1], b: $0[2]) }, grain: grain, tint: tint) }
    }

    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// ThemeView.draw(in:)'s uniforms, byte for byte (ThemeUniforms in Kite.metal, 176 bytes).
    static func uniforms(from: Theme, to: Theme, progress: Float, width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 176)
        func put<T>(_ value: T, at offset: Int) {
            withUnsafeBytes(of: value) { bytes.replaceSubrange(offset..<offset + $0.count, with: $0) }
        }
        // ThemeView's palette(_:): four slots, the last colour repeated.
        func palette(_ theme: Theme, at offset: Int) {
            let lab = theme.labColors
            for i in 0..<4 { put(SIMD4<Float>(lab[min(i, lab.count - 1)], 0), at: offset + 16 * i) }
        }
        palette(from, at: 0)
        palette(to, at: 64)
        put(SIMD2<Float>(Float(width), Float(height)), at: 128)
        put(from.grain, at: 136)
        put(to.grain, at: 140)
        put(progress, at: 144)
        put(UInt32(from.colors.count), at: 148)
        put(UInt32(to.colors.count), at: 152)
        put(from.tint, at: 156)
        put(to.tint, at: 160)
        return bytes
    }

    // Skipped only where there's no Metal device at all (some virtual Macs); every real Mac has one.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "no Metal device"))
    func kiteMetalMatchesTheWindowsReference() throws {
        let fixtureURL = Self.repository.appendingPathComponent("Tests/Fixtures/theme-backdrop.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        #expect(fixture.cases.count == 7)

        let device = try #require(MTLCreateSystemDefaultDevice(), "no Metal device")
        let queue = try #require(device.makeCommandQueue())
        let source = try String(contentsOf: Self.repository.appendingPathComponent("Sources/KiteMac/Shaders/Kite.metal"), encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: MTLCompileOptions())
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "kite_fullscreen_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "kite_theme_fragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba32Float
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        for c in fixture.cases {
            let width = c.size[0], height = c.size[1]
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
            textureDescriptor.usage = .renderTarget
            textureDescriptor.storageMode = .private
            let texture = try #require(device.makeTexture(descriptor: textureDescriptor))
            let rowBytes = width * 16
            let readBack = try #require(device.makeBuffer(length: rowBytes * height, options: .storageModeShared))

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            let commands = try #require(queue.makeCommandBuffer())
            let encoder = try #require(commands.makeRenderCommandEncoder(descriptor: pass))
            encoder.setRenderPipelineState(pipeline)
            let uniforms = Self.uniforms(from: c.from.theme, to: c.to.theme, progress: c.progress, width: width, height: height)
            uniforms.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            let blit = try #require(commands.makeBlitCommandEncoder())
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1), to: readBack, destinationOffset: 0,
                      destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * height)
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            let pixels = readBack.contents().bindMemory(to: Float.self, capacity: width * height * 4)

            // A sample is off when a channel differs by more than one 8-bit level (a grain hash
            // rounded the other way). The rest must agree closely, and on average not lean one
            // way: a wrong constant shifts every sample, the missing ±0.5/255 dither adds 0.001.
            var off = 0
            var absoluteSum = 0.0, counted = 0
            var signedSums = [0.0, 0.0, 0.0, 0.0]
            for sample in c.samples {
                let base = (Int(sample[1]) * width + Int(sample[0])) * 4
                let diffs = (0..<4).map { Double(pixels[base + $0]) - sample[2 + $0] }
                if diffs.contains(where: { !(abs($0) <= 1.0 / 255) }) {
                    off += 1
                    continue
                }
                for i in 0..<4 {
                    absoluteSum += abs(diffs[i])
                    signedSums[i] += diffs[i]
                }
                counted += 1
            }
            let offShare = Double(off) / Double(c.samples.count)
            let meanAbsolute = counted > 0 ? absoluteSum / Double(counted * 4) : .infinity
            let lean = signedSums.map { counted > 0 ? abs($0) / Double(counted) : .infinity }.max() ?? 0
            let report = "\(c.name): \(off)/\(c.samples.count) off, mean |diff| \(meanAbsolute), largest mean lean \(lean)"
            print("ThemeShaderGoldenTests: " + report)
            // First run (Apple GPU, 2026-11-03): no sample off, mean |diff| at most 1.6e-5, lean at
            // most 7.4e-6. The limits leave room for other GPUs and stay well under the dither's 1e-3.
            #expect(offShare <= 0.05, "\(report)")
            #expect(meanAbsolute <= 1e-4, "\(report)")
            #expect(lean <= 5e-5, "\(report)")
        }
    }
}
#endif
