import Foundation

public struct ThemeColor: Hashable, Codable, Sendable {
    /// sRGB, 0...1
    public var r: Float
    public var g: Float
    public var b: Float

    public init(r: Float, g: Float, b: Float) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init(hex: UInt32) {
        r = Float((hex >> 16) & 0xFF) / 255
        g = Float((hex >> 8) & 0xFF) / 255
        b = Float(hex & 0xFF) / 255
    }

    public var lab: SIMD3<Float> { OKLab.fromSRGB(self) }
}

/// A space's backdrop: up to four colors blended in OKLab, plus film grain,
/// laid as a translucent tint over the system's sidebar material, like Arc.
/// Shells hand `labColors` straight to the GPU so the shader never converts colors per pixel.
public struct Theme: Hashable, Codable, Sendable {
    public static let maxColors = 4
    /// Arc's themes read as a muted wash rather than solid paint.
    public static let defaultTint: Float = 0.55

    public var colors: [ThemeColor]
    public var grain: Float
    /// How much of the colors covers the material underneath, 0 (none) to 1 (opaque).
    public var tint: Float

    public init(colors: [ThemeColor], grain: Float = 0.35, tint: Float = Theme.defaultTint) {
        precondition(!colors.isEmpty, "A theme needs at least one color")
        self.colors = Array(colors.prefix(Self.maxColors))
        self.grain = min(max(grain, 0), 1)
        self.tint = min(max(tint, 0), 1)
    }

    private enum CodingKeys: String, CodingKey { case colors, grain, tint }

    // Sessions saved before `tint` existed decode with the default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            colors: try c.decode([ThemeColor].self, forKey: .colors),
            grain: try c.decode(Float.self, forKey: .grain),
            tint: try c.decodeIfPresent(Float.self, forKey: .tint) ?? Theme.defaultTint
        )
    }

    public var labColors: [SIMD3<Float>] { colors.map(\.lab) }

    /// Mean OKLab lightness, used to choose dark or light sidebar text.
    public var lightness: Float {
        labColors.reduce(0) { $0 + $1.x } / Float(colors.count)
    }

    public var prefersDarkForeground: Bool { lightness > 0.7 }

    /// Two vivid colors for the loading glow, taken from the ends of the palette.
    public var glowColors: (ThemeColor, ThemeColor) {
        func vivid(_ c: ThemeColor, lift: Float) -> ThemeColor {
            var lab = c.lab
            lab.x = min(max(lab.x, 0.72) + lift, 0.95)
            lab.y *= 1.2
            lab.z *= 1.2
            return OKLab.toSRGB(lab)
        }
        let first = colors[0]
        let last = colors.count > 1 ? colors[colors.count - 1] : first
        return (vivid(first, lift: 0), vivid(last, lift: colors.count > 1 ? 0 : 0.12))
    }

    /// The vivid end of the palette, for selections that should carry the space's color
    /// (Arc fills the command bar's highlighted row with it).
    public var accent: ThemeColor {
        var lab = colors.map(\.lab).max { hypot($0.y, $0.z) < hypot($1.y, $1.z) } ?? colors[0].lab
        lab.x = min(max(lab.x, 0.5), 0.62)
        return OKLab.toSRGB(lab)
    }

    /// Arc's default dark theme: near-black, no grain, at intensity 0.8, so the
    /// sidebar is mostly the system material picking up the wallpaper.
    public static let arcDefault = Theme(colors: [ThemeColor(r: 0.1, g: 0.1, b: 0.1)], grain: 0, tint: defaultTint * 0.8)

    /// Claude's orange, for the Claude space.
    public static let claude = Theme(colors: [ThemeColor(hex: 0xE8956F), ThemeColor(hex: 0xD97757)], grain: 0.3)

    public static let presets: [Theme] = [
        arcDefault,
        Theme(colors: [ThemeColor(hex: 0xFF9A6C), ThemeColor(hex: 0xF0629B), ThemeColor(hex: 0x8A5CF5)]),
        Theme(colors: [ThemeColor(hex: 0x5FD3E6), ThemeColor(hex: 0x2BA39A), ThemeColor(hex: 0x2F6FE0)]),
        Theme(colors: [ThemeColor(hex: 0xD4F7E2), ThemeColor(hex: 0xA6E3C8)], grain: 0.25),
        Theme(colors: [ThemeColor(hex: 0x3B4049), ThemeColor(hex: 0x1F2329)], grain: 0.45),
        Theme(colors: [ThemeColor(hex: 0xFFE38A), ThemeColor(hex: 0xFFB45C)], grain: 0.3),
        Theme(colors: [ThemeColor(hex: 0x8E2BB0), ThemeColor(hex: 0xD8256A), ThemeColor(hex: 0x3A4BC0), ThemeColor(hex: 0x10B0C8)]),
    ]
}

/// Björn Ottosson's OKLab: interpolating here keeps gradients free of the muddy
/// midpoints you get from mixing in sRGB.
public enum OKLab {
    public static func fromSRGB(_ c: ThemeColor) -> SIMD3<Float> {
        let r = toLinear(c.r), g = toLinear(c.g), b = toLinear(c.b)
        let l = cbrtf(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrtf(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrtf(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return SIMD3(
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    public static func toSRGB(_ lab: SIMD3<Float>) -> ThemeColor {
        let l_ = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z
        let m_ = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z
        let s_ = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return ThemeColor(
            r: toGamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            g: toGamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            b: toGamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
        )
    }

    private static func cbrtf(_ x: Float) -> Float {
        Float(Foundation.cbrt(Double(x)))
    }

    private static func toLinear(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : Float(pow((Double(c) + 0.055) / 1.055, 2.4))
    }

    private static func toGamma(_ c: Float) -> Float {
        let x = min(max(c, 0), 1)
        return x <= 0.0031308 ? 12.92 * x : Float(1.055 * pow(Double(x), 1 / 2.4) - 0.055)
    }
}
