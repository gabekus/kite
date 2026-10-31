import Foundation

/// Native messaging hosts: the manifests that let an extension talk to an app on the
/// Mac, such as 1Password's extension and its desktop app.
///
/// Apps install their manifests where Chrome and the other browsers look, never where
/// Kite's Chromium does (`<profile>/NativeMessagingHosts`), so Kite copies them in.
/// Without them `chrome.runtime.connectNative` fails and chromium.log says "Can't find
/// manifest for native messaging host".
public enum NativeMessagingHosts {
    /// Lists the manifests Kite copied, so it updates and removes only those and never
    /// a manifest someone put in the folder themselves.
    static let ledgerName = ".kite-copied"

    /// Where macOS apps install manifests, most likely first: when two folders have a
    /// manifest of the same name, the earlier one wins.
    public static func macSourceDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let support = home.appendingPathComponent("Library/Application Support")
        let user = [
            "Google/Chrome",
            "Chromium",
            "Arc/User Data",
            "BraveSoftware/Brave-Browser",
            "Microsoft Edge",
            "Vivaldi",
        ].map { support.appendingPathComponent($0).appendingPathComponent("NativeMessagingHosts") }
        let system = [
            "/Library/Google/Chrome/NativeMessagingHosts",
            "/Library/Application Support/Chromium/NativeMessagingHosts",
            "/Library/Microsoft/Edge/NativeMessagingHosts",
        ].map { URL(fileURLWithPath: $0) }
        return user + system
    }

    /// Copies every host manifest in `sources` into `destination`, updates the ones Kite
    /// copied before, and removes those whose app took its manifest away. Returns the
    /// names of the manifests Kite now provides.
    @discardableResult
    public static func sync(from sources: [URL], into destination: URL, fileManager: FileManager = .default) -> [String] {
        var wanted: [String: Data] = [:]
        for directory in sources {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names.sorted() where name.hasSuffix(".json") && wanted[name] == nil {
                guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)), isHostManifest(data) else { continue }
                wanted[name] = data
            }
        }

        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let ledger = destination.appendingPathComponent(ledgerName)
        let copiedBefore = Set(((try? String(contentsOf: ledger, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))

        var provided: [String] = []
        for (name, data) in wanted.sorted(by: { $0.key < $1.key }) {
            let target = destination.appendingPathComponent(name)
            let current = try? Data(contentsOf: target)
            // Someone else's manifest of the same name stays; an identical copy is adopted.
            if current != nil && current != data && !copiedBefore.contains(name) { continue }
            if current != data {
                guard (try? data.write(to: target, options: .atomic)) != nil else { continue }
            }
            provided.append(name)
        }
        for name in copiedBefore.subtracting(provided) where !name.isEmpty {
            try? fileManager.removeItem(at: destination.appendingPathComponent(name))
        }
        try? (provided.joined(separator: "\n") + "\n").write(to: ledger, atomically: true, encoding: .utf8)
        return provided
    }

    /// A manifest Chromium can use: it names the host and the app to start.
    static func isHostManifest(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["name"] is String && object["path"] is String
    }
}
