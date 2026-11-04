import Foundation

/// How Kite shows one of its windows or panels.
///
/// A test-safe run (`KITE_DIAGNOSTICS=1` on a `KITE_SUPPORT_PATH` profile) must never cover the user's windows or
/// take their keyboard: a window is never made key, Kite is never activated, and a window goes at normal level (a
/// floating or modal level would sit over other apps' windows) directly above Kite's own frontmost window, which is
/// behind the other apps'. That keeps Kite's own stacking order what real use would give (code that looks for Kite's
/// front window still finds the newest), without coming in front of anything else. `kite ui` reads and drives covered
/// windows, so tests lose nothing. A real profile shows windows as it always has.
public struct WindowPresentation: Equatable, Sendable {
    public enum Order: Equatable, Sendable {
        /// makeKeyAndOrderFront.
        case keyAndFront
        /// orderFront, without making it key.
        case front
        /// Just above its parent or anchor window (a child window or popover).
        case aboveParent
        /// Just above Kite's frontmost visible normal-level window.
        case aboveKite
        /// Where it is: already visible, and Kite has no other window to go above.
        case keep
        /// orderBack: behind every other window (Kite shows nothing else yet).
        case behind
        /// Just below the key window (behind everything when there is none), without making it key or main.
        case belowKey
    }

    /// Who a window is shown for. The user's (⌘N, a link from another app, the Dock icon) come forward as
    /// usual. One Kite opens for itself, for Claude's tools, never comes in front of the window the user is
    /// in and never becomes key or main, on any profile, so it can't take their typing.
    public enum Purpose: Equatable, Sendable {
        case user
        case automation
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
    ///   - hasParent: it's a child window or popover with a known parent or anchor window.
    ///   - isVisible: it's on screen already.
    ///   - kiteHasFrontWindow: Kite has another visible normal-level window to go above.
    public static func decide(testSafe: Bool, key: Bool = true, activate: Bool = false, level: Int = normalLevel,
                              hasParent: Bool = false, isVisible: Bool = false,
                              kiteHasFrontWindow: Bool = false) -> WindowPresentation {
        guard testSafe else { return WindowPresentation(order: key ? .keyAndFront : .front, activates: activate, level: nil) }
        let order: Order = hasParent ? .aboveParent : kiteHasFrontWindow ? .aboveKite : isVisible ? .keep : .behind
        return WindowPresentation(order: order, activates: false, level: level > normalLevel ? normalLevel : nil)
    }

    /// A window Kite opens for itself (Purpose.automation): below the key window on a real profile, behind
    /// everything on a test-safe run. Never key, never activating.
    public static func background(testSafe: Bool, level: Int = normalLevel) -> WindowPresentation {
        WindowPresentation(order: testSafe ? .behind : .belowKey, activates: false,
                           level: testSafe && level > normalLevel ? normalLevel : nil)
    }

    /// Whether the order makes the window key.
    public var makesKey: Bool { order == .keyAndFront }

    /// Whether this process is a test-safe run: `KITE_DIAGNOSTICS=1` counts only with `KITE_SUPPORT_PATH`, so it can't
    /// switch on for a real profile.
    public static func isTestSafe(environment: [String: String]) -> Bool {
        environment["KITE_DIAGNOSTICS"] == "1" && environment["KITE_SUPPORT_PATH"] != nil
    }

    /// Whether to run modals (alerts, open and save panels, the quit dialogs), which come to the front. A test-safe
    /// run skips them and answers `SkippedModal.proceeds`.
    public static func runsModals(testSafe: Bool) -> Bool { !testSafe }
}

/// A modal a test-safe run skips, and how it answers instead.
public enum SkippedModal: Equatable, Sendable {
    case alert, openOrSavePanel, quitConfirmation, downloadsInProgress

    /// Whether the skipped modal goes ahead. Every one answers as if dismissed (no button's action runs) except
    /// "Downloads in progress", which quits (cancelling the downloads), so a test Kite never blocks a logout or a
    /// `kite quit`.
    public var proceeds: Bool { self == .downloadsInProgress }
}

/// The source check that keeps every window, activation, modal and app launch going through WindowPresenter
/// (Tests/KiteCoreTests/WindowPresenterGuardTests.swift and scripts/checks/window-presenter.sh run it).
public enum WindowPresenterGuard {
    /// What only WindowPresenter.swift may call. A line that must call one directly says why after
    /// `// presenter-exempt:`.
    public static let forbidden: [String] = [
        "makeKeyAndOrderFront(", "orderFront(", "orderFrontRegardless(", "showWindow(", "NSApp.activate(",
        ".activate(options", "runModal(", "orderFrontStandardAboutPanel(", ".level = ", ".makeKey()",
        "NSWorkspace.shared.open(", "NSWorkspace.shared.openApplication(", "activateFileViewerSelecting(",
        "requestUserAttention(", "presentError(", ".begin {", ".begin(completionHandler", "orderBack(",
    ]
    public static let exemptMarker = "// presenter-exempt:"

    /// The forbidden calls in one file's source, as "line: text". Comments don't count.
    public static func violations(in source: String) -> [String] {
        var found: [String] = []
        for (index, line) in source.components(separatedBy: "\n").enumerated() {
            guard !line.contains(exemptMarker) else { continue }
            // WindowPresenter's own calls are the allowed route.
            let code = (line.components(separatedBy: "//").first ?? line)
                .replacingOccurrences(of: #"WindowPresenter\.\w+\("#, with: "", options: .regularExpression)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("///") { continue }
            if let call = forbidden.first(where: { code.contains($0) }) {
                found.append("\(index + 1): \(call) in \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        return found
    }
}

/// Finding AppKit's About panel on a test-safe run, which AppKit creates and orders in front in one call: the windows
/// that appeared during that call, or failing that one of AppKit's About classes. Anything not identified goes to the
/// back, so the fallback is never "stay in front".
public enum AboutPanelLookup {
    public enum Outcome<ID: Hashable>: Equatable {
        /// The panel: put it where WindowPresenter puts any shown window.
        case found(ID)
        /// Not identified: every one of these goes to the back.
        case orderBehind([ID])
    }

    /// - Parameters:
    ///   - appeared: windows visible after the call that weren't before, front to back.
    ///   - classMatches: visible windows whose class (or controller's or delegate's) names About.
    public static func decide<ID: Hashable>(appeared: [ID], classMatches: [ID]) -> Outcome<ID> {
        if appeared.count == 1 { return .found(appeared[0]) }
        let both = appeared.filter(classMatches.contains)
        if both.count == 1 { return .found(both[0]) }
        if appeared.isEmpty, classMatches.count == 1 { return .found(classMatches[0]) }
        var behind = appeared
        for id in classMatches where !behind.contains(id) { behind.append(id) }
        return .orderBehind(behind)
    }
}
