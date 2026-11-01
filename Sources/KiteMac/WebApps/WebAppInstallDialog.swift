import AppKit
import KiteCore
import Observation
import SwiftUI

// Chrome's install flow for an installable site, reimplemented from Chromium's source (BSD; nothing
// copied): WebAppInstallFlowDialogDelegate (chrome/browser/ui/views/web_apps/web_app_install_flow_dialog_delegate.cc),
// WebAppInstallIntroView, WebAppInstallOptionsView, WebAppInstallProgressView, WebAppIconNameAndOriginView
// and ImageCarouselView. Strings are Chrome's en-US ones (CEF's en.lproj/locale.pak, ids 9449-9454).
//
// Steps: the intro ("Install app", the subtitle, the app card; Learn More, Cancel, Next) → the Mac
// installer options (the app's icon, an arrow, the Kite Apps folder; Install) → progress ("Installing
// app…", no buttons) → done ("Successfully installed"; Open tab in app, Show in Finder). The intro is
// "detailed" (a card with the description and a screenshot carousel) when the manifest has wide
// screenshots, else "simple" (a banner, then the icon, name and origin).

@MainActor
@Observable
final class WebAppInstallFlow {
    enum Step: Equatable { case intro, options, progress, success }

    let name: String
    let origin: String
    let icon: NSImage
    let description: String?
    let screenshots: [NSImage]
    var step: Step = .intro
    var progress: Double = 0

    var isDetailed: Bool { !screenshots.isEmpty }

    @ObservationIgnored var onLearnMore: () -> Void = {}
    @ObservationIgnored var onCancel: () -> Void = {}
    /// Installs; calls back with success.
    @ObservationIgnored var onInstall: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    @ObservationIgnored var onOpenApp: () -> Void = {}
    @ObservationIgnored var onShowInFinder: () -> Void = {}

    init(name: String, origin: String, icon: NSImage, description: String?, screenshots: [NSImage]) {
        self.name = name
        self.origin = origin
        self.icon = icon
        self.description = description
        self.screenshots = screenshots
    }

    /// Chrome's title for each step.
    var title: String {
        switch step {
        case .intro, .options: "Install app"
        case .progress: "Installing app…"
        case .success: "Successfully installed"
        }
    }

    /// The OK button: Next, then Install, then Open tab in app (hidden while installing).
    func advance() {
        switch step {
        case .intro:
            step = .options
        case .options:
            step = .progress
            // Chrome's ProgressDelay fills the bar to 90% while it works, the rest once installed.
            withAnimation(.easeInOut(duration: 0.6)) { progress = 0.9 }
            let started = Date()
            onInstall { [weak self] success in
                guard let self else { return }
                guard success else { return self.onCancel() }
                let wait = max(0, 0.6 - Date().timeIntervalSince(started))
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                    withAnimation(.easeOut(duration: 0.2)) { self.progress = 1 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.step = .success }
                }
            }
        case .progress:
            break
        case .success:
            onOpenApp()
        }
    }
}

/// Dialog metrics: Chrome's layout-provider defaults where the Chromium source names them; the
/// rest are Kite's (not measured against Chrome on screen).
enum WebAppInstallDialogMetrics {
    /// Chrome's medium dialog width (unmeasured on screen).
    static let width: CGFloat = 448
    static let padding: CGFloat = 20
    static let cornerRadius: CGFloat = 12
    /// WebAppInstallIntroView: kManifestDetailsPadding, kManifestDetailsCornerRadius.
    static let cardPadding: CGFloat = 16
    static let cardCornerRadius: CGFloat = 8
    /// DISTANCE_RELATED_CONTROL_VERTICAL / _HORIZONTAL.
    static let verticalSpacing: CGFloat = 8
    static let iconLabelSpacing: CGFloat = 8
    /// web_app::kIconSize.
    static let iconSize: CGFloat = 32
    /// ImageCarouselView: the throbber's 50pt diameter plus 65pt above and below.
    static let screenshotHeight: CGFloat = 50 + 2 * 65
    static let screenshotSpacing: CGFloat = 8
    /// The carousel's scroll buttons: kIconSize pills, kSpacingBetweenImages in from each edge.
    static let scrollButtonSize: CGFloat = 32
    static let scrollAnimation: Double = 0.5
    /// WebAppInstallOptionsView (Mac): the 80pt app icon, a 64×94 arrow, the folder at kLargeImageSize.
    static let largeIconSize: CGFloat = 80
    static let buttonHeight: CGFloat = 32
}

struct WebAppInstallDialog: View {
    @Bindable var flow: WebAppInstallFlow
    private typealias M = WebAppInstallDialogMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if flow.step == .intro, !flow.isDetailed {
                WebAppInstallBanner(icon: flow.icon)
                    .padding(.bottom, 16)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(flow.title)
                    .font(.system(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                if flow.step == .intro {
                    Text("Access this site in a dedicated window on your computer")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
            }
            .padding(.horizontal, M.padding)
            .padding(.top, flow.step == .intro && !flow.isDetailed ? 0 : M.padding)

            Group {
                switch flow.step {
                case .intro: intro
                case .options: options
                case .progress: ProgressView(value: flow.progress).progressViewStyle(.linear)
                case .success: IconNameAndOrigin(icon: flow.icon, name: flow.name, origin: flow.origin)
                }
            }
            .padding(.horizontal, M.padding)
            .padding(.top, 16)

            if flow.step != .progress {
                buttons
                    .padding(.horizontal, M.padding)
                    .padding(.top, 20)
            }
            Spacer().frame(height: M.padding)
        }
        .frame(width: M.width, alignment: .leading)
        .background {
            // Opaque, like Chrome's dialog: a material would take on the page's colours behind it.
            RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        }
        .overlay(RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(flow.title)
    }

    @ViewBuilder private var intro: some View {
        if flow.isDetailed {
            // WebAppInstallIntroView's highlighted box of manifest details.
            VStack(alignment: .leading, spacing: M.verticalSpacing) {
                VStack(alignment: .leading, spacing: M.verticalSpacing) {
                    IconNameAndOrigin(icon: flow.icon, name: flow.name, origin: flow.origin)
                    if let description = flow.description {
                        Text(description)
                            .font(.system(size: 13))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Description")
                            .accessibilityValue(description)
                    }
                }
                .padding(.horizontal, M.cardPadding)
                ScreenshotCarousel(images: flow.screenshots)
            }
            .padding(.vertical, M.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: M.cardCornerRadius, style: .continuous))
        } else {
            IconNameAndOrigin(icon: flow.icon, name: flow.name, origin: flow.origin)
        }
    }

    /// The Mac installer options: the app's icon with its host, an arrow, the folder it goes in.
    private var options: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(spacing: 6) {
                Image(nsImage: flow.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: M.largeIconSize, height: M.largeIconSize)
                    .shadow(color: .black.opacity(0.24), radius: 2, y: 2)
                Text(flow.origin).font(.system(size: 11)).foregroundStyle(Color(nsColor: .secondaryLabelColor)).lineLimit(1).truncationMode(.middle)
            }
            .frame(width: M.largeIconSize + 40)
            Image(systemName: "arrow.right")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: 64, height: 94)
                .padding(.bottom, 20)
            VStack(spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                    .resizable()
                    .frame(width: M.largeIconSize, height: M.largeIconSize)
                Text(WebAppShim.folderName).font(.system(size: 11)).foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
            .frame(width: M.largeIconSize + 40)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if flow.step == .intro || flow.step == .options {
                DialogButton(title: "Learn More", prominent: false, action: flow.onLearnMore)
            }
            Spacer(minLength: 0)
            switch flow.step {
            case .intro, .options:
                DialogButton(title: "Cancel", prominent: false, action: flow.onCancel)
                    .keyboardShortcut(.cancelAction)
                DialogButton(title: flow.step == .intro ? "Next" : "Install", prominent: true) { flow.advance() }
            case .success:
                DialogButton(title: "Show in Finder", prominent: false, action: flow.onShowInFinder)
                DialogButton(title: "Open tab in app", prominent: true) { flow.advance() }
            case .progress:
                EmptyView()
            }
        }
    }
}

/// WebAppIconNameAndOriginView: the 32pt icon, then the name over the origin.
private struct IconNameAndOrigin: View {
    let icon: NSImage
    let name: String
    let origin: String
    private typealias M = WebAppInstallDialogMetrics

    var body: some View {
        HStack(spacing: M.iconLabelSpacing) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: M.iconSize, height: M.iconSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(origin).font(.system(size: 12)).foregroundStyle(Color(nsColor: .secondaryLabelColor)).lineLimit(1).truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// ImageCarouselView: screenshots 180pt tall in a row, 8pt apart, from 16pt in; a round › button at
/// the trailing edge while more are hidden, ‹ once scrolled, each scrolling by the images that fit.
private struct ScreenshotCarousel: View {
    let images: [NSImage]
    @State private var offset: CGFloat = 0
    private typealias M = WebAppInstallDialogMetrics

    private func width(of image: NSImage) -> CGFloat {
        guard image.size.height > 0 else { return M.screenshotHeight }
        let scaled = image.size.width * M.screenshotHeight / image.size.height
        return min(scaled, M.screenshotHeight * WebAppInstallability.maximumScreenshotRatio)
    }

    var body: some View {
        GeometryReader { proxy in
            let container = proxy.size.width
            let full = M.cardPadding * 2 + images.map(width(of:)).reduce(0, +) + M.screenshotSpacing * CGFloat(max(0, images.count - 1))
            HStack(spacing: M.screenshotSpacing) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: width(of: image), height: M.screenshotHeight)
                        .accessibilityLabel("Screenshot \(index + 1)")
                }
            }
            .padding(.horizontal, M.cardPadding)
            .fixedSize()
            .offset(x: offset)
            .frame(width: container, height: M.screenshotHeight, alignment: .leading)
            .clipped()
            .overlay {
                HStack {
                    if offset < 0 {
                        scrollButton("chevron.left", label: "Previous screenshot") { scroll(by: 1, container: container, full: full) }
                    }
                    Spacer()
                    if offset + full > container {
                        scrollButton("chevron.right", label: "Next screenshot") { scroll(by: -1, container: container, full: full) }
                    }
                }
                .padding(.horizontal, M.screenshotSpacing)
            }
        }
        .frame(height: M.screenshotHeight)
    }

    private func scroll(by direction: CGFloat, container: CGFloat, full: CGFloat) {
        let step = (images.first.map(width(of:)) ?? M.screenshotHeight) + M.screenshotSpacing
        let delta = step * max(1, (container / step).rounded(.down))
        let target = min(0, max(container - full, offset + direction * delta))
        withAnimation(.easeInOut(duration: M.scrollAnimation)) { offset = target }
    }

    private func scrollButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: M.scrollButtonSize, height: M.scrollButtonSize)
                .background(.thickMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Chrome's pill buttons: tonal with a hairline, or filled with the system primary blue.
private struct DialogButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 16)
                .frame(height: WebAppInstallDialogMetrics.buttonHeight)
                .foregroundStyle(prominent ? (scheme == .dark ? Color(hex: 0x062E6F) : .white) : (scheme == .dark ? Color(hex: 0xA8C7FA) : Color(hex: 0x0B57D0)))
                .background {
                    if prominent {
                        Capsule().fill(scheme == .dark ? Color(hex: 0xA8C7FA) : Color(hex: 0x0B57D0))
                    } else {
                        Capsule().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// The simple dialog's banner: Kite's own drawing (Chrome's illustration is an asset, not copied): an
/// app window with the app's icon in it.
private struct WebAppInstallBanner: View {
    let icon: NSImage

    var body: some View {
        ZStack {
            Rectangle().fill(Color.accentColor.opacity(0.12))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.background)
                .frame(width: 180, height: 96)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { _ in Circle().fill(.secondary.opacity(0.4)).frame(width: 6, height: 6) }
                    }
                    .padding(8)
                }
                .overlay {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 40, height: 40)
                }
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
        .frame(height: 132)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: WebAppInstallDialogMetrics.cornerRadius,
                                          topTrailingRadius: WebAppInstallDialogMetrics.cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

/// Holds the dialog over the page: tab-modal like Chrome's (constrained_window::ShowWebModalDialogViews),
/// at the top centre of the content, swallowing clicks on the page behind it.
final class WebAppInstallDialogHost: NSView {
    private let hosting: NSHostingView<AnyView>

    init(flow: WebAppInstallFlow) {
        hosting = NSHostingView(rootView: AnyView(WebAppInstallDialog(flow: flow)))
        super.init(frame: .zero)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            hosting.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.sheet)
        setAccessibilityLabel("Install app")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Clicks outside the dialog stop here instead of reaching the page.
    override func mouseDown(with event: NSEvent) {}
}
