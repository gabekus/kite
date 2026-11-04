import Foundation

/// How `ui input` types `text` into a Kite window.
///
/// Typing builds key events, and key events go through the Mac's input method: with a Japanese (or any other
/// composing) input source the letters become marked text and the input method draws its candidate window on the
/// user's screen, which a test-safe run must never do. So a test-safe run (`WindowPresentation.isTestSafe`) inserts
/// the characters straight into the field instead (`insertText(_:replacementRange:)`, no key events, no input
/// method), and only into the field editor of Kite's own command bar, which acts on nothing until Return. Anything
/// else is refused. A real profile keeps typing key by key.
public enum UITextEntry: Equatable, Sendable {
    /// One key event per character, as a real keyboard would type.
    case keyEvents
    /// Inserted directly into the command bar's field editor.
    case insertIntoCommandBar
    /// Not typed; the reason goes back to the caller.
    case refused(String)

    public static let refusal = "A test-safe run types text only into Kite's command bar (its field editor isn't the first responder: open the bar first, e.g. click New Tab)."

    /// `firstResponderIsCommandBarEditor`: the window's first responder is the field editor editing a command bar field.
    public static func decide(testSafe: Bool, firstResponderIsCommandBarEditor: Bool) -> UITextEntry {
        guard testSafe else { return .keyEvents }
        return firstResponderIsCommandBarEditor ? .insertIntoCommandBar : .refused(refusal)
    }
}
