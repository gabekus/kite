import Foundation
import Testing
@testable import KiteCore

@Suite struct ThemeCSSTests {
    @Test func hexIsDisplayP3RGBAUppercase() {
        #expect(ThemeCSS.hex(ThemeColor(r: 1, g: 1, b: 1)) == "#FFFFFFFF")
        #expect(ThemeCSS.hex(ThemeColor(r: 0, g: 0, b: 0)) == "#000000FF")
        #expect(ThemeCSS.hex(ThemeColor(r: 1, g: 1, b: 1), alpha: 0.6) == "#FFFFFF99")
        // sRGB red is inside P3, so its P3 components are less saturated: (233, 51, 35) after truncation.
        #expect(ThemeCSS.hex(ThemeColor(r: 1, g: 0, b: 0)) == "#E93323FF")
    }

    @Test func oneColourThemeGivesThePaletteAndTheSimpleColour() {
        let css = ThemeCSS.css(for: Theme(colors: [ThemeColor(r: 0.1, g: 0.1, b: 0.1)]))
        let lines = css.split(separator: "\n").map(String.init)
        #expect(lines.first == ":root {")
        #expect(lines.last == "}")
        let names = lines.dropFirst().dropLast().map { String($0.prefix { $0 != ":" }) }
        #expect(names == ThemeCSS.paletteNames.map { "--arc-palette-" + $0 } + ["--arc-background-simple-color"])
        #expect(lines.contains("--arc-palette-foregroundPrimary: #FFFFFFFF;"))
        #expect(lines.contains("--arc-palette-minContrastColor: #000000FF;"))
        #expect(lines.allSatisfy { $0 == ":root {" || $0 == "}" || $0.range(of: #"^--[a-zA-Z0-9-]+: #[0-9A-F]{8};$"#, options: .regularExpression) != nil })
    }

    @Test func gradientThemeGivesNumberedGradientColours() {
        let theme = Theme(colors: [ThemeColor(hex: 0xD4F7E2), ThemeColor(hex: 0xA6E3C8), ThemeColor(hex: 0xFFE38A)])
        let names = ThemeCSS.properties(for: theme).map(\.name)
        #expect(names.suffix(3) == ["--arc-background-gradient-color0", "--arc-background-gradient-color1", "--arc-background-gradient-color2"])
        #expect(!names.contains("--arc-background-simple-color"))
        // A light theme gets dark text.
        #expect(ThemeCSS.properties(for: theme).first?.value == "#000000FF")
    }

    @Test func scriptCarriesTheCSSAsAStringOrRemovesIt() {
        let css = ":root {\n--x: #000000FF;\n}"
        let script = ThemeCSS.script(css: css)
        #expect(script.contains(#"const css = ":root {\n--x: #000000FF;\n}";"#))
        #expect(ThemeCSS.script(css: nil).contains("const css = null;"))
        #expect(script.contains("window !== window.top"))
    }

    @Test func allowedUnlessTurnedOff() throws {
        let defaults = try #require(UserDefaults(suiteName: "ThemeCSSTests-\(UUID().uuidString)"))
        #expect(ThemeCSS.isAllowed(defaults))
        defaults.set(false, forKey: ThemeCSS.allowedKey)
        #expect(!ThemeCSS.isAllowed(defaults))
    }
}

@Suite struct DataExportTests {
    @Test func spacesAreHeadingsTabsAreURLsFoldersNest() {
        let work = Space(
            name: "Work\n  Stuff", icon: "", theme: .arcDefault,
            pinnedItems: [
                .tab(BrowserTab(url: URL(string: "https://a.example/"))),
                .folder(TabFolder(name: "Docs", items: [
                    .tab(BrowserTab(url: URL(string: "https://b.example/x?y=1"))),
                    .folder(TabFolder(name: "Old", items: [.tab(BrowserTab(url: nil))])),
                ])),
            ],
            tabs: [BrowserTab(url: URL(string: "https://c.example/"))]
        )
        let home = Space(name: "Home", icon: "", theme: .arcDefault)
        let expected = [
            "# Work Stuff", "- https://a.example/", "## Docs", "- https://b.example/x?y=1", "### Old", "- ",
            "", "- https://c.example/", "", "# Home", "",
        ].joined(separator: "\n")
        #expect(DataExport.markdown(spaces: [work, home]) == expected)
    }
}
