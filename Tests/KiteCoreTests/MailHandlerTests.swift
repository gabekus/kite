import Foundation
import Testing
@testable import KiteCore

struct MailHandlerTests {
    private let gmail = URL(string: "https://mail.google.com/mail/u/0/#inbox")!

    @Test func registersAMailtoHandlerOnThePagesOrigin() {
        let handler = MailHandler.registration(scheme: "mailto", url: "/mail/?extsrc=mailto&url=%s", pageURL: gmail)
        #expect(handler?.template == "https://mail.google.com/mail/?extsrc=mailto&url=%s")
        #expect(handler?.host == "mail.google.com")
        #expect(MailHandler.registration(scheme: "MAILTO", url: "https://mail.google.com/x?u=%s", pageURL: gmail) != nil)
    }

    @Test func rejectsWhatHTMLRejects() {
        // Another origin, no %s, not http(s), another scheme, an insecure page.
        #expect(MailHandler.registration(scheme: "mailto", url: "https://evil.com/?u=%s", pageURL: gmail) == nil)
        #expect(MailHandler.registration(scheme: "mailto", url: "http://mail.google.com/?u=%s", pageURL: gmail) == nil)
        #expect(MailHandler.registration(scheme: "mailto", url: "https://mail.google.com/compose", pageURL: gmail) == nil)
        #expect(MailHandler.registration(scheme: "mailto", url: "javascript:%s", pageURL: gmail) == nil)
        #expect(MailHandler.registration(scheme: "webcal", url: "/cal?u=%s", pageURL: gmail) == nil)
        #expect(MailHandler.registration(scheme: "mailto", url: "/m?u=%s", pageURL: URL(string: "http://example.com/")!) == nil)
    }

    @Test func loopbackHTTPIsASecureContext() {
        let page = URL(string: "http://127.0.0.1:8123/inbox.html")!
        #expect(MailHandler.registration(scheme: "mailto", url: "compose.html?to=%s", pageURL: page)?.template
            == "http://127.0.0.1:8123/compose.html?to=%s")
        #expect(MailHandler.registration(scheme: "mailto", url: "http://127.0.0.1:9000/c?u=%s", pageURL: page) == nil)
    }

    @Test func translatesTheWholeLinkQueryEscaped() {
        let handler = MailHandler(template: "https://mail.google.com/mail/?extsrc=mailto&url=%s")
        let link = URL(string: "mailto:a@b.com?cc=c@d.com&bcc=e@f.com&subject=Hi%20there&body=Line%201%0ALine%202")!
        #expect(handler.translate(link)?.absoluteString == "https://mail.google.com/mail/?extsrc=mailto&url="
            + "mailto%3Aa%40b.com%3Fcc%3Dc%40d.com%26bcc%3De%40f.com%26subject%3DHi%2520there%26body%3DLine%25201%250ALine%25202")
        #expect(handler.translate(URL(string: "https://a.com")!) == nil)
    }

    @Test func onlyTheFirstPlaceholderIsReplaced() {
        let handler = MailHandler(template: "https://m.example/c?u=%s&v=%s")
        #expect(handler.translate(URL(string: "mailto:x@y.z")!)?.absoluteString == "https://m.example/c?u=mailto%3Ax%40y.z&v=%25s")
    }

    @Test func escapesLikeChromium() {
        #expect(MailHandler.escapeQueryParamValue("a b!'()*-._~/:?#&=+%é") == "a+b!'()*-._~%2F%3A%3F%23%26%3D%2B%25%C3%A9")
    }

    @Test func settingsAskOnceAndRememberRefusals() {
        let gmail = MailHandler(template: "https://mail.google.com/mail/?url=%s")
        let outlook = MailHandler(template: "https://outlook.live.com/mail/?url=%s")
        var settings = MailHandlerSettings()
        #expect(settings.asks(for: gmail))
        #expect(settings.destination(for: URL(string: "mailto:a@b.c")!) == nil)
        settings.allow(gmail)
        #expect(!settings.asks(for: gmail))
        #expect(settings.isDefault(host: "MAIL.google.com"))
        #expect(settings.destination(for: URL(string: "mailto:a@b.c")!)?.host == "mail.google.com")
        settings.block(outlook)
        #expect(!settings.asks(for: outlook))
        #expect(settings.handler == gmail)
        settings.allow(outlook)
        #expect(settings.handler == outlook && settings.blocked.isEmpty)
        settings.remove(host: "mail.google.com")
        #expect(settings.handler == outlook)
        settings.remove(host: "outlook.live.com")
        #expect(settings.handler == nil && settings.asks(for: outlook))
    }

    @Test func settingsRoundTripThroughJSON() throws {
        let settings = MailHandlerSettings(handler: MailHandler(template: "https://a.com/?u=%s"),
                                           blocked: [MailHandler(template: "https://b.com/?u=%s")])
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(MailHandlerSettings.self, from: data) == settings)
    }
}
