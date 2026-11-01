import Foundation
import Testing
@testable import KiteCore

@Suite struct PagePrintTests {
    @Test func pdfIsLaidOutOnTheSheetsPaperWithChromeMargins() {
        let params = PagePrint.pdfParameters(paperWidthPoints: 595, paperHeightPoints: 842)  // A4
        #expect(abs((params["paperWidth"] as? Double ?? 0) - 595.0 / 72) < 0.0001)
        #expect(abs((params["paperHeight"] as? Double ?? 0) - 842.0 / 72) < 0.0001)
        for side in ["marginTop", "marginBottom", "marginLeft", "marginRight"] {
            #expect(params[side] as? Double == 0.4)
        }
        #expect(params["printBackground"] as? Bool == false)
        #expect(params["displayHeaderFooter"] as? Bool == false)
    }

    @Test func missingPaperSizeFallsBackToLetter() {
        let params = PagePrint.pdfParameters(paperWidthPoints: 0, paperHeightPoints: 0)
        #expect(params["paperWidth"] as? Double == 8.5)
        #expect(params["paperHeight"] as? Double == 11)
    }

    @Test func jobTitleIsTheTabTitleOrTheHost() {
        #expect(PagePrint.jobTitle(title: "News / Today", url: nil) == "News - Today")
        #expect(PagePrint.jobTitle(title: "  ", url: URL(string: "https://example.com/a")) == "example.com")
        #expect(PagePrint.jobTitle(title: "", url: nil) == "Page")
    }
}
