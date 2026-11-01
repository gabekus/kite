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
    /// Runs the page's own Media Session `togglemicrophone` / `togglecamera` handler (CallControls).
    case toggleMicrophone
    case toggleCamera

    /// Runs the command in the media script's world.
    public var script: String {
        switch self {
        case .play: return run("play")
        case .pause: return run("pause")
        case .previousTrack: return run("previoustrack")
        case .nextTrack: return run("nexttrack")
        case .enterPictureInPicture: return run("enterpip")
        case .exitPictureInPicture: return run("exitpip")
        case .toggleMicrophone: return run(CallControls.toggleMicrophoneAction)
        case .toggleCamera: return run(CallControls.toggleCameraAction)
        case .setVolume(let level):
            // A plain number literal: never NaN or infinity, which aren't valid JavaScript here.
            let value = TabVolume.clamp(level)
            return "globalThis.__kiteMedia?.run('volume', \(value))"
        }
    }

    private func run(_ name: String) -> String { "globalThis.__kiteMedia?.run('\(name)')" }
}

/// A call's microphone and camera buttons in the Mini Player (Arc 1.171 MiniPlayerView: "Toggle
/// Microphone" / "Toggle Camera", state `canToggleMicrophone`, `canToggleCamera`, `isMicrophoneOn`,
/// `isCameraOn`). Arc takes them from Chromium's Media Session: the page's `togglemicrophone` /
/// `togglecamera` action handlers and its `setMicrophoneActive` / `setCameraActive` calls (Google
/// Meet makes both), and a click runs the page's handler (ADKClient.toggleMicrophone). Kite's media
/// script reports the same from the page. See docs/arc-visual-spec.md.
public struct CallControls: Equatable, Sendable {
    public static let toggleMicrophoneAction = "togglemicrophone"
    public static let toggleCameraAction = "togglecamera"

    public var canToggleMicrophone: Bool
    public var canToggleCamera: Bool
    /// What the page last told `setMicrophoneActive` / `setCameraActive` (off until it says).
    public var isMicrophoneOn: Bool
    public var isCameraOn: Bool

    public init(canToggleMicrophone: Bool = false, canToggleCamera: Bool = false, isMicrophoneOn: Bool = false, isCameraOn: Bool = false) {
        self.canToggleMicrophone = canToggleMicrophone
        self.canToggleCamera = canToggleCamera
        self.isMicrophoneOn = isMicrophoneOn
        self.isCameraOn = isCameraOn
    }

    /// Parses the media script's call report (`{"call": {"actions": [...], "mic": bool, "cam": bool}}`).
    /// nil for any other payload, so it can share the media report's channel.
    public static func parse(_ payload: String) -> CallControls? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let call = object["call"] as? [String: Any] else { return nil }
        let actions = Set(call["actions"] as? [String] ?? [])
        return CallControls(
            canToggleMicrophone: actions.contains(toggleMicrophoneAction),
            canToggleCamera: actions.contains(toggleCameraAction),
            isMicrophoneOn: call["mic"] as? Bool ?? false,
            isCameraOn: call["cam"] as? Bool ?? false
        )
    }

    /// Arc slashes the symbol only when the page can toggle it and says it's off.
    public var microphoneSymbol: String { canToggleMicrophone && !isMicrophoneOn ? "mic.slash.fill" : "mic.fill" }
    public var cameraSymbol: String { canToggleCamera && !isCameraOn ? "video.slash.fill" : "video.fill" }

    public static let microphoneHelp = "Toggle Microphone"
    public static let cameraHelp = "Toggle Camera"
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
    ///   - capturing: tabs using the camera or microphone now (Arc's `Recording` media type), with
    ///     when they started; they count as playing from then.
    public static func tab(
        media: [UUID: MediaActivity], capturing: [UUID: Date] = [:], visible: Set<UUID>, hiddenAt: [UUID: Date], dismissed: Set<UUID>
    ) -> UUID? {
        var started: [UUID: Date] = [:]
        for (id, activity) in media where activity.state.isPlaying || (activity.stoppedAt ?? .distantPast) > (hiddenAt[id] ?? .distantPast) {
            started[id] = activity.startedAt
        }
        for (id, date) in capturing { started[id] = max(started[id] ?? .distantPast, date) }
        return started
            .filter { !visible.contains($0.key) && !dismissed.contains($0.key) }
            .max { $0.value < $1.value }?
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

    /// Arc's animated speaker (ARCUI `SidebarCellSpeakerIconWrapperView`): SF `speaker` with three
    /// sound waves that spring out while the tab plays and a slash that draws across it when muted.
    /// Numbers from Arc 1.171's disassembly; see docs/arc-visual-spec.md.
    public enum Speaker {
        /// The speaker moves this far left while the waves show (0 when muted).
        public static let playingOffset = -4.0
        /// Each wave's frame (8 × 12), and its x offset shown and hidden (waves 1–3).
        public static let waveSize = (width: 8.0, height: 12.0)
        public static let waveShownOffset = 5.0
        public static let waveHiddenOffsets = [2.0, 3.0, 4.0]
        /// Waves and speaker: `spring(response: 0.3, dampingFraction: 0.6)`.
        public static let waveSpring = (response: 0.3, damping: 0.6)
        /// The slash: `spring(0.3, 0.65)` drawing in, `spring(0.25, 0.7)` going away.
        public static let slashInSpring = (response: 0.3, damping: 0.65)
        public static let slashOutSpring = (response: 0.25, damping: 0.7)
        /// Wave n waits n × stagger (plus `waveShowDelay` when showing). Arc takes both from its
        /// caller; their values weren't found, so these are inferred.
        public static let waveStagger = 0.05
        public static let waveShowDelay = 0.05
        /// The slash waits this long after muting (from Arc's caller too; inferred).
        public static let slashDelay = 0.1

        /// Arc's SlashShape: a capsule at 45° from the top-left corner, as thick as 3.5/40 of the
        /// box (twice that, and 1/4.5 of it longer at each end, for the gap it cuts in the speaker),
        /// as long as `progress` of the box's diagonal.
        public static func slashThickness(boxWidth: Double, cutout: Bool) -> Double {
            boxWidth * 3.5 / (cutout ? 20 : 40)
        }

        public static func slashLength(boxWidth: Double, progress: Double, cutout: Bool) -> Double {
            let overhang = cutout ? slashThickness(boxWidth: boxWidth, cutout: true) / 4.5 : 0
            return progress * 2.0.squareRoot() * boxWidth + 2 * overhang
        }

        /// The delay before wave `index` (0–2) springs out (`showing`) or back.
        public static func waveDelay(index: Int, showing: Bool) -> Double {
            Double(index) * waveStagger + (showing ? waveShowDelay : 0)
        }
    }
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
