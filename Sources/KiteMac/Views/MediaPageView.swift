import AVKit
import AppKit
import KiteCore
import QuickLookThumbnailing
import SwiftUI

/// Arc's Library › Media page (Window › View Media…; `MediaPage` in `HomeButton`), from Arc 1.171's
/// strings: the pictures and videos from the Documents, Desktop and Downloads folders and screenshots,
/// "alongside your Captures", newest first under "Today", "Yesterday" and "Earlier This Week"; a search;
/// a "Show media from:" menu toggling Documents, Desktop, Screenshots, Arc Captures and Downloads; a
/// welcome card ("Your Media in the Library") before it reads any folder; a preview on click; and a
/// context menu with Copy, Show in Finder, Open in Preview, Open/Copy Source URL and Delete for a
/// Capture, Hide from Arc for a file. Shown in the Library (`LibraryView`).
/// Grid and card sizes are Kite's: Arc's page wasn't measured.
struct MediaPageView: View {
    /// Opens a Capture's page in a new tab.
    let openURL: (URL) -> Void
    private var model: MediaLibraryModel { .shared }

    @State private var query = ""
    @State private var previewing: MediaLibrary.Item?

    enum Metrics {
        static let maxWidth: CGFloat = 960
        static let tileMinWidth: CGFloat = 160
        static let tileHeight: CGFloat = 120
        static let tileRadius: CGFloat = 8
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if let previewing {
                MediaPreview(item: previewing) { self.previewing = nil }
            }
        }
        // Esc closes the preview wherever focus is (the search field keeps it after a search).
        .onExitCommand { previewing = nil }
        .onAppear { model.pageAppeared() }
        .onDisappear { model.pageDisappeared() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Media")
    }

    private var filter: MediaLibrary.Filter { .init(query: query, sources: model.sources) }

    private var header: some View {
        HStack(spacing: 16) {
            Text("Media")
                .font(.system(size: 20, weight: .regular))
                .frame(width: 160, alignment: .leading)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search media", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("mediaSearch")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Clear Search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .frame(maxWidth: 680)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            sourceMenu
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }

    private var sourceMenu: some View {
        Menu {
            Section("Show media from:") {
                ForEach(MediaLibrary.Source.allCases, id: \.self) { source in
                    Toggle(source.title, isOn: Binding(
                        get: { model.sources.contains(source) },
                        set: { on in
                            if on { model.sources.insert(source) } else { model.sources.remove(source) }
                        }))
                }
            }
        } label: {
            Image(systemName: model.sources.count == MediaLibrary.Source.allCases.count
                  ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 16))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show media from:")
        .accessibilityLabel("Show media from")
    }

    @ViewBuilder
    private var content: some View {
        let sections = MediaLibrary.sections(model.items, filter: filter, hidden: model.hidden)
        ScrollView {
            VStack(spacing: 16) {
                if !model.isOnboarded { WelcomeCard(allow: model.allowAccess) }
                if sections.isEmpty {
                    emptyState
                } else {
                    ForEach(sections, id: \.bucket) { section in
                        sectionView(section)
                    }
                }
            }
            .frame(maxWidth: Metrics.maxWidth)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(spacing: 6) {
            if !trimmed.isEmpty {
                Text("No results found for \u{201C}\(trimmed)\u{201D}")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            } else if model.isOnboarded {
                // Arc's empty-state copy, with Kite for Arc.
                Text("Save media to your Documents, Desktop, and Download Folders to see them here, alongside your Captures in Kite.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func sectionView(_ section: MediaLibrary.Section) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title())
                .font(.system(size: 13, weight: .semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.tileMinWidth), spacing: 12)], spacing: 12) {
                ForEach(section.items) { item in
                    MediaTile(item: item, open: { previewing = item })
                        .contextMenu { menu(for: item) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func menu(for item: MediaLibrary.Item) -> some View {
        Button("Copy") { Self.copy(item) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.file]) }
        Button("Open in Preview") { Self.openInPreview(item) }
        if let url = item.sourceURL {
            Divider()
            Button("Open Source URL") { openURL(url) }
            Button("Copy Source URL") {
                let pasteboard = BrowserWindowController.capturePasteboard
                pasteboard.clearContents()
                pasteboard.setString(url.absoluteString, forType: .string)
            }
        }
        Divider()
        if item.captureID != nil {
            Button("Delete") { model.deleteCapture(item) }
        } else {
            Button("Hide from Kite") { model.hide(item) }
        }
    }

    /// The file, so Finder and Mail paste it, and a picture's image for everything else.
    private static func copy(_ item: MediaLibrary.Item) {
        let pasteboard = BrowserWindowController.capturePasteboard
        pasteboard.clearContents()
        var objects: [NSPasteboardWriting] = [item.file as NSURL]
        if item.kind == .image, let image = NSImage(contentsOf: item.file) { objects.append(image) }
        pasteboard.writeObjects(objects)
    }

    private static func openInPreview(_ item: MediaLibrary.Item) {
        guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
            NSWorkspace.shared.open(item.file)
            return
        }
        NSWorkspace.shared.open([item.file], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Arc's welcome state: "Your Media in the Library", what the page does, that media stays on the Mac,
/// and an "Allow Access" button (Arc's empty-state action title).
private struct WelcomeCard: View {
    let allow: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Your Media in the Library")
                .font(.system(size: 15, weight: .semibold))
            Text("Quickly grab screenshots, images, and videos from your computer by showing them in the Kite Library!")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
            Text("Media never leaves your computer and is not viewable by anyone but you.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Allow Access", action: allow)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
        }
        .frame(maxWidth: 420)
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: MediaPageView.Metrics.tileRadius, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: MediaPageView.Metrics.tileRadius, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your Media in the Library")
    }
}

private struct MediaTile: View {
    let item: MediaLibrary.Item
    let open: () -> Void
    @State private var thumbnail: NSImage?
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(Color.primary.opacity(0.06))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: item.kind == .video ? "film" : "photo")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if item.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                        .padding(6)
                        .shadow(radius: 2)
                }
            }
            .frame(height: MediaPageView.Metrics.tileHeight)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: MediaPageView.Metrics.tileRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: MediaPageView.Metrics.tileRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(hovered ? 0.3 : 0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(item.name)
        .accessibilityLabel(item.name)
        .task(id: item.file) { thumbnail = await Self.thumbnail(for: item.file) }
    }

    private static func thumbnail(for file: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: file, size: CGSize(width: 320, height: 240), scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}

/// Arc's media preview (`MediaPreviewWindow` with a backdrop): the picture or video large over the
/// page. Esc or a click on the backdrop closes it. Kite draws it in the page rather than a window.
private struct MediaPreview: View {
    let item: MediaLibrary.Item
    let close: () -> Void
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
            Group {
                if item.kind == .video {
                    VideoPlayer(player: AVPlayer(url: item.file))
                } else if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .padding(40)
        }
        // Takes the keyboard from the page underneath, so Esc reaches the preview.
        .background(EscapeCatcher(onEscape: close))
        .task(id: item.file) {
            guard item.kind == .image else { return }
            image = NSImage(contentsOf: item.file)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview \(item.name)")
    }
}

/// Becomes first responder when it appears (the tab's engine view otherwise keeps the keyboard) and
/// closes on Esc.
private struct EscapeCatcher: NSViewRepresentable {
    let onEscape: () -> Void

    final class View: NSView {
        var onEscape: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
        override func cancelOperation(_ sender: Any?) { onEscape?() }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
        }
    }

    func makeNSView(context: Context) -> View {
        let view = View()
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ view: View, context: Context) { view.onEscape = onEscape }
}
