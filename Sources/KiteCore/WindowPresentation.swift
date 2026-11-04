import Foundation

/// How Kite shows one of its windows or panels.
///
/// A test-safe run (`KITE_DIAGNOSTICS=1` on a `KITE_SUPPORT_PATH` profile) must never cover the user's windows or
/// take their keyboard: every window goes behind the other apps' windows at normal level (a floating or modal level
/// would still sit over them), is never made key, and Kite is never activated. `kite ui` reads and drives covered
/// windows, so tests lose nothing. A real profile shows windows as it always has.
public struct WindowPresentation: Equatable, Sendable {
    public enum Order: Equatable, Sendable {
        /// makeKeyAndOrderFront.
        case keyAndFront
        /// orderFront, without making it key.
        case front
        /// Just above its parent window (a child window, whose parent is behind).
        case aboveParent
        /// orderBack: behind every other window at its level.
        case behind
    }

    /// NSWindow.Level.normal's raw value.
    public static let normalLevel = 0

    public var order: Order
    /// Whether to activate Kite (NSApp.activate).
    public var activates: Bool
    /// The level to set before ordering, or nil to keep the window's.
    public var level: Int?

    /// - Parameters:
    ///   - key: the caller would make the window key (makeKeyAndOrderFront, showWindow) rather than only order it.
    ///   - activate: the caller would also activate Kite.
    ///   - level: the window's level now.
    ///   - hasParent: it's a child window.
    public static func decide(testSafe: Bool, key: Bool = true, activate: Bool = false, level: Int = normalLevel,
                              hasParent: Bool = false) -> WindowPresentation {
        guard testSafe else { return WindowPresentation(order: key ? .keyAndFront : .front, activates: activate, level: nil) }
        return WindowPresentation(order: hasParent ? .aboveParent : .behind, activates: false,
                                  level: level > normalLevel ? normalLevel : nil)
    }

    /// Whether this process is a test-safe run: `KITE_DIAGNOSTICS=1` counts only with `KITE_SUPPORT_PATH`, so it can't
    /// switch on for a real profile.
    public static func isTestSafe(environment: [String: String]) -> Bool {
        environment["KITE_DIAGNOSTICS"] == "1" && environment["KITE_SUPPORT_PATH"] != nil
    }

    /// What a test-safe run does instead of a modal alert or panel, which would come to the front: it skips it and
    /// answers as if the user dismissed it (no button's action runs).
    public static func runsModals(testSafe: Bool) -> Bool { !testSafe }
}
