import Foundation
import KiteCore
import WebKit

/// Deleting a profile's folder (its cookies, logins, history, extensions). Chromium may still have
/// the profile open, so folders are removed at the next launch, before Chromium starts.
@MainActor
enum ProfileFolders {
    static var root: URL { AppDelegate.supportDirectory.appendingPathComponent("Chromium", isDirectory: true) }
    /// Set when Kite runs on WebKit, which keeps each profile in a data store of its own.
    static var usesWebKit = false
    private static var pendingFile: URL { root.appendingPathComponent("Kite Deleted Profiles.json") }

    static func folder(_ directory: String) -> URL { root.appendingPathComponent(directory, isDirectory: true) }

    static func exists(_ directory: String) -> Bool {
        FileManager.default.fileExists(atPath: folder(directory).path)
    }

    /// Everything a deleted profile kept: its Chromium folder (next launch) and its WebKit store.
    static func delete(_ profile: Profile) {
        markForDeletion(profile.directory)
        // WebKit's store removal crashes in a Chromium run, where WebKit never started.
        guard usesWebKit else { return }
        WKWebsiteDataStore.remove(forIdentifier: profile.dataStoreID) { error in
            if let error { NSLog("Kite: couldn't remove a profile's WebKit data: \(error)") }
        }
    }

    static func markForDeletion(_ directory: String) {
        guard directory != Profile.defaultDirectory, !directory.contains("/"), directory != ".." else { return }
        var pending = Set(read())
        pending.insert(directory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(pending.sorted()).write(to: pendingFile, options: .atomic)
    }

    /// At launch, before Chromium opens any profile.
    static func deletePending() {
        let pending = read()
        guard !pending.isEmpty else { return }
        for directory in pending where directory != Profile.defaultDirectory && !directory.contains("/") && directory != ".." {
            try? FileManager.default.removeItem(at: folder(directory))
        }
        try? FileManager.default.removeItem(at: pendingFile)
    }

    private static func read() -> [String] {
        (try? Data(contentsOf: pendingFile)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }
}
