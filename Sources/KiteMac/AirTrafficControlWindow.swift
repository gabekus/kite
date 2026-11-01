import AppKit
import Combine
import KiteCore
import SwiftUI

/// Air Traffic Control's routes on disk (LinkRouting.json, like Arc's StorableLinkRouting.json).
@MainActor
final class AirTrafficControlStore: ObservableObject {
    @Published var state: AirTrafficControl.State {
        didSet { if state != oldValue { save() } }
    }
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL) {
            do {
                state = try JSONDecoder().decode(AirTrafficControl.State.self, from: data)
                return
            } catch {
                NSLog("Kite: couldn't read Air Traffic Control routes: \(error)")
            }
        }
        state = AirTrafficControl.State()
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Kite: couldn't save Air Traffic Control routes: \(error)")
        }
    }
}

/// Kite menu → Air Traffic Control…: the route editor, in a small window of its own until
/// Kite has a Settings window (Arc opens it as a dialog from Preferences → Links).
@MainActor
enum AirTrafficControlWindow {
    struct SpaceChoice: Identifiable, Hashable {
        let id: UUID
        let name: String
        let icon: String
    }

    private static var window: NSWindow?

    static func show(store: AirTrafficControlStore, spaces: @escaping () -> [SpaceChoice]) {
        let window = window ?? makeWindow()
        self.window = window
        let view = AirTrafficControlView(store: store, spaces: spaces()) { [weak window] in window?.close() }
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        window.contentView = host
        if UIDiagnostics.enabledByEnvironment {
            // Test runs stay behind the user's windows.
            window.orderBack(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Air Traffic Control"
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        return window
    }
}

/// Arc's LinkRoutingDialog, rebuilt from its strings: an airplane.circle header, "Air Traffic
/// Control" and its explainer, one card per route ("URL" + "Is equal to"/"Contains" + text, then
/// "↳ Open in" + space or Little Arc, minus.circle.fill to delete), "New Route", the "Default"
/// route, and Done. Arc's geometry wasn't measured (opening the dialog means driving Arc).
private struct AirTrafficControlView: View {
    @ObservedObject var store: AirTrafficControlStore
    let spaces: [AirTrafficControlWindow.SpaceChoice]
    let done: () -> Void

    private typealias ATC = AirTrafficControl

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 36)
                .padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($store.state.rules) { $rule in
                        RuleCard(rule: $rule, spaces: spaces) {
                            store.state.rules.removeAll { $0.id == rule.id }
                        }
                    }
                    Button {
                        store.state.rules.append(ATC.Rule())
                    } label: {
                        Label("New Route", systemImage: "plus")
                    }
                    .accessibilityIdentifier("atcNewRoute")
                    defaultRoute
                        .padding(.top, 8)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("atcDone")
            }
            .padding(16)
        }
        .frame(minWidth: 480, minHeight: 320)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "airplane.circle")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Air Traffic Control")
                    .font(.system(size: 17, weight: .semibold))
                Text("Routes let you choose where specific sites open inside Kite. For example, you can route Spotify links to always open inside your Personal space.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var defaultRoute: some View {
        let opensLittle = LittleKite.opensExternalLinks(in: .standard)
        let binding = Binding<ATC.Destination>(
            get: { store.state.resolvedDefault(opensExternalLinksInLittleKite: opensLittle) },
            set: { newValue in
                // Little Kite and Most Recent Space are the Kite menu setting (Arc's
                // openExternalLinksInLittleBrowserEnabled); a space is stored with the routes.
                switch newValue {
                case .littleKite, .mostRecentSpace:
                    UserDefaults.standard.set(newValue == .littleKite, forKey: LittleKite.opensExternalLinksKey)
                    store.state.defaultDestination = nil
                case .space:
                    store.state.defaultDestination = newValue
                }
            }
        )
        return VStack(alignment: .leading, spacing: 6) {
            Text("Default")
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .foregroundStyle(.secondary)
                Text("Open in")
                DestinationPicker(selection: binding, spaces: spaces, includesMostRecent: true)
                    .accessibilityIdentifier("atcDefaultDestination")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

private struct RuleCard: View {
    @Binding var rule: AirTrafficControl.Rule
    let spaces: [AirTrafficControlWindow.SpaceChoice]
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($rule.components) { $component in
                HStack(spacing: 6) {
                    Label("URL", systemImage: "link")
                        .frame(width: 60, alignment: .leading)
                    Picker("", selection: $component.style) {
                        ForEach(AirTrafficControl.MatchStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("atcMatchStyle")
                    TextField("example.com", text: $component.pattern)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("atcPattern")
                    if component.id == rule.components.last?.id {
                        Button {
                            rule.components.append(.init())
                        } label: { Image(systemName: "plus.circle") }
                            .buttonStyle(.borderless)
                            .help("Add a URL")
                    } else {
                        Button {
                            rule.components.removeAll { $0.id == component.id }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove this URL")
                    }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .foregroundStyle(.secondary)
                Text("Open in")
                DestinationPicker(selection: $rule.destination, spaces: spaces, includesMostRecent: false)
                    .accessibilityIdentifier("atcRuleDestination")
                Spacer()
                Button(action: delete) {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Delete Route")
                .accessibilityIdentifier("atcDeleteRoute")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

private struct DestinationPicker: View {
    @Binding var selection: AirTrafficControl.Destination
    let spaces: [AirTrafficControlWindow.SpaceChoice]
    let includesMostRecent: Bool

    var body: some View {
        Picker("", selection: $selection) {
            if includesMostRecent {
                Text("Most Recent Space").tag(AirTrafficControl.Destination.mostRecentSpace)
            }
            Text("Little Kite").tag(AirTrafficControl.Destination.littleKite)
            Divider()
            ForEach(spaces) { space in
                Text("\(space.icon) \(space.name)").tag(AirTrafficControl.Destination.space(space.id))
            }
            // A route to a space that's gone still shows something.
            if case .space(let id) = selection, !spaces.contains(where: { $0.id == id }) {
                Text("Deleted Space").tag(selection)
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}
