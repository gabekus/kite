import AppKit
import KiteCore
import SwiftUI

/// ⇧-hover link previews (Arc's "5-Second Previews", its `HoverCards` module): hold ⇧ over a link
/// and a card about the linked page opens next to it, in a borderless child window of the browser
/// window. It closes when the pointer leaves the link (unless it's heading for the card), on a
/// click, a scroll, Esc, or when the window stops being key.
@MainActor
final class LinkPreviewController {
    static let shared = LinkPreviewController()

    private var hovered: (hover: LinkHover, view: NSView)?
    /// The link the card is for, and the box it was placed against.
    private var shownURL: URL?
    private var shownLink: LinkPreview.Box?
    private var window: LinkPreviewWindow?
    private let model = LinkPreviewModel()
    private var monitor: Any?
    private var showWork: DispatchWorkItem?
    private var leaveWork: DispatchWorkItem?
    private var fetch: Task<Void, Never>?
    private var resignObserver: NSObjectProtocol?

    private init() {}

    /// A page reported the link under the pointer (nil: none).
    func hover(_ hover: LinkHover?, in view: NSView) {
        guard LinkPreview.isEnabled() else { return }
        installMonitor()
        guard let hover else {
            hovered = nil
            cancelShow()
            if shownURL != nil { scheduleLeaveCheck() }
            return
        }
        hovered = (hover, view)
        if hover.url == shownURL {
            leaveWork?.cancel()
            return
        }
        if Self.isShiftOnly(hover.modifiers ?? NSEvent.modifierFlags) {
            scheduleShow()
        } else {
            cancelShow()
        }
    }

    /// Closes the card now (no fade), e.g. when the tab goes away.
    func dismiss(animated: Bool = true) {
        cancelShow()
        leaveWork?.cancel()
        fetch?.cancel()
        fetch = nil
        shownURL = nil
        shownLink = nil
        guard let window else { return }
        self.window = nil
        window.close(animated: animated)
    }

    // MARK: Showing

    /// Arc debounces hover changes by 100ms before asking for a card.
    private func scheduleShow() {
        showWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showForHoveredLink() }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + LinkPreview.Timing.showDelay, execute: work)
    }

    private func cancelShow() {
        showWork?.cancel()
        showWork = nil
    }

    private func showForHoveredLink() {
        guard let (hover, view) = hovered, let parent = view.window, parent.isVisible else { return }
        leaveWork?.cancel()
        let link = Self.box(hover.screenRect ?? Self.pointerRect())
        shownURL = hover.url
        shownLink = link
        model.reset(for: hover.url)
        load(hover.url)

        let card = window ?? LinkPreviewWindow(model: model)
        if window == nil {
            window = card
            card.onSizeChange = { [weak self] in self?.layout() }
        }
        if card.parent !== parent {
            card.parent?.removeChildWindow(card)
            parent.addChildWindow(card, ordered: .above)
            observeResign(of: parent)
        }
        layout()
        card.show()
    }

    /// Places the card against the link, sized to its content.
    private func layout() {
        guard let window, let link = shownLink, let parent = window.parent else { return }
        let (frame, placement) = LinkPreview.cardFrame(link: link, cardHeight: window.cardHeight, in: Self.box(parent.frame))
        window.place(card: NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height),
                     growsDown: placement == .below)
    }

    private func load(_ url: URL) {
        fetch?.cancel()
        // Arc's card adds an AI summary; Kite's comes from its built-in Claude, when installed.
        let summarizes = LinkPreviewSummarizer.mayBeAvailable
        if summarizes, let cached = LinkPreviewSummarizer.cached(url) {
            model.summary = cached.map { .loaded($0) } ?? .none
        } else {
            model.summary = summarizes ? .loading : .none
        }
        fetch = Task { [model] in
            let page = await LinkPreviewFetcher.page(for: url, wantsText: summarizes)
            guard !Task.isCancelled, model.url == url else { return }
            let metadata = page?.metadata
            model.metadata = metadata
            model.state = metadata.map { $0.isEmpty ? .failed : .loaded } ?? .failed
            if let imageURL = metadata?.imageURL {
                Task {
                    if let image = await LinkPreviewFetcher.image(at: imageURL), model.url == url { model.image = image }
                }
            }
            guard model.summary == .loading else { return }
            var summary: LinkPreviewSummary?
            if let text = page?.text, model.state == .loaded {
                summary = await LinkPreviewSummarizer.summary(for: url, metadata: metadata, pageText: text)
            }
            if !Task.isCancelled, model.url == url { model.summary = summary.map { .loaded($0) } ?? .none }
        }
    }

    // MARK: Closing

    /// The pointer left the link: close unless it's on its way to the card or on it.
    private func scheduleLeaveCheck() {
        leaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkLeave() }
        leaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + LinkPreview.Timing.leaveDelay, execute: work)
    }

    private func checkLeave() {
        guard shownURL != nil, hovered?.hover.url != shownURL else { return }
        if let window, let link = shownLink {
            let pointer = NSEvent.mouseLocation
            if LinkPreview.isInCorridor(x: pointer.x, y: pointer.y, link: link, card: Self.box(window.cardFrame)) {
                return scheduleLeaveCheck()
            }
        }
        dismiss()
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        // Arc's HoverCardsController watches the same events (mask 0x401022 plus keys).
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            // ⇧ pressed while already over a link opens its card; let go before it opens, nothing.
            if hovered != nil, hovered?.hover.url != shownURL, Self.isShiftOnly(event.modifierFlags) {
                scheduleShow()
            } else if !event.modifierFlags.contains(.shift) {
                cancelShow()
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if event.window !== window { dismiss(animated: false) }
        case .scrollWheel:
            if event.window !== window { dismiss() }
        case .keyDown:
            if event.keyCode == 53 { dismiss() } // Esc
            else if shownURL != nil { dismiss(animated: false) }
        default:
            break
        }
    }

    private func observeResign(of parent: NSWindow) {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: parent, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(animated: false) }
        }
    }

    // MARK: Helpers

    /// Arc opens a card only for ⇧ on its own (`modifierFlags == .shift`).
    static func isShiftOnly(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.shift, .command, .option, .control]) == .shift
    }

    /// Chromium doesn't say where the link is: use a pointer-sized box at the pointer.
    private static func pointerRect() -> NSRect {
        let point = NSEvent.mouseLocation
        return NSRect(x: point.x, y: point.y - 18, width: 1, height: 18)
    }

    static func box(_ rect: NSRect) -> LinkPreview.Box {
        LinkPreview.Box(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }
}

// MARK: - Fetching

/// Reads the start of the linked page for its title, description and image. No cookies or
/// stored credentials go with the request, so a preview never acts as the user.
enum LinkPreviewFetcher {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 0)
        return URLSession(configuration: configuration)
    }()

    private static let cache = NSCache<NSURL, Box>()

    private final class Box {
        let page: Page
        init(_ page: Page) { self.page = page }
    }

    /// The page's metadata, and its readable text when `wantsText` (for the AI summary; else nil).
    struct Page {
        var metadata: LinkPreviewMetadata
        var text: String?
    }

    static func page(for url: URL, wantsText: Bool) async -> Page? {
        if let cached = cache.object(forKey: url as NSURL)?.page, cached.text != nil || !wantsText { return cached }
        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        guard let (bytes, response) = try? await session.bytes(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        let type = response.mimeType ?? "text/html"
        guard type.contains("html") else { return Page(metadata: LinkPreviewMetadata(title: url.lastPathComponent), text: nil) }
        var data = Data()
        var checked = 0
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= LinkPreviewMetadata.maxBytes { break }
                // Without the summary, stop once the head has arrived (checked every 4 KB).
                if !wantsText, data.count - checked >= 4096 {
                    let window = data[max(0, checked - 8)...]
                    if window.range(of: Data("</head>".utf8)) != nil || window.range(of: Data("</HEAD>".utf8)) != nil { break }
                    checked = data.count
                }
            }
        } catch {
            if data.isEmpty { return nil }
        }
        let html = String(decoding: data, as: UTF8.self)
        let page = Page(metadata: LinkPreviewMetadata.parse(html: html, baseURL: response.url ?? url),
                        text: wantsText ? LinkPreviewSummary.pageText(html: html) : nil)
        cache.setObject(Box(page), forKey: url as NSURL)
        return page
    }

    static func image(at url: URL) async -> NSImage? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
        return NSImage(data: data)
    }
}

// MARK: - Card

@MainActor
final class LinkPreviewModel: ObservableObject {
    enum State { case loading, loaded, failed }

    @Published var url: URL?
    @Published var state: State = .loading
    @Published var metadata: LinkPreviewMetadata?
    @Published var image: NSImage?
    @Published var summary: Summary = .none

    /// The AI summary under the title: none (no Claude, or nothing to say), loading, or its rows.
    enum Summary: Equatable {
        case none, loading
        case loaded(LinkPreviewSummary)
    }

    func reset(for url: URL) {
        self.url = url
        state = .loading
        metadata = nil
        image = nil
        summary = .none
    }
}

/// Borderless, non-activating, transparent: the card draws its own rounded background and shadow,
/// 30pt inside the window's edges, as Arc's HoverCardWindow does.
final class LinkPreviewWindow: NSPanel {
    private let hosting: NSHostingView<LinkPreviewCardView>
    private let cardState = LinkPreviewAppearance()
    var onSizeChange: (() -> Void)?
    private var lastHeight: CGFloat = 0

    init(model: LinkPreviewModel) {
        hosting = NSHostingView(rootView: LinkPreviewCardView(model: model, appearance: cardState))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        hosting.sizingOptions = []
        contentView = hosting
        hosting.postsFrameChangedNotifications = false
        NotificationCenter.default.addObserver(forName: LinkPreviewCardView.heightChanged, object: cardState, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.contentHeightChanged() }
        }
        setAccessibilityIdentifier("LinkPreviewWindow")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private var inset: CGFloat { LinkPreview.Metrics.windowInset }

    /// The card's height for its content, capped at Arc's 400.
    var cardHeight: CGFloat {
        min(max(cardState.cardHeight, 44), LinkPreview.Metrics.maxHeight)
    }

    var cardFrame: NSRect { frame.insetBy(dx: inset, dy: inset) }

    func place(card: NSRect, growsDown: Bool) {
        cardState.growsDown = growsDown
        lastHeight = card.height
        setFrame(card.insetBy(dx: -inset, dy: -inset), display: true)
    }

    private func contentHeightChanged() {
        guard isVisible, abs(cardHeight - lastHeight) > 0.5 else { return }
        onSizeChange?()
    }

    func show() {
        if !isVisible || alphaValue < 1 {
            cardState.appeared = false
            alphaValue = 0
            orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = LinkPreview.Timing.fade
                animator().alphaValue = 1
            }
        }
        DispatchQueue.main.async { [cardState] in cardState.appeared = true }
    }

    func close(animated: Bool) {
        guard animated, isVisible else {
            parent?.removeChildWindow(self)
            orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = LinkPreview.Timing.fade
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.alphaValue == 0 else { return }
                self.parent?.removeChildWindow(self)
                self.orderOut(nil)
            }
        }
    }
}

@MainActor
final class LinkPreviewAppearance: ObservableObject {
    @Published var appeared = false
    @Published var growsDown = true
    /// The card's measured height (not published: it only resizes the window).
    var cardHeight: CGFloat = 0
}

struct LinkPreviewCardView: View {
    static let heightChanged = Notification.Name("LinkPreviewCardHeightChanged")

    @ObservedObject var model: LinkPreviewModel
    @ObservedObject var appearance: LinkPreviewAppearance

    private var metrics: LinkPreview.Metrics.Type { LinkPreview.Metrics.self }

    var body: some View {
        card
            .frame(width: metrics.width)
            .frame(maxHeight: metrics.maxHeight, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            // The card keeps its own height (fixedSize) whatever the window's, so this reads its real height.
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { report(proxy.size.height) }
                    .onChange(of: proxy.size.height) { report(proxy.size.height) }
            })
            // Arc: spring(response 0.4, damping 0.75, blend 0.1) from 0.8 scale, anchored on the link's side.
            .scaleEffect(appearance.appeared ? 1 : 0.8, anchor: appearance.growsDown ? .topLeading : .bottomLeading)
            .animation(.spring(response: 0.4, dampingFraction: 0.75, blendDuration: 0.1), value: appearance.appeared)
            .frame(maxHeight: .infinity, alignment: appearance.growsDown ? .top : .bottom)
            .padding(metrics.windowInset)
    }

    private func report(_ height: CGFloat) {
        guard abs(appearance.cardHeight - height) > 0.5 else { return }
        appearance.cardHeight = height
        NotificationCenter.default.post(name: Self.heightChanged, object: appearance)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image = model.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: metrics.width, height: 150)
                    .clipped()
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 6) {
                switch model.state {
                case .loading:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(host).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    }
                case .failed:
                    Text("No preview available")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                case .loaded:
                    if let title = model.metadata?.title {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("LinkPreviewTitle")
                    }
                    if let summary = model.metadata?.summary {
                        Text(summary)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    switch model.summary {
                    case .none: EmptyView()
                    case .loading: LinkPreviewSummaryLoadingView().padding(.top, 2)
                    case .loaded(let summary): LinkPreviewSummaryView(summary: summary).padding(.top, 2)
                    }
                }
                HStack(spacing: 6) {
                    FaviconView(page: model.url, size: 14)
                    Text(model.metadata?.siteName ?? host)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.top, 2)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(LinkPreviewMaterial())
        .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        // Arc: shadow(color: black 12%, radius: 6, x: 2, y: 2).
        .shadow(color: .black.opacity(0.12), radius: 6, x: 2, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("LinkPreviewCard")
    }

    private var host: String {
        guard let host = model.url?.host() else { return model.url?.absoluteString ?? "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Arc's HoverCardSummaryView: the quick summary in bold, then the detail rows, all 13pt, 8pt apart,
/// with a line spacing of 3 (the 3 is stored next to an environment key path; reading it as line
/// spacing is inferred).
struct LinkPreviewSummaryView: View {
    let summary: LinkPreviewSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let quick = summary.quickSummary {
                Text(Self.markdown(quick))
                    .bold()
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("LinkPreviewQuickSummary")
            }
            ForEach(Array(summary.details.enumerated()), id: \.offset) { _, detail in
                LinkPreviewDetailRow(detail: detail)
            }
        }
        .font(.system(size: 13))
        .lineSpacing(3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("LinkPreviewSummary")
    }

    /// Claude is asked for Markdown inside the strings (Arc asks for "markdown formatting" too).
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Arc's HoverCardDetailRow: HStack on the first text baseline, 12pt apart; the SF Symbol bold 16pt in a
/// 12×12 frame; then the label in bold and the info, as one text.
struct LinkPreviewDetailRow: View {
    let detail: LinkPreviewSummary.Detail

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: detail.icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 12, height: 12)
                // Arc: the icon's baseline is its centre plus 0.4 of its height.
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + $0.height * 0.4 }
                .accessibilityHidden(true)
            (Text(LinkPreviewSummaryView.markdown(detail.label)).bold() + Text(" ") + Text(LinkPreviewSummaryView.markdown(detail.info)))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("LinkPreviewDetailRow")
    }
}

/// Arc's HoverCardLoadingView: 100 spaces of 13pt text, redacted as a placeholder.
struct LinkPreviewSummaryLoadingView: View {
    var body: some View {
        Text(String(repeating: " ", count: 100))
            .font(.system(size: 13))
            .lineSpacing(3)
            .redacted(reason: .placeholder)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Loading summary")
            .accessibilityIdentifier("LinkPreviewSummaryLoading")
    }
}

/// The popover material behind the card. Arc's card background (HoverCardBackgroundModifier) wasn't
/// decoded; this is Kite's guess.
private struct LinkPreviewMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
