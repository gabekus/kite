import AppKit
import KiteCore
import SwiftUI

/// Arc's Create a Space page (`SpaceCreationView`), which takes over the sidebar under the top row after
/// + › New Space: a picture, a title and a line about spaces, the name field, the profile, Choose a Theme
/// (Arc's theme popover, applied to the window as you pick), and Create Space / Cancel at the bottom.
/// Laid out from Arc 1.169's accessibility tree and captures (docs/arc-visual-spec.md, "New space").
struct SpaceCreationView: View {
    private typealias M = ArcMetrics.SpaceCreation
    let store: BrowserStore
    let actions: SidebarActions
    let creation: BrowserStore.SpaceCreation
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Illustration()
                .frame(height: M.illustrationHeight)
                .padding(.top, M.illustrationTop)
            Text("Create a Space")
                .font(.system(size: M.titleFontSize, weight: .bold))
                .padding(.top, M.titleTop)
            Text("Separate your tabs for life,\nwork, projects, and more.")
                .font(.system(size: M.subtitleFontSize))
                .multilineTextAlignment(.center)
                .opacity(M.subtitleOpacity)
                .padding(.top, M.subtitleTop)
            VStack(spacing: 0) {
                row {
                    Image(systemName: "plus.square.dashed")
                        .font(.system(size: 16))
                        .opacity(0.6)
                        .frame(width: M.iconSize)
                    TextField("Space name…", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: M.rowFontSize))
                        .focused($nameFocused)
                        .onSubmit(create)
                }
                .padding(.top, 0)
                if actions.showsProfiles {
                    row {
                        Image(systemName: "face.smiling")
                            .font(.system(size: 15))
                            .opacity(0.7)
                            .frame(width: M.iconSize)
                        Text("Profile").font(.system(size: M.rowFontSize, weight: .semibold))
                        ProfilePill(store: store, spaceID: creation.spaceID)
                        Spacer(minLength: 0)
                        Image(systemName: "info.circle")
                            .font(.system(size: 14))
                            .opacity(0.7)
                            .help("A profile keeps its own logins, history, cookies and extensions.")
                    }
                    .padding(.top, M.profileGap)
                }
                ChooseThemeRow(store: store, spaceID: creation.spaceID)
                    .padding(.top, M.themeGap)
            }
            .padding(.top, M.fieldsTop)
            Spacer(minLength: 0)
            Button(action: create) {
                Text("Create Space")
                    .font(.system(size: M.rowFontSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(canCreate ? 1 : 0.45))
                    .frame(maxWidth: .infinity, minHeight: M.rowHeight)
                    .background(RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous)
                        .fill(Color(nsColor: M.createColor).opacity(canCreate ? 1 : M.createDisabledOpacity)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canCreate)
            .accessibilityIdentifier("spaceCreationCreateSpaceButton")
            Button("Cancel") { store.cancelNewSpace() }
                .buttonStyle(.plain)
                .font(.system(size: M.cancelFontSize, weight: .medium))
                .opacity(M.cancelOpacity)
                .padding(.top, M.cancelTop)
                .padding(.bottom, M.cancelBottom)
                .accessibilityIdentifier("spaceCreationCancelButton")
        }
        .padding(.horizontal, M.inset - ArcMetrics.Sidebar.padding)
        .onAppear { nameFocused = true }
        .onExitCommand { store.cancelNewSpace() }
    }

    private var canCreate: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func create() {
        guard canCreate else { return }
        store.finishNewSpace(name: name)
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: M.rowTextX - M.rowIconX - M.iconSize) { content() }
            .padding(.leading, M.rowIconX - M.inset)
            .padding(.trailing, 10)
            .frame(height: M.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous).fill(.white.opacity(M.rowFill)))
    }
}

/// Three cards fanned out over each other. Arc draws a picture of its own here; this is Kite's.
private struct Illustration: View {
    var body: some View {
        ZStack {
            card("leaf.fill", color: .green).rotationEffect(.degrees(-12)).offset(x: -18, y: 2)
            card("books.vertical.fill", color: .orange).rotationEffect(.degrees(12)).offset(x: 18, y: 2)
            card("laptopcomputer", color: .gray)
        }
    }

    private func card(_ symbol: String, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(.white)
            .frame(width: 28, height: 32)
            .overlay(Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(color))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}

/// "Profile" with the chosen profile's name in a pill that opens the profile list.
private struct ProfilePill: View {
    let store: BrowserStore
    let spaceID: UUID

    var body: some View {
        let current = store.state.spaces.first { $0.id == spaceID }?.profile
        Menu {
            ForEach(store.state.allProfiles) { profile in
                Button(profile.name) { store.setProfile(profile.isDefault ? nil : profile.directory, forSpace: spaceID) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(store.state.profile(current).name).font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(.white.opacity(0.1)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// Opens Arc's theme popover pointing at the row, on an empty grid until a colour is picked.
private struct ChooseThemeRow: View {
    private typealias M = ArcMetrics.SpaceCreation
    let store: BrowserStore
    let spaceID: UUID

    var body: some View {
        AnchoredButton { view in
            ThemeEditor.present(store: store, spaceID: spaceID, from: view, pointing: true)
        } label: {
            HStack(spacing: M.rowTextX - M.rowIconX - M.iconSize) {
                Image(systemName: "paintbrush.pointed.fill")
                    .font(.system(size: 14))
                    .opacity(0.7)
                    .frame(width: M.iconSize)
                Text("Choose a Theme").font(.system(size: M.rowFontSize, weight: .semibold))
                Spacer(minLength: 0)
            }
            .padding(.leading, M.rowIconX - M.inset)
            .frame(height: M.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous).fill(.white.opacity(M.rowFill)))
            .contentShape(Rectangle())
        }
    }
}

/// A button that hands its own AppKit view to the action, so a popover can hang off it.
struct AnchoredButton<Label: View>: View {
    let action: (NSView) -> Void
    @ViewBuilder let label: () -> Label
    @State private var anchor: NSView?

    var body: some View {
        Button { if let anchor { action(anchor) } } label: { label() }
            .buttonStyle(.plain)
            .background(AnchorView(view: $anchor))
    }
}
