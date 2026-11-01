import Foundation

/// Arc's interface sounds (its `SoundEffects` module). Arc has one effect, `capture`, played
/// from its Capture tool; Kite's sound for it is its own, made here from code (no recorded or
/// copied audio). Sources and numbers are in docs/arc-visual-spec.md, "Sound effects".
public enum SoundEffect: String, CaseIterable, Sendable {
    /// Taking a capture of the page. Arc: `sound(forEffect:)` loads only "capture" (a WAV).
    case capture
}

public enum SoundEffects {
    /// Settings key. Arc's is `playUserInterfaceSoundsDisabled` ("Play Arc sound effects"),
    /// unset (sounds on) by default and unset in Gabe's Arc, so Kite's is on until turned off.
    public static let enabledKey = "soundEffectsEnabled"

    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Arc sets the player's volume to 0.7 before playing (`fmov s0` 0x3f333333 at 0x101cb81b4).
    public static let volume: Float = 0.7

    public static let sampleRate = 48_000

    /// Length of Arc's capture.wav (afinfo: 0.634 s). Kite's sound fits in the same length.
    public static let captureDuration = 0.634

    /// Mono samples in -1...1 for an effect.
    public static func samples(for effect: SoundEffect) -> [Float] {
        switch effect {
        case .capture: return shutter()
        }
    }

    /// The effect as a 16-bit mono PCM WAV file.
    public static func wav(for effect: SoundEffect) -> Data {
        wav(samples: samples(for: effect), sampleRate: sampleRate)
    }

    /// A camera shutter: two short clicks (the shutter opening, then closing 70 ms later),
    /// each a burst of high-passed noise with a fast exponential decay over a low body thump.
    /// Noise comes from a fixed-seed generator, so every build makes the same sound.
    static func shutter() -> [Float] {
        let count = Int(captureDuration * Double(sampleRate))
        var out = [Float](repeating: 0, count: count)
        var seed: UInt32 = 0x4B49_5445 // "KITE"
        func noise() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(seed >> 8) / Float(1 << 23) - 1
        }
        let clicks: [(start: Double, gain: Float, decay: Double, body: Double)] = [
            (0.000, 1.00, 0.006, 210),
            (0.070, 0.75, 0.009, 160),
        ]
        for click in clicks {
            let start = Int(click.start * Double(sampleRate))
            var previousNoise: Float = 0
            var highPassed: Float = 0
            for i in start..<count {
                let t = Double(i - start) / Double(sampleRate)
                let envelope = Float(exp(-t / click.decay))
                let bodyEnvelope = Float(exp(-t / (click.decay * 3)))
                if envelope < 0.0005, bodyEnvelope < 0.0005 { break }
                // One-pole high-pass keeps the noise crisp, without low rumble.
                let n = noise()
                highPassed = 0.85 * (highPassed + n - previousNoise)
                previousNoise = n
                let body = Float(sin(2 * Double.pi * click.body * t))
                out[i] += click.gain * (0.8 * envelope * highPassed + 0.5 * bodyEnvelope * body)
            }
        }
        // Short fade-in so the first click doesn't pop, then normalise to a 0.9 peak.
        let fade = sampleRate / 2000
        for i in 0..<min(fade, count) { out[i] *= Float(i) / Float(fade) }
        let peak = out.map(abs).max() ?? 0
        if peak > 0 { out = out.map { $0 * 0.9 / peak } }
        return out
    }

    /// A RIFF/WAVE file: 16-bit signed little-endian PCM, one channel.
    public static func wav(samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)) // PCM
        append(UInt16(1)) // channels
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2)) // byte rate
        append(UInt16(2)) // block align
        append(UInt16(16)) // bits per sample
        data.append(contentsOf: Array("data".utf8)); append(bytes)
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }
        return data
    }
}
