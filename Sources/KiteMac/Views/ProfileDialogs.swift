import AppKit
import KiteCore
import SwiftUI

// Arc's profile dialogs (ARC_ProfilesUI: ProfileCreationSheetWindow, ProfileChangeSheetWindow).
// Wording and buttons are Arc's, read from its binary (the localized keys next to their comments).
// Layout from Arc 1.169 on 2026-11-01, Change Profile and both Create steps opened from the menu bar
// and read through Accessibility (frames) and a window capture (colours, dark appearance):
// sheets 450pt wide with 38pt insets, a 62pt (create) / 68pt (change) icon at the top, a 21pt title,
// body text, and 40pt buttons whose key is shown in a chip (ESC, ↩), right-aligned at the bottom.

enum ArcSheetMetrics {
    static let width: CGFloat = 450
    static let inset: CGFloat = 38
    static let titleSize: CGFloat = 17
    static let bodySize: CGFloat = 14
    static let buttonHeight: CGFloat = 40
    static let buttonRadius: CGFloat = 10
    static let buttonGap: CGFloat = 8
    /// Arc's dark sheet colours, shared with its other dialogs (`ArcDialogMetrics`; measured within a
    /// unit of these in both): background, secondary button, primary button.
    static let background = ArcDialogMetrics.background
    static let secondary = ArcDialogMetrics.secondaryFill
    static let primary = ArcDialogMetrics.primaryFill
}

private typealias M = ArcSheetMetrics

/// Arc's dialog button: a filled rounded rectangle with the title and its key in a chip.
struct ArcSheetButton: View {
    let title: String
    var key: String?
    var primary = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(title).font(.system(size: 15, weight: .medium))
                if let key {
                    Text(key)
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 6)
                        .frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.15)))
                }
            }
            .foregroundStyle(.white.opacity(enabled ? 1 : 0.4))
            .padding(.horizontal, 12)
            .frame(height: M.buttonHeight)
            .background(RoundedRectangle(cornerRadius: M.buttonRadius, style: .continuous)
                .fill((primary ? M.primary : M.secondary).opacity(enabled ? 1 : 0.35)))
            .overlay(RoundedRectangle(cornerRadius: M.buttonRadius, style: .continuous)
                .strokeBorder(.white.opacity(primary ? 0.1 : 0.25), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(title)
    }
}

/// The sheet around a profile dialog's content.
struct ArcSheet<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(M.inset)
            .frame(width: M.width, alignment: .leading)
            .background(M.background)
            .environment(\.colorScheme, .dark)
    }
}

/// Arc's smiley profile badge (icon-archie): a ring with a face, a green plus for a new profile.
struct ProfileBadge: View {
    var size: CGFloat = 62
    var adding = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .overlay(
                    Circle().fill(Color(red: 0.33, green: 0.33, blue: 0.55)).padding(size * 0.08)
                        .overlay(Image(systemName: "face.smiling").font(.system(size: size * 0.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85)))
                )
                .frame(width: size, height: size)
            if adding {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: size * 0.3))
                    .foregroundStyle(.white, Color(red: 0.3, green: 0.65, blue: 0.25))
                    .offset(x: 4, y: 2)
            }
        }
        .accessibilityHidden(true)
    }
}

private func title(_ text: Text) -> some View {
    text.font(.system(size: M.titleSize, weight: .semibold)).foregroundStyle(.white)
}

private func bodyText(_ text: String) -> some View {
    Text(text)
        .font(.system(size: M.bodySize))
        .foregroundStyle(.white.opacity(0.7))
        .fixedSize(horizontal: false, vertical: true)
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
        ArcSheet {
            ProfileBadge(adding: true)
            if step == 0 { nameStep } else { spacesStep }
            HStack(spacing: M.buttonGap) {
                Spacer()
                ArcSheetButton(title: step == 0 ? "Cancel" : "Back", key: "ESC") {
                    if step == 0 { finish(nil) } else { step = 0 }
                }
                .keyboardShortcut(.cancelAction)
                ArcSheetButton(title: step == 0 ? "Next" : "Create Profile", key: "↩", primary: true,
                               enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty, action: advance)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 30)
        }
        .onAppear {
            spaces = initialSpaces
            nameFocused = true
        }
    }

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            title(Text("Create a new Profile")).padding(.top, 17)
            bodyText("Profiles make your Spaces truly separate — with their own history, saved passwords, extensions, and other browsing data. No more flipping between work and personal accounts!")
                .padding(.top, 13)
            bodyText("What do you want to call this Profile?").padding(.top, 18)
            TextField("Personal", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($nameFocused)
                .onSubmit(advance)
                .onChange(of: name) { _, _ in error = nil }
                .padding(.horizontal, 12)
                .frame(height: 49)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.12)))
                .padding(.top, 16)
                .accessibilityLabel("Profile name")
            Group {
                if let error {
                    Text(error.message).foregroundStyle(.red)
                } else {
                    // Arc's note under the field (its binary: "between computers.").
                    Text("\(Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")) Profiles are **not synced** between computers.")
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .font(.system(size: 11.5))
            .padding(.top, 8)
        }
    }

    /// Arc shows each space as a card in its theme with a round check under it.
    private var spacesStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            title(Text("Which Spaces should use this Profile?")).padding(.top, 17)
            bodyText("These Spaces will start fresh in your brand new Profile — so you’ll have to log back in to websites, re-save your passwords, add extensions, etc. You can always switch back to your previous Profile though if you forgot something!")
                .padding(.top, 13)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(store.state.spaces) { space in spaceCard(space) }
                }
            }
            .padding(.top, 14)
        }
    }

    private func spaceCard(_ space: Space) -> some View {
        let on = spaces.contains(space.id)
        return Button {
            if on { spaces.remove(space.id) } else { spaces.insert(space.id) }
        } label: {
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: space.theme.colors.map { Color(red: Double($0.r), green: Double($0.g), blue: Double($0.b)) },
                                         startPoint: .top, endPoint: .bottom).opacity(0.6))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.25)))
                    .overlay(Text(space.icon).font(.system(size: 20)))
                    .frame(width: 64, height: 95)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(on ? Color.white : Color.white.opacity(0.4), on ? Color.green : Color.clear)
                    .padding(.top, 10)
                Text(space.name).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    .frame(width: 76)
                    .padding(.top, 10)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(space.name)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(on ? "1" : "0")
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
        let space = store.state.spaceIndex(spaceID).map { store.state.spaces[$0] }
        let name = space?.name ?? ""
        ArcSheet {
            // The space's icon on a tile, with the profile badge on its corner.
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(M.primary.opacity(0.9))
                    .overlay(Text(space?.icon ?? "").font(.system(size: 28)))
                    .frame(width: 62, height: 62)
                ProfileBadge(size: 24).offset(x: 6, y: 6)
            }
            .padding(.trailing, 6)
            title(Text("Change ") + Text("\(name)’s").bold() + Text(" Profile"))
                .padding(.top, 17)
            bodyText("Each Profile has different browser data, so you might get logged out of some websites, see different Favorites up top, or need to re-install extensions.")
                .padding(.top, 13)
            HStack(spacing: 6) {
                (Text("\(name)’s").bold() + Text(" Profile")).font(.system(size: 13)).foregroundStyle(.white)
                Picker("Profile", selection: $selection) {
                    ForEach(store.state.allProfiles) { profile in
                        Text(profile.name).tag(profile.directory)
                    }
                    Divider()
                    Text("New Profile").tag(Self.newProfileTag)
                }
                .labelsHidden()
                .fixedSize()
                .tint(M.primary)
            }
            .padding(.top, 12)
            HStack(spacing: M.buttonGap) {
                Spacer()
                ArcSheetButton(title: "Cancel", key: "ESC") { finish(.cancel) }
                    .keyboardShortcut(.cancelAction)
                ArcSheetButton(title: "Change Profile", key: "↩", primary: true) {
                    finish(selection == Self.newProfileTag ? .newProfile : .profile(selection))
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 26)
        }
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
        .padding(20)
        .frame(width: 480)
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

/// Arc's "Rename your Profile", in Arc's dark dialog style (`ArcSheet`, `arcDialogField`).
private struct RenameProfileView: View {
    let store: BrowserStore
    let profile: Profile
    let done: () -> Void
    @State private var name = ""
    @State private var error: ProfileNameError?
    @FocusState private var focused: Bool

    var body: some View {
        ArcSheet {
            title(Text("Rename your Profile"))
            bodyText("This won’t affect the names of any of the Spaces associated with this Profile.")
                .padding(.top, 8)
            TextField("", text: $name, prompt: Text("Personal").foregroundStyle(.white.opacity(0.4)))
                .arcDialogField()
                .focused($focused)
                .onSubmit(save)
                .onChange(of: name) { _, _ in error = nil }
                .padding(.top, 16)
                .accessibilityLabel("Profile name")
            if let error {
                Text(error.message).font(.system(size: 11.5)).foregroundStyle(.red).padding(.top, 8)
            }
            HStack(spacing: M.buttonGap) {
                Spacer()
                ArcSheetButton(title: "Cancel", key: "ESC", action: done).keyboardShortcut(.cancelAction)
                ArcSheetButton(title: "Rename", key: "↩", primary: true, action: save).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 24)
        }
        .onAppear {
            name = profile.name
            focused = true
        }
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

/// Arc's "Delete this Profile", confirmed by typing the profile's name, in Arc's dark dialog style.
private struct DeleteProfileView: View {
    let store: BrowserStore
    let profile: Profile
    let done: () -> Void
    @State private var typed = ""
    @FocusState private var focused: Bool

    var body: some View {
        ArcSheet {
            title(Text("Delete this Profile"))
            bodyText("Deleting \(profile.name) will permanently remove any cookies, history, preferences, and logins that belong to this Profile.")
                .padding(.top, 8)
            bodyText("To continue, please type the name of this Profile:").padding(.top, 12)
            TextField("", text: $typed, prompt: Text(profile.name).foregroundStyle(.white.opacity(0.4)))
                .arcDialogField()
                .focused($focused)
                .onSubmit(delete)
                .padding(.top, 12)
                .accessibilityLabel("Profile name")
            HStack(spacing: M.buttonGap) {
                Spacer()
                ArcSheetButton(title: "Cancel", key: "ESC", action: done).keyboardShortcut(.cancelAction)
                ArcSheetButton(title: "Delete", key: "↩", primary: true, enabled: typed == profile.name, action: delete)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 24)
        }
        .onAppear { focused = true }
    }

    private func delete() {
        guard typed == profile.name else { return NSSound.beep() }
        store.deleteProfile(profile.directory)
        done()
    }
}
