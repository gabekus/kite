import Foundation
import Testing
@testable import KiteCore

@Suite struct ExtensionsTests {
    let onePassword = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"

    @Test func recognizesExtensionIDs() {
        #expect(ChromeWebStore.isExtensionID(onePassword))
        #expect(!ChromeWebStore.isExtensionID("aeblfdkhhhdcdjpifhhbdiojplfjnco"))
        #expect(!ChromeWebStore.isExtensionID("zeblfdkhhhdcdjpifhhbdiojplfjncoa"))
        #expect(!ChromeWebStore.isExtensionID(onePassword.uppercased()))
    }

    @Test func readsIDsFromStorePages() {
        let withSlug = URL(string: "https://chromewebstore.google.com/detail/1password-%E2%80%93-password-mana/\(onePassword)?hl=en")!
        #expect(ChromeWebStore.extensionID(fromDetailURL: withSlug) == onePassword)
        #expect(ChromeWebStore.extensionID(fromDetailURL: URL(string: "https://chromewebstore.google.com/detail/\(onePassword)")!) == onePassword)
        #expect(ChromeWebStore.detailURL(for: onePassword)?.absoluteString == "https://chromewebstore.google.com/detail/\(onePassword)")
        #expect(ChromeWebStore.detailURL(for: "nope") == nil)
    }

    @Test func rejectsOtherPages() {
        for string in [
            "http://chromewebstore.google.com/detail/\(onePassword)",
            "https://chromewebstore.google.com.evil.com/detail/\(onePassword)",
            "https://chromewebstore.google.com/category/extensions",
            "https://chromewebstore.google.com/detail/a/b/\(onePassword)",
            "https://chromewebstore.google.com/detail/not-an-id",
        ] {
            #expect(ChromeWebStore.extensionID(fromDetailURL: URL(string: string)!) == nil, "\(string)")
        }
    }

    @Test func matchesGoogleResultsPages() {
        for string in [
            "https://www.google.com/search?q=1password",
            "https://google.com/search?q=x",
            "https://www.google.co.uk/search?q=x",
            "https://www.google.de/search?q=x",
            "https://www.google.com.au/search?q=x",
        ] {
            #expect(GoogleSearch.isResultsPage(URL(string: string)), "\(string)")
        }
        for string in [
            "http://www.google.com/search?q=x",
            "https://www.google.com/maps?q=x",
            "https://mail.google.com/search?q=x",
            "https://www.google.com.evil.com/search?q=x",
            "https://notgoogle.com/search?q=x",
            "https://www.google.co.uk.evil.example/search?q=x",
            "https://google.netlify.app/search?q=x",
        ] {
            #expect(!GoogleSearch.isResultsPage(URL(string: string)), "\(string)")
        }
        #expect(!GoogleSearch.isResultsPage(nil))
    }

    @Test func detectsExtensionPackages() {
        let blob = URL(string: "https://clients2.googleusercontent.com/crx/blobs/abc/EXT_1_0.crx")
        #expect(ExtensionPackage.isDownload(mimeType: "application/x-chrome-extension", suggestedName: "a.crx", url: nil))
        #expect(ExtensionPackage.isDownload(mimeType: "application/octet-stream", suggestedName: "EXT_1_0.crx", url: blob))
        #expect(ExtensionPackage.isDownload(mimeType: "", suggestedName: "x.CRX", url: URL(string: "https://r1---sn-abc.gvt1.com/edgedl/x.crx")))
        #expect(!ExtensionPackage.isDownload(mimeType: "application/octet-stream", suggestedName: "x.crx", url: URL(string: "https://example.com/x.crx")))
        #expect(!ExtensionPackage.isDownload(mimeType: "application/pdf", suggestedName: "paper.pdf", url: blob))
    }
}
