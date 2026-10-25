import Observation
import SwiftUI

/// What the sidebar's Claude button needs. Incognito windows never get `tasks`, so they show no button.
@MainActor
@Observable
final class ClaudeButtonModel {
    var tasks: ClaudeTasksController?
    @ObservationIgnored var open: () -> Void = {}
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
                    .stroke(Color.claude, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
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
        }
    }
}

/// A plain starburst, Kite's own drawing (not Anthropic's logo file).
struct ClaudeMark: Shape {
    var rays = 10

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        for i in 0..<rays {
            let angle = Double(i) / Double(rays) * 2 * .pi - .pi / 2
            // Alternate long and short rays, like a hand-drawn spark.
            let length = i.isMultiple(of: 2) ? outer : outer * 0.72
            path.move(to: CGPoint(x: center.x + cos(angle) * outer * 0.18, y: center.y + sin(angle) * outer * 0.18))
            path.addLine(to: CGPoint(x: center.x + cos(angle) * length, y: center.y + sin(angle) * length))
        }
        return path
    }
}

extension Color {
    /// Claude's orange (#D97757).
    static let claude = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
}
