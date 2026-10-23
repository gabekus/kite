import SwiftUI

/// The crashed-tab page, matching Arc 1.169 (measured on the Mac from chrome://crash):
/// a grey face centred on a black card, "Tab crashed. Maybe reload the page?" with
/// "reload" as an underlined link, and the exit code at the bottom-right. No buttons.
struct SadTabView: View {
    let code: Int
    let reload: () -> Void

    enum Metrics {
        static let glyphFrame: CGFloat = 96
        /// The glyph's drawn size inside its frame.
        static let glyphSize = CGSize(width: 88, height: 95)
        static let glyphToText: CGFloat = 64
        static let fontSize: CGFloat = 13
        static let codeFontSize: CGFloat = 13
        // Text frames sit a little inside Arc's measured ink: 22 and 23.5 from the card's edges.
        static let codeTrailing: CGFloat = 20.5
        static let codeBottom: CGFloat = 21
        // Arc's text captures as #606060; tuned so Kite's capture reads the same.
        static let textColor = Color(red: 0x50 / 255, green: 0x50 / 255, blue: 0x50 / 255)
    }

    private static let reloadURL = URL(string: "kite-sad-tab:reload")!

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.black
            VStack(spacing: Metrics.glyphToText) {
                SadFace()
                    .stroke(Metrics.textColor, style: StrokeStyle(lineWidth: SadFace.lineWidth, lineCap: .round, lineJoin: .round))
                    .frame(width: Metrics.glyphSize.width, height: Metrics.glyphSize.height)
                    .frame(width: Metrics.glyphFrame, height: Metrics.glyphFrame)
                Text(message)
                    .font(.system(size: Metrics.fontSize))
                    .foregroundStyle(Metrics.textColor)
                    .tint(Metrics.textColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("Error code: \(code)")
                .font(.system(size: Metrics.codeFontSize))
                .foregroundStyle(Metrics.textColor)
                .padding(.trailing, Metrics.codeTrailing)
                .padding(.bottom, Metrics.codeBottom)
        }
        // Cover the whole card, titlebar inset included.
        .ignoresSafeArea()
        .environment(\.openURL, OpenURLAction { url in
            guard url == Self.reloadURL else { return .discarded }
            reload()
            return .handled
        })
    }

    private var message: AttributedString {
        var link = AttributedString("reload")
        link.link = Self.reloadURL
        link.underlineStyle = .single
        return AttributedString("Tab crashed. Maybe ") + link + AttributedString(" the page?")
    }
}

/// Two crossed-out eyes over a frown, drawn for Kite (Arc's image isn't copied).
/// The strokes reach the edges of `rect`, so its size is the glyph's measured size.
private struct SadFace: Shape {
    static let lineWidth: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Inset by half the line so the ink, not the centre line, fills the rect.
        let r = rect.insetBy(dx: Self.lineWidth / 2, dy: Self.lineWidth / 2)
        let eye = r.width * 0.34
        for x in [r.minX, r.maxX - eye] {
            path.move(to: CGPoint(x: x, y: r.minY))
            path.addLine(to: CGPoint(x: x + eye, y: r.minY + eye))
            path.move(to: CGPoint(x: x + eye, y: r.minY))
            path.addLine(to: CGPoint(x: x, y: r.minY + eye))
        }
        path.move(to: CGPoint(x: r.minX + r.width * 0.1, y: r.maxY))
        path.addQuadCurve(
            to: CGPoint(x: r.maxX - r.width * 0.1, y: r.maxY),
            control: CGPoint(x: r.midX, y: r.minY + r.height * 0.42)
        )
        return path
    }
}
