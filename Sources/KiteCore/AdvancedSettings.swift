import Foundation

/// Settings › Advanced: "Haptic feedback when reordering tabs". Arc's key is
/// `tabReorderingHapticsDisabled` (unset, so haptics on, in Gabe's Arc); Kite keeps Arc's name.
/// Sources are in docs/arc-visual-spec.md, "Advanced: haptics, window restore, page-top dragging".
public enum TabReorderHaptics {
    public static let disabledKey = "tabReorderingHapticsDisabled"

    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: disabledKey)
    }
}

/// Settings › Advanced: "When opening Kite, restore windows from previous session". Arc's
/// `quitAlwaysKeepsWindows` (stored as `arc_quitAlwaysKeepsWindows`): on launch Arc restores its
/// windows only when this is on (or when it relaunches for an update). Off, it opens one window.
/// Kite's switch is on until turned off, as Kite always restored its windows before.
public enum WindowRestore {
    public static let enabledKey = "restoreWindowsOnLaunch"

    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }
}

/// Settings › Advanced: "Allow window dragging from the top of webpages". Arc's
/// `contentWindowDraggingEnabled`, on when unset. Arc lays a grabber over each page's top band
/// (`WindowContentViewController`'s `grabberView`, an `ARCUI.WindowContentGrabber`): from the
/// toolbar's bottom (the page's top when there's no toolbar) down to 60pt below the top of the
/// page's card, and the card's width less 14pt on the trailing side (the scroller). A press there
/// still reaches the page; only when the pointer is the arrow cursor (not over a link or text)
/// and then moves more than 1pt does the window move instead.
public enum PageTopWindowDrag {
    public static let enabledKey = "contentWindowDraggingEnabled"
    /// From the top of the page's card (toolbar included).
    public static let bandHeight = 60.0
    /// Left out on the trailing side, for the vertical scroller.
    public static let trailingInset = 14.0
    /// Movement before a press turns into a window drag (Arc: more than 1pt).
    public static let dragThreshold = 1.0

    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Whether a point in the card (top-left origin) is in the band. `toolbarHeight` is the toolbar
    /// across the card's top, 0 when hidden; the band starts below it.
    public static func contains(x: Double, y: Double, cardWidth: Double, toolbarHeight: Double) -> Bool {
        x >= 0 && x < cardWidth - trailingInset && y >= toolbarHeight && y < bandHeight
    }

    /// Whether a press that moved this far has become a window drag.
    public static func startsDrag(dx: Double, dy: Double) -> Bool {
        (dx * dx + dy * dy).squareRoot() > dragThreshold
    }
}
