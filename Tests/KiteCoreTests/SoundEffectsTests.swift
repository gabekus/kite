import Foundation
import Testing
@testable import KiteCore

@Suite struct SoundEffectsTests {
    @Test func onByDefaultLikeArc() {
        let defaults = UserDefaults(suiteName: "SoundEffectsTests-\(UUID())")!
        #expect(SoundEffects.isEnabled(in: defaults))
        defaults.set(false, forKey: SoundEffects.enabledKey)
        #expect(!SoundEffects.isEnabled(in: defaults))
    }

    @Test func captureIsArcsLengthAndNeverClips() {
        let samples = SoundEffects.samples(for: .capture)
        #expect(samples.count == Int(SoundEffects.captureDuration * Double(SoundEffects.sampleRate)))
        let peak = samples.map(abs).max() ?? 0
        #expect(abs(peak - 0.9) < 0.001)
        // Starts from silence (no pop) and has died away well before the end.
        #expect(samples[0] == 0)
        #expect(samples.suffix(SoundEffects.sampleRate / 10).allSatisfy { abs($0) < 0.001 })
    }

    @Test func sameSoundEveryTime() {
        #expect(SoundEffects.samples(for: .capture) == SoundEffects.samples(for: .capture))
    }

    @Test func wavHeaderDescribesSixteenBitMono() {
        let data = SoundEffects.wav(samples: [0, 1, -1], sampleRate: 48_000)
        #expect(data.count == 44 + 6)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<16], as: UTF8.self) == "WAVEfmt ")
        func u32(_ at: Int) -> UInt32 { data[at..<at + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        func u16(_ at: Int) -> UInt16 { UInt16(data[at + 1]) << 8 | UInt16(data[at]) }
        #expect(u32(4) == 36 + 6)
        #expect(u16(20) == 1 && u16(22) == 1)
        #expect(u32(24) == 48_000 && u16(34) == 16)
        #expect(u32(40) == 6)
        #expect(u16(46) == UInt16(bitPattern: Int16.max))
        #expect(u16(48) == UInt16(bitPattern: -Int16.max))
    }
}
