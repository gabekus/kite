import AppKit
import Sparkle

/// Over-the-air updates, like Arc's: Sparkle with an EdDSA-signed appcast.
///
/// Only release builds update themselves. scripts/release.sh (and package-share.sh) build Kite with
/// `KITE_UPDATE_FEED`, which bundle-app.sh writes into Info.plist as `SUFeedURL`, next to the
/// `SUPublicEDKey` every build carries. Builds without a feed (install-app.sh, update-app.sh, test
/// builds) never start Sparkle: Gabe's own Kite is updated from main by its install scripts, and
/// Check for Updates… there falls back to `UpdaterWindow`, which only looks at GitHub releases.
///
/// Settings mirror Arc's Info.plist (docs/arc-visual-spec.md, Check for Updates): check every 8 hours
/// and install silently, so a new version goes in the next time Kite quits. Sparkle never replaces the
/// app while it runs: it installs after Kite quits, or on Install and Relaunch.
/// See docs/updates.md for the release side.
@MainActor
final class SoftwareUpdater: NSObject {
    static let shared = SoftwareUpdater()

    /// Nil when this build has no update feed (see above).
    private(set) var controller: SPUStandardUpdaterController?

    /// Whether this build updates itself.
    var isEnabled: Bool { controller != nil }

    static var hasFeed: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let key = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return !feed.isEmpty && !key.isEmpty
    }

    /// Starts Sparkle (scheduled checks included) if this build has a feed. Call once at launch.
    func start() {
        guard controller == nil, Self.hasFeed else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// Kite › Check for Updates…: Sparkle's window when this build updates itself.
    /// Returns false when it doesn't, so the caller can fall back to the GitHub release check.
    func checkForUpdates() -> Bool {
        guard let controller else { return false }
        controller.checkForUpdates(nil)
        return true
    }

    /// Settings › General › Automatically update my Kite: check on a schedule and install on quit.
    var automaticallyUpdates: Bool {
        get {
            guard let updater = controller?.updater else { return false }
            return updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
        }
        set {
            guard let updater = controller?.updater else { return }
            updater.automaticallyChecksForUpdates = newValue
            updater.automaticallyDownloadsUpdates = newValue
        }
    }
}
