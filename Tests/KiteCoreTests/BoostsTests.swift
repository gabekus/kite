import Foundation
import Testing
@testable import KiteCore

@Suite struct BoostsTests {
    let page = URL(string: "https://www.Example.com/news?x=1")!

    func make(_ library: inout BoostLibrary, _ url: URL, now: Date = Date()) throws -> Boost {
        let boost = library.create(for: url, now: now)
        return try #require(boost)
    }

    @Test func domainIsTheHostWithoutWWW() {
        #expect(BoostLibrary.domain(of: page) == "example.com")
        #expect(BoostLibrary.domain(of: URL(string: "http://news.example.com/")) == "news.example.com")
        #expect(BoostLibrary.domain(of: URL(string: "kite://history")) == nil)
        #expect(BoostLibrary.domain(of: URL(string: "about:blank")) == nil)
        #expect(BoostLibrary.domain(of: URL(string: "file:///tmp/a.html")) == nil)
        #expect(BoostLibrary.domain(of: nil) == nil)
    }

    @Test func createsAnEmptyBoostForTheSiteNewestFirst() {
        var library = BoostLibrary()
        let first = library.create(for: page)
        let second = library.create(for: URL(string: "https://other.org/")!)
        #expect(first?.domain == "example.com")
        #expect(first?.name == "example.com")
        #expect(first?.isEnabled == true)
        #expect(library.boosts.map(\.id) == [second?.id, first?.id])
        #expect(library.create(for: URL(string: "kite://archive")) == nil)
        #expect(library.boosts.count == 2)
    }

    @Test func runsOnlyEnabledNonEmptyBoostsForThatDomain() throws {
        var library = BoostLibrary()
        let a = try make(&library, page)
        let b = try make(&library, page)
        let off = try make(&library, page)
        let elsewhere = try make(&library, URL(string: "https://sub.example.com/")!)
        library.update(a.id) { $0.css = "body { color: red }" }
        library.update(b.id) { $0.js = "document.title = 'x'" }
        library.update(off.id) { $0.css = "p {}" }
        library.setEnabled(off.id, false)
        library.update(elsewhere.id) { $0.css = "p {}" }
        // Oldest first, so a newer Boost's CSS comes later and wins.
        #expect(library.activeBoosts(for: URL(string: "http://example.com/a")).map(\.id) == [a.id, b.id])
        #expect(library.boosts(for: page).count == 3)
        #expect(library.activeBoosts(for: URL(string: "https://sub.example.com/")).map(\.id) == [elsewhere.id])
    }

    @Test func editsRenamesAndDeletes() throws {
        var library = BoostLibrary()
        let created = Date(timeIntervalSince1970: 0)
        let boost = try make(&library, page, now: created)
        let later = Date(timeIntervalSince1970: 100)
        library.rename(boost.id, to: "  Quiet news  ", now: later)
        #expect(library.boost(boost.id)?.name == "Quiet news")
        #expect(library.boost(boost.id)?.updatedAt == later)
        library.rename(boost.id, to: "   ")
        #expect(library.boost(boost.id)?.name == "Quiet news")
        // An edit that changes nothing keeps the date.
        library.update(boost.id, now: Date(timeIntervalSince1970: 200)) { $0.name = "Quiet news" }
        #expect(library.boost(boost.id)?.updatedAt == later)
        #expect(library.delete(boost.id)?.id == boost.id)
        #expect(library.boosts.isEmpty)
        #expect(library.delete(boost.id) == nil)
        #expect(!library.update(boost.id) { $0.css = "x" })
    }

    @Test func roundTripsThroughJSON() throws {
        var library = BoostLibrary()
        let boost = try make(&library, page)
        library.update(boost.id) { $0.css = "a { color: blue }"; $0.js = "console.log(1)" }
        let data = try JSONEncoder().encode(library)
        #expect(try JSONDecoder().decode(BoostLibrary.self, from: data) == library)
    }

    @Test func scriptAddsStylesAndRunsValidScriptsOnly() throws {
        let style = Boost(name: "a", domain: "example.com", css: "body { content: \"</style>\" }\n")
        let good = Boost(name: "b", domain: "example.com", js: "console.log('hi')")
        let broken = Boost(name: "c", domain: "example.com", css: "p { color: red }", js: "brokenCall((")
        let source = BoostScript.source(for: [style, good, broken], isValidJS: { !$0.contains("brokenCall((") })
        let script = try #require(source)
        #expect(script.contains("window.__kiteBoosts"))
        #expect(script.contains("window !== window.top"))
        #expect(script.contains(#""body { content: \"<\/style>\" }\n""#) || script.contains(#""body { content: \"</style>\" }\n""#))
        #expect(script.contains("kite-boost-" + style.id.uuidString.lowercased()))
        #expect(script.contains("console.log('hi')"))
        // The broken Boost's CSS still applies; its JavaScript is left out.
        #expect(script.contains("p { color: red }"))
        #expect(!script.contains("brokenCall"))
    }

    @Test func noScriptWithoutCode() {
        #expect(BoostScript.source(for: []) == nil)
        #expect(BoostScript.source(for: [Boost(name: "a", domain: "a.com", css: "  \n")]) == nil)
    }

    @Test func literalEscapesQuotesAndLineSeparators() {
        #expect(BoostScript.literal("a'b\"c\n\u{2028}") == "\"a'b\\\"c\\n\\u2028\"")
    }

    // MARK: Zaps

    @Test func zapsGoInTheBoostScriptAsOneZapStyle() throws {
        let a = Boost(name: "a", domain: "example.com", zaps: [".ad", "#banner"])
        let b = Boost(name: "b", domain: "example.com", css: "p { color: red }", zaps: [".ad"])
        #expect(!a.isEmpty)
        let script = try #require(BoostScript.source(for: [a, b]))
        let css = ".ad { display: none !important; }\n#banner { display: none !important; }"
        #expect(script.contains(BoostScript.literal(css)))
        #expect(script.contains("style[data-kite-zap]"))
        #expect(script.contains("p { color: red }"))
        // A zap-only Boost still makes a script; no zaps, no zap CSS.
        #expect(BoostScript.source(for: [Boost(name: "c", domain: "x.com", zaps: ["#x"])]) != nil)
        #expect(BoostScript.source(for: [Boost(name: "d", domain: "x.com", css: "a{}")])?.contains("const zaps = \"\"") == true)
    }

    @Test func zapsGoToTheEditedOrNewestBoostOrANewOne() throws {
        var library = BoostLibrary()
        let first = library.addZap(" .ad ", domain: "example.com", now: Date(timeIntervalSince1970: 1))
        let id = try #require(first)
        #expect(library.boosts.count == 1)
        #expect(library.boost(id)?.name == "example.com")
        #expect(library.boost(id)?.zaps == [".ad"])
        let again = library.addZap(".ad", domain: "example.com")
        #expect(again == id)
        #expect(library.boost(id)?.zaps == [".ad"])
        let blank = library.addZap("  ", domain: "example.com")
        #expect(blank == nil)

        let newer = try make(&library, page)
        let toNewest = library.addZap("#b", domain: "example.com")
        let toPreferred = library.addZap("#c", domain: "example.com", preferring: id)
        #expect(toNewest == newer.id)
        #expect(toPreferred == id)
        // A preferred Boost for another site doesn't take it.
        let other = try make(&library, URL(string: "https://other.org")!)
        let notOther = library.addZap("#d", domain: "example.com", preferring: other.id)
        #expect(notOther == newer.id)

        #expect(library.activeZaps(forDomain: "example.com") == [".ad", "#c", "#b", "#d"])
        library.setEnabled(id, false)
        #expect(library.activeZaps(forDomain: "example.com") == ["#b", "#d"])
        #expect(library.zapCSS(forDomain: "example.com") == "#b { display: none !important; }\n#d { display: none !important; }")
        library.removeZap("#b", from: newer.id)
        #expect(library.activeZaps(forDomain: "example.com") == ["#d"])
        #expect(library.activeBoosts(for: page).flatMap(\.zaps) == ["#d"])
    }

    @Test func oldBoostsWithoutZapsStillDecode() throws {
        let json = #"{"version":1,"boosts":[{"id":"6F1C2D3E-0000-4000-8000-000000000001","name":"a","domain":"a.com","css":"","js":"x()","isEnabled":true,"createdAt":0,"updatedAt":0}]}"#
        let library = try JSONDecoder().decode(BoostLibrary.self, from: Data(json.utf8))
        #expect(library.boosts.first?.zaps == [])
        #expect(library.boosts.first?.js == "x()")
        var withZaps = library
        withZaps.addZap("#z", domain: "a.com")
        #expect(try JSONDecoder().decode(BoostLibrary.self, from: JSONEncoder().encode(withZaps)) == withZaps)
    }

    @Test func migratesZapsJSONIntoEachSitesBoost() throws {
        var library = BoostLibrary()
        let existing = try make(&library, page)
        var zaps = ZapLibrary()
        zaps.add(".ad", for: "example.com")
        zaps.add("#promo", for: "news.org")
        let changed = library.migrate(zaps)
        #expect(changed)
        #expect(library.boost(existing.id)?.zaps == [".ad"])
        let news = try #require(library.boosts(forDomain: "news.org").first)
        #expect(news.zaps == ["#promo"])
        #expect(news.name == "news.org")
        // Running it again changes nothing.
        let changedAgain = library.migrate(zaps)
        #expect(!changedAgain)
        #expect(library.boosts.count == 2)
    }
}
