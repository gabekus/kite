import Foundation

/// Kite's first-launch onboarding (Welcome, Set Up Claude, Import from Arc), shown once on a new
/// profile. Whether it shows lives in `onboarding.json` in the profile folder, next to session.json.
public enum Onboarding {
    public struct State: Codable, Equatable {
        /// False from the first launch until the user finishes or closes onboarding, so quitting
        /// halfway brings it back next time.
        public var completed: Bool
        /// The step showing when onboarding was last left unfinished, so a relaunch resumes there.
        public var step: Int?

        public init(completed: Bool, step: Int? = nil) {
            self.completed = completed
            self.step = step
        }
    }

    /// Whether to show onboarding at launch.
    /// - Parameters:
    ///   - sessionExisted: session.json (or history.json, windows.json) was there before this launch. A profile that already has a
    ///     session is an existing install, so it never gets onboarding it didn't start.
    ///   - state: onboarding.json, nil when it isn't there.
    ///   - testProfile: a throwaway profile (`KITE_SUPPORT_PATH`). Tests get onboarding only when
    ///     they ask for it (`forced`), so it never covers another test's window.
    ///   - forced: `KITE_ONBOARDING=1` on a test profile.
    public static func shouldShow(sessionExisted: Bool, state: State?, testProfile: Bool, forced: Bool) -> Bool {
        if testProfile { return forced && state?.completed != true }
        if let state { return !state.completed }
        return !sessionExisted
    }

    /// The same, reading `KITE_SUPPORT_PATH` and `KITE_ONBOARDING` from `environment`.
    public static func shouldShow(environment: [String: String], sessionExisted: Bool, state: State?) -> Bool {
        shouldShow(sessionExisted: sessionExisted, state: state, testProfile: environment["KITE_SUPPORT_PATH"] != nil,
                   forced: environment["KITE_ONBOARDING"] == "1")
    }

    public static func load(from url: URL) -> State? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    /// The step to open on at launch: where an unfinished onboarding was left, else the first.
    public static func resumeStep(_ state: State?, stepCount: Int) -> Int {
        guard let state, !state.completed, let step = state.step, (0..<stepCount).contains(step) else { return 0 }
        return step
    }

    public static func save(_ state: State, to url: URL) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// The prompt that sets Kite up with Claude: what `kite setup` starts Claude Code with, and what
/// onboarding's Copy Prompt for Claude puts on the clipboard. The Mac's wording ("on this Mac",
/// Terminal); Kite for Windows needs its own.
public enum ClaudeSetupPrompt {
    /// Where the guide lives when a Kite is missing its copy.
    public static let guideOnGitHub = "https://github.com/gabekus/kite/blob/main/Resources/SETUP.md"

    /// For Claude Code, which reads the guide from disk (`kite setup`).
    public static func pointingAt(guidePath: String, kite: String) -> String {
        """
        Help me set up Kite, my web browser, on this Mac. Kite's setup guide is at \(guidePath) and Kite's \
        command line tool is \(kite). Read the guide first, then take me through it one step at a time: \
        check what's already done, explain each step briefly, and ask me before you change anything.
        """
    }

    /// With the guide inside it, so it also works pasted into the Claude app, which can't read the
    /// file. Claude Code gets the same prompt and can run the steps itself.
    public static func withGuide(_ guide: String, kite: String) -> String {
        """
        Help me set up Kite, my web browser, on this Mac. Kite's command line tool is \(kite). Kite's setup \
        guide is below. Take me through it one step at a time: check what's already done, explain each \
        step briefly, and ask me before you change anything. If you can't run commands here, tell me \
        each command to paste into Terminal.

        \(guide.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }
}
