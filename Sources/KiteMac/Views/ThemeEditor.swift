import AppKit
import KiteCore
import SwiftUI

/// Arc's Edit Theme popover, laid out from its accessibility tree (Arc 1.169, docs/arc-visual-spec.md
/// "Theme editor"): a 340pt dot grid with a handle per colour, appearance buttons over it, − and + for
/// the colour count, a row of preset swatches, the intensity slider and the grain dial.
///
/// How a handle's place maps to a colour wasn't measured: here the angle around the grid's centre is
/// the hue and the distance from it the chroma, with the lightness set by the appearance buttons.
struct ThemeEditor: View {
    private typealias M = ArcMetrics.ThemeEditor
    let store: BrowserStore
    let spaceID: UUID

    private var theme: Theme {
        store.state.spaces.first { $0.id == spaceID }?.theme ?? .arcDefault
    }

    private func set(_ change: (inout Theme) -> Void) {
        var theme = self.theme
        change(&theme)
        store.mutate { $0.setTheme(theme, forSpace: spaceID) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ColorField(theme: theme, set: set)
                .frame(width: M.fieldSize, height: M.fieldSize)
            presets
                .padding(.top, M.presetsTop - M.fieldSize)
            HStack(alignment: .top, spacing: 0) {
                IntensitySlider(value: Double(theme.tint)) { value in set { $0.tint = Float(value) } }
                    .frame(width: M.sliderSize.width, height: M.sliderSize.height)
                    .padding(.leading, M.sliderX)
                    .padding(.top, M.sliderTop)
                Spacer(minLength: 0)
                GrainDial(value: Double(theme.grain)) { value in set { $0.grain = Float(value) } }
                    .frame(width: M.dialSize, height: M.dialSize)
                    .offset(y: M.dialY)
                    .padding(.trailing, M.dialTrailing)
            }
            .padding(.top, M.controlsTop - M.presetsTop - M.swatchButton)
            Spacer(minLength: 0)
        }
        .padding(M.inset)
        .frame(width: M.contentSize.width, height: M.contentSize.height, alignment: .topLeading)
    }

    private var presets: some View {
        HStack(spacing: 0) {
            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .medium))
                .frame(width: M.swatchButton, height: M.swatchButton)
                .opacity(0.3)
            HStack(spacing: M.swatchPitch - M.swatchSize) {
                ForEach(Array(Theme.presets.enumerated()), id: \.offset) { _, preset in
                    Button {
                        set { theme in
                            let tint = theme.tint
                            theme = preset
                            theme.tint = tint
                        }
                    } label: {
                        Circle()
                            .fill(Color(preset.accent))
                            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1.5))
                            .frame(width: M.swatchSize, height: M.swatchSize)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, M.swatchesX - M.swatchButton)
            Spacer(minLength: 0)
            // Kite's presets fit on one page, so both arrows stay off.
            Image(systemName: "chevron.right")
                .font(.system(size: 15, weight: .medium))
                .frame(width: M.swatchButton, height: M.swatchButton)
                .opacity(0.3)
        }
        .frame(height: M.swatchButton)
    }
}

private extension Color {
    init(_ c: ThemeColor) { self.init(.sRGB, red: Double(c.r), green: Double(c.g), blue: Double(c.b)) }
}

/// The dot grid, one handle per colour.
private struct ColorField: View {
    private typealias M = ArcMetrics.ThemeEditor
    let theme: Theme
    let set: ((inout Theme) -> Void) -> Void

    enum Appearance: CaseIterable { case auto, light, dark }

    /// OKLab lightness each appearance gives the colours.
    static func lightness(_ a: Appearance) -> Float {
        switch a {
        case .auto: 0.62
        case .light: 0.86
        case .dark: 0.3
        }
    }

    private var appearance: Appearance {
        let l = theme.lightness
        return Appearance.allCases.min { abs(Self.lightness($0) - l) < abs(Self.lightness($1) - l) } ?? .dark
    }

    /// The greatest chroma the field's rim stands for.
    private static let maxChroma: Float = 0.2

    private func point(for color: ThemeColor, in size: CGFloat) -> CGPoint {
        let lab = color.lab
        let chroma = min(hypot(lab.y, lab.z) / Self.maxChroma, 1)
        let angle = atan2(lab.z, lab.y)
        let radius = Double(chroma) * (size / 2 - M.handleSize / 2)
        return CGPoint(x: size / 2 + radius * Double(cos(angle)), y: size / 2 - radius * Double(sin(angle)))
    }

    private func color(at p: CGPoint, in size: CGFloat) -> ThemeColor {
        let dx = Float(p.x - size / 2), dy = Float(size / 2 - p.y)
        let rim = Float(size / 2 - M.handleSize / 2)
        let chroma = min(hypot(dx, dy) / rim, 1) * Self.maxChroma
        let angle = atan2(dy, dx)
        return OKLab.toSRGB(SIMD3(Self.lightness(appearance), chroma * cos(angle), chroma * sin(angle)))
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size.width
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: M.fieldCornerRadius, style: .continuous)
                    .fill(.white.opacity(0.06))
                DotGrid()
                    .clipShape(RoundedRectangle(cornerRadius: M.fieldCornerRadius, style: .continuous))
                HStack(spacing: M.modeSpacing) {
                    ForEach(Appearance.allCases, id: \.self) { mode in
                        Button {
                            set { theme in
                                theme.colors = theme.colors.map { c in
                                    var lab = c.lab
                                    lab.x = Self.lightness(mode)
                                    return OKLab.toSRGB(lab)
                                }
                            }
                        } label: {
                            Image(systemName: mode == .auto ? "sparkles" : mode == .light ? "sun.max" : "moon.stars")
                                .font(.system(size: 15))
                                .frame(width: M.buttonSize, height: M.buttonSize)
                                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(mode == appearance ? 0.1 : 0)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .help(mode == .auto ? "Auto" : mode == .light ? "Light" : "Dark")
                    }
                }
                .offset(x: M.modeX, y: M.modeY)
                ForEach(Array(theme.colors.prefix(M.maxColors).enumerated()), id: \.offset) { index, c in
                    Handle(color: Color(c))
                        .position(point(for: c, in: size))
                        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                            let p = CGPoint(x: min(max(drag.location.x, 0), size), y: min(max(drag.location.y, 0), size))
                            set { $0.colors[index] = color(at: p, in: size) }
                        })
                }
                HStack(spacing: M.countSpacing) {
                    countButton("minus", enabled: theme.colors.count > 1) { set { $0.colors.removeLast() } }
                    countButton("plus", enabled: theme.colors.count < M.maxColors) {
                        set { theme in
                            // A new colour starts opposite the last one on the wheel.
                            var lab = theme.colors[theme.colors.count - 1].lab
                            lab.y = -lab.y
                            lab.z = -lab.z
                            theme.colors.append(OKLab.toSRGB(lab))
                        }
                    }
                }
                .offset(x: M.countX, y: M.countY)
            }
        }
    }

    private func countButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: M.buttonSize, height: M.buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 0.7 : 0.25)
        .help(symbol == "plus" ? "Add" : "Remove")
    }
}

private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let pitch = ArcMetrics.ThemeEditor.dotPitch
            var y = pitch / 2
            while y < size.height {
                var x = pitch / 2
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1)), with: .color(.white.opacity(0.18)))
                    x += pitch
                }
                y += pitch
            }
        }
    }
}

private struct Handle: View {
    let color: Color
    var body: some View {
        Circle()
            .fill(color)
            .overlay(Circle().strokeBorder(.white, lineWidth: ArcMetrics.ThemeEditor.handleRing))
            .frame(width: ArcMetrics.ThemeEditor.handleSize, height: ArcMetrics.ThemeEditor.handleSize)
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
    }
}

/// A wave on a track with a tall thumb; the wave is bright up to the thumb and faint past it.
private struct IntensitySlider: View {
    let value: Double
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width, h = geometry.size.height
            let thumbW = ArcMetrics.ThemeEditor.thumbSize.width
            let x = thumbW / 2 + value * (w - thumbW)
            ZStack(alignment: .topLeading) {
                Capsule().fill(.white.opacity(0.1))
                    .frame(height: ArcMetrics.ThemeEditor.trackHeight)
                    .position(x: w / 2, y: h / 2)
                Wave().stroke(.white.opacity(0.25), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                Wave().stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .mask(Rectangle().frame(width: x).frame(maxWidth: .infinity, alignment: .leading))
                RoundedRectangle(cornerRadius: thumbW / 2, style: .continuous)
                    .fill(.white)
                    .frame(width: thumbW, height: ArcMetrics.ThemeEditor.thumbSize.height)
                    .position(x: x, y: h / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                onChange(min(max((drag.location.x - thumbW / 2) / (w - thumbW), 0), 1))
            })
        }
    }
}

private struct Wave: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let inset: CGFloat = 8, amplitude = rect.height * 0.22, periods: CGFloat = 6
        let width = rect.width - 2 * inset
        for i in 0...200 {
            let t = CGFloat(i) / 200
            let p = CGPoint(x: inset + t * width, y: rect.midY - sin(t * periods * 2 * .pi) * amplitude)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}

/// A ring of dots with a pointer at the top that turns with the grain; drag up or down to turn it.
private struct GrainDial: View {
    let value: Double
    let onChange: (Double) -> Void
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size.width
            let ring = size / 2 - 6
            ZStack {
                ForEach(0..<24, id: \.self) { i in
                    let angle = Double(i) / 24 * 2 * .pi
                    Circle().fill(.white.opacity(0.3))
                        .frame(width: 4, height: 4)
                        .position(x: size / 2 + ring * sin(angle), y: size / 2 - ring * cos(angle))
                }
                Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1)
                    .frame(width: size * 0.58, height: size * 0.58)
                Capsule().fill(.white)
                    .frame(width: 8, height: 16)
                    .position(x: size / 2, y: size / 2 - ring)
                    .rotationEffect(.radians(value * 2 * .pi * 0.9))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let start = dragStart ?? value
                    dragStart = start
                    onChange(min(max(start - drag.translation.height / 120, 0), 1))
                }
                .onEnded { _ in dragStart = nil })
            .help("Grain")
        }
    }
}

extension ThemeEditor {
    /// Shows the editor for one space next to `view`, the sidebar, bottom-aligned at its edge like Arc's.
    @MainActor
    static func present(store: BrowserStore, spaceID: UUID, from view: NSView) {
        shown?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ThemeEditor(store: store, spaceID: spaceID))
        popover.contentSize = M.contentSize
        // Arc's popover hangs off the sidebar's edge with its bottom on the window's: a popover centres
        // on its anchor, so the anchor goes half the popover's height up from the bottom.
        let half = M.popoverSize.height / 2
        let anchor = NSRect(x: view.bounds.maxX - 1, y: view.isFlipped ? view.bounds.maxY - half - 0.5 : view.bounds.minY + half - 0.5,
                            width: 1, height: 1)
        // Arc's has no arrow.
        if popover.responds(to: Selector(("setShouldHideAnchor:"))) { popover.setValue(true, forKey: "shouldHideAnchor") }
        popover.show(relativeTo: anchor, of: view, preferredEdge: .maxX)
        shown = popover
    }

    @MainActor private static weak var shown: NSPopover?
}
