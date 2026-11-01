import Foundation
import Testing
@testable import KiteCore

@Suite struct VerificationCodesTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func message(_ subject: String, _ snippet: String = "", from name: String = "FedEx", _ email: String = "noreply@fedex.com", ago: TimeInterval = 60) -> VerificationCodes.Message {
        .init(subject: subject, snippet: snippet, senderName: name, senderEmail: email, date: now.addingTimeInterval(-ago))
    }

    @Test func findsCodes() {
        let cases: [(String, String?)] = [
            ("Your FedEx verification code is 482913", "482913"),
            ("482913 is your Instagram code", "482913"),
            ("Use code 482 913 to sign in", "482913"),
            ("Your one-time passcode: K7P2QX", "K7P2QX"),
            ("Sign-in code 4829. It expires in 10 minutes.", "4829"),
            ("Your order #48291344 has shipped", nil),
            ("Receipt for $482913", nil),
            ("Welcome to the 2026 conference", nil),
            ("Meeting at 10:30 about the launch", nil),
        ]
        for (text, expected) in cases {
            #expect(VerificationCodes.code(inText: text) == expected, "\(text)")
        }
    }

    @Test func readsTheSnippetWhenTheSubjectHasNoCode() {
        let m = message("Verify your identity", "Hi Gabe, enter 551204 on the FedEx site. This code is valid for 10 minutes.")
        #expect(VerificationCodes.code(in: m) == "551204")
    }

    @Test func prefersTheSitesOwnSenderAndSkipsStaleCodes() {
        let messages = [
            message("Your Slack code is 111111", from: "Slack", "no-reply@slack.com", ago: 30),
            message("Your verification code is 222222", from: "FedEx", "auth@notify.fedex.com", ago: 120),
            message("Your FedEx code is 333333", ago: 20 * 60),
        ]
        #expect(VerificationCodes.best(in: messages, forHost: "www.fedex.com", now: now)?.code == "222222")
        #expect(VerificationCodes.best(in: messages, forHost: "example.com", now: now)?.code == "111111")
        #expect(VerificationCodes.best(in: [messages[2]], forHost: "www.fedex.com", now: now) == nil)
    }

    @Test func namesSites() {
        #expect(VerificationCodes.siteName("www.fedex.com") == "fedex")
        #expect(VerificationCodes.siteName("mail.fedex.co.uk") == "fedex")
        #expect(VerificationCodes.siteName("fedex.com") == "fedex")
    }

    @Test func parsesGmailsFeed() {
        let feed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed version="0.3" xmlns="http://purl.org/atom/ns#">
        <title>Gmail - Inbox for someone@example.com</title><fullcount>1</fullcount>
        <entry>
        <title>Your FedEx verification code</title>
        <summary>Enter 551204 to verify your identity. This code is valid for 10 minutes.</summary>
        <link rel="alternate" href="https://mail.google.com/mail" type="text/html" />
        <modified>2027-01-15T08:00:00Z</modified>
        <issued>2027-01-15T08:00:00Z</issued>
        <id>tag:gmail.google.com,2004:1</id>
        <author><name>FedEx</name><email>auth@fedex.com</email></author>
        </entry>
        </feed>
        """
        let messages = VerificationCodes.parseGmailFeed(Data(feed.utf8))
        #expect(messages.count == 1)
        #expect(messages.first?.senderEmail == "auth@fedex.com")
        #expect(messages.first.flatMap(VerificationCodes.code(in:)) == "551204")
    }

    @Test func readsMessagesBodies() {
        // NSArchiver archives of NSAttributedString(string:), the format of chat.db's attributedBody.
        let short = "BAtzdHJlYW10eXBlZIHoA4QBQISEhBJOU0F0dHJpYnV0ZWRTdHJpbmcAhIQITlNPYmplY3QAhZKEhIQITlNTdHJpbmcBlIQBKyZTb2x2OiBZb3VyIHZlcmlmaWNhdGlvbiBjb2RlIGlzIDQ4MjkxM4aEAmlJASaShISEDE5TRGljdGlvbmFyeQCUhAFpAIaG"
        #expect(VerificationCodes.messagesText(attributedBody: Data(base64Encoded: short)!) == "Solv: Your verification code is 482913")
        // 300 characters: the length is 0x81 and two little-endian bytes.
        let long = Data(base64Encoded: "BAtzdHJlYW10eXBlZIHoA4QBQISEhBJOU0F0dHJpYnV0ZWRTdHJpbmcAhIQITlNPYmplY3QAhZKEhIQITlNTdHJpbmcBlIQBK4EsAQ==")!
            + Data(repeating: 0x61, count: 300) + Data([0x86, 0x84])
        #expect(VerificationCodes.messagesText(attributedBody: long) == String(repeating: "a", count: 300))
        #expect(VerificationCodes.messagesText(attributedBody: Data("nothing here".utf8)) == nil)
    }

    @Test func convertsMessagesDates() {
        #expect(VerificationCodes.messagesDate(VerificationCodes.messagesTimestamp(now)) == now)
        #expect(VerificationCodes.messagesDate(800_000_000) == Date(timeIntervalSinceReferenceDate: 800_000_000))
    }

    @Test func findsCodesInTexts() {
        let texts = [
            message("Solv: Your verification code is 482913. Do not share it.", from: "Messages", "", ago: 30),
            message("Your Slack code is 111111", from: "Messages", "", ago: 10),
        ]
        #expect(VerificationCodes.best(in: texts, forHost: "www.solvhealth.com", now: now)?.code == "111111")
        #expect(VerificationCodes.best(in: texts, forHost: "solv.com", now: now)?.code == "482913")
    }
}
