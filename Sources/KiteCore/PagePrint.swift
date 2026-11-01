import Foundation

/// File › Print ⌘P: what Kite asks the engine for before showing the macOS print sheet.
public enum PagePrint {
    /// Chrome's default print margins, 0.4 in (about 1 cm) on every side.
    public static let marginInches = 0.4
    /// US Letter, for a printer that reports no paper size.
    static let fallbackPaperInches = (width: 8.5, height: 11.0)

    /// DevTools `Page.printToPDF` parameters for Chromium: the page laid out on the sheet's paper
    /// (in points, as AppKit reports it) with Chrome's margins, no backgrounds and no
    /// header or footer, like WebKit's own print operation.
    public static func pdfParameters(paperWidthPoints: Double, paperHeightPoints: Double) -> [String: Any] {
        let valid = paperWidthPoints > 0 && paperHeightPoints > 0
        return [
            "paperWidth": valid ? paperWidthPoints / 72 : fallbackPaperInches.width,
            "paperHeight": valid ? paperHeightPoints / 72 : fallbackPaperInches.height,
            "marginTop": marginInches,
            "marginBottom": marginInches,
            "marginLeft": marginInches,
            "marginRight": marginInches,
            "printBackground": false,
            "displayHeaderFooter": false,
            "preferCSSPageSize": true,
        ]
    }

    /// The print job's name, which Save as PDF in the sheet offers as the file name.
    public static func jobTitle(title: String, url: URL?) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? (url?.host() ?? "Page") : trimmed
        return name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}
