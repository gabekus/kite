import Foundation

/// A close the person asked for (⌘W, a close button, closing Peek or a window), as the page's beforeunload
/// decides it: the engine starts a non-forced close, the page may ask "Leave site?", and the close goes ahead
/// only if it lets go. Chrome does the same when you close a tab with unsaved changes.
///
/// The engine feeds it what happens and carries out the effects it returns. One request is answered once:
/// `close`, `stay`, or `superseded` when a newer request or a forced close took over.
public struct PageClose: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The page let go (or never answered in time); the caller closes it.
        case close
        /// The person picked Cancel, or the page dropped its dialog.
        case stay
        /// A newer request took over its answer, or something closed the page without asking.
        case superseded
    }

    public enum Effect: Equatable, Sendable {
        /// Start the engine's non-forced close (CEF's CloseBrowser(false)).
        case startUnload
        /// Call `timerFired(generation:)` after `PageClose.unresponsiveTimeout` unless cancelled.
        case armTimer(generation: Int)
        case cancelTimer
        /// The page didn't answer in time: close it without asking (its script is stopped later only if
        /// it's still running, `stuckScriptTimeout`).
        case forceClose
        /// Answer request `generation` (deliver it on a later turn, never inside the engine's callback).
        case finish(Outcome, generation: Int)
    }

    public enum Phase: Equatable, Sendable {
        case idle
        /// The page is running beforeunload; no dialog yet.
        case waiting(Int)
        /// "Leave site?" is on screen for request `Int`.
        case asking(Int)
        /// The person picked Leave; the engine is closing the page.
        case leaving(Int)
        /// The page is going: let go, timed out, or closed without asking.
        case closing
    }

    /// How long a page may take to run beforeunload before Kite closes it anyway. Chromium's own hang timer
    /// doesn't run while a DevTools client is attached, and Kite always attaches one.
    public static let unresponsiveTimeout: TimeInterval = 1.5
    /// How long a page closed at that deadline may keep running script before Kite stops it.
    public static let stuckScriptTimeout: TimeInterval = 5

    public private(set) var phase: Phase = .idle
    private var generation = 0

    public init() {}

    /// The request in flight, if any.
    public var pending: Int? {
        switch phase {
        case .waiting(let g), .asking(let g), .leaving(let g): g
        case .idle, .closing: nil
        }
    }

    /// The person asked to close the page. Returns the new request's generation with the effects.
    public mutating func request() -> (generation: Int, effects: [Effect]) {
        generation += 1
        let g = generation
        switch phase {
        case .idle:
            phase = .waiting(g)
            // The timer first: a page with nothing to ask lets go inside startUnload.
            return (g, [.armTimer(generation: g), .startUnload])
        case .waiting(let old):
            // The engine ignores a second close while one is pending; the new request takes the answer.
            phase = .waiting(g)
            return (g, [.finish(.superseded, generation: old), .armTimer(generation: g)])
        case .asking(let old):
            phase = .asking(g)
            return (g, [.finish(.superseded, generation: old)])
        case .leaving(let old):
            phase = .leaving(g)
            return (g, [.finish(.superseded, generation: old)])
        case .closing:
            return (g, [.finish(.close, generation: g)])
        }
    }

    /// The page's "Leave site?" dialog came up. Only a dialog during a request counts: a page asks the same
    /// way when it navigates away.
    public mutating func dialogShown() -> [Effect] {
        guard case .waiting(let g) = phase else { return [] }
        phase = .asking(g)
        return [.cancelTimer]
    }

    /// The person answered the dialog. Call it before handing the answer to the engine, which resets the
    /// page's dialog state on the way (`dialogReset`).
    public mutating func answered(leave: Bool) -> [Effect] {
        guard case .asking(let g) = phase else { return [] }
        if leave {
            // Unload handlers still run; the same deadline covers a page that hangs in them.
            phase = .leaving(g)
            return [.armTimer(generation: g)]
        }
        phase = .idle
        return [.finish(.stay, generation: g)]
    }

    /// The engine dropped the page's dialogs (a navigation). Only a request whose dialog was showing is over.
    public mutating func dialogReset() -> [Effect] {
        guard case .asking(let g) = phase else { return [] }
        phase = .idle
        return [.finish(.stay, generation: g)]
    }

    /// The page let go: the engine is closing it (CEF's DoClose after a non-forced close).
    public mutating func pageLetGo() -> [Effect] {
        guard let g = pending else { return [] }
        phase = .closing
        return [.cancelTimer, .finish(.close, generation: g)]
    }

    public mutating func timerFired(generation g: Int) -> [Effect] {
        switch phase {
        case .waiting(g), .leaving(g): break
        default: return []
        }
        phase = .closing
        return [.forceClose, .finish(.close, generation: g)]
    }

    /// Something closed the page without asking (hibernation, quitting) while a request was in flight.
    public mutating func forced() -> [Effect] {
        guard let g = pending else {
            phase = .closing
            return []
        }
        phase = .closing
        return [.cancelTimer, .finish(.superseded, generation: g)]
    }
}

/// Asks a set of pages in turn whether they may close, all or nothing (closing a window that ends its tabs,
/// Clear Today): Chrome's window close. Only pages with a beforeunload handler are asked; the rest close only
/// once every asked page agreed, so Cancel leaves them as they were. A page that agreed is already closing.
public struct PageCloseChain<ID: Hashable & Sendable>: Sendable {
    public enum Step: Equatable, Sendable {
        case ask(ID)
        /// Every asked page agreed: close everything (`approved` are already closing).
        case proceed(approved: [ID])
        /// A page stayed: keep everything else. `approved` agreed before it and are closing.
        case stop(approved: [ID])
    }

    private var queue: [ID]
    public private(set) var approved: [ID] = []
    public private(set) var current: ID?

    /// `ordered` are the pages with handlers, the ones on screen first.
    public init(asking ordered: [ID]) { queue = ordered }

    /// The pages to ask, on-screen ones first; `hasHandler` says which pages registered beforeunload.
    public static func order(_ ids: [ID], shown: Set<ID>, hasHandler: Set<ID>) -> [ID] {
        let asked = ids.filter(hasHandler.contains)
        return asked.filter(shown.contains) + asked.filter { !shown.contains($0) }
    }

    public mutating func start() -> Step { next() }

    /// The current page's answer.
    public mutating func answered(_ outcome: PageClose.Outcome) -> Step {
        guard let id = current else { return next() }
        current = nil
        switch outcome {
        case .close:
            approved.append(id)
            return next()
        case .stay, .superseded:
            queue = []
            return .stop(approved: approved)
        }
    }

    private mutating func next() -> Step {
        guard !queue.isEmpty else { return .proceed(approved: approved) }
        let id = queue.removeFirst()
        current = id
        return .ask(id)
    }
}
