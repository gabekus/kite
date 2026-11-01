import AppKit
import KiteCore
import SwiftUI

/// Arc's tab switcher overlay (`ModalItemSwitcherView`): a rounded panel centred over the window with a
/// row of cards, one per recent tab, each a picture of the page above its favicon and title. The highlight
/// behind the focused card slides between cards. Numbers from Arc 1.171's binary (docs/arc-visual-spec.md).
struct RecentTabSwitcherView: View {
    enum Metrics {
        /// The panel's corner radius and its shadow's blur (black at 50%).
        static let panelRadius: CGFloat = 24
        /// Padding around the row of cards inside the panel.
        static let rowPadding: CGFloat = 16
        /// Padding around each card, inside its highlight.
        static let itemPadding: CGFloat = 12
        /// The focus highlight's corner radius.
        static let highlightRadius: CGFloat = 8
        /// The page picture's corner radius.
        static let cardRadius: CGFloat = 6
        /// Between the card and its favicon and title, and between the favicon and the title.
        static let labelSpacing: CGFloat = 8
        static let titleSize: CGFloat = 14
        static let faviconSize: CGFloat = 16
        /// The page picture's width (Arc's `preferredSnapshotWidth`; its value isn't in the binary's constants).
        static let cardWidth: CGFloat = 180
        /// The panel keeps this far from the window's edges.
        static let windowMargin: CGFloat = 40
    }

    @ObservedObject var model: RecentTabSwitcherModel

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                panel(maxWidth: max(proxy.size.width - Metrics.windowMargin * 2, Metrics.cardWidth))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .environment(\.colorScheme, model.isDark ? .dark : .light)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(RecentTabSwitcher.title)
    }

    private func panel(maxWidth: CGFloat) -> some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(model.items) { item in
                        card(item)
                            .id(item.id)
                            .onTapGesture { model.onPick(item.id) }
                    }
                }
                .padding(Metrics.rowPadding)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: min(contentWidth, maxWidth))
            .background(PanelMaterial(isDark: model.isDark))
            .clipShape(RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: Metrics.panelRadius / 2)
            .onChange(of: model.focusedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.1)) { reader.scrollTo(id, anchor: .center) }
            }
            .onAppear { if let id = model.focusedID { reader.scrollTo(id, anchor: .center) } }
        }
    }

    private var contentWidth: CGFloat {
        CGFloat(model.items.count) * (Metrics.cardWidth + Metrics.itemPadding * 2) + Metrics.rowPadding * 2
    }

    private func card(_ item: RecentTabSwitcherModel.Item) -> some View {
        let focused = item.id == model.focusedID
        return VStack(alignment: .leading, spacing: Metrics.labelSpacing) {
            picture(item)
                .frame(width: Metrics.cardWidth, height: (Metrics.cardWidth * model.cardAspect).rounded())
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 2)
                )
                .shadow(color: .black.opacity(0.06), radius: 2)
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            HStack(spacing: Metrics.labelSpacing) {
                FaviconView(tab: item.tab, size: Metrics.faviconSize)
                Text(item.title)
                    .font(.system(size: Metrics.titleSize, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 2)
            .frame(width: Metrics.cardWidth, alignment: .leading)
        }
        .padding(Metrics.itemPadding)
        .background(
            RoundedRectangle(cornerRadius: Metrics.highlightRadius, style: .continuous)
                .fill(Color.primary.opacity(focused ? 0.15 : 0))
        )
        .animation(.spring(response: 0.15, dampingFraction: 0.95), value: focused)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(focused ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private func picture(_ item: RecentTabSwitcherModel.Item) -> some View {
        if let snapshot = item.snapshot {
            Image(nsImage: snapshot)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Metrics.cardWidth, height: (Metrics.cardWidth * model.cardAspect).rounded(), alignment: .top)
        } else {
            // Not on screen yet this session: the site's icon on the card's tint.
            ZStack {
                Color.primary.opacity(0.05)
                FaviconView(tab: item.tab, size: 32)
            }
        }
    }
}

private struct PanelMaterial: NSViewRepresentable {
    let isDark: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.state = .active
        view.material = .hudWindow
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}
