import Foundation

/// When Chromium doesn't start, Kite used to come up on WebKit without a word: other cookies (every cart empty, every
/// site signed out) and no way for Claude to act (Gabe, 5 Nov 2026). Chromium most often fails right after a restart,
/// while the last Kite's helpers still hold the profile, so Kite starts itself again a few times before giving up,
/// and then says so: an alert for the user, and an error for Claude's tools naming the fix.
public enum EngineFallback {
    /// The environment variable counting the tries, across the re-launches.
    public static let attemptKey = "KITE_CHROMIUM_ATTEMPT"
    public static let maxAttempts = 4
    /// Seconds before each new try: long enough for the last Kite's helpers to let go of the profile.
    public static let retryDelay: Double = 1.5

    /// Whether Kite should start itself again after Chromium failed on try `attempt` (from 1).
    public static func shouldRetry(attempt: Int) -> Bool { attempt < maxAttempts }

    /// The try this process is (1 for the first launch).
    public static func attempt(environment: [String: String]) -> Int {
        environment[attemptKey].flatMap(Int.init).map { max(1, $0) } ?? 1
    }

    /// CEF's result codes for a profile another Chromium process has open (cef_resultcode_t):
    /// 21 PROFILE_IN_USE, and 24 NORMAL_EXIT_PROCESS_NOTIFIED (the launch was handed to the running one).
    public static let profileInUseExitCodes: Set<Int32> = [21, 24]
    /// Exit status of a Kite that found its profile open in another Kite (EX_TEMPFAIL).
    public static let profileInUseExitStatus: Int32 = 75
    /// Set on the fresh process a WebKit fallback starts (with KITE_ENGINE=webkit), so it says it fell back.
    public static let fellBackKey = "KITE_ENGINE_FELL_BACK"

    public enum Step: Equatable, Sendable {
        /// Start Kite again and try Chromium once more.
        case retry
        /// Another Kite has the profile open: say so and quit. Never WebKit on a profile a Chromium Kite is using
        /// (its cookies aren't there, and it would take Claude's socket with empty carts), and never a hang.
        case refuseProfileInUse
        /// Chromium is broken here: start Kite again on WebKit, in a fresh process. A process whose CefInitialize
        /// failed never finishes launching AppKit (seen 5 Nov 2026: it sat in NSApplication.run with no window).
        case webKit
    }

    /// What to do after Chromium failed on try `attempt` with CEF's `exitCode`.
    public static func next(attempt: Int, exitCode: Int32) -> Step {
        if shouldRetry(attempt: attempt) { return .retry }
        return profileInUseExitCodes.contains(exitCode) ? .refuseProfileInUse : .webKit
    }

    /// How long a Kite whose profile is open in another waits for that one to quit (a restart's old Kite saving its
    /// session) before refusing. Each CefInitialize retry against a running Kite takes 4 to 13 s, so this, not the
    /// retries, decides how soon a second Kite says so.
    public static let holderQuitWait: Double = 8

    /// The PID in Chromium's SingletonLock link ("<host>-<pid>"), the process holding the profile.
    public static func lockHolderPID(lockTarget: String) -> Int32? {
        guard let dash = lockTarget.lastIndex(of: "-"), let pid = Int32(lockTarget[lockTarget.index(after: dash)...]),
              pid > 0 else { return nil }
        return pid
    }

    /// The refusal's log line.
    public static func profileInUseMessage(profile: String, holder: String?) -> String {
        "Kite: not starting: the profile at \(profile) is already open in another Kite"
            + (holder.map { ", \($0)" } ?? "") + ". Use that Kite, or quit it first; a second Kite on the same profile "
            + "would run without its cookies and without Claude's connection. Test builds each take a fresh "
            + "KITE_SUPPORT_PATH."
    }

    /// What Claude's tools say while Kite runs on WebKit because Chromium didn't start.
    public static let toolError = "Kite is running on its backup engine (WebKit) because Chromium didn't start, so its tabs "
        + "have other cookies (carts look empty, sites signed out) and Claude can't act in them. Nothing you see in Kite "
        + "now reflects the user's real sessions. Ask the user to quit Kite (⌘Q) and open it again, then retry."

    public static let alertTitle = "Kite started on its backup engine"
    public static let alertText = "Chromium didn't start, so Kite opened on WebKit: your tabs here have other cookies "
        + "(carts look empty, sites signed out), and Claude can read but not act. Quit and reopen Kite to get your "
        + "usual tabs back."
}
