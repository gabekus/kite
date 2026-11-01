import Foundation

/// What a tab's page is playing, as its media script reports it (MediaStateScript).
///
/// One element per page: the one that played last. nil in PageStatus means the page has
/// nothing that ever played (or it was removed, or the page navigated). It's the shared
/// base for the sidebar Mini Player, tab audio indicators and a media list.
public struct MediaState: Equatable, Sendable {
    public var isPlaying: Bool
    /// A `<video>` with a picture (not an audio-only element or a video without frames).
    public var hasVideo: Bool
    /// The page muted the element itself or set its volume to 0 (not the browser's tab mute).
    public var isElementMuted: Bool
    public var isInPictureInPicture: Bool
    /// From the page's Media Session metadata, falling back to the document title.
    public var title: String
    public var artist: String?
    public var artworkURL: URL?
    /// Media Session actions the page handles itself (previous / next track).
    public var actions: Set<MediaAction>

    public init(
        isPlaying: Bool, hasVideo: Bool = false, isElementMuted: Bool = false, isInPictureInPicture: Bool = false,
        title: String = "", artist: String? = nil, artworkURL: URL? = nil, actions: Set<MediaAction> = []
    ) {
        self.isPlaying = isPlaying
        self.hasVideo = hasVideo
        self.isElementMuted = isElementMuted
        self.isInPictureInPicture = isInPictureInPicture
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.actions = actions
    }

    /// Whether you'd hear it (before the browser's tab mute).
    public var isAudible: Bool { isPlaying && !isElementMuted }

    /// Parses the script's report. `.some(nil)` is "no media"; nil is a payload that isn't a report.
    public static func parse(_ payload: String) -> MediaState?? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        if object is NSNull { return .some(nil) }
        guard let report = object as? [String: Any], let playing = report["playing"] as? Bool else { return nil }
        let text = { (key: String) -> String? in
            (report[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        // Artwork is shown in Kite's own UI, so only web URLs (no javascript:, file:).
        let artwork = text("artwork").flatMap(URL.init(string:)).flatMap { ["http", "https", "data"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        return .some(MediaState(
            isPlaying: playing,
            hasVideo: report["video"] as? Bool ?? false,
            isElementMuted: report["muted"] as? Bool ?? false,
            isInPictureInPicture: report["pip"] as? Bool ?? false,
            title: String((text("title") ?? "").prefix(300)),
            artist: text("artist").map { String($0.prefix(300)) },
            artworkURL: artwork,
            actions: Set((report["actions"] as? [String] ?? []).compactMap(MediaAction.init(rawValue:)))
        ))
    }
}

/// Media Session actions Kite can ask a page to run.
public enum MediaAction: String, Sendable, CaseIterable {
    case previousTrack = "previoustrack"
    case nextTrack = "nexttrack"
}

/// What the Mini Player (and auto picture in picture) asks a page to do.
public enum MediaCommand: String, Sendable {
    case play
    case pause
    case previousTrack = "previoustrack"
    case nextTrack = "nexttrack"
    case enterPictureInPicture = "enterpip"
    case exitPictureInPicture = "exitpip"

    /// Runs the command in the media script's world.
    public var script: String { "globalThis.__kiteMedia?.run('\(rawValue)')" }
}

/// When a tab's media last started and stopped playing.
public struct MediaActivity: Equatable, Sendable {
    public var state: MediaState
    public var startedAt: Date
    public var stoppedAt: Date?

    public init(state: MediaState, startedAt: Date, stoppedAt: Date? = nil) {
        self.state = state
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
    }

    /// Applies a new report at `now`. Returns nil when the page has no media any more.
    public static func update(_ activity: MediaActivity?, with state: MediaState?, now: Date) -> MediaActivity? {
        guard let state else { return nil }
        guard var activity else {
            return MediaActivity(state: state, startedAt: now, stoppedAt: state.isPlaying ? nil : now)
        }
        if state.isPlaying, !activity.state.isPlaying {
            activity.startedAt = now
            activity.stoppedAt = nil
        } else if !state.isPlaying, activity.state.isPlaying {
            activity.stoppedAt = now
        }
        activity.state = state
        return activity
    }
}

/// Arc's Mini Player: the media of a tab you left, at the bottom of the sidebar.
public enum MiniPlayer {
    /// The tab the Mini Player shows: of the tabs that aren't on screen and that were playing
    /// when you left them or played since, the one that most recently started playing.
    /// A tab you paused from the Mini Player keeps it; a tab whose player was closed
    /// (`dismissed`) gets it back when it starts playing again (the caller clears it).
    /// - Parameters:
    ///   - visible: the tabs on screen (the selected tab, or its split's panes).
    ///   - hiddenAt: when each tab last left the screen.
    public static func tab(media: [UUID: MediaActivity], visible: Set<UUID>, hiddenAt: [UUID: Date], dismissed: Set<UUID>) -> UUID? {
        media
            .filter { id, activity in
                guard !visible.contains(id), !dismissed.contains(id) else { return false }
                return activity.state.isPlaying || (activity.stoppedAt ?? .distantPast) > (hiddenAt[id] ?? .distantPast)
            }
            .max { $0.value.startedAt < $1.value.startedAt }?
            .key
    }
}

/// Arc pops a playing video into picture in picture when you leave its tab
/// (`autoPipGloballyDisabled`, `autoPipDisabledForHosts` in Arc's preferences).
public enum AutoPictureInPicture {
    public static func shouldEnter(_ media: MediaState?, host: String?, globallyDisabled: Bool, disabledHosts: Set<String>) -> Bool {
        guard !globallyDisabled, let media, media.isPlaying, media.hasVideo, !media.isInPictureInPicture else { return false }
        guard let host = host?.lowercased() else { return true }
        return !disabledHosts.contains(host)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
