import Foundation

/// Kite's one-shot flags: things it asks or shows once (the password manager's Add offer, Claude's setup, the
/// favorites tray's empty state). A real profile keeps them in UserDefaults. A test profile (`KITE_SUPPORT_PATH`)
/// keeps them in a file in its folder, so each test profile starts fresh: UserDefaults follow the bundle, which every
/// test build shares.
// UserDefaults is thread-safe, and the file URL never changes.
public struct OneShotFlags: @unchecked Sendable {
    public static let fileName = "One-Shot Flags.plist"
    /// Posted after `set`, on a real profile and a test one alike, with the key as `userInfo["key"]`.
    public static let didChange = Notification.Name("KiteOneShotFlagsDidChange")

    private let defaults: UserDefaults
    /// The flags file, on a test profile.
    private let file: URL?

    public init(defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.defaults = defaults
        file = environment["KITE_SUPPORT_PATH"].map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(Self.fileName) }
    }

    /// Kite's, for this process (the environment doesn't change while it runs).
    public static let standard = OneShotFlags()

    public func bool(forKey key: String) -> Bool {
        guard let file else { return defaults.bool(forKey: key) }
        return read(file)[key] ?? false
    }

    public func set(_ value: Bool, forKey key: String) {
        defer { NotificationCenter.default.post(name: Self.didChange, object: nil, userInfo: ["key": key]) }
        guard let file else { return defaults.set(value, forKey: key) }
        var flags = read(file)
        flags[key] = value
        guard let data = try? PropertyListEncoder().encode(flags) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private func read(_ file: URL) -> [String: Bool] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? PropertyListDecoder().decode([String: Bool].self, from: data)) ?? [:]
    }
}
