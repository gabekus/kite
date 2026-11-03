#pragma once
// What was typed into the command bar → a URL to load. Port of KiteCore's URLInput.swift;
// its Swift tests are ported case for case in tests/URLInputTests.cpp.

#include <optional>
#include <string>
#include <string_view>

namespace kite {

enum class SearchEngine { Google, DuckDuckGo, Kagi, Bing };

// "google", "duckDuckGo", "kagi", "bing": the Mac's raw values in session.json.
std::optional<SearchEngine> SearchEngineFromRaw(std::string_view raw);
std::string SearchURL(SearchEngine engine, std::string_view query);
// "Google", "DuckDuckGo", "Kagi", "Bing" (SearchEngine.displayName).
const char* DisplayName(SearchEngine engine);

namespace url_input {

// A URL, or a search URL for anything that isn't one; nullopt for blank input.
std::optional<std::string> Resolve(std::string_view input, SearchEngine engine);
// What was typed as a URL, or nullopt when it would be a search.
std::optional<std::string> AsURL(std::string_view input);
bool LooksLikeURL(std::string_view input);

}  // namespace url_input
}  // namespace kite
