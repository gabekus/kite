import Foundation
import Testing
@testable import KiteCore

@Suite struct OAuthResumeTests {
    private let tab = UUID()
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let query = "code=true&client_id=9d1c&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=user%3Ainference&code_challenge=abc123&code_challenge_method=S256&state=xyz"

    private var request: URL { URL(string: "https://claude.ai/oauth/authorize?\(query)")! }
    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test func recognizesAuthorizeRequests() {
        #expect(OAuthResume.isAuthorizeRequest(request))
        #expect(OAuthResume.isAuthorizeRequest(url("https://claude.com/cai/oauth/authorize?\(query)")))
        #expect(OAuthResume.isAuthorizeRequest(url("https://claude.ai/authorize/?client_id=a&redirect_uri=b&state=c")))
        // Only Claude's hosts: other sites' OAuth is never remembered.
        #expect(!OAuthResume.isAuthorizeRequest(url("https://idp.example/authorize/?client_id=a&redirect_uri=b&state=c")))
        #expect(!OAuthResume.isAuthorizeRequest(url("https://carbonarc.okta.com/oauth2/v1/authorize?client_id=a&redirect_uri=b&state=c")))
        #expect(!OAuthResume.isAuthorizeRequest(url("https://claude.ai/oauth/authorize")))
        #expect(!OAuthResume.isAuthorizeRequest(url("https://claude.ai/oauth/authorize?client_id=a&state=c")))
        #expect(!OAuthResume.isAuthorizeRequest(url("https://claude.ai/oauth/authorize?code_challenge=")))
        #expect(!OAuthResume.isAuthorizeRequest(url("https://example.com/authorized?code_challenge=x")))
    }

    @Test func recognizesSignInPages() {
        #expect(OAuthResume.isSignInPage(url("https://claude.ai/login?selectAccount=true")))
        #expect(OAuthResume.isSignInPage(url("https://accounts.google.com/v3/signin/identifier")))
        #expect(OAuthResume.isSignInPage(url("https://carbonarc.okta.com/app/x/sso/saml")))
        #expect(OAuthResume.isSignInPage(url("https://example.com/auth/magic-link?t=1")))
        #expect(!OAuthResume.isSignInPage(url("https://claude.ai/new")))
        #expect(!OAuthResume.isSignInPage(url("https://claude.ai/oauth/authorize")))
    }

    @Test func loadsTheRequestAgainWhenTheSignInDropsIt() {
        var resume = OAuthResume()
        #expect(resume.observe(request, tab: tab, now: start) == nil)
        #expect(resume.observe(url("https://claude.ai/login?selectAccount=true&from=logout"), tab: tab, now: start + 2) == nil)
        #expect(resume.observe(url("https://accounts.google.com/v3/signin/identifier?continue=x"), tab: tab, now: start + 5) == nil)
        #expect(resume.observe(url("https://claude.ai/oauth/authorize?code=true"), tab: tab, now: start + 30) == request)
        // Once: the reload of the same request isn't armed again, and a second drop is left alone.
        #expect(resume.observe(request, tab: tab, now: start + 31) == nil)
        #expect(resume.observe(url("https://claude.ai/login"), tab: tab, now: start + 32) == nil)
        #expect(resume.observe(url("https://claude.ai/oauth/authorize"), tab: tab, now: start + 40) == nil)
    }

    @Test func remembersTheRequestFromTheLoginPagesReturnTo() {
        var resume = OAuthResume()
        // The authorize page never reported (a server redirect straight to the login page).
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let login = url("https://claude.ai/login?selectAccount=true&from=logout&returnTo=%2Foauth%2Fauthorize%3F\(encoded)")
        #expect(resume.observe(login, tab: tab, now: start) == nil)
        #expect(resume.observe(url("https://claude.ai/oauth/authorize"), tab: tab, now: start + 20) == request)

        // returnTo left unencoded swallows the rest of the query.
        var plain = OAuthResume()
        let other = UUID()
        #expect(plain.observe(url("https://claude.ai/login?from=logout&returnTo=/oauth/authorize?\(query)"), tab: other, now: start) == nil)
        #expect(plain.observe(url("https://claude.ai/oauth/authorize?code=true"), tab: other, now: start + 20)?.query()?.contains("code_challenge=abc123") == true)

        // Unencoded with code_challenge first: the part cut short at its first `&` looks like a request too,
        // but the whole one wins, state and all.
        var challengeFirst = OAuthResume()
        let full = "code_challenge=abc123&client_id=9d1c&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&state=xyz"
        #expect(challengeFirst.observe(url("https://claude.ai/login?returnTo=/oauth/authorize?\(full)"), tab: other, now: start) == nil)
        let resumed = challengeFirst.observe(url("https://claude.ai/oauth/authorize"), tab: other, now: start + 20)
        #expect(resumed.map(OAuthResume.query)?["state"] == "xyz")
        #expect(resumed.map(OAuthResume.query)?["client_id"] == "9d1c")

        // A returnTo on another host is ignored.
        var foreign = OAuthResume()
        #expect(foreign.observe(url("https://claude.ai/login?returnTo=https%3A%2F%2Fevil.example%2Foauth%2Fauthorize%3F\(encoded)"), tab: tab, now: start) == nil)
        #expect(foreign.observe(url("https://evil.example/oauth/authorize"), tab: tab, now: start + 5) == nil)
    }

    @Test func leavesEverythingElseAlone() {
        // No sign-in page in between: a plain reload without the parameters isn't resumed.
        var noSignIn = OAuthResume()
        _ = noSignIn.observe(request, tab: tab, now: start)
        #expect(noSignIn.observe(url("https://claude.ai/oauth/authorize"), tab: tab, now: start + 5) == nil)

        // Back with the parameters: nothing to do.
        var kept = OAuthResume()
        _ = kept.observe(request, tab: tab, now: start)
        _ = kept.observe(url("https://claude.ai/login"), tab: tab, now: start + 1)
        #expect(kept.observe(request, tab: tab, now: start + 10) == nil)

        // Another tab, or another path.
        var other = OAuthResume()
        _ = other.observe(request, tab: tab, now: start)
        _ = other.observe(url("https://claude.ai/login"), tab: tab, now: start + 1)
        #expect(other.observe(url("https://claude.ai/oauth/authorize"), tab: UUID(), now: start + 5) == nil)
        #expect(other.observe(url("https://claude.ai/new"), tab: tab, now: start + 6) == nil)

        // Too late: after 10 minutes the request is forgotten.
        var late = OAuthResume()
        _ = late.observe(request, tab: tab, now: start)
        _ = late.observe(url("https://claude.ai/login"), tab: tab, now: start + 1)
        #expect(late.observe(url("https://claude.ai/oauth/authorize"), tab: tab, now: start + OAuthResume.window + 1) == nil)

        // The request reached its redirect URI: done, forgotten.
        var done = OAuthResume()
        _ = done.observe(request, tab: tab, now: start)
        _ = done.observe(url("https://claude.ai/login"), tab: tab, now: start + 1)
        _ = done.observe(url("https://platform.claude.com/oauth/code/callback?code=c&state=xyz"), tab: tab, now: start + 2)
        #expect(done.observe(url("https://claude.ai/oauth/authorize"), tab: tab, now: start + 3) == nil)

        // Forgotten when the tab closes.
        var closed = OAuthResume()
        _ = closed.observe(request, tab: tab, now: start)
        _ = closed.observe(url("https://claude.ai/login"), tab: tab, now: start + 1)
        closed.forget(tab: tab)
        #expect(closed.observe(url("https://claude.ai/oauth/authorize"), tab: tab, now: start + 2) == nil)
    }

    @Test func aClientIdentityRequestIsResumedWhenItsStateGoesMissing() {
        var resume = OAuthResume()
        let plain = url("https://claude.ai/oauth/authorize?client_id=a&redirect_uri=https%3A%2F%2Fapp.example%2Fcb&state=s")
        _ = resume.observe(plain, tab: tab, now: start)
        _ = resume.observe(url("https://claude.ai/signin"), tab: tab, now: start + 1)
        #expect(resume.observe(url("https://claude.ai/oauth/authorize?client_id=a&redirect_uri=x"), tab: tab, now: start + 2) == plain)
    }

    @Test func anotherSitesOAuthIsNeverReplayed() {
        var resume = OAuthResume()
        let okta = url("https://carbonarc.okta.com/oauth2/v1/authorize?client_id=a&redirect_uri=https%3A%2F%2Fapp.example%2Fcb&state=s")
        #expect(resume.observe(okta, tab: tab, now: start) == nil)
        #expect(resume.observe(url("https://carbonarc.okta.com/oauth2/v1/login"), tab: tab, now: start + 1) == nil)
        #expect(resume.observe(url("https://carbonarc.okta.com/oauth2/v1/authorize?client_id=a"), tab: tab, now: start + 2) == nil)
    }
}
