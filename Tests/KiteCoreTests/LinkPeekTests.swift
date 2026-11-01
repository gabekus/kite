import Foundation
import Testing
@testable import KiteCore

@Suite struct LinkPeekTests {
    let mail = URL(string: "https://mail.google.com/mail/u/0/#inbox")!

    @Test func pinnedAndFavoriteLinksToOtherSitesPeek() {
        let news = URL(string: "https://www.nytimes.com/article")!
        #expect(LinkPeek.opensInPeek(section: .pinned, from: mail, to: news, shift: false))
        #expect(LinkPeek.opensInPeek(section: .favorite, from: mail, to: news, shift: false))
        #expect(!LinkPeek.opensInPeek(section: .unpinned, from: mail, to: news, shift: false))
        #expect(!LinkPeek.opensInPeek(section: nil, from: mail, to: news, shift: false))
    }

    @Test func sameSiteLinksStayInTheTab() {
        let calendar = URL(string: "https://calendar.google.com/")!
        #expect(!LinkPeek.opensInPeek(section: .pinned, from: mail, to: calendar, shift: false))
        let uk = URL(string: "https://shop.example.co.uk/a")!
        #expect(!LinkPeek.opensInPeek(section: .pinned, from: uk, to: URL(string: "https://www.example.co.uk/b")!, shift: false))
    }

    @Test func shiftPeeksFromAnyTab() {
        let sameSite = URL(string: "https://mail.google.com/other")!
        #expect(LinkPeek.opensInPeek(section: .unpinned, from: mail, to: sameSite, shift: true))
    }

    @Test func onlyWebLinksPeek() {
        #expect(!LinkPeek.opensInPeek(section: .pinned, from: mail, to: URL(string: "mailto:a@b.c")!, shift: false))
        #expect(!LinkPeek.opensInPeek(section: .pinned, from: mail, to: URL(string: "about:blank")!, shift: true))
        // No page yet (a pinned tab that hasn't loaded): nothing to compare with.
        #expect(!LinkPeek.opensInPeek(section: .pinned, from: nil, to: URL(string: "https://a.com")!, shift: false))
    }

    @Test func cardIsEightyPercentWideAndInsetTwelve() {
        let card = LinkPeek.cardFrame(hostWidth: 1000, hostHeight: 700)
        #expect(card == LinkPeek.Frame(x: 100, y: 12, width: 800, height: 676))
        let controls = LinkPeek.controlsFrame(card: card, buttons: 3)
        #expect(controls == LinkPeek.Frame(x: 913, y: 12, width: 120, height: 135))
        #expect(LinkPeek.controlsFrame(card: card, buttons: 2).height == 90)
    }

    @Test func springMatchesArcsDerivation() {
        let spring = LinkPeek.openSpring
        #expect(abs(spring.stiffness - pow(2 * .pi / 0.245, 2)) < 1e-9)
        #expect(abs(spring.damping - 4 * .pi * 0.865 / 0.245) < 1e-9)
    }
}
