import Foundation

/// Settings › Advanced › "Allow websites to get your theme data" (g95).
///
/// Arc (1.171) gives the page shown in a window a stylesheet of CSS custom properties built from
/// the space's theme, and replaces it whenever the theme changes. The text is
/// `:root {` + one `name: value;` line per property + `}`, each value `#RRGGBBAA` from the colour's
/// Display P3 components (×255, truncated). The properties are twelve `--arc-palette-*` colours
/// plus the backdrop: `--arc-background-simple-color` for a one-colour theme, or
/// `--arc-background-gradient-color<N>` (and `…-overlay-color<N>`) for a gradient. Arc's defaults
/// key is `themeToCSSSharingAllowed`, on when unset. See docs/arc-visual-spec.md.
///
/// Kite keeps Arc's property names so pages written for Arc work unchanged. Kite's themes have
/// no palette of their own, so the palette colours are derived from the theme here; Kite's
/// themes have no overlay colours, so no overlay properties are given.
public enum ThemeCSS {
    /// Arc's defaults key; unset means on.
    public static let allowedKey = "themeToCSSSharingAllowed"

    public static func isAllowed(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: allowedKey) as? Bool ?? true
    }

    /// Arc's twelve palette properties, in the order Arc's binary lists them.
    public static let paletteNames = [
        "foregroundPrimary", "foregroundSecondary", "foregroundTertiary", "maxContrastColor",
        "minContrastColor", "backgroundExtra", "background", "focus", "hover", "cutoutColor",
        "title", "subtitle",
    ]

    /// The properties for `theme`, in a fixed order: the palette, then the backdrop.
    public static func properties(for theme: Theme) -> [(name: String, value: String)] {
        let dark = !theme.prefersDarkForeground
        let ink = dark ? ThemeColor(r: 1, g: 1, b: 1) : ThemeColor(r: 0, g: 0, b: 0)
        let paper = dark ? ThemeColor(r: 0, g: 0, b: 0) : ThemeColor(r: 1, g: 1, b: 1)
        var lab = theme.labColors.reduce(SIMD3<Float>(0, 0, 0), +) / Float(theme.colors.count)
        let background = OKLab.toSRGB(lab)
        lab.x = min(max(lab.x + (dark ? 0.06 : -0.06), 0), 1)
        let backgroundExtra = OKLab.toSRGB(lab)
        lab.x = min(max(lab.x + (dark ? -0.12 : 0.12), 0), 1)
        let cutout = OKLab.toSRGB(lab)
        let palette: [String: String] = [
            "foregroundPrimary": hex(ink),
            "foregroundSecondary": hex(ink, alpha: 0.6),
            "foregroundTertiary": hex(ink, alpha: 0.4),
            "maxContrastColor": hex(ink),
            "minContrastColor": hex(paper),
            "backgroundExtra": hex(backgroundExtra),
            "background": hex(background),
            "focus": hex(theme.accent),
            "hover": hex(ink, alpha: 0.1),
            "cutoutColor": hex(cutout),
            "title": hex(ink),
            "subtitle": hex(ink, alpha: 0.6),
        ]
        var result = paletteNames.map { ("--arc-palette-" + $0, palette[$0]!) }
        if theme.colors.count == 1 {
            result.append(("--arc-background-simple-color", hex(theme.colors[0])))
        } else {
            for (i, color) in theme.colors.enumerated() {
                result.append(("--arc-background-gradient-color\(i)", hex(color)))
            }
        }
        return result
    }

    /// The stylesheet Arc hands the page: `:root {`, a `name: value;` line each, `}`.
    public static func css(for theme: Theme) -> String {
        ":root {\n" + properties(for: theme).map { "\($0.name): \($0.value);" }.joined(separator: "\n") + "\n}"
    }

    /// A script for the top frame that puts `css` in the page's theme stylesheet, replacing what's
    /// there, or removes the stylesheet when `css` is nil. Safe at document start (it waits for the
    /// root element) and to run again.
    public static func script(css: String?) -> String {
        let literal: String
        if let css, let data = try? JSONSerialization.data(withJSONObject: [css]),
           let array = String(data: data, encoding: .utf8) {
            literal = String(array.dropFirst().dropLast())
        } else {
            literal = "null"
        }
        return """
        (() => {
          if (window !== window.top || !(document instanceof HTMLDocument)) return;
          const css = \(literal);
          const apply = () => {
            const root = document.documentElement;
            if (!root) return false;
            let style = document.querySelector('style[data-kite-theme-css]');
            if (css === null) { if (style) style.remove(); return true; }
            if (!style) {
              style = document.createElement('style');
              style.setAttribute('data-kite-theme-css', '');
              (document.head || root).appendChild(style);
            }
            if (style.textContent !== css) style.textContent = css;
            return true;
          };
          if (!apply()) {
            const observer = new MutationObserver(() => { if (apply()) observer.disconnect(); });
            observer.observe(document, { childList: true });
          }
        })();
        """
    }

    /// `#RRGGBBAA` from the colour's Display P3 components, each ×255 and truncated, as Arc does.
    public static func hex(_ color: ThemeColor, alpha: Float = 1) -> String {
        let p3 = displayP3(color)
        // The small nudge keeps float noise (white at 0.99999…) from truncating a whole step.
        let bytes = [p3.0, p3.1, p3.2, alpha].map { Int(min(max($0, 0), 1) * 255 + 0.001) }
        return "#" + bytes.map { String(format: "%02X", $0) }.joined()
    }

    /// sRGB to Display P3 (same white point and transfer curve, wider primaries).
    static func displayP3(_ c: ThemeColor) -> (Float, Float, Float) {
        func linear(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : Float(pow((Double(v) + 0.055) / 1.055, 2.4)) }
        func gamma(_ v: Float) -> Float {
            let x = min(max(v, 0), 1)
            return x <= 0.0031308 ? 12.92 * x : Float(1.055 * pow(Double(x), 1 / 2.4) - 0.055)
        }
        let r = linear(c.r), g = linear(c.g), b = linear(c.b)
        return (
            gamma(0.8224621 * r + 0.1775380 * g),
            gamma(0.0331941 * r + 0.9668058 * g),
            gamma(0.0170827 * r + 0.0723974 * g + 0.9105199 * b)
        )
    }
}
