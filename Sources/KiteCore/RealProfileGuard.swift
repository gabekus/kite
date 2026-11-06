import Foundation

/// Only the installed Kite may open the user's real profile (`~/Library/Application Support/Kite`) and serve its
/// automation socket, the one every `kite mcp` connects to.
///
/// The installed Kite is the bundle `dev.gabek.Kite` at /Applications/Kite.app (or ~/Applications/Kite.app, where
/// install.sh puts it without admin rights). Anything else, a debug bundle (`dev.gabek.Kite.dev`), a perf build, a
/// release build still in a checkout's build/ or a bare `swift build` binary, refuses to start on the real profile:
/// launch it with `KITE_SUPPORT_PATH` set to a fresh test profile instead.
///
/// Why: on 5 Nov 2026 macOS's default browser was a dev bundle (`dev.gabek.Kite.dev`, build 1231), so a link opened
/// from another app started ~/dev/kite-perf/build/baseline.app through Launch Services, with no
/// `KITE_SUPPORT_PATH`, on the real profile. It held the automation socket for three hours, and every Claude session
/// drove that old build instead of /Applications/Kite.app.
public enum RealProfileGuard {
    /// The installed Kite's bundle ID (release builds; debug bundles are dev.gabek.Kite.dev).
    public static let installedBundleID = "dev.gabek.Kite"
    /// Exit status of a refused launch (EX_CONFIG).
    public static let refusedExitStatus: Int32 = 78
    /// Extra folders a test treats as the real profile, so the refusal can be run end to end on a throwaway
    /// profile. It only ever adds to what counts as real: the real profile always does.
    public static let testRealProfileKey = "KITE_TEST_REAL_PROFILE"

    /// Where the installed Kite lives.
    public static func installedBundlePaths(home: String) -> [String] {
        ["/Applications/Kite.app", (home as NSString).appendingPathComponent("Applications/Kite.app")]
    }

    /// The real profile: what Kite uses when `KITE_SUPPORT_PATH` isn't set.
    public static func realSupportDirectory(home: String) -> String {
        (home as NSString).appendingPathComponent("Library/Application Support/Kite")
    }

    /// Whether a bundle is the installed Kite. `bundlePath` is resolved (symlinks, `..`) before comparing.
    public static func isInstalledKite(bundleID: String?, bundlePath: String?, home: String,
                                       resolve: (String) -> String = resolvedPath) -> Bool {
        guard bundleID == installedBundleID, let bundlePath else { return false }
        let path = resolve(bundlePath)
        return installedBundlePaths(home: home).contains { samePath(resolve($0), path) }
    }

    /// The folders that count as the real profile.
    public static func realProfiles(home: String, environment: [String: String]) -> [String] {
        var profiles = [realSupportDirectory(home: home)]
        if let test = environment[testRealProfileKey], !test.isEmpty { profiles.append(test) }
        return profiles
    }

    /// Whether this run's profile is the real one: `KITE_SUPPORT_PATH` unset, or set to the real profile (or a
    /// link to it, or a folder inside it).
    public static func usesRealProfile(environment: [String: String], home: String,
                                       resolve: (String) -> String = resolvedPath) -> Bool {
        let profiles = realProfiles(home: home, environment: environment).map(resolve)
        guard let override = environment["KITE_SUPPORT_PATH"] else { return true }
        // Kite reads an empty KITE_SUPPORT_PATH as the current folder.
        let path = resolve(override.isEmpty ? FileManager.default.currentDirectoryPath : override)
        return profiles.contains { samePath($0, path) || isInside(path, $0) }
    }

    public enum Verdict: Equatable, Sendable {
        case allowed
        case refused(String)
    }

    /// Whether this Kite may start. Refused: a build that isn't the installed Kite, on the real profile.
    public static func check(bundleID: String?, bundlePath: String?, environment: [String: String], home: String,
                             resolve: (String) -> String = resolvedPath) -> Verdict {
        guard usesRealProfile(environment: environment, home: home, resolve: resolve) else { return .allowed }
        if isInstalledKite(bundleID: bundleID, bundlePath: bundlePath, home: home, resolve: resolve) { return .allowed }
        return .refused(refusal(bundleID: bundleID, bundlePath: bundlePath, environment: environment, home: home))
    }

    /// The log line for a refused launch (also the alert's text).
    public static func refusal(bundleID: String?, bundlePath: String?, environment: [String: String], home: String) -> String {
        let what = "\(bundlePath ?? "this Kite") (\(bundleID ?? "no bundle ID"))"
        let profile = environment["KITE_SUPPORT_PATH"].map { "KITE_SUPPORT_PATH=\($0), which is the real profile" }
            ?? "no KITE_SUPPORT_PATH, so the real profile at \(realSupportDirectory(home: home))"
        return "Kite: refusing to start \(what) with \(profile). Only \(installedBundleID) in /Applications may open "
            + "the real profile and its automation socket. Test builds run with KITE_SUPPORT_PATH=$(mktemp -d /tmp/k.XXXX)."
    }

    /// Whether macOS sends web links to a Kite build that isn't the installed one (the 5 Nov 2026 cause: the default
    /// browser was dev.gabek.Kite.dev, so links started whichever debug build Launch Services picked).
    public static func isStrayKiteDefault(handlerBundleID: String?, handlerPath: String?, home: String,
                                          resolve: (String) -> String = resolvedPath) -> Bool {
        guard let id = handlerBundleID?.lowercased(), [installedBundleID.lowercased(), "dev.gabek.kite.dev"].contains(id) else {
            return false
        }
        return !isInstalledKite(bundleID: handlerBundleID, bundlePath: handlerPath, home: home, resolve: resolve)
    }

    /// Whether `socketPath` is the real profile's automation socket, where only the installed Kite should answer.
    public static func isRealProfileSocket(_ socketPath: String, environment: [String: String], home: String,
                                           resolve: (String) -> String = resolvedPath) -> Bool {
        let path = resolve(socketPath)
        return realProfiles(home: home, environment: environment).contains { profile in
            samePath(resolve(AutomationWire.socketURL(supportDirectory: URL(fileURLWithPath: profile, isDirectory: true)).path), path)
        }
    }

    /// Symlinks and `..` resolved, so /tmp and /private/tmp (or a link to the profile) compare equal.
    public static func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// macOS volumes are case-insensitive unless formatted otherwise; err towards "the same".
    static func samePath(_ a: String, _ b: String) -> Bool {
        trimmed(a).caseInsensitiveCompare(trimmed(b)) == .orderedSame
    }

    static func isInside(_ path: String, _ folder: String) -> Bool {
        trimmed(path).lowercased().hasPrefix(trimmed(folder).lowercased() + "/")
    }

    private static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
