import Foundation

// Arc's simple Boost controls: page colours (colour wheel), font, text size and text case.
// Measured from Arc 1.171's binary; see docs/arc-visual-spec.md, "Boost style controls".

/// Arc's `BoostTextTransform`: the text case a Boost forces on the page.
public enum BoostTextCase: String, Codable, CaseIterable, Sendable {
    case capitalize, uppercase, lowercase

    /// The case after this one when the editor's text case button is clicked (nil is the
    /// page's own case). Arc's declaration order; the cycling itself is inferred.
    public static func next(after current: BoostTextCase?) -> BoostTextCase? {
        guard let current else { return allCases.first }
        let index = allCases.firstIndex(of: current)! + 1
        return index < allCases.count ? allCases[index] : nil
    }
}

/// Arc's `BoostTextZoomOption`: small, normal, medium, large, larger.
public enum BoostTextZoom {
    /// Percent, from the option's raw values (Arc-arm64 __const at 0x103719a58).
    public static let levels = [90, 100, 110, 125, 150]
    public static let normal = 100

    /// The level after `current` when the editor's text size button is clicked, wrapping round.
    public static func next(after current: Int?) -> Int {
        let current = current ?? normal
        return levels.first { $0 > current } ?? levels[0]
    }
}

/// Arc's font picker: the families it offers (strings 199697–199714, in order).
public enum BoostFonts {
    public static let families = [
        "Helvetica Neue", "Avenir", "Futura", "DIN Alternate", "PT Mono", "Courier", "Times New Roman",
        "Charter", "Baskerville", "Hoefler Text", "Palatino", "Chalkboard", "SignPainter", "Snell Roundhand",
        "Papyrus", "Apple Chancery", "Luminari", "Wingdings",
    ]
}

/// Arc's colour-wheel colour scheme (`BoostColorWheelScheme`): a primary hue and saturation
/// picked on the wheel, a second hue at an offset from it, and the advanced sliders.
/// Arc turns it into a 4×5 matrix over a colour's hue, saturation, lightness and alpha, which its
/// Chromium applies to the page (`registerColorFilter:forHostPattern:`).
public struct BoostColorWheel: Codable, Equatable, Sendable {
    /// 0–360.
    public var primaryHueDegrees: Double
    /// 0–1: the puck's distance from the wheel's centre.
    public var primarySaturation: Double
    /// Degrees from the primary hue to the second one.
    public var secondaryHueOffset: Double
    /// Arc's "Invert lightness": light colours turn dark and dark ones light.
    public var invertLightness: Bool
    /// "Original Saturation", 0–1; nil is Arc's 0.5.
    public var preservedSaturation: Double?
    /// "Contrast", 0–1; nil is Arc's 0.5.
    public var preservedLightness: Double?
    /// "Brightness", -1–1; nil is 0.
    public var lightnessShift: Double?

    public init(
        primaryHueDegrees: Double, primarySaturation: Double, secondaryHueOffset: Double = 180,
        invertLightness: Bool = false, preservedSaturation: Double? = nil, preservedLightness: Double? = nil,
        lightnessShift: Double? = nil
    ) {
        self.primaryHueDegrees = primaryHueDegrees
        self.primarySaturation = primarySaturation
        self.secondaryHueOffset = secondaryHueOffset
        self.invertLightness = invertLightness
        self.preservedSaturation = preservedSaturation
        self.preservedLightness = preservedLightness
        self.lightnessShift = lightnessShift
    }

    /// Arc's matrix, rows hue, saturation, lightness, alpha; columns h, s, l, a, offset. Hue in
    /// turns (0–1). From BoostsClient.applyToWebContent (Arc-arm64 0x10117683c) and the lightness
    /// row's helper at 0x101146d14.
    public var matrix: [[Double]] {
        let hue = primaryHueDegrees / 360
        let secondHue = (primaryHueDegrees + secondaryHueOffset) / 360
        let saturation = min(max(primarySaturation, 0), 1)
        let keepSaturation = preservedSaturation ?? 0.5
        let k = (1 - (preservedLightness ?? 0.5)) * 0.2 * saturation
        let shift = min(max(lightnessShift ?? 0, -1), 1) * 0.2
        let (scale, offset) = invertLightness ? (3 * k - 1, 1 - k) : (1 - 3 * k, 2 * k)
        return [
            [0, 0, hue - secondHue, 0, secondHue],
            [0, keepSaturation, 0, 0, (1 - keepSaturation) * primarySaturation],
            [0, 0, scale, 0, offset + shift],
            [0, 0, 0, 1, 0],
        ]
    }

    /// One colour through the matrix: hue in turns, everything 0–1.
    public func map(hue: Double, saturation: Double, lightness: Double) -> (hue: Double, saturation: Double, lightness: Double) {
        let m = matrix
        let input = [hue, saturation, lightness, 1, 1]
        func row(_ r: [Double]) -> Double { zip(r, input).reduce(0) { $0 + $1.0 * $1.1 } }
        var h = row(m[0]).truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
        return (h, min(max(row(m[1]), 0), 1), min(max(row(m[2]), 0), 1))
    }

    /// The colour the page's lightness `l` (0–1) turns into, as sRGB 0–1, for a grey (Kite's
    /// filter can't see a colour's own saturation, so it maps every colour as if it were grey).
    public func rgb(forLightness l: Double) -> (r: Double, g: Double, b: Double) {
        let mapped = map(hue: 0, saturation: 0, lightness: l)
        return BoostColor.rgb(hue: mapped.hue, saturation: mapped.saturation, lightness: mapped.lightness)
    }
}

public enum BoostColor {
    /// HSL (all 0–1, hue in turns) to sRGB 0–1.
    public static func rgb(hue: Double, saturation: Double, lightness: Double) -> (r: Double, g: Double, b: Double) {
        guard saturation > 0 else { return (lightness, lightness, lightness) }
        let q = lightness < 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
        let p = 2 * lightness - q
        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return (channel(hue + 1.0 / 3), channel(hue), channel(hue - 1.0 / 3))
    }
}

/// The CSS and SVG filter for a Boost's simple controls.
public enum BoostStyle {
    /// Arc's selector: every element except icon fonts (BoostsClient strings 71516–71517).
    static let selector = "*:not(i, .material-symbols-outlined, .material-icons)"
    /// The id of the SVG filter that carries a Boost's colours.
    public static let filterID = "kite-boost-colors"

    /// The font and text case rules, as Arc writes them (strings 71516–71517, arc.s 0x101176734).
    public static func css(for boost: Boost) -> String {
        var rules: [String] = []
        if let family = boost.fontFamily?.trimmingCharacters(in: .whitespacesAndNewlines), !family.isEmpty {
            let quoted = family.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            rules.append("\(selector) { font-family: \"\(quoted)\" !important; }")
        }
        if let textCase = boost.textCase {
            rules.append("\(selector) { text-transform: \(textCase.rawValue) !important; }")
        }
        return rules.joined(separator: "\n")
    }

    /// Text size: Arc sets the page's zoom factor to level/100 for the site; Kite zooms the root.
    public static func zoomCSS(_ level: Int?) -> String {
        guard let level, level != BoostTextZoom.normal, level > 0 else { return "" }
        return "html { zoom: \(format(Double(level) / 100)) !important; }"
    }

    /// The rule that runs the page through the colour filter.
    public static func colorCSS(_ wheel: BoostColorWheel?) -> String {
        guard wheel != nil else { return "" }
        return "html { filter: url(#\(filterID)) !important; }"
    }

    /// Samples in the filter's lookup tables.
    static let tableSize = 33

    /// The filter's first step: every channel becomes the mean of R, G and B (Kite's estimate of
    /// a pixel's HSL lightness); alpha stays.
    public static let meanMatrix = {
        let mean = "0.3333 0.3333 0.3333 0 0"
        return "\(mean) \(mean) \(mean) 0 0 0 1 0"
    }()

    /// The filter's lookup tables (feFuncR/G/B tableValues): what each lightness turns into, so
    /// hue and lightness follow Arc's rows exactly for greys. Approximates Arc's matrix.
    public static func filterTables(_ wheel: BoostColorWheel) -> (r: String, g: String, b: String) {
        var r: [String] = [], g: [String] = [], b: [String] = []
        for i in 0..<tableSize {
            let rgb = wheel.rgb(forLightness: Double(i) / Double(tableSize - 1))
            r.append(format(rgb.r)); g.append(format(rgb.g)); b.append(format(rgb.b))
        }
        return (r.joined(separator: " "), g.joined(separator: " "), b.joined(separator: " "))
    }

    static func format(_ value: Double) -> String {
        let rounded = (value * 10000).rounded() / 10000
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(rounded)
    }
}
