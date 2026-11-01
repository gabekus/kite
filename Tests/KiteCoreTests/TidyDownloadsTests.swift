import Foundation
import Testing
@testable import KiteCore

@Suite struct TidyDownloadsTests {
    @Test func settingDefaultsOnLikeGabesArc() throws {
        let suite = "TidyDownloadsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(TidyDownloads.isEnabled(in: defaults))
        defaults.set(false, forKey: TidyDownloads.enabledKey)
        #expect(!TidyDownloads.isEnabled(in: defaults))
    }

    @Test func keepsTheOriginalExtensionExactly() {
        #expect(TidyDownloads.tidiedName("Line LA Folio, Aug 14.pdf", original: "folio_6691488.PDF") == "Line LA Folio, Aug 14.PDF")
        #expect(TidyDownloads.tidiedName("Trip photo", original: "IMG_1234.jpg") == "Trip photo.jpg")
        #expect(TidyDownloads.tidiedName("Trip photo.jpeg", original: "IMG_1234.jpg") == "Trip photo.jpg")
        #expect(TidyDownloads.tidiedName("Kite 1.6.0", original: "kite-1.6.0.dmg") == "Kite 1.6.0.dmg")
        #expect(TidyDownloads.tidiedName("Source code.zip", original: "repo-main.tar.gz") == "Source code.tar.gz")
        #expect(TidyDownloads.tidiedName("Source code.tar.gz", original: "repo-main.tar.gz") == "Source code.tar.gz")
        #expect(TidyDownloads.tidiedName("Notes.txt", original: "README") == "Notes.txt")
    }

    @Test func staysOneVisibleFileName() {
        #expect(TidyDownloads.tidiedName("../../etc/passwd", original: "a.txt") == "-..-etc-passwd.txt")
        #expect(TidyDownloads.tidiedName("Report: Q3/Q4\nfinal", original: "r.pdf") == "Report- Q3-Q4 final.pdf")
        #expect(TidyDownloads.tidiedName(".hidden", original: "a.txt") == "hidden.txt")
        #expect(TidyDownloads.tidiedName("   ", original: "a.txt") == nil)
        #expect(TidyDownloads.tidiedName(".pdf", original: "a.pdf") == nil)
        #expect(TidyDownloads.tidiedName("Same.pdf", original: "Same.pdf") == nil)
        let long = String(repeating: "word ", count: 60)
        let name = TidyDownloads.tidiedName(long, original: "a.pdf")!
        #expect(name.hasSuffix("word.pdf"))
        #expect(name.count <= TidyDownloads.maxBaseLength + 4)
    }

    @Test func neverTakesATakenName() {
        let taken: Set<String> = ["Report.pdf", "Report 2.pdf", "Archive.tar.gz"]
        #expect(TidyDownloads.available("Notes.pdf") { taken.contains($0) } == "Notes.pdf")
        #expect(TidyDownloads.available("Report.pdf") { taken.contains($0) } == "Report 3.pdf")
        #expect(TidyDownloads.available("Archive.tar.gz") { taken.contains($0) } == "Archive 2.tar.gz")
    }

    @Test func readsClaudeCodesJSONResult() {
        let structured = #"{"type":"result","is_error":false,"result":"{\"newName\":\"A.pdf\"}","structured_output":{"newName":"B.pdf"}}"#
        #expect(TidyDownloads.name(fromClaudeOutput: structured) == "B.pdf")
        let plain = #"{"type":"result","is_error":false,"result":"Sure: {\"newName\": \"A.pdf\"}"}"#
        #expect(TidyDownloads.name(fromClaudeOutput: plain) == "A.pdf")
        let error = #"{"type":"result","is_error":true,"result":"Not logged in"}"#
        #expect(TidyDownloads.name(fromClaudeOutput: error) == nil)
        #expect(TidyDownloads.name(fromClaudeOutput: "garbage") == nil)
    }

    @Test func promptCarriesArcsThreeInputsAndLanguage() {
        let prompt = TidyDownloads.prompt(fileName: "image0.png", tabTitle: "Nate - Slack", domain: "files.slack.com", language: "French")
        #expect(prompt.contains("Original filename: 'image0.png'"))
        #expect(prompt.contains("Source tab title: 'Nate - Slack'"))
        #expect(prompt.contains("Source domain: 'files.slack.com'"))
        #expect(prompt.contains("in French"))
        #expect(TidyDownloads.languageName(preferred: ["fr-CA"]) == "French")
        #expect(TidyDownloads.languageName(preferred: []) == "English")
    }

    @Test func claudeRunsWithoutToolsOrMCP() {
        let arguments = TidyDownloads.arguments()
        #expect(arguments.first == "-p")
        #expect(arguments.contains("--strict-mcp-config"))
        let tools = arguments.firstIndex(of: "--tools")!
        #expect(arguments[tools + 1] == "")
    }
}
