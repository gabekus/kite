// KiteCoreTests.swift URLInputTests, case for case.

#include "Check.h"
#include "core/URLInput.h"
#include "core/Url.h"

using namespace kite;

TEST(resolvesURLs) {
    const std::pair<const char*, const char*> cases[] = {
        {"apple.com", "https://apple.com"},
        {"news.ycombinator.com/item?id=1", "https://news.ycombinator.com/item?id=1"},
        {"localhost:3000", "http://localhost:3000"},
        {"192.168.1.10:8080/admin", "http://192.168.1.10:8080/admin"},
        {"https://example.org/a b", "https://example.org/a%20b"},
        {"about:blank", "about:blank"},
    };
    for (const auto& [input, expected] : cases) {
        CHECK(url_input::Resolve(input, SearchEngine::Google) == std::optional<std::string>(expected));
        CHECK(url_input::LooksLikeURL(input));
    }
}

TEST(searchesEverythingElse) {
    for (const char* input : {"swift concurrency", "what is 2+2", "kite", "file.txt please", "a.b"}) {
        auto resolved = url_input::Resolve(input, SearchEngine::DuckDuckGo);
        CHECK(resolved && url::Host(*resolved) == std::optional<std::string>("duckduckgo.com"));
        CHECK(!url_input::LooksLikeURL(input));
    }
}

TEST(encodesQueryCharacters) {
    CHECK(SearchURL(SearchEngine::Google, "c++ & rust?") == "https://www.google.com/search?q=c%2B%2B%20%26%20rust%3F");
}

TEST(emptyInputResolvesToNothing) { CHECK(!url_input::Resolve("   ", SearchEngine::Google)); }

TEST(searchEngineRawValuesMatchTheMac) {
    CHECK(SearchEngineFromRaw("duckDuckGo") == SearchEngine::DuckDuckGo);
    CHECK(!SearchEngineFromRaw("DuckDuckGo"));
}

TEST(hostParsing) {
    CHECK(url::Host("https://user@Example.com:8080/x") == std::optional<std::string>("Example.com"));
    CHECK(url::Host("http://[::1]:3000/") == std::optional<std::string>("::1"));
    CHECK(!url::Host("about:blank"));
    CHECK(url::Scheme("HTTPS://x") == std::optional<std::string>("https"));
}

// Not in the Mac suite: Unicode text, where Swift works on characters, not bytes.
TEST(trimsAndSplitsOnUnicodeWhitespace) {
    CHECK(url_input::Resolve("example.com\xC2\xA0", SearchEngine::Google) == std::optional<std::string>("https://example.com"));  // NBSP
    CHECK(!url_input::LooksLikeURL("foo\xC2\xA0" "bar.com"));
    CHECK(!url_input::LooksLikeURL("yahoo.co.jp\xE3\x80\x80\xE5\xA4\xA9\xE6\xB0\x97"));  // ideographic space (IME)
    CHECK(!url_input::Resolve("\xE3\x80\x80 ", SearchEngine::Google));
}

TEST(classifiesUnicodeLettersLikeSwift) {
    CHECK(url_input::LooksLikeURL("m\xC3\xBCnchen.de"));             // ü is a letter
    CHECK(url_input::LooksLikeURL("example.\xD1\x80\xD1\x84"));      // .рф
    CHECK(!url_input::LooksLikeURL("e.g\xE2\x80\xA6"));              // … is punctuation
    CHECK(!url_input::LooksLikeURL("a.b\xE2\x86\x92"));              // → is a symbol
    CHECK(!url_input::LooksLikeURL("x.\xC3\xA9"));                   // a one-character TLD
    CHECK(!url_input::LooksLikeURL("x.e\xCC\x81"));                  // e + combining acute: still one character
    CHECK(url_input::LooksLikeURL("caf\x65\xCC\x81.fr"));            // a combining mark inside a label
    CHECK(url_input::LooksLikeURL("example.xn--p1ai"));
}

TEST(hostEdgeCasesFollowSwift) {
    CHECK(url_input::Resolve(".localhost", SearchEngine::Google) == std::optional<std::string>("http://.localhost"));
    CHECK(url_input::Resolve("010.0.0.1", SearchEngine::Google) == std::optional<std::string>("http://010.0.0.1"));
    CHECK(!url_input::LooksLikeURL("256.0.0.1"));
    CHECK(!url_input::LooksLikeURL("localhost:"));
    CHECK(!url_input::LooksLikeURL("localhost:80:80"));
}
