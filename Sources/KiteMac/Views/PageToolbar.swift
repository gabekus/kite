import KiteCore
import SwiftUI

/// View → Show Toolbar: Arc 1.169's bar across the top of the content card (measured
/// on the Mac): back, forward and reload on the left, the site's host in the middle,
/// Site Controls and Split View on the right, and a hairline under it. While it's on,
/// the sidebar drops its navigation buttons and URL field.
struct PageToolbar: View {
    let store: BrowserStore
    let actions: SidebarActions
    /// Opens Site Controls under the button.
    var showSiteControls: ((NSView) -> Void)?
    @State private var siteControlsAnchor: NSView?
    /// Kite menu → Show Full URL in Toolbar (Arc: "Show full URL when Toolbar is enabled").
    @AppStorage(ToolbarURL.showsFullURLKey) private var showsFullURL = false
    #if canImport(CEFBridge)
    /// Pinned extensions and the extensions menu; nil where extensions don't run (incognito, WebKit).
    var extensions: ExtensionsSelection?
    #endif

    enum Metrics {
        static let height: CGFloat = 32
        /// The bar plus its divider: how far the page moves down.
        static let inset: CGFloat = height + 1
        static let buttonPitch: CGFloat = 37
        /// The first icon's left edge is 15.5 from the card's; a 13pt icon centred in a 37pt slot.
        static let leading: CGFloat = 15.5 - (buttonPitch - 13) / 2
        /// The last icon's right edge is 14 from the card's; a 14pt icon centred in a 37pt slot.
        static let trailing: CGFloat = 14 - (buttonPitch - 14) / 2
        /// Arc's host group sits 11pt left of the card's centre.
        static let centerOffset: CGFloat = -11
        static let iconSize: CGFloat = 13
        static let fontSize: CGFloat = 13
        // Greys tuned so a capture of Kite reads like Arc's: bar #2D2D2D, divider #3B3B3B,
        // icons #C3C3C3 (disabled #6C6C6C), host #D2D2D2.
        static let background = grey(0x24)
        static let divider = grey(0x2C)
        static let enabled = grey(0xB8)
        static let disabled = grey(0x59)
        static let text = grey(0xC8)
        static let siteControlsSize: CGFloat = 16
        /// Room kept clear on each side of the centred address: the three navigation buttons plus
        /// a gap (the right side, Site Controls and Split View, is narrower). Kite's, not measured.
        static let urlInset: CGFloat = leading + 3 * buttonPitch + 12

        static func grey(_ level: Int) -> Color {
            Color(red: Double(level) / 255, green: Double(level) / 255, blue: Double(level) / 255)
        }
    }

    var body: some View {
        let selected = store.state.selectedTab
        let page = selected.flatMap { store.pages[$0.id] } ?? PageStatus()
        ZStack {
            HStack(spacing: 0) {
                button("arrow.left", "Back", enabled: page.canGoBack, action: actions.goBack)
                button("arrow.right", "Forward", enabled: page.canGoForward, action: actions.goForward)
                button(page.isLoading ? "xmark" : "arrow.clockwise", "Reload", enabled: selected != nil, action: actions.reloadButton)
                Spacer()
                #if canImport(CEFBridge)
                if let extensions {
                    // Site Controls' icon sits 10.5pt into its 37pt slot; Arc leaves 12pt to it.
                    ExtensionsSelectionView(selection: extensions) { ExtensionsToolbarItems(model: $0) }
                        .padding(.trailing, ExtensionsToolbarItems.Metrics.siteControlsGap - (Metrics.buttonPitch - Metrics.siteControlsSize) / 2)
                }
                #endif
                let hasSite = SiteControls.applies(to: selected?.url)
                Button { if let siteControlsAnchor { showSiteControls?(siteControlsAnchor) } } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: Metrics.siteControlsSize, height: Metrics.siteControlsSize)
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(lineWidth: 1.25))
                        .foregroundStyle(hasSite ? Metrics.enabled : Metrics.disabled)
                        .frame(width: Metrics.buttonPitch, height: Metrics.height)
                        .background(AnchorView(view: $siteControlsAnchor))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .allowsHitTesting(hasSite)
                .help("Site Control Center")
                .accessibilityLabel("Site Control Center")
                Button(action: actions.addSplitView) {
                    Image(systemName: "rectangle.split.2x1")
                        .resizable()
                        .fontWeight(.medium)
                        .frame(width: 14, height: 14.5)
                        .foregroundStyle(Metrics.enabled)
                        .frame(width: Metrics.buttonPitch, height: Metrics.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add Split View")
                .accessibilityLabel("Add Split View")
            }
            .padding(.leading, Metrics.leading)
            .padding(.trailing, Metrics.trailing)

            Button { store.showCommandBar(selected == nil ? .newTab : .editCurrent) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "link")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Metrics.enabled)
                    Text(ToolbarURL.text(for: selected?.url, full: showsFullURL))
                        .font(.system(size: Metrics.fontSize))
                        .foregroundStyle(Metrics.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // A full URL truncates before it reaches the buttons on either side.
            .padding(.horizontal, Metrics.urlInset)
            .offset(x: Metrics.centerOffset)
            .opacity(selected?.url == nil ? 0 : 1)
        }
        .frame(height: Metrics.height)
        .background(Metrics.background)
        .overlay(alignment: .bottom) {
            Metrics.divider.frame(height: 1).offset(y: 1)
        }
        .frame(height: Metrics.inset, alignment: .top)
        .ignoresSafeArea()
    }

    private func button(_ symbol: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Metrics.iconSize, weight: .medium))
                .foregroundStyle(enabled ? Metrics.enabled : Metrics.disabled)
                .frame(width: Metrics.buttonPitch, height: Metrics.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Not .disabled(), which dims the icon further than Arc's disabled grey.
        .allowsHitTesting(enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}
