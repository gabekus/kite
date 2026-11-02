import Testing
@testable import KiteCore

@Suite struct SearchSuggestionsLingerTests {
    @Test func lastAnswerStaysWhileTyping() {
        let previous = ["weather today", "weather tomorrow", "weather radar"]
        #expect(SearchSuggestions.lingering(previous, for: "weath") == previous)
        #expect(SearchSuggestions.lingering(previous, for: "something else") == previous)
    }

    @Test func dropsTheRowThatIsNowTyped() {
        let previous = ["weather today", "weather radar"]
        #expect(SearchSuggestions.lingering(previous, for: " Weather Radar ") == ["weather today"])
    }

    @Test func emptyFieldShowsNothing() {
        #expect(SearchSuggestions.lingering(["a"], for: "  ").isEmpty)
    }
}
