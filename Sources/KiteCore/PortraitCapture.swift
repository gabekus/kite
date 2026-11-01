import Foundation

/// Arc's File › Capture in Portrait Mode, without the AppKit parts: the background choices, the
/// colour slider's palette and the picture's layout. Evidence is in docs/arc-visual-spec.md
/// ("Capture in Portrait Mode"). Colours are plain components: KiteCore stays Foundation-only.
public enum PortraitCapture {
    /// What goes behind the page. Arc's `WindowScreenshotViewModel.background`: case 0 is the
    /// slider's colour, 1 the website's colour, and no value (an unset default) the desktop wallpaper.
    public enum Background: Int, CaseIterable, Sendable {
        case color = 0
        case website = 1
        case wallpaper = 2
    }

    /// The colour space a component triple is in, as Arc's asset catalog gives it.
    public enum ColorSpace: Sendable { case sRGB, extendedLinearSRGB, displayP3 }

    public struct RGB: Equatable, Sendable {
        public var red, green, blue: Double
        public var space: ColorSpace

        public init(_ red: Double, _ green: Double, _ blue: Double, _ space: ColorSpace = .sRGB) {
            self.red = red
            self.green = green
            self.blue = blue
            self.space = space
        }
    }

    // MARK: Settings (Arc's user-default names)

    public static let backgroundKey = "portraitCaptureBackground"
    public static let colorPercentageKey = "portraitCaptureColorPercentage"
    public static let hidesWatermarkKey = "portraitCaptureHidesWatermark"

    /// Arc stores the background as an optional Bool: false is the slider's colour, true the
    /// website's, and no value the wallpaper, which is so the default.
    public static func background(stored: Bool?) -> Background {
        switch stored {
        case false?: .color
        case true?: .website
        case nil: .wallpaper
        }
    }

    public static func stored(_ background: Background) -> Bool? {
        switch background {
        case .color: false
        case .website: true
        case .wallpaper: nil
        }
    }

    // MARK: Colour

    /// The slider's track, left to right: Arc's ColorPickerBrand1…9 (ARCClients_BaseAssets.bundle).
    public static let palette: [RGB] = [
        RGB(0.95, 0.918, 0.894),
        RGB(0.95, 0.608, 0.733),
        RGB(0.651, 0.447, 0.616),
        RGB(0.949, 0.369, 0.42),
        RGB(1, 0.235, 0.097, .extendedLinearSRGB),
        RGB(0.95, 0.84, 0.428, .displayP3),
        RGB(0.451, 0.897, 0.612, .displayP3),
        RGB(0.496, 0.721, 0.838, .displayP3),
        RGB(0.401, 0.404, 0.527, .displayP3),
    ]

    /// Where the slider sits when a page has no colour of its own (Arc's fallback, 0.95).
    public static let websiteFallbackPercentage = 0.95

    /// Arc's background hue shift: the picture's backdrop blends the colour turned 30° each way.
    public static let hueShiftDegrees = 30.0

    /// The two palette colours a slider position falls between and how far it is from the first
    /// (Arc: index = ⌊p·(n−1)⌋, the next one capped at the end, fraction = p·(n−1) − index).
    public static func paletteStop(at percentage: Double) -> (from: Int, to: Int, fraction: Double) {
        let last = palette.count - 1
        let position = min(max(percentage, 0), 1) * Double(last)
        let index = min(Int(position.rounded(.down)), last)
        return (index, min(index + 1, last), position - Double(index))
    }

    // MARK: Layout

    /// The finished picture, in points of the page snapshot: the page inset on its backdrop.
    public struct Layout: Equatable, Sendable {
        public var width, height: Double
        /// The page's rectangle from the picture's top-left corner.
        public var page: Capture.Rect
        public var cornerRadius: Double
        public var shadowRadius: Double
        /// The watermark's height; it sits centred in the bottom margin.
        public var watermarkHeight: Double
    }

    /// The margin around the page, as a share of its longer side. Kite's number: Arc's frame
    /// sizes weren't found in the binary.
    public static let marginFraction = 0.06

    public static func layout(pageWidth: Double, pageHeight: Double) -> Layout {
        let width = max(pageWidth, 1), height = max(pageHeight, 1)
        let margin = (max(width, height) * marginFraction).rounded()
        return Layout(
            width: width + 2 * margin,
            height: height + 2 * margin,
            page: Capture.Rect(x: margin, y: margin, width: width, height: height),
            cornerRadius: (margin * 0.25).rounded(),
            shadowRadius: (margin * 0.3).rounded(),
            watermarkHeight: (margin * 0.32).rounded()
        )
    }

    /// The saved file's name: "Portrait Capture-2026-11-01-153045.png" (Kite's name; Arc copies
    /// the picture and saves it from the toast, its file name wasn't found).
    public static func filename(date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "Portrait Capture-" + formatter.string(from: date) + ".png"
    }
}
