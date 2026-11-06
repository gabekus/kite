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

    /// What Claude's tools say while Kite runs on WebKit because Chromium didn't start.
    public static let toolError = "Kite is running on its backup engine (WebKit) because Chromium didn't start, so its tabs "
        + "have other cookies (carts look empty, sites signed out) and Claude can't act in them. Nothing you see in Kite "
        + "now reflects the user's real sessions. Ask the user to quit Kite (⌘Q) and open it again, then retry."

    public static let alertTitle = "Kite started on its backup engine"
    public static let alertText = "Chromium didn't start, so Kite opened on WebKit: your tabs here have other cookies "
        + "(carts look empty, sites signed out), and Claude can read but not act. Quit and reopen Kite to get your "
        + "usual tabs back."
}
