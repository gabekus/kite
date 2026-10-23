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
        static let glyphToText: CGFloat = 68
        static let fontSize: CGFloat = 13
        static let codeFontSize: CGFloat = 11
        static let codeTrailing: CGFloat = 22
        static let codeBottom: CGFloat = 23
        static let textColor = Color(red: 0x60 / 255, green: 0x60 / 255, blue: 0x60 / 255)
    }

    private static let reloadURL = URL(string: "kite-sad-tab:reload")!

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.black
            VStack(spacing: Metrics.glyphToText) {
                SadFace()
                    .stroke(Metrics.textColor, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
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
private struct SadFace: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        let eye = w * 0.16
        for cx in [w * 0.27, w * 0.73] {
            let cy = h * 0.3
            path.move(to: CGPoint(x: rect.minX + cx - eye / 2, y: rect.minY + cy - eye / 2))
            path.addLine(to: CGPoint(x: rect.minX + cx + eye / 2, y: rect.minY + cy + eye / 2))
            path.move(to: CGPoint(x: rect.minX + cx + eye / 2, y: rect.minY + cy - eye / 2))
            path.addLine(to: CGPoint(x: rect.minX + cx - eye / 2, y: rect.minY + cy + eye / 2))
        }
        path.move(to: CGPoint(x: rect.minX + w * 0.2, y: rect.minY + h * 0.82))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + w * 0.8, y: rect.minY + h * 0.82),
            control: CGPoint(x: rect.midX, y: rect.minY + h * 0.52)
        )
        return path
    }
}
