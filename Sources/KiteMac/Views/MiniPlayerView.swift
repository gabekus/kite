import KiteCore
import SwiftUI

/// What the Mini Player's buttons do, for the tab it shows.
struct MiniPlayerActions {
    var backToTab: (UUID) -> Void
    var command: (UUID, MediaCommand) -> Void
    var toggleMute: (UUID) -> Void
    var close: (UUID) -> Void
}

/// Arc's Mini Player (MediaControlsFeature/MiniPlayerView): the media of a tab you left, as a
/// card at the bottom of the sidebar. Numbers are from Arc's binary; see docs/arc-visual-spec.md.
private enum Metrics {
    static let cornerRadius: CGFloat = 8
    static let strokeWidth: CGFloat = 0.5
    static let strokeOpacity: Double = 0.1
    static let rowHeight: CGFloat = 33
    static let titleRowPadding: CGFloat = 10
    static let controlsRowPadding: CGFloat = 8
    static let spacing: CGFloat = 4
    static let buttonSize: CGFloat = 24
    static let iconFrame: CGFloat = 16
    static let iconPointSize: CGFloat = 14
    static let pipPointSize: CGFloat = 12
    static let artworkSize: CGFloat = 16
    static let artworkCornerRadius: CGFloat = 4
    static let titleFontSize: CGFloat = 12
    /// Below these card widths Arc drops controls (GeometryProxy compares against 160 and 126).
    static let compactWidth: CGFloat = 160
    static let tinyWidth: CGFloat = 126
    /// PlaybackControlForeground: black 50% in light, white 66% in dark.
    static let foregroundLight: Double = 0.5
    static let foregroundDark: Double = 0.66
    static let hoverAnimation = Animation.spring(response: 0.25, dampingFraction: 0.9)
}

struct MiniPlayerView: View {
    let tab: BrowserTab
    let media: MediaState
    let isMuted: Bool
    let actions: MiniPlayerActions
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        GeometryReader { proxy in
            card(width: proxy.size.width)
        }
        .frame(height: Metrics.rowHeight * 2)
        .onHover { inside in withAnimation(Metrics.hoverAnimation) { hovering = inside } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mini Player")
    }

    private var foreground: Color {
        scheme == .dark ? .white.opacity(Metrics.foregroundDark) : .black.opacity(Metrics.foregroundLight)
    }

    private func card(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            titleRow
            controlsRow(width: width)
        }
        .background(
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .fill(Color.white.opacity(scheme == .dark ? 0.10 : 0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .strokeBorder(scheme == .dark ? Color.white.opacity(Metrics.strokeOpacity) : .clear, lineWidth: Metrics.strokeWidth)
        )
    }

    private var title: String {
        if !media.title.isEmpty { return media.title }
        return tab.title.isEmpty ? (tab.url?.host() ?? "") : tab.title
    }

    private var titleRow: some View {
        HStack(spacing: Metrics.spacing) {
            artwork
                .frame(width: Metrics.buttonSize, height: Metrics.buttonSize)
            Text(title)
                .font(.system(size: Metrics.titleFontSize, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hovering {
                if media.hasVideo {
                    MiniPlayerButton(symbol: "pip", pointSize: Metrics.pipPointSize, help: "Open Picture in Picture", foreground: foreground) {
                        actions.command(tab.id, .enterPictureInPicture)
                    }
                    .transition(.opacity)
                }
                MiniPlayerButton(symbol: "xmark", pointSize: Metrics.iconPointSize, help: "Close Mini Player", foreground: foreground) {
                    actions.close(tab.id)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Metrics.titleRowPadding)
        .frame(height: Metrics.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture { actions.backToTab(tab.id) }
        .help("Back to Tab")
    }

    @ViewBuilder
    private var artwork: some View {
        let icon = FaviconView(tab: tab, size: Metrics.artworkSize)
        if let url = media.artworkURL {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                icon
            }
            .frame(width: Metrics.artworkSize, height: Metrics.artworkSize)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.artworkCornerRadius, style: .continuous))
        } else {
            icon
        }
    }

    private func controlsRow(width: CGFloat) -> some View {
        HStack(spacing: Metrics.spacing) {
            if width >= Metrics.compactWidth, media.actions.contains(.previousTrack) {
                MiniPlayerButton(symbol: "backward.end.fill", help: "Previous Track", foreground: foreground) {
                    actions.command(tab.id, .previousTrack)
                }
            }
            MiniPlayerButton(
                symbol: media.isPlaying ? "pause.fill" : "play.fill",
                help: media.isPlaying ? "Pause" : "Play",
                foreground: foreground
            ) {
                actions.command(tab.id, media.isPlaying ? .pause : .play)
            }
            if width >= Metrics.compactWidth, media.actions.contains(.nextTrack) {
                MiniPlayerButton(symbol: "forward.end.fill", help: "Next Track", foreground: foreground) {
                    actions.command(tab.id, .nextTrack)
                }
            }
            Spacer(minLength: 0)
            if width >= Metrics.tinyWidth {
                MiniPlayerButton(
                    symbol: isMuted || media.isElementMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    help: isMuted ? "Unmute Tab" : "Mute Tab",
                    foreground: foreground
                ) {
                    actions.toggleMute(tab.id)
                }
            }
        }
        .padding(.horizontal, Metrics.controlsRowPadding)
        .frame(height: Metrics.rowHeight)
    }
}

/// A 24pt button with a 16pt symbol frame, as in Arc's media controls.
private struct MiniPlayerButton: View {
    let symbol: String
    var pointSize: CGFloat = Metrics.iconPointSize
    let help: String
    let foreground: Color
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: pointSize, weight: .medium))
                .frame(width: Metrics.iconFrame, height: Metrics.iconFrame)
                .frame(width: Metrics.buttonSize, height: Metrics.buttonSize)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.artworkCornerRadius, style: .continuous)
                        .fill(hovering ? (scheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.08)) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
