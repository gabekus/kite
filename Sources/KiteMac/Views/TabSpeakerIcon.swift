import KiteCore
import SwiftUI

/// The sidebar tab's speaker (Arc's ARCUI `SidebarCellSpeakerIconWrapperView`): SF `speaker` at
/// 14pt medium; while the tab plays it moves 4pt left and three sound waves spring out after it,
/// one after another; muted, they spring back and a slash draws across the speaker, cutting a gap
/// in it. The waves' shapes are Kite's own arcs (Arc draws custom Bézier waves).
struct TabSpeakerIcon: View {
    let isMuted: Bool

    private typealias S = TabAudioButton.Speaker

    var body: some View {
        let playing = !isMuted
        ZStack {
            Image(systemName: "speaker")
                .font(.system(size: 14, weight: .medium))
                .mask(SlashShape(progress: playing ? 0 : 1, cutout: true)
                    .fill(style: FillStyle(eoFill: true))
                    .animation(slashAnimation(playing: playing), value: playing))
                .overlay(SlashShape(progress: playing ? 0 : 1, cutout: false)
                    .animation(slashAnimation(playing: playing), value: playing))
                .offset(x: playing ? S.playingOffset : 0)
                .animation(.spring(response: S.waveSpring.response, dampingFraction: S.waveSpring.damping)
                    .delay(playing ? 0 : S.slashDelay), value: playing)
            ForEach(0..<3, id: \.self) { index in
                SoundWave(index: index)
                    .frame(width: S.waveSize.width, height: S.waveSize.height)
                    .offset(x: playing ? S.waveShownOffset : S.waveHiddenOffsets[index])
                    .opacity(playing ? 1 : 0)
                    .animation(.spring(response: S.waveSpring.response, dampingFraction: S.waveSpring.damping)
                        .delay(S.waveDelay(index: index, showing: playing)), value: playing)
            }
        }
        .accessibilityHidden(true)
    }

    private func slashAnimation(playing: Bool) -> Animation {
        playing
            ? .spring(response: S.slashOutSpring.response, dampingFraction: S.slashOutSpring.damping)
            : .spring(response: S.slashInSpring.response, dampingFraction: S.slashInSpring.damping).delay(S.slashDelay)
    }
}

/// Arc's SlashShape: a capsule at 45° from the box's top-left corner, `progress` of the diagonal long.
/// The cut-out variant is twice as thick, a little longer, and fills the rest of the box (even-odd),
/// so it masks a gap into the speaker under the slash.
private struct SlashShape: Shape {
    var progress: Double
    let cutout: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        typealias S = TabAudioButton.Speaker
        let width = Double(rect.width)
        let thickness = S.slashThickness(boxWidth: width, cutout: cutout)
        let overhang = cutout ? thickness / 4.5 : 0
        let length = S.slashLength(boxWidth: width, progress: max(progress, 0), cutout: cutout)
        var path = Path()
        if progress > 0.001 {
            let band = CGRect(x: -overhang, y: -thickness / 2, width: length, height: thickness)
            let transform = CGAffineTransform(translationX: rect.minX, y: rect.minY).rotated(by: .pi / 4)
            path.addRoundedRect(in: band, cornerSize: CGSize(width: thickness / 2, height: thickness / 2),
                                style: .circular, transform: transform)
        }
        if cutout { path.addRect(rect) }
        return path
    }
}

/// One of the three sound waves: an arc around a point on the frame's left edge, wider for each
/// wave (Kite's shape; Arc's are custom Bézier outlines in the same 8 × 12 frame).
private struct SoundWave: Shape {
    let index: Int

    func path(in rect: CGRect) -> Path {
        let lineWidth: CGFloat = 1.5
        let radius = (rect.width - lineWidth) * CGFloat(index + 1) / 3
        let spread = Angle.degrees(index == 0 ? 50 : 45)
        var path = Path()
        path.addArc(center: CGPoint(x: rect.minX, y: rect.midY), radius: radius,
                    startAngle: -spread, endAngle: spread, clockwise: false)
        return path.strokedPath(StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }
}
