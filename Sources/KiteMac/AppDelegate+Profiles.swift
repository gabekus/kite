#if canImport(CEFBridge)
import AppKit
import KiteCore

/// Arc's Profiles on the app side: each profile's engine gets its own extensions tabs bridge and
/// 1Password, and the menu bar's Extensions menu follows the front window's profile.
extension AppDelegate {
    /// Readies a profile's engine the first time a window shows one of its spaces.
    func prepareProfile(_ engine: WebEngine) {
        guard let profile = engine.profileDirectory, extensionTabs[profile] == nil,
              let host = windowController else { return }
        let bridge = ExtensionTabsBridge(host: host)
        bridge.start(engine: engine)
        extensionTabs[profile] = bridge
        // Once the window is up, so Chrome's "Add 1Password?" dialog has somewhere to hang.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { OnePasswordIntegration.installIfNeeded(engine: engine) }
    }

    func followProfiles(of controller: BrowserWindowController) {
        controller.onProfileChange = { [weak self, weak controller] engine in
            guard let self else { return }
            self.prepareProfile(engine)
            if controller?.window?.isKeyWindow == true || controller === self.windowController {
                self.extensionsMenu?.show(ExtensionsModel.shared(engine: engine))
            }
        }
        // The window may already be on another profile's space.
        let engine = controller.pool.currentEngine
        if engine.profileDirectory != Profile.defaultDirectory { controller.onProfileChange?(engine) }
    }
}
#endif
