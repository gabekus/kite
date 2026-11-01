import AppKit
import SwiftUI

/// Arc 1.169's Settings window, measured on the Mac with `kite probe Arc tree` and window
/// captures of all eight panes (notes in ~/rea-arc/settings): 684pt wide, a 52pt preference
/// toolbar under a 28pt titlebar, content from y 80, 642pt tall on every pane.
enum SettingsMetrics {
    static let width: CGFloat = 684
    static let windowHeight: CGFloat = 642
    static let titlebarAndToolbar: CGFloat = 80
    static let contentHeight = windowHeight - titlebarAndToolbar
    /// Panes that overflow (Max, Links) widen the window by a legacy scroller, as Arc's do (699pt).
    static let legacyScrollerWidth: CGFloat = 15
    /// Sections are 556pt wide, 64pt in from each side, the first 20pt under the toolbar.
    static let margin: CGFloat = 64
    static let topMargin: CGFloat = 20
    static let sectionWidth = width - 2 * margin
    /// 8pt between sections; rows are 36.5pt for a line of text, with content 10pt in from the
    /// section's edges and separators from 8pt in to 9pt in.
    static let sectionSpacing: CGFloat = 8
    static let rowInset: CGFloat = 10
    static let rowVerticalPadding: CGFloat = 10.25
    static let separatorLeading: CGFloat = 8
    static let separatorTrailing: CGFloat = 9
    static let cornerRadius: CGFloat = 7
    /// Arc's row icons (Advanced): 20pt rounded squares, text 8pt after.
    static let iconSize: CGFloat = 20
    static let iconCornerRadius: CGFloat = 5

    // Captured from Arc in dark mode: window #2B2B29, section #2E2E2C, border and separators #3F3F3E.
    // Light mode wasn't observed; it uses the system's equivalents.
    static let background = dynamic(dark: 0x2B2B29, light: .windowBackgroundColor)
    static let sectionFill = dynamic(dark: 0x2E2E2C, light: .controlBackgroundColor)
    static let line = dynamic(dark: 0x3F3F3E, light: .separatorColor)

    private static func dynamic(dark: UInt32, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            guard appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua else { return light }
            return NSColor(
                srgbRed: CGFloat(dark >> 16 & 0xFF) / 255, green: CGFloat(dark >> 8 & 0xFF) / 255,
                blue: CGFloat(dark & 0xFF) / 255, alpha: 1
            )
        })
    }
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

    /// SF Symbols close to Arc's icons (Arc draws General, Max and Links from its own assets).
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

    /// Whether the pane's content is taller than the window (Arc: Max and Links).
    var scrolls: Bool { self == .max || self == .links || self == .advanced }

    /// Arc widens the window by the scroller when a pane scrolls and scrollers are always shown.
    @MainActor var width: CGFloat {
        SettingsMetrics.width
            + (scrolls && NSScroller.preferredScrollerStyle == .legacy ? SettingsMetrics.legacyScrollerWidth : 0)
    }

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
        .font(.system(size: 13))
        .frame(width: width, height: contentHeight)
        .background(SettingsMetrics.background)
    }
}

// MARK: Shared pieces

/// A scrolling pane: sections 64pt in from each side, the first 20pt down.
struct SettingsPaneContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                content
            }
            .frame(width: SettingsMetrics.sectionWidth, alignment: .leading)
            .padding(.top, SettingsMetrics.topMargin)
            .padding(.bottom, SettingsMetrics.topMargin)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// One rounded section, like a grouped form's, optionally with a header above it.
/// Put SettingsSeparator() between its rows.
struct SettingsSection<Content: View>: View {
    var header: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header {
                Text(header).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.leading, SettingsMetrics.rowInset)
                    .padding(.top, 8)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: SettingsMetrics.cornerRadius).fill(SettingsMetrics.sectionFill))
            .overlay(RoundedRectangle(cornerRadius: SettingsMetrics.cornerRadius).strokeBorder(SettingsMetrics.line, lineWidth: 1))
        }
    }
}

/// The line between two rows of a section.
struct SettingsSeparator: View {
    var body: some View {
        SettingsMetrics.line.frame(height: 1)
            .padding(.leading, SettingsMetrics.separatorLeading)
            .padding(.trailing, SettingsMetrics.separatorTrailing)
    }
}

/// Arc's coloured row icon (Advanced): a white symbol on a 20pt rounded square.
struct SettingsIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: SettingsMetrics.iconSize, height: SettingsMetrics.iconSize)
            .background(RoundedRectangle(cornerRadius: SettingsMetrics.iconCornerRadius).fill(color))
    }
}

/// A row: optional icon, a label (and a note under it), and a control on the trailing edge.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    var icon: SettingsIcon?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            if let icon { icon.padding(.trailing, 8) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            // Arc's buttons and pop-ups are 20pt; AppKit's frames include room around the bezel.
            control.fixedSize().frame(maxHeight: 20)
        }
        .padding(.horizontal, SettingsMetrics.rowInset)
        .padding(.vertical, SettingsMetrics.rowVerticalPadding)
        .frame(minHeight: 36.5)
    }
}

/// Arc's switches are the mini size (26×15).
private struct SettingsSwitch: View {
    let isOn: Binding<Bool>

    var body: some View {
        Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden().controlSize(.mini)
    }
}

/// A switch bound to a menu command: on when the menu item is checked.
struct CommandToggle: View {
    @EnvironmentObject private var model: SettingsModel
    let title: String
    var detail: String?
    var icon: SettingsIcon?
    let command: SettingsModel.Command

    init(_ title: String, detail: String? = nil, icon: SettingsIcon? = nil, _ action: Selector, tag: Int = 0) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.command = .init(action: action, tag: tag)
    }

    var body: some View {
        let _ = model.revision
        let state = model.state(command)
        SettingsRow(title: title, detail: detail, icon: icon) {
            SettingsSwitch(isOn: Binding(get: { state.on }, set: { _ in model.perform(command) }))
        }
        .disabled(!state.enabled)
    }
}

/// An Arc option Kite doesn't have yet: shown where Arc has it, switched off and disabled.
struct UnsupportedToggle: View {
    let title: String
    var detail: String?
    var icon: SettingsIcon?

    init(_ title: String, detail: String? = nil, icon: SettingsIcon? = nil) {
        self.title = title
        self.detail = detail
        self.icon = icon
    }

    var body: some View {
        SettingsRow(title: title, detail: detail, icon: icon) { SettingsSwitch(isOn: .constant(false)) }
            .disabled(true)
            .help("Not in Kite yet")
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

/// A paragraph above a section (Profiles, Max, Links), 10pt in like the rows below it.
struct SettingsBlurb: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SettingsMetrics.rowInset)
            .padding(.vertical, 4)
    }
}
