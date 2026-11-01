import AppKit
import KiteCore
import SwiftUI

/// Arc's HoverCardShareButton: an icon-only "Share" label (`square.and.arrow.up`, 14pt semibold,
/// in a 32×32 frame) in ARCUI's SkeuPrimaryButtonStyle.
struct LinkPreviewShareButton: View {
    let action: () -> Void

    private var share: LinkPreview.Share.Type { LinkPreview.Share.self }

    var body: some View {
        Button(action: action) {
            Label {
                Text("Share")
            } icon: {
                Image(systemName: share.symbol)
                    .frame(width: share.size, height: share.size)
                    .padding(.bottom, share.symbolBottomInset)
                    .padding(.leading, share.symbolLeadingInset)
            }
            .font(.system(size: share.symbolPointSize, weight: .semibold))
        }
        .labelStyle(.iconOnly)
        .buttonStyle(SkeuPrimaryButtonStyle())
        .frame(height: share.size)
        .help("Share")
        .accessibilityIdentifier("LinkPreviewShareButton")
    }
}

/// ARCUI's SkeuPrimaryButtonStyle, from its colour assets (ARCUI_ARCUI.bundle Assets.car,
/// `PrimaryButton*`). The shape's radius, the stroke and shadow geometry and the press scale
/// are Kite's reading of the style's constants, not confirmed on screen.
struct SkeuPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SkeuPrimaryButton(configuration: configuration)
    }

    private struct SkeuPrimaryButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.colorScheme) private var scheme
        @State private var hovering = false

        private static let radius: CGFloat = 10
        /// PrimaryButtonFace / Hovered / Pressed (same in light and dark).
        private static let face = Color(.sRGB, red: 0.192, green: 0.224, blue: 0.984)
        private static let hovered = Color(.sRGB, red: 0.173, green: 0.200, blue: 0.886)
        private static let pressed = Color(.sRGB, red: 0.165, green: 0.188, blue: 0.835)

        /// PrimaryButtonBorder: white 0% in light, 20% in dark.
        private var border: Color { .white.opacity(scheme == .dark ? 0.2 : 0) }
        /// PrimaryButtonShadow: #3438B2 in light, #5A61FC at 50% in dark.
        private var shadow: Color {
            scheme == .dark
                ? Color(.sRGB, red: 0.353, green: 0.380, blue: 0.988, opacity: 0.5)
                : Color(.sRGB, red: 0.204, green: 0.220, blue: 0.698)
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            configuration.label
                .foregroundStyle(.white) // PrimaryButtonForeground
                .background(shape.fill(configuration.isPressed ? Self.pressed : hovering ? Self.hovered : Self.face))
                .overlay(shape.strokeBorder(border, lineWidth: 1))
                .shadow(color: shadow, radius: 0, x: 0, y: 1)
                .scaleEffect(configuration.isPressed ? 0.95 : 1)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .contentShape(shape)
                .onHover { hovering = $0 }
        }
    }
}

/// Arc's HoverCardViewShareSnapshot: the card's content drawn on its own for the shared image.
struct LinkPreviewShareSnapshot: View {
    @ObservedObject var model: LinkPreviewModel

    var body: some View {
        LinkPreviewCardContent(model: model)
            .frame(width: LinkPreview.Metrics.width)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: LinkPreview.Metrics.cornerRadius, style: .continuous))
    }
}

/// Arc's ShareMenu as the hover card builds it: a "Copy as …" item for each thing being shared
/// (the snapshot image, then the link), then Share ▸ with the system's sharing services for them.
/// It pops up at the pointer (`popUpMenuPositioningItem:atLocation:inView:` with
/// `NSEvent.mouseLocation`).
@MainActor
final class LinkPreviewShareMenu: NSObject {
    private let url: URL
    private let image: NSImage?
    private var services: [NSSharingService] = []

    init(url: URL, image: NSImage?) {
        self.url = url
        self.image = image
    }

    private var shareItems: [Any] {
        if let image { return [url, image] }
        return [url]
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if image != nil {
            menu.addItem(item(LinkPreview.Share.copyTitle("Image"), symbol: "photo.on.rectangle", action: #selector(copyImage)))
        }
        menu.addItem(item(LinkPreview.Share.copyTitle("Link"), symbol: "link", action: #selector(copyLink)))
        // Share ▸: the system's sharing services for the same items, each with its own icon.
        services = NSSharingService.sharingServices(forItems: shareItems)
        if !services.isEmpty {
            let submenu = NSMenu()
            for (index, service) in services.enumerated() {
                let entry = NSMenuItem(title: service.menuItemTitle, action: #selector(performService(_:)), keyEquivalent: "")
                entry.target = self
                entry.tag = index
                entry.image = service.image
                submenu.addItem(entry)
            }
            let share = item("Share", symbol: LinkPreview.Share.symbol, action: nil)
            menu.addItem(share)
            menu.setSubmenu(submenu, for: share)
        }
        return menu
    }

    /// Shows the menu at the pointer and returns once it closes (menus track synchronously).
    func popUpAtPointer() {
        makeMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func item(_ title: String, symbol: String, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    @objc private func copyImage() {
        guard let image else { return }
        let pasteboard = BrowserWindowController.capturePasteboard
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    @objc private func copyLink() {
        let pasteboard = BrowserWindowController.capturePasteboard
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setString(url.absoluteString, forType: .string)
    }

    @objc private func performService(_ sender: NSMenuItem) {
        guard services.indices.contains(sender.tag) else { return }
        services[sender.tag].perform(withItems: shareItems)
    }
}
