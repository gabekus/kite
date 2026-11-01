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

    @Test func matchLabelFollowsArc() {
        for ask in [true, false] {
            #expect(AskOnPage.matchLabel(query: "", found: false, matches: 0, activeMatch: nil, askEnabled: ask) == "")
            #expect(AskOnPage.matchLabel(query: "sky", found: true, matches: 3, activeMatch: 2, askEnabled: ask) == "2/3")
            #expect(AskOnPage.matchLabel(query: "sky", found: true, matches: nil, activeMatch: nil, askEnabled: ask) == "")
        }
        // Ask on Page on: the SwiftUI view's "No matches"; off: the AppKit view's "Not Found".
        #expect(AskOnPage.matchLabel(query: "sky", found: false, matches: 0, activeMatch: nil, askEnabled: true) == "No matches")
        #expect(AskOnPage.matchLabel(query: "sky", found: false, matches: 0, activeMatch: nil, askEnabled: false) == "Not Found")
        // WebKit only says found or not.
        #expect(AskOnPage.matchLabel(query: "sky", found: false, matches: nil, activeMatch: nil, askEnabled: true) == "No matches")
        #expect(AskOnPage.matchLabel(query: "sky", found: false, matches: nil, activeMatch: nil, askEnabled: false) == "Not Found")
    }

    @Test func findBarStylesFollowArc() {
        #expect(FindBarStyle(askEnabled: false) == .find)
        #expect(FindBarStyle.find.width == 300 && FindBarStyle.find.inset == 10 && FindBarStyle.find.cornerRadius == 5)
        #expect(FindBarStyle.ask.width == 400 && FindBarStyle.ask.inset == 20 && FindBarStyle.ask.cornerRadius == 10)
        #expect(FindBarStyle.find.slides == false && FindBarStyle.ask.slides)
        // The find bar's divider: 1pt, 7pt from top and bottom of the 32pt bar, 1.5pt left of the close button.
        #expect(FindBarStyle.dividerHeight(barHeight: 32) == 18)
        // The ask card's spring: Arc's (response 0.28 s, damping fraction 0.63) as CASpringAnimation terms.
        let spring = FindBarStyle.spring
        #expect(abs(spring.stiffness - 503.5) < 0.5)
        #expect(abs(spring.damping - 28.27) < 0.01)
        #expect(spring.mass == 1)
        #expect(FindBarStyle.askHiddenOffset(height: 44) == 104)
    }

    @Test func conversationsAreKeptPerTab() {
        var conversations = AskOnPage.Conversations<String>()
        let a = UUID(), b = UUID()
        conversations.keep("about a", for: a)
        conversations.keep("about b", for: b)
        #expect(conversations.take(for: a) == "about a")
        #expect(conversations.take(for: a) == nil)
        conversations.keep("about a", for: a)
        #expect(conversations.prune(keeping: [a]) == ["about b"])
        #expect(conversations.tabs == [a])
    }
}
