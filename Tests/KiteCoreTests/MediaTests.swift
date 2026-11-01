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
