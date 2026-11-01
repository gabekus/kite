import AppKit
import KiteCore
import SwiftUI

// Arc's profile dialogs (ARC_ProfilesUI: ProfileCreationSheetWindow, ProfileChangeSheetWindow).
// Wording and buttons are Arc's, read from its binary (the localized keys next to their comments):
// "Create a new Profile", "What do you want to call this Profile?" (placeholder "Personal"),
// Next / Back / Create Profile, "Which Spaces should use this Profile?", and for changing a
// space's profile "Change Profile" / "Cancel" with a "New Profile" option. Layout is not
// measured from Arc yet: it follows a macOS sheet.

private enum M {
    static let width: CGFloat = 420
    static let padding: CGFloat = 20
}

/// Create a new Profile: name it, then pick the spaces that use it.
struct CreateProfileView: View {
    let store: BrowserStore
    /// Spaces ticked to start with (the space it was opened from).
    let initialSpaces: Set<UUID>
    let finish: (Profile?) -> Void

    @State private var step = 0
    @State private var name = ""
    @State private var spaces: Set<UUID> = []
    @State private var error: ProfileNameError?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create a new Profile").font(.system(size: 15, weight: .semibold))
            if step == 0 { nameStep } else { spacesStep }
            HStack {
                Button("Cancel") { finish(nil) }.keyboardShortcut(.cancelAction)
                Spacer()
                if step == 1 { Button("Back") { step = 0 } }
                Button(step == 0 ? "Next" : "Create Profile", action: advance)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(M.padding)
        .frame(width: M.width)
        .onAppear {
            spaces = initialSpaces
            nameFocused = true
        }
    }

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Profiles make your Spaces truly separate — with their own history, saved passwords, extensions, and other browsing data. No more flipping between work and personal accounts!")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("What do you want to call this Profile?").font(.system(size: 13, weight: .medium))
            TextField("Personal", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(advance)
                .onChange(of: name) { _, _ in error = nil }
                .accessibilityLabel("Profile name")
            if let error {
                Text(error.message).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
    }

    private var spacesStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which Spaces should use this Profile?").font(.system(size: 13, weight: .medium))
            Text("These Spaces will start fresh in your brand new Profile — so you’ll have to log back in to websites, re-save your passwords, add extensions, etc. You can always switch back to your previous Profile though if you forgot something!")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(store.state.spaces) { space in
                    Toggle(isOn: Binding(
                        get: { spaces.contains(space.id) },
                        set: { if $0 { spaces.insert(space.id) } else { spaces.remove(space.id) } }
                    )) {
                        Text("\(space.icon)  \(space.name)")
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func advance() {
        if let problem = store.state.validateProfileName(name) {
            error = problem
            step = 0
            return
        }
        if step == 0 { return step = 1 }
        let ordered = store.state.spaces.map(\.id).filter(spaces.contains)
        do {
            finish(try store.createProfile(named: name, spaces: ordered))
        } catch let problem as ProfileNameError {
            error = problem
            step = 0
        } catch {}
    }
}

/// Change Profile (Spaces menu): the profile the current space uses.
struct ChangeProfileView: View {
    let store: BrowserStore
    let spaceID: UUID
    /// The chosen profile's folder; "New Profile" asks to create one instead.
    let finish: (ChangeProfileView.Choice) -> Void

    enum Choice: Equatable {
        case cancel
        case profile(String)
        case newProfile
    }

    private static let newProfileTag = "\u{0}new"
    @State private var selection = Profile.defaultDirectory

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change Profile").font(.system(size: 15, weight: .semibold))
            Picker("Profile", selection: $selection) {
                ForEach(store.state.allProfiles) { profile in
                    Text(profile.name).tag(profile.directory)
                }
                Divider()
                Text("New Profile").tag(Self.newProfileTag)
            }
            .labelsHidden()
            Text("Each Profile has different browser data, so you might get logged out of some websites, see different Favorites up top, or need to re-install extensions.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { finish(.cancel) }.keyboardShortcut(.cancelAction)
                Button("Change Profile") {
                    finish(selection == Self.newProfileTag ? .newProfile : .profile(selection))
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(M.padding)
        .frame(width: M.width)
        .onAppear {
            if let s = store.state.spaceIndex(spaceID) { selection = store.state.profileDirectory(ofSpace: s) }
        }
    }
}

/// Settings' profile list (Arc's Profiles pane: "Your Profiles", each with its space count),
/// with Rename and Delete. Arc deletes only a profile no space uses, never the default one,
/// and asks you to type the profile's name first.
struct ProfilesListView: View {
    let store: BrowserStore
    let createProfile: () -> Void
    @State private var renaming: Profile?
    @State private var deleting: Profile?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Profiles help keep your data separate across Spaces — like history, logins, cookies, and extensions. You can use any Profile across one or more Spaces.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Your Profiles").font(.system(size: 13, weight: .semibold))
            VStack(spacing: 0) {
                ForEach(store.state.allProfiles) { profile in
                    row(profile)
                    if profile.id != store.state.allProfiles.last?.id { Divider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            HStack {
                Button("New Profile…", action: createProfile)
                Spacer()
            }
        }
        .padding(M.padding)
        .frame(width: M.width + 60)
        .sheet(item: $renaming) { profile in
            RenameProfileView(store: store, profile: profile) { renaming = nil }
        }
        .sheet(item: $deleting) { profile in
            DeleteProfileView(store: store, profile: profile) { deleting = nil }
        }
    }

    private func row(_ profile: Profile) -> some View {
        let count = store.state.spaces(usingProfile: profile.directory).count
        let canDelete = store.state.canDeleteProfile(profile.directory)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                Text(Self.spaceCount(count)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if !profile.isDefault {
                Button("Rename…") { renaming = profile }
                Button("Delete…") { deleting = profile }
                    .disabled(!canDelete)
                    .help(canDelete ? "" : "Only Profiles not assigned to any Spaces can be deleted.")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(profile.name)
    }

    /// Arc: "Not used", then the count ("%d Spaces"; the one-space string's value isn't confirmed).
    static func spaceCount(_ n: Int) -> String {
        switch n {
        case 0: "Not used"
        case 1: "1 Space"
        default: "\(n) Spaces"
        }
    }
}

/// Arc's "Rename your Profile".
private struct RenameProfileView: View {
    let store: BrowserStore
    let profile: Profile
    let done: () -> Void
    @State private var name = ""
    @State private var error: ProfileNameError?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename your Profile").font(.system(size: 15, weight: .semibold))
            Text("This won’t affect the names of any of the Spaces associated with this Profile.")
                .foregroundStyle(.secondary)
            TextField("Personal", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
                .onChange(of: name) { _, _ in error = nil }
            if let error { Text(error.message).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Rename", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(M.padding)
        .frame(width: M.width)
        .onAppear { name = profile.name }
    }

    private func save() {
        do {
            try store.renameProfile(profile.directory, to: name)
            done()
        } catch let problem as ProfileNameError {
            error = problem
        } catch {}
    }
}

/// Arc's "Delete this Profile", confirmed by typing the profile's name.
private struct DeleteProfileView: View {
    let store: BrowserStore
    let profile: Profile
    let done: () -> Void
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Delete this Profile").font(.system(size: 15, weight: .semibold))
            Text("Deleting \(profile.name) will permanently remove any cookies, history, preferences, and logins that belong to this Profile.")
                .fixedSize(horizontal: false, vertical: true)
            Text("To continue, please type the name of this Profile:").foregroundStyle(.secondary)
            TextField(profile.name, text: $typed).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Delete") {
                    store.deleteProfile(profile.directory)
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(typed != profile.name)
            }
        }
        .padding(M.padding)
        .frame(width: M.width)
    }
}
