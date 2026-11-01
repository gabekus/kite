import AppKit
import KiteCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

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

/// Arc's Library button at the leading end of the sidebar's bottom bar (`HomeBadging.HomeButton`,
/// tooltip "open Library"): clicking it opens the Library, which covers the sidebar until it's
/// exited. While files download, Arc's `DownloadProgressBadge` sits on it.
struct LibrarySidebarButton: View {
    let library: LibraryModel
    let size: CGFloat
    private var downloads: DownloadsModel { .shared }

    var body: some View {
        let list = downloads.list
        Button { library.toggle() } label: {
            ZStack {
                // Arc draws its own LibraryIcon (a template PDF); Kite uses the SF Symbol Arc's
                // MainMenu.nib gives the Library menu item.
                Image(systemName: "archivebox")
                    .font(.system(size: 15, weight: .regular))
                    .opacity(0.7)
                if !list.active.isEmpty {
                    DownloadProgressBadge(progress: list.activeFraction)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: list.active.isEmpty)
            .frame(width: size, height: size)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Library")
        .accessibilityLabel("Library")
        .accessibilityValue(list.active.isEmpty ? "" : "Downloading")
    }
}

/// Arc's `DownloadProgressBadge` (BaseHomeComponents, decompiled): a 24pt disc with a 1pt edge, a heavy
/// 10pt `arrow.down`, and a 21.5pt ring 2.5pt wide: a faint track (0.2) under the progress, which
/// eases out as it grows. The ring turns once every 1.5 s unless Reduce Motion is on. Arc takes the
/// colours from its palette (not resolved); Kite uses the sidebar's primary colour.
struct DownloadProgressBadge: View {
    enum Metrics {
        static let size: CGFloat = 24
        static let ringSize: CGFloat = 21.5
        static let ringWidth: CGFloat = 2.5
        static let edgeWidth: CGFloat = 1
        static let iconSize: CGFloat = 10
        static let turn: Double = 1.5
    }

    /// 0…1, nil while no size is known.
    let progress: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(nsColor: .windowBackgroundColor))
            Circle()
                .strokeBorder(Color.primary.opacity(0.2), lineWidth: Metrics.edgeWidth)
            Image(systemName: "arrow.down")
                .font(.system(size: Metrics.iconSize, weight: .heavy))
            Group {
                Circle()
                    .stroke(Color.primary.opacity(0.2), lineWidth: Metrics.ringWidth)
                Circle()
                    .trim(from: 0, to: progress ?? 0.1)
                    .stroke(Color.primary, style: StrokeStyle(lineWidth: Metrics.ringWidth))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut, value: progress)
            }
            .frame(width: Metrics.ringSize, height: Metrics.ringSize)
            .rotationEffect(.degrees(turning ? 360 : 0))
        }
        .frame(width: Metrics.size, height: Metrics.size)
        .onAppear { spin() }
        .onChange(of: reduceMotion) { spin() }
    }

    private func spin() {
        guard !reduceMotion else {
            turning = false
            return
        }
        withAnimation(.linear(duration: Metrics.turn).repeatForever(autoreverses: false)) { turning = true }
    }
}

/// Recent downloads, newest first: progress while downloading, then open, reveal in Finder,
/// cancel or hide each one (Arc's Library › Downloads page and its download context menu).
struct DownloadsList: View {
    /// One row's height plus the gap between rows.
    static let rowPitch: CGFloat = 54
    private var downloads: DownloadsModel { .shared }

    var body: some View {
        let items = downloads.list.items
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads")
                    // The same title as the Library's Archive page.
                    .font(.system(size: 20, weight: .regular))
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
            .padding(.horizontal, 20)
            .frame(height: 56)

            Divider()

            if items.isEmpty {
                // Arc's Downloads page empty-state subtitle (its title isn't in the strings).
                Text("Come back after you've found some cool stuff to save.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
