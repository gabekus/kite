#if canImport(CEFBridge)
import AppKit
import KiteCore
import SwiftUI

/// Pinned extension icons and the extensions button, on the right of the page toolbar,
/// as in Arc 1.169's content toolbar (measured on the Mac with the masked probe):
/// 16pt icons on a 36pt pitch, 8pt below the bar's top, then a 32×28 button 2pt below
/// the top, 12pt after the last icon. Its menu is a 262pt popover hanging from it.
struct ExtensionsToolbarItems: View {
    @ObservedObject var model: ExtensionsModel
    @State private var showsMenu = false

    enum Metrics {
        static let iconSize: CGFloat = 16
        static let iconPitch: CGFloat = 36
        static let buttonSize = CGSize(width: 32, height: 28)
        /// From the last icon's right edge to the button's left edge.
        static let buttonGap: CGFloat = 12
        /// From the button's right edge to Site Controls' 16pt icon (Arc: 1973 → 1985).
        static let siteControlsGap: CGFloat = 12
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(model.pinned) { item in
                PinnedExtensionButton(item: item, model: model)
            }
            Button { showsMenu.toggle() } label: {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PageToolbar.Metrics.enabled)
                    .frame(width: Metrics.buttonSize.width, height: Metrics.buttonSize.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Extensions")
            .accessibilityLabel("Extensions")
            // The pinned icons' 36pt slots leave 10pt after the last icon.
            .padding(.leading, model.pinned.isEmpty ? 0 : Metrics.buttonGap - (Metrics.iconPitch - Metrics.iconSize) / 2)
            .popover(isPresented: $showsMenu, arrowEdge: .bottom) {
                ExtensionsMenu(model: model) { showsMenu = false }
            }
        }
        .onAppear { model.refresh() }
        .onChange(of: showsMenu) { _, shown in if shown { model.refresh() } }
    }
}

/// One pinned extension: clicking opens its popup under the icon.
private struct PinnedExtensionButton: View {
    let item: InstalledExtension
    let model: ExtensionsModel
    @State private var anchor: NSView?

    var body: some View {
        Button { openPopup() } label: {
            ExtensionIcon(file: item.iconFile, size: ExtensionsToolbarItems.Metrics.iconSize)
                .frame(width: ExtensionsToolbarItems.Metrics.iconPitch, height: PageToolbar.Metrics.height)
                .background(AnchorView(view: $anchor))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.name)
        .accessibilityLabel(item.name)
        .contextMenu { ExtensionActions(item: item, model: model) }
    }

    private func openPopup() {
        guard let anchor else { return }
        if let popup = item.popupURL {
            ExtensionPopover.show(popup, engine: model.engine, relativeTo: anchor.bounds, of: anchor)
        } else if let options = item.optionsURL {
            ExtensionPopover.show(options, engine: model.engine, relativeTo: anchor.bounds, of: anchor)
        }
    }
}

/// The extensions popover: every extension as a tile (click opens its popup; the
/// right-click menu pins, turns off or removes it), as in Arc's: 13pt inset, a section
/// header, then 48×32 tiles in four columns on a 56 × 40 pitch, pinned ones badged.
struct ExtensionsMenu: View {
    @ObservedObject var model: ExtensionsModel
    let dismiss: () -> Void

    enum Metrics {
        static let width: CGFloat = 262
        static let inset: CGFloat = 13
        static let tileSize = CGSize(width: 48, height: 32)
        static let columnPitch: CGFloat = 56
        static let rowPitch: CGFloat = 40
        static let badgeSize: CGFloat = 14
        static let iconSize: CGFloat = 20
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Extensions")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.extensions.isEmpty {
                Text("Extensions you add from the Chrome Web Store show up here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(Metrics.tileSize.width), spacing: Metrics.columnPitch - Metrics.tileSize.width,
                                                       alignment: .leading), count: 4),
                    alignment: .leading,
                    spacing: Metrics.rowPitch - Metrics.tileSize.height
                ) {
                    ForEach(model.extensions) { item in
                        ExtensionTile(item: item, model: model, dismiss: dismiss)
                    }
                }
            }
            Button("Chrome Web Store") {
                if let url = URL(string: "https://chromewebstore.google.com/") {
                    NSApp.sendAction(#selector(AppDelegate.openURLFromExtensionsMenu(_:)), to: nil, from: url as NSURL)
                }
                dismiss()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(Metrics.inset)
        .frame(width: Metrics.width, alignment: .leading)
    }
}

private struct ExtensionTile: View {
    let item: InstalledExtension
    let model: ExtensionsModel
    let dismiss: () -> Void
    @State private var anchor: NSView?
    @State private var hovering = false

    var body: some View {
        Button { open() } label: {
            ExtensionIcon(file: item.iconFile, size: ExtensionsMenu.Metrics.iconSize)
                .opacity(item.enabled ? 1 : 0.35)
                .frame(width: ExtensionsMenu.Metrics.tileSize.width, height: ExtensionsMenu.Metrics.tileSize.height)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hovering ? 0.1 : 0.05)))
                .background(AnchorView(view: $anchor))
                .overlay(alignment: .bottomTrailing) {
                    if model.isPinned(item.id) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 7, weight: .semibold))
                            .frame(width: ExtensionsMenu.Metrics.badgeSize, height: ExtensionsMenu.Metrics.badgeSize)
                            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                            // Arc's badge sits at the tile's (37, 21): 3pt in from its right and bottom.
                            .offset(x: -3, y: -(ExtensionsMenu.Metrics.tileSize.height - 21 - ExtensionsMenu.Metrics.badgeSize))
                            .accessibilityLabel("Pinned")
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.enabled ? item.name : "\(item.name) (off)")
        .accessibilityLabel(item.name)
        .contextMenu { ExtensionActions(item: item, model: model) }
    }

    private func open() {
        guard item.enabled, let anchor, let url = item.popupURL ?? item.optionsURL else { return }
        dismiss()
        ExtensionPopover.show(url, engine: model.engine, relativeTo: anchor.bounds, of: anchor)
    }
}

/// Pin, turn on or off, options and remove: the tile's and pinned icon's right-click menu.
private struct ExtensionActions: View {
    let item: InstalledExtension
    let model: ExtensionsModel

    var body: some View {
        Button(model.isPinned(item.id) ? "Unpin" : "Pin to Toolbar") { model.setPinned(item.id, !model.isPinned(item.id)) }
            .disabled(!item.enabled && !model.isPinned(item.id))
        Button(item.enabled ? "Turn Off" : "Turn On") { model.setEnabled(item.id, !item.enabled) }
            .disabled(!item.mayDisable)
        if let options = item.optionsURL {
            Button("Options") {
                NSApp.sendAction(#selector(AppDelegate.openURLFromExtensionsMenu(_:)), to: nil, from: options as NSURL)
            }
        }
        Divider()
        Button("Remove…") { model.remove(item.id) }
    }
}

/// An extension's icon from its folder, or a puzzle piece.
private struct ExtensionIcon: View {
    let file: URL?
    let size: CGFloat

    var body: some View {
        if let file, let image = NSImage(contentsOf: file) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: "puzzlepiece.extension").font(.system(size: size * 0.75)).frame(width: size, height: size)
        }
    }
}

/// Hands SwiftUI's backing NSView to code that anchors AppKit popovers.
private struct AnchorView: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.view = view }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
