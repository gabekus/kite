import Foundation
import Testing
@testable import KiteCore

@Suite struct BoostStylesTests {
    @Test func fontAndCaseUseArcsRules() {
        let boost = Boost(name: "a", domain: "example.com", fontFamily: "Times New Roman", textCase: .uppercase)
        #expect(BoostStyle.css(for: boost) == """
        *:not(i, .material-symbols-outlined, .material-icons) { font-family: "Times New Roman" !important; }
        *:not(i, .material-symbols-outlined, .material-icons) { text-transform: uppercase !important; }
        """)
        #expect(BoostStyle.css(for: Boost(name: "a", domain: "example.com")) == "")
        // A quote in a family can't end the string early.
        let odd = Boost(name: "a", domain: "x.com", fontFamily: "A\"B")
        #expect(BoostStyle.css(for: odd).contains("font-family: \"A\\\"B\" !important"))
    }

    @Test func textSizeIsArcsFiveLevels() {
        #expect(BoostTextZoom.levels == [90, 100, 110, 125, 150])
        #expect(BoostTextZoom.next(after: nil) == 110)
        #expect(BoostTextZoom.next(after: 125) == 150)
        #expect(BoostTextZoom.next(after: 150) == 90)
        #expect(BoostStyle.zoomCSS(125) == "html { zoom: 1.25 !important; }")
        #expect(BoostStyle.zoomCSS(100) == "")
        #expect(BoostStyle.zoomCSS(nil) == "")
    }

    @Test func textCaseCyclesInArcsOrder() {
        #expect(BoostTextCase.next(after: nil) == .capitalize)
        #expect(BoostTextCase.next(after: .capitalize) == .uppercase)
        #expect(BoostTextCase.next(after: .uppercase) == .lowercase)
        #expect(BoostTextCase.next(after: .lowercase) == nil)
    }

    @Test func colorMatrixMatchesArcsRows() {
        let wheel = BoostColorWheel(primaryHueDegrees: 90, primarySaturation: 1, secondaryHueOffset: 180)
        let m = wheel.matrix
        // Hue runs from the second hue (dark) to the primary (light).
        #expect(abs(m[0][2] - -0.5) < 1e-9)
        #expect(abs(m[0][4] - 0.75) < 1e-9)
        // Saturation keeps half the page's and takes half the wheel's.
        #expect(m[1] == [0, 0.5, 0, 0, 0.5])
        // k = (1 - 0.5) * 0.2 * 1 = 0.1: L' = 0.7 L + 0.2.
        #expect(abs(m[2][2] - 0.7) < 1e-9 && abs(m[2][4] - 0.2) < 1e-9)
        #expect(m[3] == [0, 0, 0, 1, 0])

        var inverted = wheel
        inverted.invertLightness = true
        #expect(abs(inverted.matrix[2][2] - -0.7) < 1e-9 && abs(inverted.matrix[2][4] - 0.9) < 1e-9)

        var brighter = wheel
        brighter.lightnessShift = 1
        brighter.preservedLightness = 1
        // No compression (k = 0) and Brightness at the top adds 0.2.
        #expect(abs(brighter.matrix[2][2] - 1) < 1e-9 && abs(brighter.matrix[2][4] - 0.2) < 1e-9)
    }

    @Test func mapsWhiteToThePrimaryHueAndBlackToTheSecond() {
        let wheel = BoostColorWheel(primaryHueDegrees: 0, primarySaturation: 1, secondaryHueOffset: 120)
        let white = wheel.map(hue: 0.5, saturation: 0, lightness: 1)
        #expect(abs(white.hue - 0) < 1e-9)
        #expect(abs(white.lightness - 0.9) < 1e-9)
        let black = wheel.map(hue: 0.5, saturation: 0, lightness: 0)
        #expect(abs(black.hue - 1.0 / 3) < 1e-9)
        #expect(abs(black.lightness - 0.2) < 1e-9)
        // White turns a light red.
        let rgb = wheel.rgb(forLightness: 1)
        #expect(rgb.r > rgb.g && abs(rgb.g - rgb.b) < 1e-9)
    }

    @Test func hslToRGB() {
        let red = BoostColor.rgb(hue: 0, saturation: 1, lightness: 0.5)
        #expect(red.r == 1 && red.g == 0 && red.b == 0)
        let grey = BoostColor.rgb(hue: 0.3, saturation: 0, lightness: 0.25)
        #expect(grey.r == 0.25 && grey.g == 0.25 && grey.b == 0.25)
        let blue = BoostColor.rgb(hue: 2.0 / 3, saturation: 1, lightness: 0.5)
        #expect(abs(blue.b - 1) < 1e-9 && abs(blue.r) < 1e-9)
    }

    @Test func filterTablesHaveOneValuePerSample() {
        let tables = BoostStyle.filterTables(BoostColorWheel(primaryHueDegrees: 200, primarySaturation: 0.6))
        #expect(tables.r.split(separator: " ").count == 33)
        #expect(tables.b.split(separator: " ").allSatisfy { (Double($0) ?? -1) >= 0 && (Double($0) ?? 2) <= 1 })
    }

    @Test func styleOnlyBoostRunsAndTheNewestOwnsSizeAndColours() throws {
        var older = Boost(name: "a", domain: "example.com", textZoom: 110,
                          colors: BoostColorWheel(primaryHueDegrees: 10, primarySaturation: 1))
        older.createdAt = Date(timeIntervalSince1970: 0)
        let newer = Boost(name: "b", domain: "example.com", fontFamily: "Futura", textZoom: 150)
        #expect(!newer.isEmpty && newer.hasStyle)
        #expect(Boost(name: "c", domain: "example.com", textZoom: 100).isEmpty)
        let source = try #require(BoostScript.source(for: [older, newer]))
        #expect(source.contains("zoom: 1.5 !important"))
        #expect(!source.contains("zoom: 1.1 "))
        #expect(source.contains("filter: url(#kite-boost-colors)"))
        #expect(source.contains("font-family: \\\"Futura\\\""))
        #expect(source.contains(BoostScript.filterAttribute))
        #expect(BoostScript.source(for: [Boost(name: "c", domain: "example.com")]) == nil)
    }

    @Test func oldBoostsJSONStillDecodesAndNewKeysRoundTrip() throws {
        let old = """
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"n","domain":"example.com","css":"","js":"",
         "isEnabled":true,"createdAt":0,"updatedAt":0}
        """
        let boost = try JSONDecoder().decode(Boost.self, from: Data(old.utf8))
        #expect(boost.fontFamily == nil && boost.textCase == nil && boost.textZoom == nil && boost.colors == nil)

        var styled = boost
        styled.fontFamily = "Avenir"
        styled.textCase = .lowercase
        styled.textZoom = 90
        styled.colors = BoostColorWheel(primaryHueDegrees: 300, primarySaturation: 0.4, invertLightness: true, lightnessShift: -0.5)
        let data = try JSONEncoder().encode(styled)
        #expect(try JSONDecoder().decode(Boost.self, from: data) == styled)

        // A text case this Kite doesn't know is dropped rather than failing the whole file.
        let future = old.replacingOccurrences(of: "\"js\":\"\"", with: "\"js\":\"\",\"textCase\":\"smallCaps\"")
        #expect(try JSONDecoder().decode(Boost.self, from: Data(future.utf8)).textCase == nil)
    }

    /// A seeded generator, so a shuffle test sees the same draws every run.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    @Test func shuffleDrawsArcsRangesAndKeepsCode() {
        let boost = Boost(name: "a", domain: "example.com", css: "p{}", js: "1", zaps: [".ad"])
        var generator = Seeded(state: 7)
        var fonts = Set<String>(), cases = Set<String>(), zooms = Set<Int>(), offsets = Set<Double>(), inverts = Set<Bool>()
        for _ in 0..<400 {
            let shuffled = BoostEdits.shuffled(boost, using: &generator)
            #expect(shuffled.css == "p{}" && shuffled.js == "1" && shuffled.zaps == [".ad"])
            #expect(shuffled.id == boost.id && shuffled.name == "a" && shuffled.domain == "example.com")
            let colors = try! #require(shuffled.colors)
            #expect((0...360).contains(colors.primaryHueDegrees))
            #expect((0...1).contains(colors.primarySaturation))
            #expect((0...1).contains(colors.preservedSaturation!) && (0...1).contains(colors.preservedLightness!))
            #expect((-1...1).contains(colors.lightnessShift!))
            offsets.insert(colors.secondaryHueOffset)
            inverts.insert(colors.invertLightness)
            fonts.insert(try! #require(shuffled.fontFamily))
            cases.insert(shuffled.textCase?.rawValue ?? "none")
            zooms.insert(shuffled.textZoom ?? 100)
        }
        #expect(offsets == [45, 90])
        #expect(inverts == [true, false])
        #expect(fonts == Set(BoostFonts.families))
        #expect(cases == ["none", "capitalize", "uppercase", "lowercase"])
        #expect(zooms == Set(BoostTextZoom.levels))
    }

    @Test func resetAllEditsEmptiesTheBoost() {
        let boost = Boost(
            name: "Mine", domain: "example.com", css: "p{}", js: "1", zaps: [".ad"], fontFamily: "Futura",
            textCase: .uppercase, textZoom: 125, colors: BoostColorWheel(primaryHueDegrees: 10, primarySaturation: 0.5),
            isEnabled: false
        )
        let reset = BoostEdits.reset(boost)
        #expect(reset.isEmpty)
        #expect(reset.id == boost.id && reset.name == "Mine" && reset.domain == "example.com" && !reset.isEnabled)
    }
}
