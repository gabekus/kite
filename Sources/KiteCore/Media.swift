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
    /// The element's own `volume` as it plays now (the page's volume times the tab volume), 0...1.
    public var volume: Double
    /// The tab volume the page's media script applies (Mini Player's "Adjust Tab Volume"), 0...1.
    /// The script starts at 1 on every page load, so Kite sends its level again when they differ.
    public var tabVolume: Double

    public init(
        isPlaying: Bool, hasVideo: Bool = false, isElementMuted: Bool = false, isInPictureInPicture: Bool = false,
        title: String = "", artist: String? = nil, artworkURL: URL? = nil, actions: Set<MediaAction> = [],
        volume: Double = 1, tabVolume: Double = 1
    ) {
        self.isPlaying = isPlaying
        self.hasVideo = hasVideo
        self.isElementMuted = isElementMuted
        self.isInPictureInPicture = isInPictureInPicture
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.actions = actions
        self.volume = volume
        self.tabVolume = tabVolume
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
            actions: Set((report["actions"] as? [String] ?? []).compactMap(MediaAction.init(rawValue:))),
            volume: TabVolume.clamp((report["volume"] as? NSNumber)?.doubleValue ?? 1),
            tabVolume: TabVolume.clamp((report["level"] as? NSNumber)?.doubleValue ?? 1)
        ))
    }
}

/// Media Session actions Kite can ask a page to run.
public enum MediaAction: String, Sendable, CaseIterable {
    case previousTrack = "previoustrack"
    case nextTrack = "nexttrack"
}

/// What the Mini Player (and auto picture in picture) asks a page to do.
public enum MediaCommand: Equatable, Sendable {
    case play
    case pause
    case previousTrack
    case nextTrack
    case enterPictureInPicture
    case exitPictureInPicture
    /// Scales every media element on the page to this tab volume (0...1); see TabVolume.
    case setVolume(Double)

    /// Runs the command in the media script's world.
    public var script: String {
        switch self {
        case .play: return run("play")
        case .pause: return run("pause")
        case .previousTrack: return run("previoustrack")
        case .nextTrack: return run("nexttrack")
        case .enterPictureInPicture: return run("enterpip")
        case .exitPictureInPicture: return run("exitpip")
        case .setVolume(let level):
            // A plain number literal: never NaN or infinity, which aren't valid JavaScript here.
            let value = TabVolume.clamp(level)
            return "globalThis.__kiteMedia?.run('volume', \(value))"
        }
    }

    private func run(_ name: String) -> String { "globalThis.__kiteMedia?.run('\(name)')" }
}

/// Arc's per-tab volume (Mini Player "Adjust Tab Volume", MediaControlsFeature, Arc 1.171):
/// a 0...1 level that scales what the tab plays. Arc sets it on the tab's web contents
/// (ADKClient.setVolume); Kite's media script multiplies each media element's own volume by it.
/// It lives as long as the tab's page, like the tab's mute. See docs/arc-visual-spec.md.
public enum TabVolume {
    /// Arc's Slider runs over 0...1 with no step.
    public static let range: ClosedRange<Double> = 0...1

    public static func clamp(_ level: Double) -> Double {
        guard level.isFinite else { return 1 }
        return min(max(level, range.lowerBound), range.upperBound)
    }

    /// The speaker symbol Arc shows for the tab's volume (its MiniPlayerView picks it from
    /// `isMuted` and `volume`): slashed when muted, no waves at 0, then one, two or three
    /// waves split at 1/3 and 2/3.
    public static func symbol(volume: Double, isMuted: Bool) -> String {
        if isMuted { return "speaker.slash.fill" }
        if volume == 0 { return "speaker.fill" }
        if volume < 1.0 / 3 { return "speaker.wave.1.fill" }
        if volume >= 2.0 / 3, volume <= 1 { return "speaker.wave.3.fill" }
        return "speaker.wave.2.fill"
    }

    /// Whether the page's script runs a different level from the tab's (it starts again at 1
    /// after every navigation), so Kite should send the tab's level again.
    public static func needsReapply(tab: Double, reported: Double) -> Bool {
        abs(clamp(tab) - clamp(reported)) > 0.0005
    }
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

/// Arc's sidebar tab audibility button (TabCellView.audibilityButton, Arc 1.171): a 24pt
/// square speaker between the favicon and the title, shown while the tab is audible or
/// muted; clicking it toggles the tab's mute. See docs/arc-visual-spec.md.
public enum TabAudioButton {
    /// Width and height (Arc: both constraints are 24, the same constant as the close button).
    public static let side = 24.0
    /// Arc's custom spacing after the button in the tab's body stack (to the title).
    public static let spacingAfter = 2.0
    /// Arc animates the button in and out with an NSAnimationContext of 0.18s.
    public static let showHideDuration = 0.18

    /// Arc's TabCellState carries `isAudible` and `isMuted`: the button is there for either
    /// (a muted tab keeps it so it can be unmuted).
    public static func isShown(isAudible: Bool, isMuted: Bool) -> Bool { isAudible || isMuted }

    /// Arc's hover tooltips ("Tooltip; mutes the tab." / "Tooltip; unmutes the tab.").
    public static func tooltip(isMuted: Bool) -> String { isMuted ? "Unmute this tab" : "Mute this tab" }

    /// Arc's sidebar context menu items ("Context menu action to mute the selected tab" /
    /// "... to unmute a tab").
    public static func menuTitle(isMuted: Bool) -> String { isMuted ? "Unmute" : "Mute" }
}

/// Arc's command-bar actions Mute All Tabs / Unmute All Tabs (actions `muteAllTabs` / `unmuteAllTabs`,
/// "Action to mute all tabs", Arc 1.171): not in Arc's menu bar or sidebar menus. Kite applies them to every
/// live page in the window (all its spaces). See docs/arc-visual-spec.md.
public enum MuteAllTabs {
    /// Arc's action titles (built in code as "Mute All Tabs" / "Unmute All Tabs").
    public static func title(mute: Bool) -> String { mute ? "Mute All Tabs" : "Unmute All Tabs" }

    /// The pages to change so every page's mute is `mute`, given each page's current mute.
    public static func pagesToChange<ID: Hashable>(_ muted: [ID: Bool], mute: Bool) -> [ID] {
        muted.compactMap { $0.value == mute ? nil : $0.key }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
