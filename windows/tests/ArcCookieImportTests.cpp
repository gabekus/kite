// Import from Arc's sign-ins, the rules half (W33b): core/ArcCookieImport.h. Ports
// KiteCoreTests' ArcCookieImportTests.swift case for case, with its test doubles. Every row is
// made up in memory; no real cookies, and the transform double is a plain reverse, not any real
// algorithm. Then what Kite for Windows adds: the reason each row stays behind (v20 among them),
// CEF's values, and the counts.

#include <algorithm>
#include <string>

#include "Check.h"
#include "core/ArcCookieImport.h"

using namespace kite;
using namespace kite::arc_import;

namespace {

// 1_800_000_000 Unix seconds, as the Mac's `now`, in Foundation's seconds.
const Timestamp kNow = FromUnixTime(1'800'000'000);
const int64_t kLater = ChromeTime(kNow) + 1'000'000;

CookieRow Row(const std::string& host = ".example.com", const std::string& value = "", const std::string& stored = "",
              int64_t expires = kLater, bool secure = true) {
    CookieRow row;
    row.host = host;
    row.name = "sid";
    row.value = value;
    row.encryptedValue = stored;
    row.path = "/";
    row.expiresUTC = expires;
    row.isSecure = secure;
    row.isHTTPOnly = true;
    row.sameSite = 1;
    row.priority = 1;
    return row;
}

// The Mac test's doubles: the stored bytes are the plaintext reversed, and the host "hash" is 32
// bytes made from the host. Not real transforms; the rules under test don't care which transform.
std::optional<std::string> Reversed(std::string_view data) { return std::string(data.rbegin(), data.rend()); }
std::optional<std::string> Fails(std::string_view) { return std::nullopt; }
std::string Tag(std::string_view host) { return (std::string(host) + std::string(32, '#')).substr(0, 32); }
std::string Stored(const std::string& plain) { return "v10" + std::string(plain.rbegin(), plain.rend()); }

std::optional<ArcCookie> Cookie(const CookieRow& row, int version, CookieDecrypt open = Reversed) {
    return CookieFrom(row, version, kNow, open, Tag);
}

}  // namespace

TEST(ArcCookieDecryptsAndDropsTheHostHashFromVersion24) {
    auto cookie = Cookie(Row(".example.com", "", Stored(Tag(".example.com") + "abc")), 24);
    CHECK(cookie && cookie->value == "abc");
    // Another host's tag: a wrong key or a tampered row.
    CHECK(!Cookie(Row(".example.com", "", Stored(Tag("other.com") + "abc")), 24));
    // Before version 24 there is no leading tag.
    CHECK(Cookie(Row(".example.com", "", Stored("abc")), 23) && Cookie(Row(".example.com", "", Stored("abc")), 23)->value == "abc");
    // Too short for the tag: not a cookie Kite can trust.
    CHECK(!Cookie(Row(".example.com", "", Stored("abc")), 24));
}

TEST(ArcCookieLeavesOutWhatItCantUse) {
    // Expired.
    CHECK(!Cookie(Row(".example.com", "x", "", 1), 24));
    // A scheme Kite doesn't read, a failed open, or not text.
    CHECK(!Cookie(Row(".example.com", "", "v11abc"), 24));
    CHECK(!Cookie(Row(".example.com", "", Stored("abc")), 23, Fails));
    CHECK(!Cookie(Row(".example.com", "", Stored(std::string{'\xFF', '\xFE'})), 23));
    // A session cookie and a plain value come over as they are.
    CHECK(Cookie(Row(".example.com", "plain", "", 0), 24) && Cookie(Row(".example.com", "plain", "", 0), 24)->value == "plain");
}

TEST(ArcCookiePartitionedCookiesStayBehind) {
    CookieRow row = Row(".example.com", "x");
    row.topFrameSiteKey = "https://a.com";
    CHECK(!Cookie(row, 24));
}

// v20 (Chromium 127+ app-bound encryption) is a thing of its own, not a failed read: Kite can't
// open it and says so by its reason.
TEST(ArcCookieAppBoundStaysBehindAsItsOwnReason) {
    auto result = ClassifyCookie(Row(".example.com", "", "v20somebytes"), 24, kNow, Reversed, Tag);
    CHECK(std::holds_alternative<CookieSkip>(result) && std::get<CookieSkip>(result) == CookieSkip::AppBound);
    auto other = ClassifyCookie(Row(".example.com", "", "v11somebytes"), 24, kNow, Reversed, Tag);
    CHECK(std::holds_alternative<CookieSkip>(other) && std::get<CookieSkip>(other) == CookieSkip::OtherScheme);
}

TEST(ArcCookieSetForTheSchemeAndPortThatSetIt) {
    // Not Secure, but set by an https page.
    CookieRow row = Row("app.example.com", "", "", kLater, false);
    row.sourceScheme = 2;
    row.sourcePort = 443;
    CHECK((ArcCookie{row, "v"}.Url()) == "https://app.example.com/");
    row.sourceScheme = 1;
    row.sourcePort = 8080;
    CHECK((ArcCookie{row, "v"}.Url()) == "http://app.example.com:8080/");
}

TEST(ArcCookieUrlAndDomain) {
    const ArcCookie domain{Row(".example.com"), "v"};
    CHECK(domain.Url() == "https://example.com/");
    CHECK(domain.Domain() == ".example.com");
    CookieRow plain = Row("app.example.com", "", "", kLater, false);
    plain.sourceScheme = 1;
    const ArcCookie host{plain, "v"};
    CHECK(host.Url() == "http://app.example.com/");
    CHECK(!host.Domain());
}

TEST(ArcCookieChromeTimeIsFrom1601) {
    CHECK(ChromeTime(FromUnixTime(0)) == 11'644'473'600'000'000);
}

// Kite for Windows adds: Chromium's stored same-site -1…2 to CEF's 0…3, priority 0…2 to -1…1,
// and the session flag (expires 0).
TEST(ArcCookieToSetMapsSameSiteAndPriority) {
    CookieRow row = Row(".example.com", "v", "", 0);
    row.sameSite = -1;
    row.priority = 0;
    auto none = ToSet(ArcCookie{row, "v"});
    CHECK(none && none->sameSite == 0 && none->priority == -1 && none->expires == 0 && none->domain == ".example.com");
    row.sameSite = 2;  // strict
    row.priority = 2;  // high
    auto strict = ToSet(ArcCookie{row, "v"});
    CHECK(strict && strict->sameSite == 3 && strict->priority == 1);
    // A value out of Chromium's range is CEF's unspecified and medium, not a shift out of range.
    row.sameSite = 7;
    row.priority = 9;
    auto odd = ToSet(ArcCookie{row, "v"});
    CHECK(odd && odd->sameSite == 0 && odd->priority == 0);
}

// A host no URL can hold has nothing to set it for.
TEST(ArcCookieToSetNoneForAHostNoUrlCanHold) {
    CHECK(!(ArcCookie{Row("has space"), "v"}.Url()));
    CHECK(!ToSet(ArcCookie{Row(""), "v"}));
    // An IPv6 host keeps its brackets.
    CHECK((ArcCookie{Row("[::1]", "v", "", kLater, true), "v"}.Url()) == "https://[::1]/");
}

// DecideCookies counts every row once, by reason, and keeps only the cookies with a URL.
TEST(ArcCookieDecideCountsEveryRowOnce) {
    CookieTable table;
    table.version = 24;
    table.rows.push_back(Row(".example.com", "", Stored(Tag(".example.com") + "keep")));  // kept
    table.rows.push_back(Row(".example.com", "x", "", 1));                                // expired
    table.rows.push_back(Row(".example.com", "", "v20bytes"));                            // app-bound
    table.rows.push_back(Row(".example.com", "", "v11bytes"));                            // other scheme
    table.rows.push_back(Row(".example.com", "", Stored(Tag("wrong.com") + "no")));       // not opened (tag)
    CookieRow partitioned = Row(".example.com", "y");
    partitioned.topFrameSiteKey = "https://a.com";
    table.rows.push_back(partitioned);                                                    // partitioned
    table.tooLong = 2;
    CookieRead read = DecideCookies(table, kNow, Reversed, Tag);
    CHECK(read.cookies.size() == 1);
    CHECK(read.rows == 8);  // 6 rows + 2 tooLong
    CHECK(read.expired == 1 && read.appBound == 1 && read.otherScheme == 1 && read.notDecrypted == 1 && read.partitioned == 1);
    CHECK(read.tooLong == 2);
}

// TallyCookies classifies rows by encryption prefix without opening any.
TEST(ArcCookieTallyByPrefix) {
    CookieTable table;
    table.version = 24;
    table.rows.push_back(Row(".a.com", "", "v10bytes"));
    table.rows.push_back(Row(".b.com", "", "v20bytes"));
    table.rows.push_back(Row(".c.com", "plain", ""));       // plain value
    table.rows.push_back(Row(".d.com", "", "v99bytes"));    // other
    table.rows.push_back(Row(".e.com", "", "v10bytes", 0)); // session
    table.rows.push_back(Row(".f.com", "", "v10bytes", 1)); // expired
    CookieTally t = TallyCookies(table, kNow);
    CHECK(t.rows == 6 && t.v10 == 3 && t.v20 == 1 && t.plain == 1 && t.other == 1);
    CHECK(t.session == 1 && t.expired == 1);
}
