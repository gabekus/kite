import KiteCore
import SwiftUI

private typealias M = ArcMetrics.Sidebar

/// Arc's `InstantLinksCellView`: the Today row that stands in for Instant Links' results while
/// they're found. A tab-like row: the Arc Max flower in the favicon's place (spinning while it
/// loads), Arc's title, and a close button on hover that cancels it.
struct InstantLinksRow: View {
    let row: InstantLinks.Pending
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if row.status == .loading {
                    SpinningMaxFlower()
                } else {
                    MaxFlower()
                }
            }
            .frame(width: MaxFlower.size, height: MaxFlower.size)
            .frame(width: M.iconSize, height: M.iconSize)
            .opacity(M.tabTextOpacity)
            Text(row.title)
                .font(.system(size: M.tabFontSize))
                .opacity(M.tabTextOpacity)
                .lineLimit(1)
                .truncationMode(.tail)
                // Arc: the title stack starts 6pt after the icon's container.
                .padding(.leading, 6)
            Spacer(minLength: 0)
            if hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(0.6)
                .accessibilityLabel("Close")
            }
        }
        .padding(.leading, M.iconInset)
        .padding(.trailing, 6)
        .frame(height: M.pillHeight)
        .modifier(TabPillFill(isSelected: false, isHovered: hovering))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("InstantLinksRow")
    }
}

/// Arc's `AnimatedFlowerView` (disassembly at 0x100185600): the flower turns clockwise once a second
/// (`transform.rotation` 0 → −2π, 1 s, linear, forever) and bobs 1.5pt down and up over 2 s
/// (`position.y` keyframes 0, −1.5, 0, +1.5, 0 at 0/¼/½/¾/1, ease-out away from the middle and
/// ease-in back, forever). AppKit's y points up, so Arc's −1.5 is down.
private struct SpinningMaxFlower: View {
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(start)
            MaxFlower()
                .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 1) * 360))
                .offset(y: Self.bob(at: t))
        }
    }

    static func bob(at t: TimeInterval) -> CGFloat {
        let phase = t.truncatingRemainder(dividingBy: 2) / 0.5
        let segment = min(Int(phase), 3)
        let p = phase - Double(segment)
        // Away from the middle eases out, back to it eases in.
        let eased = segment.isMultiple(of: 2) ? UnitCurve.easeOut.value(at: p) : 1 - UnitCurve.easeIn.value(at: p)
        return CGFloat(eased * 1.5) * (segment < 2 ? 1 : -1)
    }
}

/// The Arc Max flower, drawn by Kite from measurements of Arc's 22pt `MaxFlowerIcon` template:
/// the outline of four overlapping round petals around a hollow diamond, with a stalk from the
/// diamond into each petal. Drawn at 16pt (`AnimatedFlowerView`'s size).
struct MaxFlower: View {
    static let size: CGFloat = 16

    var body: some View {
        Canvas { context, canvas in
            let unit = min(canvas.width, canvas.height) / 22
            let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            let line = 1.3 * unit
            let offsets = [CGPoint(x: 0, y: -1), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: -1, y: 0)]
            func petals(radius: CGFloat) -> Path {
                var path = Path()
                for o in offsets {
                    let c = CGPoint(x: center.x + o.x * 5.5 * unit, y: center.y + o.y * 5.5 * unit)
                    path.addEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
                }
                return path
            }
            // The petals' outer outline only: the union, less a smaller union.
            context.drawLayer { layer in
                layer.fill(petals(radius: (4.35 + 0.65) * unit), with: .foreground)
                layer.blendMode = .destinationOut
                layer.fill(petals(radius: (4.35 - 0.65) * unit), with: .color(.black))
            }
            let corner = 2.7 * unit
            var diamond = Path()
            var stalks = Path()
            for (i, o) in offsets.enumerated() {
                let point = CGPoint(x: center.x + o.x * corner, y: center.y + o.y * corner)
                if i == 0 { diamond.move(to: point) } else { diamond.addLine(to: point) }
                stalks.move(to: point)
                stalks.addLine(to: CGPoint(x: center.x + o.x * 6.9 * unit, y: center.y + o.y * 6.9 * unit))
            }
            diamond.closeSubpath()
            let style = StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round)
            context.stroke(diamond, with: .foreground, style: style)
            context.stroke(stalks, with: .foreground, style: style)
        }
        .accessibilityHidden(true)
    }
}
