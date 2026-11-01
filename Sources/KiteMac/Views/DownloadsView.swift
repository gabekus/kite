import AppKit
import KiteCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// This window's downloads list: a popover from the sidebar's downloads button. ⇧⌘J (Window ›
/// View Downloads…) and the button both toggle it.
@MainActor
@Observable
final class DownloadsButtonModel: NSObject, NSPopoverDelegate {
    private(set) var isListShown = false
    @ObservationIgnored weak var anchor: NSView?
    @ObservationIgnored private var popover: NSPopover?

    /// Shows the button while the list is open, even with nothing downloaded yet.
    private(set) var isButtonForced = false

    func toggle() {
        if let popover, popover.isShown { return popover.close() }
        guard let anchor, anchor.window != nil else {
            // No downloads yet, so no button: show it, then hang the list from it.
            guard !isButtonForced else { return }
            isButtonForced = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                if self.anchor?.window != nil { self.toggle() } else { self.isButtonForced = false }
            }
            return
        }
        let popover = NSPopover()
        let host = NSHostingController(rootView: DownloadsList())
        // Sized before it shows and as the list changes, so the popover stays on its button.
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.contentSize = host.view.fittingSize
        popover.behavior = .transient
        popover.delegate = self
        // Above the button: it sits at the bottom of the window.
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: anchor.isFlipped ? .minY : .maxY)
        self.popover = popover
        isListShown = true
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        isListShown = false
        isButtonForced = false
    }
}

/// Arc's download colours, from its asset catalogs (`assetutil --info`): the Little Arc
/// downloads tray's DownloadItemBackground / DownloadItemBackgroundHovered, and BaseAssets'
/// DownloadProgressBarBackground.
private enum DownloadColors {
    static let rowHovered = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(displayP3Red: 0.12, green: 0.12, blue: 0.12, alpha: 1)
            : NSColor(displayP3Red: 0.96, green: 0.96, blue: 0.96, alpha: 1)
    })
    static let progressTrack = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(srgbRed: 0.443, green: 0.467, blue: 0.51, alpha: 1)
            : NSColor(srgbRed: 0.808, green: 0.843, blue: 0.906, alpha: 1)
    })
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

/// Downloads in the sidebar's bottom bar, where Arc's Library button carries its
/// DownloadProgressBadge. Shown once there's something in the list; a ring fills while
/// files are downloading. Clicking opens the list.
struct DownloadsSidebarButton: View {
    let model: DownloadsButtonModel
    let size: CGFloat
    private var downloads: DownloadsModel { .shared }

    var body: some View {
        let list = downloads.list
        if !list.items.isEmpty || model.isListShown || model.isButtonForced {
            Button { model.toggle() } label: {
                ZStack {
                    if !list.active.isEmpty {
                        Circle()
                            .stroke(DownloadColors.progressTrack, lineWidth: 2)
                            .frame(width: 20, height: 20)
                        Circle()
                            .trim(from: 0, to: list.activeFraction ?? 0.1)
                            .stroke(Color.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 20, height: 20)
                            .animation(.linear(duration: 0.2), value: list.activeFraction)
                        Image(systemName: "arrow.down")
                            .font(.system(size: 9, weight: .bold))
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 15, weight: .regular))
                    }
                }
                .frame(width: size, height: size)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(0.7)
            .help("Downloads")
            .accessibilityLabel("Downloads")
            .background(DownloadsAnchor(model: model))
        }
    }
}

/// Hands the button's NSView to the model, which anchors the popover to it.
private struct DownloadsAnchor: NSViewRepresentable {
    let model: DownloadsButtonModel

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { model.anchor = view }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if model.anchor !== nsView { model.anchor = nsView }
    }
}

/// Recent downloads, newest first: progress while downloading, then open, reveal in Finder,
/// cancel or hide each one (Arc's Library › Downloads page and its download context menu).
/// The sidebar's popover and the Library's Downloads page both show it.
struct DownloadsList: View {
    /// One row's height plus the gap between rows.
    static let rowPitch: CGFloat = 54
    /// In the Library: fills the page instead of a 320pt popover.
    var fillsPage = false
    private var downloads: DownloadsModel { .shared }

    var body: some View {
        let items = downloads.list.items
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads")
                    // In the Library, the same title as the Archive page's.
                    .font(.system(size: fillsPage ? 20 : 13, weight: fillsPage ? .regular : .semibold))
                Spacer()
                if items.contains(where: { $0.state != .inProgress }) {
                    Button("Clear") { downloads.clearFinished() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Button {
                    NSWorkspace.shared.open(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .focusEffectDisabled()
                .help("Open Downloads Folder")
            }
            .padding(.horizontal, fillsPage ? 20 : 14)
            .padding(.top, fillsPage ? 0 : 12)
            .padding(.bottom, fillsPage ? 0 : 8)
            .frame(height: fillsPage ? 56 : nil)

            if fillsPage { Divider() }

            if items.isEmpty && fillsPage {
                // Arc's Downloads page empty-state subtitle (its title isn't in the strings).
                Text("Come back after you've found some cool stuff to save.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                Text("No downloads yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else if fillsPage {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(items) { item in
                            DownloadRow(item: item)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(items) { item in
                            DownloadRow(item: item)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                .frame(height: min(CGFloat(items.count) * DownloadsList.rowPitch + 6, 360))
            }
        }
        .frame(width: fillsPage ? nil : 320)
        .frame(maxWidth: fillsPage ? .infinity : nil, maxHeight: fillsPage ? .infinity : nil, alignment: .top)
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    @State private var hovering = false
    private var downloads: DownloadsModel { .shared }

    var body: some View {
        let exists = downloads.fileExists(item)
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 32, height: 32)
                .opacity(item.state == .complete && !exists ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.fileName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.state == .inProgress {
                    ProgressBar(fraction: item.fraction)
                }
                Text(item.state == .complete && !exists ? "File deleted or moved" : DownloadText.subtitle(item))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if item.state == .inProgress {
                RowButton(symbol: "xmark.circle.fill", help: "Cancel Download") { downloads.cancel(item) }
            } else if exists {
                RowButton(symbol: "magnifyingglass.circle.fill", help: "Show in Finder") { downloads.reveal(item) }
                    .opacity(hovering ? 1 : 0)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: DownloadsList.rowPitch - 2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? DownloadColors.rowHovered : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if item.state == .complete { downloads.open(item) } }
        .contextMenu {
            Button("Open") { downloads.open(item) }.disabled(item.state != .complete || !exists)
            Button("Copy") { downloads.copy(item) }.disabled(!exists)
            Button("Show in Finder") { downloads.reveal(item) }.disabled(!exists)
            Divider()
            Button("Hide from Kite") { downloads.remove(item) }
            Button("Move to Trash") { downloads.moveToTrash(item) }.disabled(!exists || item.state == .inProgress)
            if item.state == .inProgress {
                Divider()
                Button("Cancel Download") { downloads.cancel(item) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.fileName)
    }

    private var icon: NSImage {
        if !item.path.isEmpty, FileManager.default.fileExists(atPath: item.path) {
            return NSWorkspace.shared.icon(forFile: item.path)
        }
        let ext = (item.fileName as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }
}

private struct ProgressBar: View {
    let fraction: Double?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(DownloadColors.progressTrack)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: proxy.size.width * (fraction ?? 0.15))
                    .animation(.linear(duration: 0.2), value: fraction)
            }
        }
        .frame(height: 4)
    }
}

private struct RowButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
