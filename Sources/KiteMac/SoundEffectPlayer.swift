import AppKit
import KiteCore

/// Plays Kite's interface sounds (`SoundEffects`), like Arc's `SoundEffectClient`: one player per
/// effect, made once from the WAV that `SoundEffects` renders in code, at Arc's volume of 0.7.
/// Kite menu → Play Kite Sound Effects turns them off (Arc: "Play Arc sound effects").
///
/// Test runs (a `KITE_SUPPORT_PATH` profile) play at volume 0 and log each sound instead, so
/// automated testing never makes noise on the Mac it runs on.
@MainActor final class SoundEffectPlayer {
    static let shared = SoundEffectPlayer()

    private var sounds: [SoundEffect: NSSound] = [:]
    private let isTestRun = ProcessInfo.processInfo.environment["KITE_SUPPORT_PATH"] != nil

    func play(_ effect: SoundEffect) {
        guard SoundEffects.isEnabled() else { return }
        guard let sound = sound(for: effect) else { return }
        sound.volume = isTestRun ? 0 : SoundEffects.volume
        // A second capture right after the first starts the sound over.
        if sound.isPlaying { sound.stop() }
        sound.play()
        if isTestRun { NSLog("Kite: sound effect \(effect.rawValue) (test run, volume 0)") }
    }

    private func sound(for effect: SoundEffect) -> NSSound? {
        if let sound = sounds[effect] { return sound }
        guard let sound = NSSound(data: SoundEffects.wav(for: effect)) else {
            NSLog("Kite: couldn't make sound effect \(effect.rawValue)")
            return nil
        }
        sounds[effect] = sound
        return sound
    }
}
