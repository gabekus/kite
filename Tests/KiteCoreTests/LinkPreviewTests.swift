import Foundation
import Testing
@testable import KiteCore

@Suite struct LinkPreviewTests {
    let base = URL(string: "https://example.com/articles/1")!

    @Test func openGraphTagsWinOverTitleAndDescription() {
        let html = """
            <html><head>
            <title>Plain title</title>
            <meta name="description" content="Plain description">
            <meta property="og:title" content="OG &amp; title">
            <meta content="OG description" property="og:description" />
            <meta property='og:image' content='/img/cover.jpg'>
            <meta property="og:site_name" content="Example">
            </head><body><meta property="og:title" content="Body tag"></body></html>
            """
        let metadata = LinkPreviewMetadata.parse(html: html, baseURL: base)
        #expect(metadata.title == "OG & title")
        #expect(metadata.summary == "OG description")
        #expect(metadata.imageURL == URL(string: "https://example.com/img/cover.jpg"))
        #expect(metadata.siteName == "Example")
    }

    @Test func fallsBackToTitleTagAndDescriptionMeta() {
        let html = "<head><TITLE>\n  Hello &#8212; world  \n</TITLE><meta name=Description content=\"It&#x27;s fine\"></head>"
        let metadata = LinkPreviewMetadata.parse(html: html, baseURL: base)
        #expect(metadata.title == "Hello — world")
        #expect(metadata.summary == "It's fine")
        #expect(metadata.imageURL == nil)
        #expect(!metadata.isEmpty)
    }

    @Test func emptyPageHasNoMetadata() {
        #expect(LinkPreviewMetadata.parse(html: "<html><body>hi</body></html>", baseURL: base).isEmpty)
        // Images that aren't web URLs are dropped.
        let html = #"<meta property="og:image" content="data:image/png;base64,AAAA">"#
        #expect(LinkPreviewMetadata.parse(html: html, baseURL: base).imageURL == nil)
    }

    @Test func entitiesDecodeAndUnknownOnesStay() {
        #expect(LinkPreviewMetadata.decodeEntities("a &lt;b&gt; &quot;c&quot; &unknown; & d") == "a <b> \"c\" &unknown; & d")
    }

    @Test func onlyWebLinksArePreviewed() {
        #expect(LinkPreview.canPreview(URL(string: "https://a.com/x")!))
        #expect(LinkPreview.canPreview(URL(string: "HTTP://a.com")!))
        #expect(!LinkPreview.canPreview(URL(string: "mailto:a@b.com")!))
        #expect(!LinkPreview.canPreview(URL(string: "javascript:void(0)")!))
        #expect(!LinkPreview.canPreview(URL(fileURLWithPath: "/tmp/a.html")))
    }

    @Test func statusTextBecomesALink() {
        #expect(LinkPreview.link(fromStatus: "https://news.ycombinator.com/item?id=1") == URL(string: "https://news.ycombinator.com/item?id=1"))
        #expect(LinkPreview.link(fromStatus: "  https://a.com/a b  ") == URL(string: "https://a.com/a%20b"))
        #expect(LinkPreview.link(fromStatus: "") == nil)
        #expect(LinkPreview.link(fromStatus: nil) == nil)
        #expect(LinkPreview.link(fromStatus: "Loading…") == nil)
        #expect(LinkPreview.link(fromStatus: "mailto:a@b.com") == nil)
    }

    @Test func settingDefaultsOn() throws {
        let suite = "LinkPreviewTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(LinkPreview.isEnabled(in: defaults))
        defaults.set(false, forKey: LinkPreview.enabledKey)
        #expect(!LinkPreview.isEnabled(in: defaults))
    }

    // Screen coordinates: origin bottom-left, y up. A 1000×800 window at the origin.
    let window = LinkPreview.Box(x: 0, y: 0, width: 1000, height: 800)

    @Test func cardOpensBelowTheLinkAlignedToItsLeftEdge() {
        let link = LinkPreview.Box(x: 200, y: 600, width: 120, height: 18)
        let (frame, placement) = LinkPreview.cardFrame(link: link, cardHeight: 220, in: window)
        #expect(placement == .below)
        #expect(frame == LinkPreview.Box(x: 200, y: 600 - 8 - 220, width: 300, height: 220))
    }

    @Test func cardFlipsAboveNearTheBottomAndStaysInside() {
        let link = LinkPreview.Box(x: 900, y: 100, width: 80, height: 18)
        let (frame, placement) = LinkPreview.cardFrame(link: link, cardHeight: 220, in: window)
        #expect(placement == .above)
        #expect(frame.y == 118 + 8)
        #expect(frame.x == 1000 - 8 - 300)
    }

    @Test func cardIsCappedAt400AndPinnedWhenNeitherSideFits() {
        let short = LinkPreview.Box(x: 0, y: 0, width: 1000, height: 500)
        let link = LinkPreview.Box(x: 10, y: 220, width: 50, height: 20)
        let (frame, placement) = LinkPreview.cardFrame(link: link, cardHeight: 900, in: short)
        #expect(frame.height == 400)
        #expect(frame.x == 10)
        #expect(placement == .above)
        #expect(frame.y == 500 - 8 - 400)
    }

    @Test func corridorCoversTheWayFromLinkToCard() {
        let link = LinkPreview.Box(x: 200, y: 600, width: 120, height: 18)
        let card = LinkPreview.Box(x: 200, y: 372, width: 300, height: 220)
        #expect(LinkPreview.isInCorridor(x: 260, y: 596, link: link, card: card))
        #expect(LinkPreview.isInCorridor(x: 510, y: 500, link: link, card: card))
        #expect(!LinkPreview.isInCorridor(x: 600, y: 500, link: link, card: card))
        #expect(!LinkPreview.isInCorridor(x: 260, y: 700, link: link, card: card))
    }
}
