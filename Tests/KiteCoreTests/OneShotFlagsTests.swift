import Foundation
import Testing
@testable import KiteCore

struct OneShotFlagsTests {
    private func scratchDefaults() -> (UserDefaults, String) {
        let suite = "OneShotFlagsTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func scratchFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OneShotFlagsTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func aRealProfileKeepsItsFlagsInUserDefaults() {
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let flags = OneShotFlags(defaults: defaults, environment: [:])
        #expect(!flags.bool(forKey: "asked"))
        flags.set(true, forKey: "asked")
        #expect(flags.bool(forKey: "asked"))
        #expect(defaults.bool(forKey: "asked"))
    }

    @Test func aTestProfileKeepsThemInItsFolderAndLeavesUserDefaultsAlone() {
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        // What an earlier run left in the shared bundle's defaults doesn't reach a new test profile.
        defaults.set(true, forKey: "asked")
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let flags = OneShotFlags(defaults: defaults, environment: ["KITE_SUPPORT_PATH": folder.path])
        #expect(!flags.bool(forKey: "asked"))
        flags.set(true, forKey: "dismissed")
        #expect(flags.bool(forKey: "dismissed"))
        #expect(!defaults.bool(forKey: "dismissed"))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(OneShotFlags.fileName).path))
        flags.set(false, forKey: "dismissed")
        #expect(!flags.bool(forKey: "dismissed"))
    }

    @Test func eachTestProfileStartsFresh() {
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = scratchFolder(), second = scratchFolder()
        defer { [first, second].forEach { try? FileManager.default.removeItem(at: $0) } }
        OneShotFlags(defaults: defaults, environment: ["KITE_SUPPORT_PATH": first.path]).set(true, forKey: "asked")
        #expect(OneShotFlags(defaults: defaults, environment: ["KITE_SUPPORT_PATH": first.path]).bool(forKey: "asked"))
        #expect(!OneShotFlags(defaults: defaults, environment: ["KITE_SUPPORT_PATH": second.path]).bool(forKey: "asked"))
    }
}
