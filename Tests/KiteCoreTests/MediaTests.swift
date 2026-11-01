import Foundation
import Testing
@testable import KiteCore

@Suite struct MediaTests {
    @Test func parsesAReport() throws {
        let payload = #"{"playing":true,"video":true,"muted":false,"pip":false,"title":" Song ","artist":"Band","artwork":"https://i.example/a.jpg","actions":["nexttrack","seekto"]}"#
        let state = try #require(MediaState.parse(payload) ?? nil)
        #expect(state.isPlaying && state.hasVideo && state.isAudible)
        #expect(state.title == "Song")
        #expect(state.artist == "Band")
        #expect(state.artworkURL == URL(string: "https://i.example/a.jpg"))
        #expect(state.actions == [.nextTrack])
    }

    @Test func nullIsNoMediaAndGarbageIsIgnored() {
        #expect(MediaState.parse("null").map { $0 == nil } == true)
        #expect(MediaState.parse("{\"title\":\"x\"}") == nil)
        #expect(MediaState.parse("not json") == nil)
    }

    @Test func dropsArtworkThatIsntAWebURL() throws {
        let state = try #require(MediaState.parse(#"{"playing":false,"artwork":"javascript:alert(1)"}"#) ?? nil)
        #expect(state.artworkURL == nil)
        #expect(!state.isAudible)
    }

    @Test func activityTracksStartAndStop() throws {
        let t0 = Date(timeIntervalSince1970: 0)
        var activity = MediaActivity.update(nil, with: MediaState(isPlaying: true), now: t0)
        #expect(activity?.startedAt == t0 && activity?.stoppedAt == nil)
        activity = MediaActivity.update(activity, with: MediaState(isPlaying: false), now: t0 + 5)
        #expect(activity?.startedAt == t0 && activity?.stoppedAt == t0 + 5)
        activity = MediaActivity.update(activity, with: MediaState(isPlaying: true), now: t0 + 9)
        #expect(activity?.startedAt == t0 + 9 && activity?.stoppedAt == nil)
        #expect(MediaActivity.update(activity, with: nil, now: t0 + 10) == nil)
    }

    @Test func miniPlayerShowsTheLatestTabYouLeftPlaying() {
        let t0 = Date(timeIntervalSince1970: 0)
        let a = UUID(), b = UUID(), c = UUID()
        let media: [UUID: MediaActivity] = [
            a: MediaActivity(state: MediaState(isPlaying: true), startedAt: t0),
            b: MediaActivity(state: MediaState(isPlaying: true), startedAt: t0 + 1),
            // Paused before it was left: no player.
            c: MediaActivity(state: MediaState(isPlaying: false), startedAt: t0 + 2, stoppedAt: t0 + 3),
        ]
        let hidden = [a: t0 + 4, b: t0 + 4, c: t0 + 4]
        #expect(MiniPlayer.tab(media: media, visible: [], hiddenAt: hidden, dismissed: []) == b)
        #expect(MiniPlayer.tab(media: media, visible: [b], hiddenAt: hidden, dismissed: []) == a)
        #expect(MiniPlayer.tab(media: media, visible: [], hiddenAt: hidden, dismissed: [a, b]) == nil)
    }

    @Test func pausingFromTheMiniPlayerKeepsIt() {
        let t0 = Date(timeIntervalSince1970: 0)
        let a = UUID()
        let media = [a: MediaActivity(state: MediaState(isPlaying: false), startedAt: t0, stoppedAt: t0 + 8)]
        #expect(MiniPlayer.tab(media: media, visible: [], hiddenAt: [a: t0 + 5], dismissed: []) == a)
    }

    @Test func autoPictureInPictureOnlyForPlayingVideo() {
        let video = MediaState(isPlaying: true, hasVideo: true)
        #expect(AutoPictureInPicture.shouldEnter(video, host: "youtube.com", globallyDisabled: false, disabledHosts: []))
        #expect(!AutoPictureInPicture.shouldEnter(video, host: "youtube.com", globallyDisabled: true, disabledHosts: []))
        #expect(!AutoPictureInPicture.shouldEnter(video, host: "YouTube.com", globallyDisabled: false, disabledHosts: ["youtube.com"]))
        #expect(!AutoPictureInPicture.shouldEnter(MediaState(isPlaying: true), host: nil, globallyDisabled: false, disabledHosts: []))
        #expect(!AutoPictureInPicture.shouldEnter(MediaState(isPlaying: false, hasVideo: true), host: nil, globallyDisabled: false, disabledHosts: []))
        #expect(!AutoPictureInPicture.shouldEnter(nil, host: nil, globallyDisabled: false, disabledHosts: []))
    }

    @Test func commandScriptsCallTheMediaWorld() {
        #expect(MediaCommand.enterPictureInPicture.script == "globalThis.__kiteMedia?.run('enterpip')")
    }
}

@Suite struct TabAudioButtonTests {
    @Test func shownWhileAudibleOrMuted() {
        #expect(!TabAudioButton.isShown(isAudible: false, isMuted: false))
        #expect(TabAudioButton.isShown(isAudible: true, isMuted: false))
        #expect(TabAudioButton.isShown(isAudible: false, isMuted: true))
        #expect(TabAudioButton.isShown(isAudible: true, isMuted: true))
    }

    @Test func arcsWording() {
        #expect(TabAudioButton.tooltip(isMuted: false) == "Mute this tab")
        #expect(TabAudioButton.tooltip(isMuted: true) == "Unmute this tab")
        #expect(TabAudioButton.menuTitle(isMuted: false) == "Mute")
        #expect(TabAudioButton.menuTitle(isMuted: true) == "Unmute")
    }

    @Test func arcsGeometry() {
        #expect(TabAudioButton.side == 24)
        #expect(TabAudioButton.spacingAfter == 2)
        #expect(TabAudioButton.showHideDuration == 0.18)
    }

    @Test func volumeCommandScript() {
        #expect(MediaCommand.setVolume(0.25).script == "globalThis.__kiteMedia?.run('volume', 0.25)")
        #expect(MediaCommand.setVolume(3).script == "globalThis.__kiteMedia?.run('volume', 1.0)")
        #expect(MediaCommand.setVolume(.nan).script == "globalThis.__kiteMedia?.run('volume', 1.0)")
        #expect(MediaCommand.pause.script == "globalThis.__kiteMedia?.run('pause')")
    }

    @Test func parsesVolumes() throws {
        let state = try #require(MediaState.parse(#"{"playing":true,"volume":0.4,"level":0.5}"#) ?? nil)
        #expect(state.volume == 0.4 && state.tabVolume == 0.5)
        let old = try #require(MediaState.parse(#"{"playing":true}"#) ?? nil)
        #expect(old.volume == 1 && old.tabVolume == 1)
        let wild = try #require(MediaState.parse(#"{"playing":true,"level":7}"#) ?? nil)
        #expect(wild.tabVolume == 1)
    }

    @Test func volumeSymbolsFollowArcsThresholds() {
        #expect(TabVolume.symbol(volume: 0.5, isMuted: true) == "speaker.slash.fill")
        #expect(TabVolume.symbol(volume: 0, isMuted: false) == "speaker.fill")
        #expect(TabVolume.symbol(volume: 0.2, isMuted: false) == "speaker.wave.1.fill")
        #expect(TabVolume.symbol(volume: 0.5, isMuted: false) == "speaker.wave.2.fill")
        #expect(TabVolume.symbol(volume: 2.0 / 3, isMuted: false) == "speaker.wave.3.fill")
        #expect(TabVolume.symbol(volume: 1, isMuted: false) == "speaker.wave.3.fill")
    }

    @Test func reappliesOnlyWhenThePageDiffers() {
        #expect(!TabVolume.needsReapply(tab: 1, reported: 1))
        #expect(TabVolume.needsReapply(tab: 0.3, reported: 1))
        #expect(!TabVolume.needsReapply(tab: 0.3, reported: 0.3))
    }
}

@Suite struct MuteAllTabsTests {
    @Test func arcsTitles() {
        #expect(MuteAllTabs.title(mute: true) == "Mute All Tabs")
        #expect(MuteAllTabs.title(mute: false) == "Unmute All Tabs")
    }

    @Test func changesOnlyPagesNotAlreadyThere() {
        let pages = ["a": false, "b": true, "c": false]
        #expect(Set(MuteAllTabs.pagesToChange(pages, mute: true)) == ["a", "c"])
        #expect(MuteAllTabs.pagesToChange(pages, mute: false) == ["b"])
        #expect(MuteAllTabs.pagesToChange([String: Bool](), mute: true).isEmpty)
    }
}

@Suite struct CallControlsTests {
    @Test func parsesTheCallReport() throws {
        let call = try #require(CallControls.parse(#"{"call":{"actions":["togglemicrophone"],"mic":true,"cam":false}}"#))
        #expect(call == CallControls(canToggleMicrophone: true, canToggleCamera: false, isMicrophoneOn: true, isCameraOn: false))
        #expect(CallControls.parse(#"{"call":{"actions":[]}}"#) == CallControls())
    }

    @Test func otherPayloadsArentCallReports() {
        #expect(CallControls.parse("null") == nil)
        #expect(CallControls.parse(#"{"playing":true}"#) == nil)
        #expect(CallControls.parse("nope") == nil)
        // The media report ignores the call report.
        #expect(MediaState.parse(#"{"call":{"actions":[]}}"#) == nil)
    }

    @Test func arcsSymbolsAndTooltips() {
        var call = CallControls(canToggleMicrophone: true, canToggleCamera: true, isMicrophoneOn: true, isCameraOn: true)
        #expect(call.microphoneSymbol == "mic.fill" && call.cameraSymbol == "video.fill")
        call.isMicrophoneOn = false
        call.isCameraOn = false
        #expect(call.microphoneSymbol == "mic.slash.fill" && call.cameraSymbol == "video.slash.fill")
        // Slashed only when the page can toggle it.
        #expect(CallControls().microphoneSymbol == "mic.fill" && CallControls().cameraSymbol == "video.fill")
        #expect(CallControls.microphoneHelp == "Toggle Microphone" && CallControls.cameraHelp == "Toggle Camera")
    }

    @Test func toggleCommandsRunThePagesHandlers() {
        #expect(MediaCommand.toggleMicrophone.script == "globalThis.__kiteMedia?.run('togglemicrophone')")
        #expect(MediaCommand.toggleCamera.script == "globalThis.__kiteMedia?.run('togglecamera')")
    }

    @Test func aTabInACallYouLeftGetsTheMiniPlayer() {
        let call = UUID(), music = UUID()
        let t0 = Date(timeIntervalSince1970: 1000)
        let media = [music: MediaActivity(state: MediaState(isPlaying: true), startedAt: t0)]
        let capturing = [call: t0 + 10]
        #expect(MiniPlayer.tab(media: media, capturing: capturing, visible: [], hiddenAt: [:], dismissed: []) == call)
        #expect(MiniPlayer.tab(media: media, capturing: capturing, visible: [call], hiddenAt: [:], dismissed: []) == music)
        #expect(MiniPlayer.tab(media: [:], capturing: capturing, visible: [], hiddenAt: [:], dismissed: [call]) == nil)
        // A call that started earlier than the music loses to it, as playing tabs do.
        #expect(MiniPlayer.tab(media: media, capturing: [call: t0 - 10], visible: [], hiddenAt: [:], dismissed: []) == music)
    }
}
