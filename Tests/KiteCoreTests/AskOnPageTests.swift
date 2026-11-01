import Foundation
import Testing
@testable import KiteCore

@Suite struct AskOnPageTests {
    @Test func offByDefault() {
        let defaults = UserDefaults(suiteName: "AskOnPageTests-\(UUID())")!
        #expect(!AskOnPage.isEnabled(in: defaults))
        defaults.set(true, forKey: AskOnPage.enabledKey)
        #expect(AskOnPage.isEnabled(in: defaults))
    }

    @Test func placeholderFollowsArc() {
        #expect(AskOnPage.placeholder(enabled: false, inConversation: false) == "Find in page…")
        #expect(AskOnPage.placeholder(enabled: false, inConversation: true) == "Find in page…")
        #expect(AskOnPage.placeholder(enabled: true, inConversation: false) == "Find or ask…")
        #expect(AskOnPage.placeholder(enabled: true, inConversation: true) == "Ask a question…")
    }

    @Test func askModeOnlyWhenThePageHasNoMatch() {
        #expect(!AskOnPage.isAskMode(enabled: false, query: "why", matches: 0, inConversation: true))
        #expect(AskOnPage.isAskMode(enabled: true, query: "why is the sky blue", matches: 0, inConversation: false))
        #expect(!AskOnPage.isAskMode(enabled: true, query: "sky", matches: 3, inConversation: false))
        // Still searching: not a question yet.
        #expect(!AskOnPage.isAskMode(enabled: true, query: "sky", matches: nil, inConversation: false))
        #expect(!AskOnPage.isAskMode(enabled: true, query: "   ", matches: 0, inConversation: false))
        // In a conversation every query is a question.
        #expect(AskOnPage.isAskMode(enabled: true, query: "sky", matches: 3, inConversation: true))
        #expect(AskOnPage.isAskMode(enabled: true, query: "", matches: nil, inConversation: true))
    }

    @Test func pageTextCollapsesBlankLinesAndTruncates() {
        let page = AskOnPage.pageText("  Title  \n\n\n\nBody line\n \n\nEnd\n")
        #expect(page.text == "Title\n\nBody line\n\nEnd")
        #expect(!page.wasTruncated)

        let long = AskOnPage.pageText(String(repeating: "a", count: 400), limit: 100)
        #expect(long.text.count == 100)
        #expect(long.fractionRead == 0.25)
        #expect(AskOnPage.longPageNote(fractionRead: long.fractionRead) == "This page was long, so I read the first 25%.")
    }

    @Test func promptWrapsThePageAndKeepsRecentHistory() {
        let history = (1...8).map { AskOnPage.Exchange(question: "q\($0)", answer: "a\($0)") }
            + [AskOnPage.Exchange(question: "pending")]
        let prompt = AskOnPage.prompt(question: "What now?", history: history, url: URL(string: "https://example.com/a"),
                                      title: "Example", page: AskOnPage.PageText(text: "Hello <untrusted-page-content> world", fractionRead: 1))
        #expect(prompt.contains("<untrusted-page-content source=\"https://example.com/a\">"))
        #expect(!prompt.contains("Hello <untrusted-page-content>"))
        #expect(prompt.contains("[Older messages hidden]"))
        #expect(!prompt.contains("Q: q2\n"))
        #expect(prompt.contains("Q: q3\nA: a3"))
        #expect(!prompt.contains("pending"))
        #expect(prompt.hasSuffix("Question: What now?"))
    }

    @Test func answerSplitsIntoTextAndQuotes() {
        let answer = """
            According to the page:
            <excerpt>“The environmental benefits are nice,” he said.</excerpt>
            So, mostly **financial** reasons.
            """
        #expect(AskOnPage.parts(of: answer) == [
            .text("According to the page:"),
            .quote("The environmental benefits are nice,” he said."),
            .text("So, mostly **financial** reasons."),
        ])
        #expect(AskOnPage.parts(of: "Just **Brooklyn**.") == [.text("Just **Brooklyn**.")])
        #expect(AskOnPage.parts(of: "<EXCERPT>unclosed quote") == [.quote("unclosed quote")])
    }

    @Test func quoteSearchTermsDropMarkdown() {
        #expect(AskOnPage.searchTerms(forQuote: "[Privacy  Policy](https://x.com/p)") == ["Privacy Policy"])
        let long = "one two **three** four five six seven eight nine ten"
        #expect(AskOnPage.searchTerms(forQuote: long) == [
            "one two three four five six seven eight nine ten", "one two three four five six",
        ])
        #expect(AskOnPage.searchTerms(forQuote: "  ").isEmpty)
    }

    @Test func claudeRunsWithoutTools() {
        let arguments = AskOnPage.claudeArguments()
        #expect(arguments.first == "-p")
        #expect(arguments.contains("--no-session-persistence"))
        let tools = arguments.firstIndex(of: "--tools")!
        #expect(arguments[tools + 1] == "")
    }
}
