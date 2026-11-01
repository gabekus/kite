import Foundation

/// When a window's open command bar (⌘T, ⌘L) takes the keyboard back for its field.
///
/// SwiftUI gives every window's text field the same field editor. A window that puts its bar's field
/// in charge pulls that editor out of any other window, whose first responder falls back to the
/// window itself. If every window with an open bar took the keyboard back whenever its first
/// responder changed, two of them would hand the editor back and forth forever on the main thread
/// (g66: two new windows from ⌘N spun the CPU and froze Kite). So only the window in front (key, or
/// the one `ui input` is delivering to) takes it back on a responder change; any window does when its
/// bar opens or when it becomes the window in front.
public enum CommandBarFocus {
    public enum Trigger: Sendable {
        /// The bar just opened (or is still being built after opening).
        case opened
        /// The bar was already open and the window's state changed (⌘T or ⌘L again, a store update).
        case stillOpen
        /// The window's first responder changed while the bar was open (a page took the keyboard, or
        /// another window took the shared field editor).
        case responderChanged
        /// The window became key.
        case becameKey
    }

    public static func takesFocus(after trigger: Trigger, inFront: Bool) -> Bool {
        switch trigger {
        case .opened, .becameKey: return true
        case .stillOpen, .responderChanged: return inFront
        }
    }
}
