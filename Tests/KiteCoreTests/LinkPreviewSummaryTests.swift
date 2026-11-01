import Foundation
import Testing
@testable import KiteCore

@Suite struct LinkPreviewSummaryTests {
    let url = URL(string: "https://example.com/recipes/pasta")!

    @Test func readsTheJSONInsideAFencedReply() throws {
        let reply = """
            Here you go:
            ```json
            {"blocked": false, "quickSummary": "  Ready in **20**   minutes ",
             "details": [{"label": "Price:", "icon": "dollarsign.circle", "info": "About $8 for four servings"},
                         {"label": "Story:", "icon": "book", "info": "A grandmother's weeknight recipe"}]}
            ```
            """
        let summary = try #require(LinkPreviewSummary.parse(reply: reply))
        #expect(summary.quickSummary == "Ready in **20** minutes")
        #expect(summary.details.count == 2)
        #expect(summary.details[0] == .init(label: "Price:", icon: "dollarsign.circle", info: "About $8 for four servings"))
    }

    @Test func blockedOrEmptyPagesHaveNoSummary() {
        #expect(LinkPreviewSummary.parse(reply: #"{"blocked": true, "quickSummary": "Enable JavaScript", "details": []}"#) == nil)
        #expect(LinkPreviewSummary.parse(reply: #"{"blocked": false, "quickSummary": null, "details": []}"#) == nil)
        #expect(LinkPreviewSummary.parse(reply: "Sorry, I can't help with that.") == nil)
        #expect(LinkPreviewSummary.parse(reply: "{not json}") == nil)
    }

    @Test func keepsAtMostFourDetailsAndDropsBrokenOnes() throws {
        let rows = (1...6).map { #"{"label": "Item \#($0):", "icon": "star", "info": "Thing \#($0)"}"# }
        let reply = #"{"quickSummary": "Six things", "details": [{"label": 3}, "#
            + rows.joined(separator: ",") + "]}"
        let summary = try #require(LinkPreviewSummary.parse(reply: reply))
        #expect(summary.blocked == false)
        #expect(summary.details.map(\.label) == ["Item 1:", "Item 2:", "Item 3:", "Item 4:"])
    }

    @Test func detailsAloneAreEnough() throws {
        let summary = try #require(LinkPreviewSummary.parse(reply: #"{"details": [{"label": "Fix:", "icon": "wrench", "info": "Restart the router"}]}"#))
        #expect(summary.quickSummary == nil)
        #expect(summary.details.count == 1)
    }

    @Test func pageTextDropsScriptsStylesAndMarkup() {
        let html = """
            <html><head><title>T</title><style>p{color:red}</style></head>
            <body><script>var x = "<p>no</p>";</script><!-- hidden -->
            <h1>Pasta &amp; sauce</h1><p>Boil   the
            water.</p><noscript>Turn on JS</noscript><svg><text>logo</text></svg></body></html>
            """
        #expect(LinkPreviewSummary.pageText(html: html) == "Pasta & sauce Boil the water.")
    }

    @Test func promptCarriesThePageAsUntrustedContent() {
        let metadata = LinkPreviewMetadata(title: "Pasta", summary: "Quick pasta")
        let prompt = LinkPreviewSummary.prompt(url: url, metadata: metadata, pageText: String(repeating: "a", count: 30_000),
                                               language: "French")
        #expect(prompt.hasPrefix("Write the card's text in French."))
        #expect(prompt.contains("Page title: Pasta"))
        #expect(prompt.contains("Page description: Quick pasta"))
        #expect(prompt.contains("<\(UntrustedContent.tag) source=\"\(url.absoluteString)\">"))
        #expect(prompt.count < 21_000)
        #expect(LinkPreviewSummary.prompt(url: url, metadata: nil, pageText: "", language: "English")
            .contains("The page has no readable text."))
    }

    @Test func claudeRunsWithoutTools() {
        let arguments = LinkPreviewSummary.claudeArguments()
        #expect(arguments.first == "-p")
        #expect(arguments.contains("--no-session-persistence"))
        let tools = try? #require(arguments.firstIndex(of: "--tools"))
        #expect(tools.map { arguments[$0 + 1] } == "")
    }

    @Test func languageNames() {
        #expect(LinkPreviewSummary.languageName(for: "en-US") == "English")
        #expect(LinkPreviewSummary.languageName(for: "fr-CA") == "French")
        #expect(LinkPreviewSummary.languageName(for: nil) == "English")
    }

    @Test func speakerSlashAndWaves() {
        typealias S = TabAudioButton.Speaker
        #expect(S.slashThickness(boxWidth: 16, cutout: false) == 1.4)
        #expect(S.slashThickness(boxWidth: 16, cutout: true) == 2.8)
        #expect(S.slashLength(boxWidth: 16, progress: 0, cutout: false) == 0)
        #expect(abs(S.slashLength(boxWidth: 16, progress: 1, cutout: false) - 16 * 2.0.squareRoot()) < 1e-9)
        #expect(S.slashLength(boxWidth: 16, progress: 0, cutout: true) > 0)
        // Showing, the waves follow one another after a short wait; hiding, they start at once.
        #expect(S.waveDelay(index: 0, showing: false) == 0)
        #expect(S.waveDelay(index: 2, showing: true) > S.waveDelay(index: 1, showing: true))
        #expect(S.waveDelay(index: 0, showing: true) > 0)
        #expect(S.waveHiddenOffsets.allSatisfy { $0 < S.waveShownOffset })
    }
}
