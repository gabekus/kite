import AppKit
import KiteCore
import SwiftUI

/// Arc's Profiles commands: File › New Profile (`newProfile:`), Spaces › Change Profile
/// (`changeProfileForCurrentSpace:`), and the space menu's Set Profile.
extension BrowserWindowController {
    @objc func newProfile(_ sender: Any?) {
        presentCreateProfile(for: store.state.selectedSpaceID)
    }

    @objc func changeProfileForCurrentSpace(_ sender: Any?) {
        let spaceID = store.state.selectedSpaceID
        presentSheet { [weak self] close in
            ChangeProfileView(store: self!.store, spaceID: spaceID) { choice in
                close()
                switch choice {
                case .cancel: break
                case .newProfile: self?.presentCreateProfile(for: spaceID)
                case .profile(let directory): self?.store.setProfile(directory, forSpace: spaceID)
                }
            }
        }
    }

    /// Settings' Profiles pane, in its own sheet until Kite has Arc's Settings window.
    @objc func showProfiles(_ sender: Any?) {
        presentSheet { [weak self] close in
            VStack(spacing: 0) {
                ProfilesListView(store: self!.store) {
                    close()
                    self?.presentCreateProfile(for: nil)
                }
                HStack {
                    Spacer()
                    Button("Done", action: close).keyboardShortcut(.defaultAction)
                }
                .padding([.horizontal, .bottom], 20)
            }
        }
    }

    /// The space menu's Set Profile: Arc asks first, with "Switch it up".
    func setProfile(_ directory: String?, forSpace id: UUID) {
        guard let window, let index = store.state.spaceIndex(id) else { return }
        let target = store.state.profile(directory).directory
        guard target != store.state.profileDirectory(ofSpace: index) else { return }
        let alert = NSAlert()
        alert.messageText = "Each Profile has different browser data, so your \(store.state.spaces[index].name) might look a little different!"
        alert.informativeText = "For example, you might get logged out of some websites, see different Favorites up top, or need to re-install an extension."
        alert.addButton(withTitle: "Switch it up")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.store.setProfile(target, forSpace: id)
        }
    }

    func presentCreateProfile(for spaceID: UUID?) {
        presentSheet { [weak self] close in
            CreateProfileView(store: self!.store, initialSpaces: Set(spaceID.map { [$0] } ?? [])) { _ in close() }
        }
    }

    /// A SwiftUI sheet on the window; `content` gets a function that closes it.
    private func presentSheet<Content: View>(_ content: (@escaping () -> Void) -> Content) {
        guard let window, window.attachedSheet == nil else { return NSSound.beep() }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let close = { [weak window, weak sheet] in
            guard let sheet else { return }
            window?.endSheet(sheet)
        }
        let host = NSHostingController(rootView: content(close))
        sheet.contentViewController = host
        sheet.setContentSize(host.view.fittingSize)
        window.beginSheet(sheet)
    }

    func validateProfileItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(newProfile(_:)), #selector(changeProfileForCurrentSpace(_:)), #selector(showProfiles(_:)):
            return !isIncognito
        default:
            return nil
        }
    }
}

/// The space menu's Set Profile submenu: every profile, the space's own ticked, then New Profile….
struct SetProfileMenu: View {
    let store: BrowserStore
    let actions: SidebarActions
    let space: Space

    var body: some View {
        Menu("Set Profile") {
            let current = store.state.spaceIndex(space.id).map(store.state.profileDirectory(ofSpace:))
            ForEach(store.state.allProfiles) { profile in
                Toggle(profile.name, isOn: Binding(
                    get: { profile.directory == current },
                    set: { _ in actions.setProfile(space.id, profile.directory) }
                ))
            }
            Divider()
            Button("New Profile…") { actions.newProfile(space.id) }
        }
    }
}
