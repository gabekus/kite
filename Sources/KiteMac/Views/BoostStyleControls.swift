import KiteCore
import SwiftUI

// Arc's simple Boost controls (BoostsEditor module, Arc 1.171): the colour wheel with Invert
// lightness, Reset to original colors and Advanced color controls (Contrast, Brightness,
// Original Saturation), the font picker ("Aa" buttons in a grid), and the text size and text
// case buttons. Layout and sizes are Kite's; see docs/arc-visual-spec.md.

/// The simple controls for one Boost. Changes save straight away and show live in the site's
/// open pages (LiveBoosts).
struct BoostStyleControls: View {
    let boostID: UUID
    @State private var showingAdvanced = false
    private var model: BoostsModel { BoostsModel.shared }

    var body: some View {
        if let boost = model.library.boost(boostID) {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 8) {
                    BoostColorWheelView(colors: colorsBinding)
                        .frame(width: 132, height: 132)
                        .accessibilityLabel("Color wheel")
                        .accessibilityIdentifier("boostColorWheel")
                    colorButtons(boost)
                }
                VStack(alignment: .leading, spacing: 10) {
                    if showingAdvanced {
                        advanced(boost)
                    } else {
                        fontGrid(boost)
                    }
                    HStack(spacing: 8) {
                        textSize(boost)
                        textCase(boost)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
        }
    }

    private var colorsBinding: Binding<BoostColorWheel?> {
        Binding(
            get: { model.library.boost(boostID)?.colors },
            set: { value in model.update(boostID) { $0.colors = value } }
        )
    }

    // MARK: Colours

    private func colorButtons(_ boost: Boost) -> some View {
        HStack(spacing: 6) {
            toolButton("lightbulb", "Invert lightness", id: "boostInvertLightness",
                       selected: boost.colors?.invertLightness == true) {
                model.update(boostID) { boost in
                    var colors = boost.colors ?? BoostColorWheelView.starting
                    colors.invertLightness.toggle()
                    boost.colors = colors
                }
            }
            toolButton("nosign", "Reset to original colors", id: "boostResetColors", selected: false) {
                model.update(boostID) { $0.colors = nil }
                showingAdvanced = false
            }
            .disabled(boost.colors == nil)
            toolButton("slider.horizontal.3", "Advanced color controls", id: "boostAdvancedColors",
                       selected: showingAdvanced) {
                showingAdvanced.toggle()
            }
            .disabled(boost.colors == nil)
        }
    }

    private func advanced(_ boost: Boost) -> some View {
        // Arc's order: Contrast, Brightness, Original Saturation.
        VStack(alignment: .leading, spacing: 8) {
            slider("Contrast", value: boost.colors?.preservedLightness ?? 0.5, range: 0...1, id: "boostContrast") { colors, value in
                colors.preservedLightness = value
            }
            slider("Brightness", value: boost.colors?.lightnessShift ?? 0, range: -1...1, id: "boostBrightness") { colors, value in
                colors.lightnessShift = value
            }
            slider("Original Saturation", value: boost.colors?.preservedSaturation ?? 0.5, range: 0...1,
                   id: "boostOriginalSaturation") { colors, value in
                colors.preservedSaturation = value
            }
        }
    }

    private func slider(
        _ title: String, value: Double, range: ClosedRange<Double>, id: String,
        set: @escaping (inout BoostColorWheel, Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(get: { value }, set: { newValue in
                model.update(boostID) { boost in
                    guard var colors = boost.colors else { return }
                    set(&colors, newValue)
                    boost.colors = colors
                }
            }), in: range)
            .controlSize(.small)
            .accessibilityLabel(title)
            .accessibilityIdentifier(id)
        }
    }

    // MARK: Font, size, case

    private func fontGrid(_ boost: Boost) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 6), alignment: .leading, spacing: 6) {
            ForEach(BoostFonts.families, id: \.self) { family in
                let selected = boost.fontFamily == family
                Button {
                    // Clicking the chosen font again goes back to the page's own fonts.
                    model.update(boostID) { $0.fontFamily = selected ? nil : family }
                } label: {
                    Text("Aa")
                        .font(.custom(family, size: 13))
                        .frame(width: 30, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(family)
                .accessibilityLabel(family)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("boostFont-\(family)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("boostFontPicker")
    }

    private func textSize(_ boost: Boost) -> some View {
        let level = boost.textZoom ?? BoostTextZoom.normal
        return Button {
            let next = BoostTextZoom.next(after: boost.textZoom)
            model.update(boostID) { $0.textZoom = next == BoostTextZoom.normal ? nil : next }
        } label: {
            Label("\(level)%", systemImage: "textformat.size")
                .monospacedDigit()
        }
        .help("Change text size")
        .accessibilityLabel("Change text size")
        .accessibilityValue("\(level)%")
        .accessibilityIdentifier("boostTextSize")
    }

    private func textCase(_ boost: Boost) -> some View {
        Button {
            model.update(boostID) { $0.textCase = BoostTextCase.next(after: $0.textCase) }
        } label: {
            Text(Self.caseLabel(boost.textCase)).frame(minWidth: 40)
        }
        .help("Change text case")
        .accessibilityLabel("Change text case")
        .accessibilityValue(boost.textCase?.rawValue ?? "original")
        .accessibilityIdentifier("boostTextCase")
    }

    static func caseLabel(_ textCase: BoostTextCase?) -> String {
        switch textCase {
        case nil: "Aa"
        case .capitalize: "Ab Cd"
        case .uppercase: "AB"
        case .lowercase: "ab"
        }
    }

    private func toolButton(
        _ symbol: String, _ title: String, id: String, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}

/// Arc's colour wheel: a hue ring with a puck for the primary colour (angle is hue, distance
/// from the centre is saturation) and a smaller one for the second hue. Dragging anywhere moves
/// the primary puck; dragging from the second puck changes its offset.
struct BoostColorWheelView: View {
    @Binding var colors: BoostColorWheel?
    @State private var draggingSecondary: Bool?

    /// The scheme a first touch of the wheel starts from (offset inferred; see the spec).
    static let starting = BoostColorWheel(primaryHueDegrees: 0, primarySaturation: 0.5, secondaryHueOffset: 180)

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let radius = size / 2
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: (0...12).map { Color(hue: Double($0) / 12, saturation: 1, brightness: 1) }, center: .center))
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.85), Color(white: 0.85).opacity(0)], center: .center,
                                         startRadius: 0, endRadius: radius))
                if let colors {
                    puck(hue: colors.primaryHueDegrees, saturation: colors.primarySaturation, diameter: 18,
                         center: center, radius: radius)
                    puck(hue: colors.primaryHueDegrees + colors.secondaryHueOffset, saturation: colors.primarySaturation,
                         diameter: 12, center: center, radius: radius)
                }
            }
            .frame(width: size, height: size)
            .position(center)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                drag(value, center: center, radius: radius)
            }.onEnded { _ in draggingSecondary = nil })
        }
    }

    private func puck(hue: Double, saturation: Double, diameter: CGFloat, center: CGPoint, radius: CGFloat) -> some View {
        let angle = CGFloat(hue * .pi / 180)
        let distance = radius * (0.1 + 0.9 * min(max(saturation, 0), 1))
        return Circle()
            .fill(Color(hue: (hue / 360).truncatingRemainder(dividingBy: 1), saturation: saturation, brightness: 1))
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.3), radius: 2)
            .frame(width: diameter, height: diameter)
            .position(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
            .allowsHitTesting(false)
    }

    private func drag(_ value: DragGesture.Value, center: CGPoint, radius: CGFloat) {
        let dx = value.location.x - center.x
        let dy = value.location.y - center.y
        // Arc: atan2 of the point from the centre, in degrees 0–360 (y grows downwards), and
        // saturation is the distance with the inner tenth as a dead zone (Arc-arm64 0x1012d2560).
        var degrees = atan2(dy, dx) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        let saturation = min(max((hypot(dx, dy) / radius - 0.1) / 0.9, 0), 1)
        var scheme = colors ?? Self.starting
        if draggingSecondary == nil {
            draggingSecondary = colors.map { isNearSecondary(value.startLocation, colors: $0, center: center, radius: radius) } ?? false
        }
        if draggingSecondary == true {
            var offset = (degrees - scheme.primaryHueDegrees).truncatingRemainder(dividingBy: 360)
            if offset < 0 { offset += 360 }
            scheme.secondaryHueOffset = offset
        } else {
            scheme.primaryHueDegrees = degrees
            scheme.primarySaturation = saturation
        }
        colors = scheme
    }

    private func isNearSecondary(_ point: CGPoint, colors: BoostColorWheel, center: CGPoint, radius: CGFloat) -> Bool {
        let angle = CGFloat((colors.primaryHueDegrees + colors.secondaryHueOffset) * .pi / 180)
        let distance = radius * (0.1 + 0.9 * min(max(colors.primarySaturation, 0), 1))
        let secondary = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
        return hypot(point.x - secondary.x, point.y - secondary.y) < 10
    }
}
