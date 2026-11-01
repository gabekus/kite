import AppKit
import SwiftUI

/// Arc 1.169's Settings window, measured on the Mac with `kite probe Arc tree` (Account pane):
/// 684pt wide, a 52pt preference toolbar under a 28pt titlebar, content from y 80.
enum SettingsMetrics {
    static let width: CGFloat = 684
    /// The window's full height on Arc's Account pane, titlebar and toolbar included.
    static let windowHeight: CGFloat = 642
    static let titlebarAndToolbar: CGFloat = 80
    static let contentHeight = windowHeight - titlebarAndToolbar
    /// Pane padding and section spacing. Not measured yet (only the Account pane was observed):
    /// from macOS's grouped forms, which Arc's sections resemble.
    static let padding: CGFloat = 20
    static let sectionSpacing: CGFloat = 16
    static let sectionCornerRadius: CGFloat = 8
}

/// Arc's eight toolbar tabs, in its order. Arc names the first after the signed-in account.
enum SettingsPane: String, CaseIterable {
    case account, general, profiles, max, links, shortcuts, icon, advanced

    var toolbarIdentifier: NSToolbarItem.Identifier { .init("settings.\(rawValue)") }

    var toolbarLabel: String {
        switch self {
        case .account: "Account"
        case .general: "General"
        case .profiles: "Profiles"
        case .max: "Max"
        case .links: "Links"
        case .shortcuts: "Shortcuts"
        case .icon: "Icon"
        case .advanced: "Advanced"
        }
    }

    /// The window title, as in Arc: the pane's name.
    var title: String { toolbarLabel }

    /// SF Symbols close to Arc's icons (Arc draws General and Links from its own assets).
    var symbol: String {
        switch self {
        case .account: "person.crop.square.filled.and.at.rectangle"
        case .general: "gearshape"
        case .profiles: "person"
        case .max: "sparkle"
        case .links: "macwindow.on.rectangle"
        case .shortcuts: "keyboard"
        case .icon: "app.badge"
        case .advanced: "slider.horizontal.3"
        }
    }

    /// The content height under the toolbar. Only the Account pane's (562) is measured; the
    /// others use it until they're observed.
    var contentHeight: CGFloat { SettingsMetrics.contentHeight }

    @MainActor @ViewBuilder
    func view(model: SettingsModel) -> some View {
        Group {
            switch self {
            case .account: AccountPane()
            case .general: GeneralPane()
            case .profiles: ProfilesPane()
            case .max: MaxPane()
            case .links: LinksPane()
            case .shortcuts: ShortcutsPane()
            case .icon: IconPane()
            case .advanced: AdvancedPane()
            }
        }
        .environmentObject(model)
        .frame(width: SettingsMetrics.width, height: contentHeight)
    }
}

// MARK: Shared pieces

/// A scrolling pane of grouped sections.
struct SettingsPaneContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                content
            }
            .padding(SettingsMetrics.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One rounded section, optionally with a header above it.
struct SettingsSection<Content: View>: View {
    var header: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header {
                Text(header).font(.system(size: 13, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SettingsMetrics.sectionCornerRadius)
                    .fill(Color.primary.opacity(0.05))
            )
        }
    }
}

/// A switch bound to a menu command: on when the menu item is checked.
struct CommandToggle: View {
    @EnvironmentObject private var model: SettingsModel
    let title: String
    var detail: String?
    let command: SettingsModel.Command

    init(_ title: String, detail: String? = nil, _ action: Selector, tag: Int = 0) {
        self.title = title
        self.detail = detail
        self.command = .init(action: action, tag: tag)
    }

    var body: some View {
        let _ = model.revision
        let state = model.state(command)
        SettingsRow(title: title, detail: detail) {
            Toggle("", isOn: Binding(get: { state.on }, set: { _ in model.perform(command) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        .disabled(!state.enabled)
    }
}

/// An Arc option Kite doesn't have yet: shown where Arc has it, switched off and disabled.
struct UnsupportedToggle: View {
    let title: String
    var detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        SettingsRow(title: title, detail: detail) {
            Toggle("", isOn: .constant(false)).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .disabled(true)
        .help("Not in Kite yet")
    }
}

/// A label (and optional note under it) with a control on the trailing edge.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
    }
}

/// A button that runs a menu command.
struct CommandButton: View {
    @EnvironmentObject private var model: SettingsModel
    let title: String
    let command: SettingsModel.Command

    init(_ title: String, _ action: Selector) {
        self.title = title
        self.command = .init(action: action)
    }

    var body: some View {
        let _ = model.revision
        Button(title) { model.perform(command) }
            .disabled(!model.state(command).enabled)
    }
}
