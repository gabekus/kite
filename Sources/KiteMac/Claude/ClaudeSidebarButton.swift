import Observation
import SwiftUI

/// What the sidebar's Claude button needs. Incognito windows never get `tasks`, so they show no button.
@MainActor
@Observable
final class ClaudeButtonModel {
    var tasks: ClaudeTasksController?
    /// Which tabs Claude is driving, for the sidebar's rows and Claude folders. Nil in incognito.
    var automation: AutomationController?
    @ObservationIgnored var open: () -> Void = {}
    /// The button's frame in the sidebar's hosting view (top-left origin), or nil while it isn't shown.
    /// Claude's control pill sits just above it.
    @ObservationIgnored var frame: CGRect? {
        didSet { if frame != oldValue { onFrameChange() } }
    }
    @ObservationIgnored var onFrameChange: () -> Void = {}
}

/// Claude in the sidebar's bottom bar. A yellow dot means Claude isn't set up yet:
/// clicking sets it up, then opens Claude Tasks.
struct ClaudeSidebarButton: View {
    let model: ClaudeButtonModel
    let size: CGFloat

    var body: some View {
        if let tasks = model.tasks {
            Button(action: model.open) {
                ClaudeMark()
                    .fill(Color.claude)
                    .frame(width: 15, height: 15)
                    .frame(width: size, height: size)
                    .overlay(alignment: .topTrailing) {
                        if !tasks.isSetUp {
                            Circle()
                                .fill(Color(nsColor: .systemYellow))
                                .frame(width: 8, height: 8)
                                .offset(x: -5, y: 5)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(tasks.isSettingUp ? 0.4 : 1)
            .disabled(tasks.isSettingUp)
            .help(tasks.isSetUp ? "Claude" : "Set up Claude")
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.frame = $0 }
            .onDisappear { model.frame = nil }
        }
    }
}

/// A plain starburst, Kite's own drawing (not Anthropic's logo file).
/// Claude's logo, the spark, as one filled shape on a 24-point square (Simple Icons' "claude" path, CC0),
/// scaled to fit. Fill it in `Color.claude`.
struct ClaudeMark: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / 24
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * scale, y: origin.y + y * scale) }
        var path = Path()
        path.move(to: p(4.7144, 15.9555))
        path.addLine(to: p(9.4318, 13.3084))
        path.addLine(to: p(9.5108, 13.0777))
        path.addLine(to: p(9.4318, 12.9502))
        path.addLine(to: p(9.2011, 12.9502))
        path.addLine(to: p(8.4118, 12.9016))
        path.addLine(to: p(5.7162, 12.8287))
        path.addLine(to: p(3.3787, 12.7316))
        path.addLine(to: p(1.1141, 12.6102))
        path.addLine(to: p(0.5434, 12.4887))
        path.addLine(to: p(0.0091, 11.7845))
        path.addLine(to: p(0.0637, 11.4323))
        path.addLine(to: p(0.5434, 11.1105))
        path.addLine(to: p(1.2294, 11.1713))
        path.addLine(to: p(2.7473, 11.2745))
        path.addLine(to: p(5.024, 11.4323))
        path.addLine(to: p(6.6754, 11.5295))
        path.addLine(to: p(9.1222, 11.7845))
        path.addLine(to: p(9.5108, 11.7845))
        path.addLine(to: p(9.5654, 11.6266))
        path.addLine(to: p(9.4318, 11.5295))
        path.addLine(to: p(9.3286, 11.4323))
        path.addLine(to: p(6.973, 9.8356))
        path.addLine(to: p(4.423, 8.1477))
        path.addLine(to: p(3.0874, 7.1763))
        path.addLine(to: p(2.3649, 6.6845))
        path.addLine(to: p(2.0006, 6.2231))
        path.addLine(to: p(1.8428, 5.2153))
        path.addLine(to: p(2.4985, 4.4928))
        path.addLine(to: p(3.3788, 4.5535))
        path.addLine(to: p(3.6034, 4.6142))
        path.addLine(to: p(4.4959, 5.3002))
        path.addLine(to: p(6.4023, 6.7756))
        path.addLine(to: p(8.8916, 8.6092))
        path.addLine(to: p(9.2559, 8.9127))
        path.addLine(to: p(9.4016, 8.8095))
        path.addLine(to: p(9.4198, 8.7367))
        path.addLine(to: p(9.2558, 8.4634))
        path.addLine(to: p(7.9019, 6.0167))
        path.addLine(to: p(6.4569, 3.5274))
        path.addLine(to: p(5.8134, 2.4954))
        path.addLine(to: p(5.6434, 1.876))
        path.addCurve(to: p(5.5402, 1.1475), control1: p(5.5827, 1.621), control2: p(5.5402, 1.4086))
        path.addLine(to: p(6.287, 0.1335))
        path.addLine(to: p(6.6997, 0))
        path.addLine(to: p(7.6954, 0.1336))
        path.addLine(to: p(8.1144, 0.4978))
        path.addLine(to: p(8.7336, 1.9125))
        path.addLine(to: p(9.7354, 4.1407))
        path.addLine(to: p(11.2897, 7.1703))
        path.addLine(to: p(11.745, 8.0688))
        path.addLine(to: p(11.9879, 8.9006))
        path.addLine(to: p(12.0789, 9.1556))
        path.addLine(to: p(12.2368, 9.1556))
        path.addLine(to: p(12.2368, 9.0099))
        path.addLine(to: p(12.3643, 7.3039))
        path.addLine(to: p(12.6011, 5.2092))
        path.addLine(to: p(12.8318, 2.5135))
        path.addLine(to: p(12.9107, 1.7546))
        path.addLine(to: p(13.2871, 0.8439))
        path.addLine(to: p(14.0339, 0.3521))
        path.addLine(to: p(14.6167, 0.6314))
        path.addLine(to: p(15.0964, 1.3174))
        path.addLine(to: p(15.0296, 1.7607))
        path.addLine(to: p(14.7443, 3.6124))
        path.addLine(to: p(14.1857, 6.5145))
        path.addLine(to: p(13.8214, 8.4574))
        path.addLine(to: p(14.0339, 8.4574))
        path.addLine(to: p(14.2768, 8.2145))
        path.addLine(to: p(15.2603, 6.9092))
        path.addLine(to: p(16.9117, 4.8449))
        path.addLine(to: p(17.6403, 4.0253))
        path.addLine(to: p(18.4903, 3.1207))
        path.addLine(to: p(19.0367, 2.6896))
        path.addLine(to: p(20.0688, 2.6896))
        path.addLine(to: p(20.8278, 3.8189))
        path.addLine(to: p(20.4878, 4.9846))
        path.addLine(to: p(19.4253, 6.3324))
        path.addLine(to: p(18.5449, 7.4738))
        path.addLine(to: p(17.2821, 9.1738))
        path.addLine(to: p(16.4928, 10.5338))
        path.addLine(to: p(16.5657, 10.6431))
        path.addLine(to: p(16.7539, 10.6248))
        path.addLine(to: p(19.6074, 10.0178))
        path.addLine(to: p(21.1495, 9.7384))
        path.addLine(to: p(22.9891, 9.4227))
        path.addLine(to: p(23.8209, 9.8113))
        path.addLine(to: p(23.9119, 10.2059))
        path.addLine(to: p(23.5841, 11.0134))
        path.addLine(to: p(21.6171, 11.4991))
        path.addLine(to: p(19.3099, 11.9605))
        path.addLine(to: p(15.8735, 12.7741))
        path.addLine(to: p(15.831, 12.8045))
        path.addLine(to: p(15.8796, 12.8652))
        path.addLine(to: p(17.4278, 13.0109))
        path.addLine(to: p(18.0896, 13.0473))
        path.addLine(to: p(19.7106, 13.0473))
        path.addLine(to: p(22.7281, 13.272))
        path.addLine(to: p(23.5173, 13.794))
        path.addLine(to: p(23.9909, 14.4316))
        path.addLine(to: p(23.9119, 14.9173))
        path.addLine(to: p(22.6977, 15.5366))
        path.addLine(to: p(21.0584, 15.148))
        path.addLine(to: p(17.2334, 14.2373))
        path.addLine(to: p(15.9221, 13.9094))
        path.addLine(to: p(15.7399, 13.9094))
        path.addLine(to: p(15.7399, 14.0187))
        path.addLine(to: p(16.8328, 15.0873))
        path.addLine(to: p(18.8363, 16.8965))
        path.addLine(to: p(21.3438, 19.2279))
        path.addLine(to: p(21.4713, 19.8047))
        path.addLine(to: p(21.1495, 20.2601))
        path.addLine(to: p(20.8095, 20.2115))
        path.addLine(to: p(18.6056, 18.554))
        path.addLine(to: p(17.7556, 17.8072))
        path.addLine(to: p(15.831, 16.1862))
        path.addLine(to: p(15.7035, 16.1862))
        path.addLine(to: p(15.7035, 16.3562))
        path.addLine(to: p(16.1467, 17.0058))
        path.addLine(to: p(18.4903, 20.5272))
        path.addLine(to: p(18.6117, 21.6079))
        path.addLine(to: p(18.4417, 21.96))
        path.addLine(to: p(17.8346, 22.1725))
        path.addLine(to: p(17.1667, 22.0511))
        path.addLine(to: p(15.7946, 20.1265))
        path.addLine(to: p(14.38, 17.959))
        path.addLine(to: p(13.2386, 16.0162))
        path.addLine(to: p(13.0989, 16.0952))
        path.addLine(to: p(12.4249, 23.3504))
        path.addLine(to: p(12.1093, 23.7207))
        path.addLine(to: p(11.3807, 24))
        path.addLine(to: p(10.7736, 23.5386))
        path.addLine(to: p(10.4518, 22.7918))
        path.addLine(to: p(10.7736, 21.3165))
        path.addLine(to: p(11.1622, 19.3919))
        path.addLine(to: p(11.4779, 17.8619))
        path.addLine(to: p(11.7632, 15.9615))
        path.addLine(to: p(11.9332, 15.3301))
        path.addLine(to: p(11.9211, 15.2876))
        path.addLine(to: p(11.7814, 15.3058))
        path.addLine(to: p(10.3486, 17.273))
        path.addLine(to: p(8.169, 20.2176))
        path.addLine(to: p(6.4447, 22.0632))
        path.addLine(to: p(6.0319, 22.2272))
        path.addLine(to: p(5.3155, 21.8568))
        path.addLine(to: p(5.3822, 21.195))
        path.addLine(to: p(5.783, 20.6061))
        path.addLine(to: p(8.169, 17.5704))
        path.addLine(to: p(9.6079, 15.6884))
        path.addLine(to: p(10.5369, 14.6016))
        path.addLine(to: p(10.5307, 14.4437))
        path.addLine(to: p(10.4761, 14.4437))
        path.addLine(to: p(4.1376, 18.5601))
        path.addLine(to: p(3.0083, 18.7058))
        path.addLine(to: p(2.5226, 18.2504))
        path.addLine(to: p(2.5834, 17.5037))
        path.addLine(to: p(2.8141, 17.2608))
        path.addLine(to: p(4.7205, 15.9494))
        path.closeSubpath()
        return path
    }
}

extension Color {
    /// Claude's orange (#D97757).
    static let claude = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
}
