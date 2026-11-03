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
