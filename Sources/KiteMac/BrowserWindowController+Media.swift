import AppKit
import KiteCore

/// The sidebar's Mini Player and automatic picture in picture.
extension BrowserWindowController {
    /// Arc's `autoPipGloballyDisabled` (default off, so auto picture in picture is on).
    static let autoPictureInPictureDisabledKey = "autoPictureInPictureDisabled"
    /// Arc's `autoPipDisabledForHosts`: hosts that never pop out on their own.
    static let autoPictureInPictureDisabledHostsKey = "autoPictureInPictureDisabledHosts"

    var miniPlayerActions: MiniPlayerActions {
        MiniPlayerActions(
            backToTab: { [weak self] id in self?.store.mutate { $0.select(tab: id) } },
            command: { [weak self] id, command in self?.pool.loadedPage(id)?.runMediaCommand(command) },
            toggleMute: { [weak self] id in self?.toggleMute(id) },
            setVolume: { [weak self] id, level in self?.setTabVolume(id, level) },
            close: { [weak self] id in
                // Closing the player stops what it was playing (it'd otherwise play on with no controls).
                self?.pool.loadedPage(id)?.runMediaCommand(.pause)
                self?.store.dismissMiniPlayer(id)
            }
        )
    }

    func toggleMute(_ id: UUID) {
        guard let page = pool.loadedPage(id) else { return }
        page.isAudioMuted.toggle()
        let muted = page.isAudioMuted
        store.updatePage(id) { $0.isAudioMuted = muted }
    }

    /// Arc's command-bar Mute All Tabs: every live page in this window, in all its spaces.
    @objc func muteAllTabs(_ sender: Any?) { setAllTabsMuted(true) }

    /// Arc's command-bar Unmute All Tabs.
    @objc func unmuteAllTabs(_ sender: Any?) { setAllTabsMuted(false) }

    func setAllTabsMuted(_ muted: Bool) {
        let live = pool.livePages
        for id in MuteAllTabs.pagesToChange(live.mapValues(\.isAudioMuted), mute: muted) {
            live[id]?.isAudioMuted = muted
            store.updatePage(id) { $0.isAudioMuted = muted }
        }
    }

    /// Arc's "Adjust Tab Volume" slider: scales everything the tab plays (TabVolume).
    func setTabVolume(_ id: UUID, _ level: Double) {
        guard let page = pool.loadedPage(id) else { return }
        let level = TabVolume.clamp(level)
        store.updatePage(id) { $0.tabVolume = level }
        page.runMediaCommand(.setVolume(level))
    }

    /// Tabs left the screen or came onto it (switching tabs, spaces or split panes).
    func tabsChangedOnScreen(left: [UUID], arrived: [UUID]) {
        store.tabsLeftScreen(left)
        let defaults = UserDefaults.standard
        let disabled = defaults.bool(forKey: Self.autoPictureInPictureDisabledKey)
        let hosts = Set((defaults.stringArray(forKey: Self.autoPictureInPictureDisabledHostsKey) ?? []).map { $0.lowercased() })
        for id in left {
            let media = store.pages[id]?.media?.state
            guard AutoPictureInPicture.shouldEnter(media, host: store.state.tab(id)?.url?.host(), globallyDisabled: disabled, disabledHosts: hosts),
                  let page = pool.loadedPage(id) else { continue }
            page.runMediaCommand(.enterPictureInPicture)
            autoPictureInPictureTabs.insert(id)
        }
        for id in arrived where autoPictureInPictureTabs.remove(id) != nil {
            pool.loadedPage(id)?.runMediaCommand(.exitPictureInPicture)
        }
    }
}
