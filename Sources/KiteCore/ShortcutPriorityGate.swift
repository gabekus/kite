import Foundation

/// Arc's "Use Both" priority (`promptAfterConsumedByWebView`): the first press of a shortcut goes to
/// the page; if the page uses it, Kite says "Press ⌘L again to …", and the next press runs Kite's
/// command instead of going to the page. This is the bookkeeping, kept free of AppKit.
///
/// Neither engine says when a page used a key, only when it didn't (CEF and WebKit hand an unused
/// key to the menu bar). So a key counts as used when `consumedDelay` passes without its command
/// running.
public struct ShortcutPriorityGate: Sendable {
    /// How long a page has to pass a key back before it counts as used.
    public static let consumedDelay: TimeInterval = 0.35
    /// How long a second press still counts: as long as Kite's toast stays up.
    public static let secondPressWindow: TimeInterval = 4.6

    private struct Press: Sendable {
        let action: String
        let window: Int
        let time: TimeInterval
        var consumed = false
    }

    private var last: Press?

    public init() {}

    /// A press of `action`'s shortcut while a page has the keys. True means it's the second press:
    /// run Kite's command now, before the page sees it. Otherwise the page gets it, and
    /// `pageConsumed` says later whether to prompt.
    public mutating func press(_ action: String, window: Int, at time: TimeInterval, isRepeat: Bool) -> Bool {
        if let last, last.action == action, last.window == window, time - last.time <= Self.secondPressWindow {
            // A held key repeating isn't a second press; it keeps the first one's place.
            if isRepeat { return false }
            self.last = nil
            return true
        }
        last = isRepeat ? nil : Press(action: action, window: window, time: time)
        return false
    }

    /// The command ran from the menu bar: the page didn't use the key, so nothing to ask.
    public mutating func commandRan(_ action: String) {
        if last?.action == action { last = nil }
    }

    /// `consumedDelay` after the press at `time`: true if the page kept the key, so it's time to
    /// show the prompt.
    public mutating func pageConsumed(_ action: String, window: Int, pressedAt time: TimeInterval) -> Bool {
        guard var press = last, press.action == action, press.window == window, press.time == time, !press.consumed else { return false }
        press.consumed = true
        last = press
        return true
    }

    /// "Press ⌘L again to Add Split View" (Arc: "Take an action again, '<do something> again to <do action>'").
    public static func prompt(shortcut: KeyShortcut, title: String) -> String {
        let action = title.hasSuffix("…") ? String(title.dropLast()) : title
        return "Press \(shortcut.displayString) again to \(action)"
    }
}
