import AppKit
import KiteCore
import SwiftUI

/// Arc's Edit Theme popover, laid out from its accessibility tree (Arc 1.169, docs/arc-visual-spec.md
/// "Theme editor"): a 340pt dot grid with a handle per colour, appearance buttons over it, − and + for
/// the colour count, a row of preset swatches, the intensity slider and the grain dial.
///
/// The grid's mapping was sampled in Arc's dark mode (25 taps, 1 Nov 2026): the angle around the centre,
/// clockwise from the right, is the HSL hue; saturation stays near 0.6; lightness rises from 0.565 at
/// the centre by 0.0025 a point; taps outside the 170pt circle do nothing. Opened from Create a Space it
/// starts empty ("Tap to pick a color for this space") until a colour is picked.
struct ThemeEditor: View {
    private typealias M = ArcMetrics.ThemeEditor
    let store: BrowserStore
    let spaceID: UUID

    private var theme: Theme {
        store.state.spaces.first { $0.id == spaceID }?.theme ?? .arcDefault
    }

    /// Create a Space's grid stays empty until the first pick.
    private var empty: Bool {
        guard let creation = store.spaceCreation, creation.spaceID == spaceID else { return false }
        return !creation.themeChosen
    }

    private func set(_ change: (inout Theme) -> Void) {
        var theme = self.theme
        change(&theme)
        store.mutate { $0.setTheme(theme, forSpace: spaceID) }
        if empty { store.spaceThemeChosen() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ColorField(theme: theme, empty: empty, set: set)
                .frame(width: M.fieldSize, height: M.fieldSize)
            presets
                .padding(.top, M.presetsTop - M.fieldSize)
            HStack(alignment: .top, spacing: 0) {
                IntensitySlider(value: Double(theme.tint), showsThumb: !empty) { value in set { $0.tint = Float(value) } }
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
                            .fill(Color(theme: preset.accent))
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


/// The dot grid, one handle per colour.
private struct ColorField: View {
    private typealias M = ArcMetrics.ThemeEditor
    let theme: Theme
    let empty: Bool
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

    private static let saturation: Double = 0.6
    private static let centreLightness: Double = 0.565
    private static let lightnessPerPoint: Double = 0.0025

    private func point(for color: ThemeColor, in size: CGFloat) -> CGPoint {
        let (h, _, l) = HSL.from(color)
        let radius = min(max((l - Self.centreLightness) / Self.lightnessPerPoint, 0), size / 2)
        return CGPoint(x: size / 2 + radius * cos(h * .pi / 180), y: size / 2 + radius * sin(h * .pi / 180))
    }

    /// Nil outside the circle, where Arc ignores taps.
    private func color(at p: CGPoint, in size: CGFloat, clamped: Bool) -> ThemeColor? {
        let dx = Double(p.x - size / 2), dy = Double(p.y - size / 2)
        var r = hypot(dx, dy)
        if r > size / 2 { guard clamped else { return nil }; r = size / 2 }
        let hue = (atan2(dy, dx) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return HSL.color(hue: hue, saturation: Self.saturation, lightness: min(Self.centreLightness + r * Self.lightnessPerPoint, 0.98))
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size.width
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: M.fieldCornerRadius, style: .continuous)
                    .fill(.white.opacity(0.06))
                DotGrid()
                    .clipShape(RoundedRectangle(cornerRadius: M.fieldCornerRadius, style: .continuous))
                    .contentShape(Rectangle())
                    // A tap anywhere in the circle puts the first colour there, as in Arc.
                    .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                        guard let c = color(at: drag.location, in: size, clamped: false) else { return }
                        set { theme in if theme.colors.isEmpty { theme.colors = [c] } else { theme.colors[0] = c } }
                    })
                if empty {
                    Text("Tap to pick a color for this space")
                        .font(.system(size: M.hintFontSize, weight: .semibold))
                        .frame(width: size)
                        .offset(y: M.hintY)
                        .allowsHitTesting(false)
                }
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
                ForEach(Array(theme.colors.prefix(empty ? 0 : M.maxColors).enumerated()), id: \.offset) { index, c in
                    Handle(color: Color(theme: c))
                        .position(point(for: c, in: size))
                        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                            guard let c = color(at: drag.location, in: size, clamped: true) else { return }
                            set { $0.colors[index] = c }
                        })
                }
                HStack(spacing: M.countSpacing) {
                    countButton("minus", enabled: !empty && theme.colors.count > 1) { set { $0.colors.removeLast() } }
                    countButton("plus", enabled: !empty && theme.colors.count < M.maxColors) {
                        set { theme in
                            // A new colour starts opposite the last one on the wheel.
                            let (h, sat, l) = HSL.from(theme.colors[theme.colors.count - 1])
                            theme.colors.append(HSL.color(hue: (h + 180).truncatingRemainder(dividingBy: 360), saturation: sat, lightness: l))
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
    var showsThumb = true
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
                    .mask(Rectangle().frame(width: showsThumb ? x : 0).frame(maxWidth: .infinity, alignment: .leading))
                RoundedRectangle(cornerRadius: thumbW / 2, style: .continuous)
                    .fill(.white.opacity(showsThumb ? 1 : 0))
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
    /// From the space menu: off the sidebar's edge, bottom on the window's, no arrow. From Create a Space's
    /// Choose a Theme (`pointing`): beside that row, with an arrow at it (Arc's capture, 1 Nov 2026).
    static func present(store: BrowserStore, spaceID: UUID, from view: NSView, pointing: Bool = false) {
        shown?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ThemeEditor(store: store, spaceID: spaceID))
        popover.contentSize = M.contentSize
        if pointing {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxX)
        } else {
            // Arc's popover hangs off the sidebar's edge with its bottom on the window's: a popover centres
            // on its anchor, so the anchor goes half the popover's height up from the bottom.
            let half = M.popoverSize.height / 2
            let anchor = NSRect(x: view.bounds.maxX - 1, y: view.isFlipped ? view.bounds.maxY - half - 0.5 : view.bounds.minY + half - 0.5,
                                width: 1, height: 1)
            // Arc's has no arrow.
            if popover.responds(to: Selector(("setShouldHideAnchor:"))) { popover.setValue(true, forKey: "shouldHideAnchor") }
            popover.show(relativeTo: anchor, of: view, preferredEdge: .maxX)
        }
        shown = popover
    }

    @MainActor private static weak var shown: NSPopover?
}

/// sRGB ⇄ HSL, the space Arc's colour grid is laid out in.
enum HSL {
    static func from(_ c: ThemeColor) -> (hue: Double, saturation: Double, lightness: Double) {
        let r = Double(c.r), g = Double(c.g), b = Double(c.b)
        let maxC = max(r, g, b), minC = min(r, g, b), l = (maxC + minC) / 2
        guard maxC > minC else { return (0, 0, l) }
        let d = maxC - minC
        let s = d / (1 - abs(2 * l - 1))
        var h: Double
        switch maxC {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        h *= 60
        return (h, s, l)
    }

    static func color(hue: Double, saturation s: Double, lightness l: Double) -> ThemeColor {
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r, g, b): (Double, Double, Double) = switch hue {
        case ..<60: (c, x, 0)
        case ..<120: (x, c, 0)
        case ..<180: (0, c, x)
        case ..<240: (0, x, c)
        case ..<300: (x, 0, c)
        default: (c, 0, x)
        }
        return ThemeColor(r: Float(r + m), g: Float(g + m), b: Float(b + m))
    }
}
