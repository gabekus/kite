import AppKit
import SwiftUI
import KiteCore

/// Arc's Zap picker (BoostsEditor's SelectorPicker): a native overlay over the page. Moving
/// the pointer highlights the element under it; clicking one offers "Zap this" and "Zap all
/// related elements"; the shelf lists the Boost's zaps, and removing one shows it again.
/// Zaps are stored on the site's Boost (the one being edited, else the site's newest, else a
/// new one). The page side only answers where elements are (`ZapPickerScript`).
@MainActor
final class ZapPicker: NSView {
    /// Arc's numbers where they're known; see docs/arc-visual-spec.md (Zap).
    enum Metrics {
        /// SelectorPicker.swift's post-click overlay: `.frame(width: 250)`.
        static let panelWidth: CGFloat = 250
        /// Arc's BoostsRed (ARC_BoostsEditor Assets.car), the highlight colour (which Arc asset the
        /// highlight uses isn't confirmed).
        static let highlight = NSColor(srgbRed: 1, green: 0.055, blue: 0.055, alpha: 1)
        /// ZapPreviewBackground: a zap's cell on the shelf.
        static let zapCell = Color(.sRGB, red: 0.851, green: 0.851, blue: 0.851)
        static let shelfInset: CGFloat = 12
    }

    let page: WebPage
    /// The Boost zaps go to; nil until the site has one (the first zap makes it).
    private(set) var boostID: UUID?
    var onClose: (() -> Void)?

    private let model = ZapShelfModel()
    private let highlight = CAShapeLayer()
    private let related = CAShapeLayer()
    private var panel: NSHostingView<ZapPanel>?
    private var shelf: NSHostingView<ZapShelf>!
    private var hoverPoint: NSPoint?
    private var hoverInFlight = false
    /// The element clicked, while its panel is open.
    private var target: ZapTarget?
    private var domain: String?
    private var hostKnown = false

    init(page: WebPage, boostID: UUID? = nil) {
        self.page = page
        self.boostID = boostID
        super.init(frame: .zero)
        wantsLayer = true
        for layer in [related, highlight] {
            layer.fillColor = Metrics.highlight.withAlphaComponent(0.15).cgColor
            layer.strokeColor = Metrics.highlight.cgColor
            layer.lineWidth = 2
            self.layer?.addSublayer(layer)
        }
        related.lineDashPattern = [4, 3]
        related.fillColor = Metrics.highlight.withAlphaComponent(0.08).cgColor

        model.onRemove = { [weak self] selector in
            guard let self, let boostID = self.boostID else { return }
            BoostsModel.shared.removeZap(selector, from: boostID)
            self.zapsChanged()
        }
        model.onPreview = { [weak self] selector in
            guard let self else { return }
            BoostsModel.shared.applyZapsLive(to: self.page, except: selector)
        }
        model.onClose = { [weak self] in self?.onClose?() }
        shelf = NSHostingView(rootView: ZapShelf(model: model))
        shelf.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shelf)
        // Bottom centre of the page; SwiftUI sizes it as zaps come and go.
        NSLayoutConstraint.activate([
            shelf.centerXAnchor.constraint(equalTo: centerXAnchor),
            shelf.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.shelfInset),
            shelf.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -2 * Metrics.shelfInset),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(zapsChanged), name: .kiteZapsChanged, object: nil)
        // Covers the page exactly, wherever its container lays it out.
        frame = page.view.frame
        page.view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(followPage), name: NSView.frameDidChangeNotification, object: page.view)
        page.evaluateJavaScript(ZapScript.hostScript) { [weak self] host in self?.setHost(host as? String) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setHost(_ host: String?) {
        let domain = ZapLibrary.domain(ofHost: host)
        guard !hostKnown || domain != self.domain else { return }
        hostKnown = true
        self.domain = domain
        zapsChanged()
    }

    @objc private func followPage() {
        frame = page.view.frame
    }

    @objc private func zapsChanged() {
        let boost = domain.flatMap { BoostsModel.shared.zapBoost(forDomain: $0, preferring: boostID) }
        boostID = boost?.id ?? boostID
        model.zaps = boost?.zaps ?? []
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    // MARK: Pointer

    private var zoom: Double { max(page.zoomFactor, 0.01) }

    override func mouseMoved(with event: NSEvent) {
        guard target == nil else { return }
        hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        guard target == nil else { return }
        hoverPoint = nil
        highlight.path = nil
    }

    /// Asks the page what's under `point`; one question at a time, the latest point wins.
    func hover(at point: NSPoint) {
        hoverPoint = point
        guard !hoverInFlight else { return }
        hoverInFlight = true
        page.evaluateJavaScript(ZapPickerScript.hovered(x: point.x / zoom, y: point.y / zoom)) { [weak self] result in
            guard let self else { return }
            self.hoverInFlight = false
            guard self.target == nil else { return }
            let hovered = ZapTarget.decode(result)
            if let hovered { self.setHost(hovered.host) }
            self.highlight.path = hovered.map { self.path([$0.rect]) }
            if let latest = self.hoverPoint, latest != point { self.hover(at: latest) }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if target != nil { return closePanel() }
        page.evaluateJavaScript(ZapPickerScript.target(x: point.x / zoom, y: point.y / zoom)) { [weak self] result in
            guard let self, let target = ZapTarget.decode(result) else { return }
            self.setHost(target.host)
            guard self.domain != nil, target.selector != nil || target.related != nil else { return NSSound.beep() }
            self.showPanel(for: target)
        }
    }

    /// The page scrolls under the overlay as usual.
    override func scrollWheel(with event: NSEvent) {
        guard let superview else { return }
        let point = superview.convert(event.locationInWindow, from: nil)
        isHidden = true
        let hit = superview.hitTest(point)
        isHidden = false
        hit?.scrollWheel(with: event)
        if target != nil { closePanel() }
        if let hoverPoint { hover(at: hoverPoint) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            target != nil ? closePanel() : onClose?()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: Panel

    private func showPanel(for target: ZapTarget) {
        self.target = target
        highlight.path = path([target.rect])
        let host = NSHostingView(rootView: ZapPanel(
            canZapRelated: target.related != nil,
            canZapThis: target.selector != nil,
            onZapThis: { [weak self] in self?.zap(target.selector) },
            onZapRelated: { [weak self] in self?.zap(target.related) },
            onHoverRelated: { [weak self] hovering in
                guard let self else { return }
                self.related.path = hovering ? self.path(target.relatedRects ?? []) : nil
            },
            onCancel: { [weak self] in self?.closePanel() }
        ))
        panel?.removeFromSuperview()
        panel = host
        addSubview(host)
        let size = host.fittingSize
        let rect = scaled(target.rect)
        // Below the element when there's room, else above it, kept inside the page.
        var y = rect.maxY + 8
        if y + size.height > bounds.height - Metrics.shelfInset { y = max(rect.minY - 8 - size.height, Metrics.shelfInset) }
        let x = min(max(rect.minX, Metrics.shelfInset), max(bounds.width - size.width - Metrics.shelfInset, Metrics.shelfInset))
        host.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func closePanel() {
        target = nil
        panel?.removeFromSuperview()
        panel = nil
        related.path = nil
        highlight.path = nil
    }

    private func zap(_ selector: String?) {
        guard let selector, let domain else { return }
        closePanel()
        boostID = BoostsModel.shared.addZap(selector, domain: domain, preferring: boostID) ?? boostID
        zapsChanged()
    }

    // MARK: Geometry

    private func scaled(_ rect: ZapTarget.Rect) -> NSRect {
        NSRect(x: rect.x * zoom, y: rect.y * zoom, width: rect.width * zoom, height: rect.height * zoom)
    }

    private func path(_ rects: [ZapTarget.Rect]) -> CGPath {
        let path = CGMutablePath()
        for rect in rects { path.addRect(scaled(rect).insetBy(dx: 1, dy: 1)) }
        return path
    }
}

/// What the shelf shows, and what its buttons do.
@MainActor
final class ZapShelfModel: ObservableObject {
    @Published var zaps: [String] = []
    var onRemove: ((String) -> Void)?
    /// A cell is hovered (its zap shows again meanwhile), or nil when none is.
    var onPreview: ((String?) -> Void)?
    var onClose: (() -> Void)?
}

/// Arc's BoostsEditorShelfView while zapping: "Click elements on the page to **Zap** them",
/// then one cell per zap (IndividualZapCell) that removes it.
struct ZapShelf: View {
    @ObservedObject var model: ZapShelfModel
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                (Text("Click elements on the page to ") + Text("Zap").bold() + Text(" them"))
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Button(action: { model.onClose?() }) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Hide Selector Picker")
                .accessibilityLabel("Hide Selector Picker")
            }
            if !model.zaps.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.zaps, id: \.self) { zap in
                            cell(zap)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 320, maxWidth: 560, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
    }

    private func cell(_ zap: String) -> some View {
        HStack(spacing: 6) {
            Text(zap)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180)
            Button(action: { model.onRemove?(zap) }) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove zap")
        }
        .foregroundStyle(Color.black.opacity(0.8))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(ZapPicker.Metrics.zapCell, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { inside in
            hovered = inside ? zap : (hovered == zap ? nil : hovered)
            model.onPreview?(hovered)
        }
    }
}

/// Arc's post-click overlay: "Zap this", "Zap all related elements" and "Cancel", 250pt wide.
struct ZapPanel: View {
    var canZapRelated: Bool
    var canZapThis: Bool
    var onZapThis: () -> Void
    var onZapRelated: () -> Void
    var onHoverRelated: (Bool) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            if canZapThis {
                button("Zap this", action: onZapThis)
            }
            if canZapRelated {
                button("Zap all related elements", action: onZapRelated)
                    .onHover(perform: onHoverRelated)
            }
            button("Cancel", prominent: false, action: onCancel)
        }
        .padding(8)
        .frame(width: ZapPicker.Metrics.panelWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
    }

    private func button(_ title: String, prominent: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13, weight: prominent ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(prominent ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
