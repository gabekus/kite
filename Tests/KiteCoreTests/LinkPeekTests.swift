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

    @Test func linksSwitchesGateEachCase() {
        let news = URL(string: "https://www.nytimes.com/article")!
        let noShift = LinkPeek.Options(shiftClick: false)
        #expect(!LinkPeek.opensInPeek(section: .unpinned, from: mail, to: news, shift: true, options: noShift))
        #expect(LinkPeek.opensInPeek(section: .pinned, from: mail, to: news, shift: false, options: noShift))
        let noOtherSites = LinkPeek.Options(otherSites: false)
        #expect(!LinkPeek.opensInPeek(section: .pinned, from: mail, to: news, shift: false, options: noOtherSites))
        #expect(!LinkPeek.opensInPeek(section: .favorite, from: mail, to: news, shift: false, options: noOtherSites))
        #expect(LinkPeek.opensInPeek(section: .pinned, from: mail, to: news, shift: true, options: noOtherSites))
    }

    @Test func linksSwitchesReadArcsKeysOnByDefault() {
        let defaults = UserDefaults(suiteName: "LinkPeekTests-\(UUID().uuidString)")!
        #expect(LinkPeek.Options(defaults: defaults) == LinkPeek.Options(shiftClick: true, otherSites: true))
        defaults.set(true, forKey: "disableShiftClickToOpenLinksInModal")
        defaults.set(false, forKey: "modalEnabled")
        #expect(LinkPeek.Options(defaults: defaults) == LinkPeek.Options(shiftClick: false, otherSites: false))
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

    @Test func tweenStartsAtTheSourcesWidthAndCentre() {
        let card = LinkPeek.Frame(x: 100, y: 12, width: 800, height: 676)
        let link = LinkPeek.Frame(x: 40, y: 300, width: 80, height: 20)
        let tween = LinkPeek.sourceTween(source: link, card: card, cornerRadius: 4)
        #expect(tween == LinkPeek.SourceTween(scale: 0.1, dx: 80 - 500, dy: 310 - 350, cornerRadius: 40))
        #expect(LinkPeek.sourceTween(source: .init(x: 0, y: 0, width: 0, height: 10), card: card) == nil)
    }

    @Test func sourceFrameAppliesZoomAndRejectsJunk() {
        let result: [String: Any] = ["x": 10, "y": 20.5, "width": 30, "height": 8]
        #expect(LinkPeek.sourceFrame(scriptResult: result, zoom: 1.5) == .init(x: 15, y: 30.75, width: 45, height: 12))
        #expect(LinkPeek.sourceFrame(scriptResult: nil, zoom: 1) == nil)
        #expect(LinkPeek.sourceFrame(scriptResult: ["x": 1, "y": 1, "width": 0, "height": 5], zoom: 1) == nil)
        let script = LinkPeek.sourceRectScript(point: (12, 34), url: "https://a.com/\"x")
        #expect(script.contains("at = [12.0, 34.0]"))
        #expect(script.contains(#"["https:\/\/a.com\/\"x"][0]"#))
        #expect(LinkPeek.sourceRectScript(point: nil, url: "https://a.com/").contains("at = null"))
    }
}

@Suite struct LinkPeekSwipeTests {
    typealias Swipe = LinkPeek.Swipe

    @Test func arcsThresholdsAndRubberbanding() {
        #expect(Swipe.minimumDismissTranslation == 75)
        #expect(Swipe.minimumDismissTranslationNoVelocity == 152)
        let tug = Swipe.tug(translation: .init(x: 100, y: -10))
        #expect(abs(tug.x - 6) < 1e-9 && abs(tug.y + 0.6) < 1e-9)
    }

    @Test func dismissNeedsDistanceAndARightwardOrRestingRelease() {
        #expect(!Swipe.dismisses(translationX: 74, release: .right))
        #expect(Swipe.dismisses(translationX: 75, release: .right))
        #expect(!Swipe.dismisses(translationX: 151, release: .resting))
        #expect(Swipe.dismisses(translationX: 152, release: .resting))
        #expect(!Swipe.dismisses(translationX: 400, release: .left))
        #expect(!Swipe.dismisses(translationX: 400, release: .down))
    }

    @Test func releaseDirectionFromVelocity() {
        #expect(Swipe.release(velocity: .init(x: 10, y: 5)) == .resting)
        #expect(Swipe.release(velocity: .init(x: 300, y: 50)) == .right)
        #expect(Swipe.release(velocity: .init(x: -300, y: 50)) == .left)
        #expect(Swipe.release(velocity: .init(x: 30, y: -300)) == .up)
    }

    @Test func velocityUsesTheLastTenthOfASecond() {
        let samples = [(time: 0.0, dx: 50.0, dy: 0.0), (time: 0.95, dx: 10, dy: 2), (time: 1.0, dx: 10, dy: 0)]
        let v = Swipe.velocity(samples: samples, end: 1.0)
        #expect(abs(v.x - 200) < 1e-9 && abs(v.y - 20) < 1e-9)
        #expect(Swipe.velocity(samples: samples, end: 2.0) == .zero)
    }

    @Test func hapticOnlyWhenCrossingRightward() {
        #expect(Swipe.crossesHapticThreshold(from: 150, to: 153))
        #expect(!Swipe.crossesHapticThreshold(from: 153, to: 160))
        #expect(!Swipe.crossesHapticThreshold(from: 160, to: 140))
    }

    @Test func cardShrinksAlongTheMainAxisAndItsHairlineFades() {
        #expect(abs(Swipe.scale(tug: .init(x: 10, y: 2)) - 0.99) < 1e-9)
        #expect(abs(Swipe.scale(tug: .init(x: 1, y: 20)) - 0.98) < 1e-9)
        #expect(Swipe.scale(tug: .zero) == 1)
        #expect(Swipe.borderOpacity(tug: .zero) == 0.25)
        #expect(Swipe.borderOpacity(tug: .init(x: 22, y: 0)) == 0.125)
        #expect(Swipe.borderOpacity(tug: .init(x: 60, y: 0)) == 0)
        #expect(Swipe.controlsOffset(tug: .init(x: 8, y: 1)) == 10)
        #expect(Swipe.controlsOffset(tug: .init(x: 1, y: 8)) == 2)
    }

    @Test func snapshotFadesWithArcsShareOfTheTransition() {
        let out = LinkPeek.snapshotFadeOut
        #expect(out.from == 1 && out.to == 0 && out.delay == 0)
        #expect(out.spring.dampingRatio == 0.95)
        #expect(abs(out.spring.response - 0.1225) < 1e-9)
        let back = LinkPeek.snapshotFadeIn
        #expect(back.from == 0 && back.to == 1)
        #expect(abs(back.delay - 0.07875) < 1e-9)
        #expect(abs(back.spring.response - 0.14625) < 1e-9)
    }

    @Test func snapshotCoversTheSourceUnderTheTween() {
        let source = LinkPeek.Frame(x: 100, y: 300, width: 200, height: 40)
        let card = LinkPeek.Frame(x: 50, y: 12, width: 800, height: 600)
        let frame = LinkPeek.snapshotFrame(source: source, cardWidth: card.width, cardHeight: card.height)!
        #expect(frame.width == 800 && frame.height == 160 && frame.y == 220)
        // Scaled by the tween about the card's centre, the snapshot lands on the source.
        let tween = LinkPeek.sourceTween(source: source, card: card)!
        let centerY = card.y + card.height / 2
        let top = centerY + tween.dy + (card.y + frame.y - centerY) * tween.scale
        #expect(abs(top - source.y) < 1e-9)
        #expect(abs(frame.height * tween.scale - source.height) < 1e-9)
        #expect(LinkPeek.snapshotFrame(source: .init(x: 0, y: 0, width: 0, height: 4), cardWidth: 800, cardHeight: 600) == nil)
    }

    @Test func tugSpringSettlesToRest() {
        let spring = Swipe.tugSpring
        let start = spring.settle(value: 9, velocity: 0, after: 0)
        #expect(abs(start.value - 9) < 1e-9 && abs(start.velocity) < 1e-9)
        let later = spring.settle(value: 9, velocity: -20, after: 2)
        #expect(abs(later.value) < 0.01 && abs(later.velocity) < 0.1)
        // Damping 0.9 overshoots only slightly.
        let samples = stride(from: 0.0, through: 2, by: 0.01).map { spring.settle(value: 9, velocity: 0, after: $0).value }
        #expect(samples.min()! > -0.2)
        #expect(samples.min()! < 0)
    }
}
