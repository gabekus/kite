import KiteCore
import SwiftUI

/// View → Show Toolbar: Arc 1.169's bar across the top of the content card (measured
/// on the Mac): back, forward and reload on the left, the site's host in the middle,
/// Site Controls and Split View on the right, and a hairline under it. While it's on,
/// the sidebar drops its navigation buttons and URL field.
struct PageToolbar: View {
    let store: BrowserStore
    let actions: SidebarActions

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
        static let background = Color(red: 0x2D / 255, green: 0x2D / 255, blue: 0x2D / 255)
        static let divider = Color(red: 0x3B / 255, green: 0x3B / 255, blue: 0x3B / 255)
        static let enabled = Color(red: 0xC3 / 255, green: 0xC3 / 255, blue: 0xC3 / 255)
        static let disabled = Color(red: 0x6C / 255, green: 0x6C / 255, blue: 0x6C / 255)
        static let text = Color(red: 0xD2 / 255, green: 0xD2 / 255, blue: 0xD2 / 255)
    }

    var body: some View {
        let selected = store.state.selectedTab
        let page = selected.flatMap { store.pages[$0.id] } ?? PageStatus()
        ZStack {
            HStack(spacing: 0) {
                button("arrow.left", "Back", enabled: page.canGoBack, action: actions.goBack)
                button("arrow.right", "Forward", enabled: page.canGoForward, action: actions.goForward)
                button(page.isLoading ? "xmark" : "arrow.clockwise", "Reload", enabled: selected != nil, action: actions.reload)
                Spacer()
                // Kite has neither yet; shown as in Arc, disabled.
                button("slider.horizontal.3", "Site Controls", enabled: false) {}
                button("rectangle.split.2x1", "Add Split View", enabled: false) {}
            }
            .padding(.leading, Metrics.leading)
            .padding(.trailing, Metrics.trailing)

            Button { store.showCommandBar(selected == nil ? .newTab : .editCurrent) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "link")
                        .font(.system(size: 11, weight: .medium))
                    Text(selected?.url?.host() ?? "")
                        .font(.system(size: Metrics.fontSize))
                        .lineLimit(1)
                }
                .foregroundStyle(Metrics.text)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
        .disabled(!enabled)
        .help(help)
    }
}
