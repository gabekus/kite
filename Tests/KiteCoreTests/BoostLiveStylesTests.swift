import Foundation
import Testing
@testable import KiteCore
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

struct BoostLiveStylesTests {
    /// Whether `source` parses as JavaScript (always true where JavaScriptCore isn't available).
    private func parses(_ source: String) -> Bool {
        #if canImport(JavaScriptCore)
        let context = JSGlobalContextCreate(nil)
        defer { JSGlobalContextRelease(context) }
        let script = JSStringCreateWithUTF8CString(source)
        defer { JSStringRelease(script) }
        return JSCheckScriptSyntax(context, script, nil, 1, nil)
        #else
        return true
        #endif
    }

    @Test func stylesFollowCSSAndControlsButNotJavaScript() {
        var library = BoostLibrary()
        let boost = library.create(for: URL(string: "https://www.example.com/a"))!
        let empty = library.liveStyles(forDomain: "example.com")
        #expect(empty.isEmpty)

        library.update(boost.id) { $0.js = "console.log(1)" }
        // JavaScript runs again only on a reload, as in Arc: nothing to apply live.
        #expect(library.liveStyles(forDomain: "example.com") == empty)

        library.update(boost.id) { $0.css = "p { color: red }" }
        let css = library.liveStyles(forDomain: "example.com")
        #expect(css.styles == [.init(id: "kite-boost-" + boost.id.uuidString.lowercased(), css: "p { color: red }")])

        library.update(boost.id) { $0.fontFamily = "Futura"; $0.textZoom = 125 }
        let styled = library.liveStyles(forDomain: "example.com")
        #expect(styled.styles.first?.css.contains("font-family: \"Futura\"") == true)
        #expect(styled.styles.first?.css.hasSuffix("p { color: red }") == true)
        #expect(styled.look.contains("zoom: 1.25"))

        library.update(boost.id) { $0.colors = BoostColorWheel(primaryHueDegrees: 200, primarySaturation: 0.6, secondaryHueOffset: 180) }
        #expect(library.liveStyles(forDomain: "example.com").tables != nil)

        library.setEnabled(boost.id, false)
        #expect(library.liveStyles(forDomain: "example.com").isEmpty)
    }

    @Test func liveScriptReplacesEachBoostStyleAndTheLook() {
        let a = Boost(name: "a", domain: "example.com", css: "body { content: \"</style>\" }", textZoom: 110)
        let b = Boost(name: "b", domain: "example.com", css: "p { color: red }",
                      colors: BoostColorWheel(primaryHueDegrees: 30, primarySaturation: 0.5, secondaryHueOffset: 180))
        let script = BoostScript.applyLive(BoostLiveStyles([a, b]))
        #expect(parses(script))
        #expect(script.contains("window !== window.top"))
        #expect(script.contains("kite-boost-" + a.id.uuidString.lowercased()))
        #expect(script.contains("kite-boost-" + b.id.uuidString.lowercased()))
        #expect(script.contains("style[id^=\"kite-boost-\"]"))
        #expect(script.contains(BoostScript.lookAttribute))
        #expect(script.contains(BoostScript.filterAttribute))
        // No Boosts left: the script still runs, to take the old styles out.
        let none = BoostScript.applyLive(BoostLiveStyles([]))
        #expect(parses(none))
        #expect(none.contains("const styles = [];"))
        #expect(none.contains("const tables = null;"))
    }

    @Test func documentStartScriptStillParsesWithEveryPart() throws {
        let boost = Boost(name: "a", domain: "example.com", css: "p{}", js: "let x = 1", zaps: [".ad"],
                          fontFamily: "Avenir", textCase: .uppercase, textZoom: 90,
                          colors: BoostColorWheel(primaryHueDegrees: 10, primarySaturation: 0.4, secondaryHueOffset: 90))
        let source = try #require(BoostScript.source(for: [boost]))
        #expect(parses(source))
        #expect(source.contains("filterSVG(tables)"))
    }
}
