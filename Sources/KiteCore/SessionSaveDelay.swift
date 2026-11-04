import Foundation

/// When BrowserStore writes the session (and BrowserWindows windows.json) after a change. Sidebar
/// changes and navigations save a second after the last one, as before. A page's title and favicon
/// change all the time (a page can set `document.title` every second), so they wait longer and
/// don't push back a save that's already waiting: a page that never stops ticking still gets
/// saved. Quitting and closing the window save at once.
public enum SessionSaveDelay: Sendable, Equatable {
    /// A change to the sidebar, the selection, a tab's URL or settings.
    case soon
    /// A title or favicon reported by a page.
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

/// The waiting save of a debounced file (session.json, windows.json): what kind of change it's for.
public struct PendingSave: Sendable, Equatable {
    public private(set) var pending: SessionSaveDelay?

    public init() {}

    /// A change of kind `delay`: the seconds to (re)arm the save timer with, or nil to leave the
    /// waiting save as it is.
    public mutating func arm(_ delay: SessionSaveDelay) -> Double? {
        guard let seconds = delay.rearm(pending: pending) else { return nil }
        pending = delay
        return seconds
    }

    /// The save happened (or was cancelled for an immediate one).
    public mutating func saved() { pending = nil }
}

/// A trailing debounce that still saves at least every `maxWait` seconds while changes keep coming
/// (history.json while a page's title ticks).
public struct CappedDebounce: Sendable, Equatable {
    public var quiet: Double
    public var maxWait: Double
    /// When the first change not yet saved came in; nil when everything is saved.
    public private(set) var pendingSince: Double?

    public init(quiet: Double, maxWait: Double) {
        self.quiet = quiet
        self.maxWait = maxWait
    }

    /// A change at `now` (seconds on any steady clock): how long to arm the save timer for.
    public mutating func changed(at now: Double) -> Double {
        let since = pendingSince ?? now
        pendingSince = since
        return max(0, min(quiet, since + maxWait - now))
    }

    /// The save happened.
    public mutating func saved() { pendingSince = nil }
}
