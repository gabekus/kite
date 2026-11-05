import KiteCore
import SwiftUI

/// Arc's `MarqueeText` (ARCUI): one line of text that, when it doesn't fit, rests for 3 s and then
/// scrolls left forever as two copies 32pt apart, with a 4pt fade on the leading edge and 8pt on
/// the trailing edge. Like Arc's, the text sizes itself as a one-line `Text` and draws in an
/// overlay that reaches past its frame by the fade widths, so at rest the title sits exactly where
/// a plain `Text` would. Unlike Arc's, the timeline pauses while the text fits or rests, and
/// draws at most 60 times a second: the title moves (width + 32) / 20 pt/s, a fraction of a
/// pixel per frame even at 60, and the Mini Player shows for as long as music plays.
struct MarqueeText: View {
    let text: String
    let font: Font

    /// Arc's `ViewModel.startAt`: when the text starts moving.
    @State private var startAt = Date.distantFuture
    /// Past `startAt`: until then every frame would be the same.
    @State private var moving = false
    @State private var textWidth: CGFloat = 0
    @State private var frameWidth: CGFloat = 0

    private var overflows: Bool {
        Marquee.overflows(textWidth: textWidth, availableWidth: frameWidth)
    }

    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .background(GeometryReader { proxy in
                Color.clear.preference(key: FrameWidthKey.self, value: proxy.size.width)
            })
            .background(
                // The text's full one-line width, whatever room it has.
                Text(text).font(font).lineLimit(1).fixedSize().hidden()
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: TextWidthKey.self, value: proxy.size.width)
                    })
            )
            .onPreferenceChange(FrameWidthKey.self) { frameWidth = $0 }
            .onPreferenceChange(TextWidthKey.self) { textWidth = $0 }
            .overlay { scroller }
            .onAppear { restart() }
            // Arc pushes startAt to now + 3 on every frame while the text fits, so a title that
            // stops fitting (a narrower sidebar, the hover buttons) waits 3 s before it moves.
            .onChange(of: overflows) { if overflows { restart() } }
            .task(id: startAt) {
                guard startAt != .distantFuture else { return }
                let wait = startAt.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                if !Task.isCancelled { moving = true }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityIdentifier("MarqueeText")
            .accessibilityValue(overflows ? "scrolling" : "")
    }

    private func restart() {
        moving = false
        startAt = Date().addingTimeInterval(Marquee.startDelay)
    }

    private var scroller: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !overflows || !moving)) { context in
            let elapsed = context.date.timeIntervalSince(startAt)
            Canvas { graphics, size in
                draw(in: &graphics, size: size, elapsed: elapsed)
            }
        }
        .mask(fadeMask)
        .padding(EdgeInsets(top: 0, leading: -Marquee.leadingFade, bottom: 0, trailing: -Marquee.trailingFade))
    }

    private func draw(in graphics: inout GraphicsContext, size: CGSize, elapsed: TimeInterval) {
        let resolved = graphics.resolve(Text(text).font(font))
        let measured = resolved.measure(in: CGSize(width: CGFloat.infinity, height: size.height))
        let available = size.width - Marquee.leadingFade - Marquee.trailingFade
        let offset = Marquee.offset(textWidth: measured.width, availableWidth: available, elapsed: elapsed)
        let y = (size.height - measured.height) * 0.5
        let x = Marquee.leadingFade - offset
        graphics.draw(resolved, in: CGRect(origin: CGPoint(x: x, y: y), size: measured))
        if Marquee.overflows(textWidth: measured.width, availableWidth: available) {
            let second = x + measured.width + Marquee.gap
            graphics.draw(resolved, in: CGRect(origin: CGPoint(x: second, y: y), size: measured))
        }
    }

    /// Arc's mask: clear→black over the leading fade, black, black→clear over the trailing fade.
    private var fadeMask: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: Marquee.leadingFade)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: Marquee.trailingFade)
        }
    }
}

private struct FrameWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct TextWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
