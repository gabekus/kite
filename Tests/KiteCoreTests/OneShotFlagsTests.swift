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

    /// Tests/Fixtures/one-shot-flags.plist is the flags file Kite for Windows (windows/) shares with a test
    /// profile's (every Windows profile keeps its flags in one): both test suites read it.
    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/one-shot-flags.plist")

    @Test func readsTheSharedFixture() throws {
        let data = try Data(contentsOf: Self.fixture)
        let decoded = try PropertyListDecoder().decode([String: Bool].self, from: data)
        #expect(decoded == ["favoritesEmptyStateDismissed": true, "passwordManagerOfferShown": false])
        // Through the read a test profile's flags take.
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try data.write(to: folder.appendingPathComponent(OneShotFlags.fileName))
        let flags = OneShotFlags(defaults: defaults, environment: ["KITE_SUPPORT_PATH": folder.path])
        #expect(flags.bool(forKey: "favoritesEmptyStateDismissed"))
        #expect(!flags.bool(forKey: "passwordManagerOfferShown"))
    }

    @Test func settingPostsDidChangeWithTheKey() {
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = Keys()
        let token = NotificationCenter.default.addObserver(forName: OneShotFlags.didChange, object: nil, queue: nil) { note in
            if let key = note.userInfo?["key"] as? String { keys.append(key) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        OneShotFlags(defaults: defaults, environment: [:]).set(true, forKey: "real")
        OneShotFlags(defaults: defaults, environment: ["KITE_SUPPORT_PATH": folder.path]).set(true, forKey: "test")
        #expect(keys.all.contains("real") && keys.all.contains("test"))
    }
}

/// The keys a test's observer saw. The observer block is `@Sendable`, so it can't append to a captured `var`.
private final class Keys: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String] = []

    func append(_ key: String) {
        lock.lock()
        keys.append(key)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return keys
    }
}
