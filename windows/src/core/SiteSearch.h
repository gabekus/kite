#pragma once
// Arc's Site Search: type a site's shortcut in the command bar, press Tab, and the query goes
// to that site's search page. Ports the model of KiteCore's SiteSearch.swift that Import from
// Arc needs: the entry and its JSON, Arc's defaults, seeding them and merging imported ones.
// The command bar doesn't use them on Windows yet.
//
// They live in session.json as the Mac keeps them, in BrowserState::extra: "siteSearches" and
// "siteSearchDefaultsSeeded".

#include <optional>
#include <string>
#include <vector>

#include "core/Json.h"
#include "core/Models.h"

namespace kite {

struct SiteSearch {
    std::string id;           // a UUID
    std::string name;         // "Search YouTube" shows it
    std::string shortcut;     // what's typed before Tab
    std::string urlTemplate;  // %s where the query goes
    std::optional<std::string> color;  // the chip's colour, "RRGGBB"
    bool isActive = true;      // Chromium's is_active: an inactive one stays saved

    // From a Chromium search engine (Arc's Site Search settings): Chromium writes the query as
    // {searchTerms}; other {…} parameters need Chromium's own substitution, so those are skipped.
    static std::optional<SiteSearch> FromChromium(const std::string& name, const std::string& keyword, const std::string& url);
    // Arc 1.169's default Site Searches, in Arc's order (SiteSearch.arcDefaults), each with a new id.
    static std::vector<SiteSearch> ArcDefaults();

    json::Value ToJson() const;
    static std::optional<SiteSearch> FromJson(const json::Value& value);
    bool operator==(const SiteSearch&) const = default;
};

// The session's Site Searches; none when there are none or they don't read (`readable` false then).
std::vector<SiteSearch> SiteSearches(const BrowserState& state, bool* readable = nullptr);
void SetSiteSearches(BrowserState& state, const std::vector<SiteSearch>& sites);
// Adds Arc's defaults that aren't there yet, as the Mac does when it reads any session.
void SeedDefaultSiteSearches(BrowserState& state);
// Adds imported shortcuts after seeding the defaults; one with the same shortcut (ignoring
// case) replaces the entry, keeping its id. False when the session's own entries don't read
// (they're left as they are).
bool MergeSiteSearches(BrowserState& state, const std::vector<SiteSearch>& imported);

}  // namespace kite
