import Foundation

/// When BrowserStore writes the session after a change. Sidebar changes save a second after the
/// last one, as before. A page's title, URL and favicon change all the time (a page can set
/// `document.title` every second), so they wait longer and don't push back a save that's already
/// waiting: a page that never stops ticking still gets saved. Quitting and closing the window
/// save at once.
public enum SessionSaveDelay: Sendable, Equatable {
    /// A change to the sidebar, the selection or settings.
    case soon
    /// A title, URL or favicon reported by a page.
    case pageEvent

    public var seconds: Double {
        switch self {
        case .soon: 1
        case .pageEvent: 10
        }
    }

    /// The delay to arm the save timer with for a change of this kind, when a save of kind
    /// `pending` is already waiting (nil: none is), or nil to leave the waiting save alone.
    public func rearm(pending: SessionSaveDelay?) -> Double? {
        switch (self, pending) {
        case (.soon, _): seconds
        case (.pageEvent, nil): seconds
        case (.pageEvent, .some): nil
        }
    }
}
