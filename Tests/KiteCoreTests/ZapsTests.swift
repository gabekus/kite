import Foundation
import Testing
@testable import KiteCore

@Suite struct ZapTests {
    @Test func siteIsTheHostWithoutWWW() {
        #expect(ZapLibrary.domain(of: URL(string: "https://www.Example.com/a?b")) == "example.com")
        #expect(ZapLibrary.domain(of: URL(string: "http://news.example.com.")) == "news.example.com")
        #expect(ZapLibrary.domain(of: URL(string: "kite://history")) == nil)
        #expect(ZapLibrary.domain(of: URL(string: "about:blank")) == nil)
        #expect(ZapLibrary.domain(ofHost: "www.") == "www")
        #expect(ZapLibrary.domain(ofHost: "") == nil)
    }

    @Test func addAndUndoZaps() {
        var library = ZapLibrary()
        let added = [
            library.add(" .ad ", for: "example.com"), library.add(".ad", for: "example.com"),
            library.add("  ", for: "example.com"), library.add("#banner", for: "example.com"),
        ]
        #expect(added == [true, false, false, true])
        #expect(library.selectors(for: "example.com") == [".ad", "#banner"])
        #expect(library.css(for: "example.com") == ".ad { display: none !important; }\n#banner { display: none !important; }")

        let removed = [
            library.remove(".ad", for: "example.com"), library.remove(".ad", for: "example.com"),
            library.remove("#banner", for: "example.com"),
        ]
        #expect(removed == [true, false, true])
        #expect(library.sites.isEmpty)
        #expect(library.css(for: "example.com").isEmpty)
    }

    @Test func roundTripsAsJSON() throws {
        var library = ZapLibrary()
        library.add("div.promo > a", for: "example.com")
        let decoded = try JSONDecoder().decode(ZapLibrary.self, from: JSONEncoder().encode(library))
        #expect(decoded == library)
    }

    @Test func liveScriptHasOnlyTheGivenCSS() {
        let script = ZapScript.apply(css: "</style><b>'\"")
        #expect(script.contains(ZapScript.literal("</style><b>'\"")))
        #expect(script.contains("style[data-kite-zap]"))
    }

    @Test func pickerScriptsTakeViewportPoints() {
        #expect(ZapPickerScript.hovered(x: 12.25, y: 40).hasSuffix("('hovered', 12.2, 40.0)") ||
                ZapPickerScript.hovered(x: 12.25, y: 40).hasSuffix("('hovered', 12.3, 40.0)"))
        #expect(ZapPickerScript.target(x: .nan, y: 3).hasSuffix("('target', 0, 3.0)"))
    }

    @Test func decodesPickerResults() {
        let json = ##"{"rect":{"x":1,"y":2,"width":3,"height":4},"selector":"#a","related":".b","relatedCount":2,"relatedRects":[]}"##
        let target = ZapTarget.decode(json)
        #expect(target?.selector == "#a")
        #expect(target?.related == ".b")
        #expect(target?.rect == ZapTarget.Rect(x: 1, y: 2, width: 3, height: 4))
        #expect(ZapTarget.decode(nil) == nil)
        #expect(ZapTarget.decode("null") == nil)
    }
}
