// Port of KiteCore SiteSearch.swift (the model, arcDefaults, seedDefaultSiteSearches,
// mergeSiteSearches); see SiteSearch.h.

#include "core/SiteSearch.h"

#include <algorithm>

#include "core/ArcImport.h"
#include "core/Unicode.h"
#include "core/Url.h"
#include "core/Uuid.h"

namespace kite {

namespace {

// BrowserState.siteSearchDefaultsVersion: 2 added the defaults' chip colours.
constexpr int kDefaultsVersion = 2;

std::string Replace(std::string text, std::string_view from, std::string_view to) {
    for (size_t at = text.find(from); at != std::string::npos; at = text.find(from, at + to.size())) text.replace(at, from.size(), to);
    return text;
}

}  // namespace

std::optional<SiteSearch> SiteSearch::FromChromium(const std::string& name, const std::string& keyword, const std::string& url) {
    const std::string urlTemplate = Replace(url, "{searchTerms}", "%s");
    if (keyword.empty() || urlTemplate.find("%s") == std::string::npos || urlTemplate.find('{') != std::string::npos) return std::nullopt;
    const std::string sample = Replace(urlTemplate, "%s", "q");
    auto scheme = url::Scheme(sample);
    if (!arc_import::IsURL(sample) || (scheme != "https" && scheme != "http")) return std::nullopt;
    return SiteSearch{NewUuid(), name, keyword, urlTemplate, std::nullopt, true};
}

std::vector<SiteSearch> SiteSearch::ArcDefaults() {
    struct Default {
        const char *name, *shortcut, *url, *color;
    };
    static constexpr Default kDefaults[] = {
        {"Google Drive", "drive.google.com", "https://drive.google.com/drive/search?q=%s", "0F9D58"},
        {"Gmail", "mail.google.com", "https://mail.google.com/mail/ca/u/0/#apps/%s", "D44638"},
        {"Google Maps", "maps.google.com", "https://www.google.com/maps/search/%s", "FBBC05"},
        {"Google Calendar", "calendar.google.com", "https://calendar.google.com/calendar/u/0/r/search?q=%s", "9C27B0"},
        {"Google Docs", "docs.google.com", "https://docs.google.com/document/u/0/?q=%s", "4285F4"},
        {"Dropbox", "dropbox.com", "https://www.dropbox.com/search/personal?&query=%s", "007EE5"},
        {"Amazon", "amazon.com", "https://www.amazon.com/s?k=%s", "FF9900"},
        {"GitHub", "github.com", "https://github.com/search?q=%s", "743FC7"},
        {"Figma", "figma.com", "https://www.figma.com/files/search?q=%s", "F24E1E"},
        {"X", "x.com", "https://x.com/search?q=%s", "000000"},
        {"X", "twitter.com", "https://twitter.com/search?q=%s", "000000"},
        {"YouTube", "youtube.com", "https://www.youtube.com/results?search_query=%s", "FF0000"},
        {"Wikipedia", "wikipedia.org", "https://wikipedia.org/w/index.php?search=%s", "FF4500"},
        {"Reddit", "reddit.com", "https://www.reddit.com/search/?q=%s", "FF4500"},
        {"SoundCloud", "soundcloud.com", "https://soundcloud.com/search?q=%s", "F85216"},
        {"Asana", "asana.com", "https://app.asana.com/0/search?q=%s", "F06A6A"},
        {"LinkedIn", "linkedin.com", "https://linkedin.com/search/results/all/?keywords=%s", "0B66C2"},
        {"Apple Music", "music.apple.com", "https://music.apple.com/us/search?term=%s", "FA2A44"},
        {"Spotify", "spotify.com", "https://open.spotify.com/search/%s", "1DB954"},
    };
    std::vector<SiteSearch> out;
    for (const Default& d : kDefaults) out.push_back({NewUuid(), d.name, d.shortcut, d.url, std::string(d.color), true});
    return out;
}

json::Value SiteSearch::ToJson() const {
    json::Object o{{"id", id}, {"name", name}, {"shortcut", shortcut}, {"urlTemplate", urlTemplate}};
    if (color) o.emplace("color", *color);
    if (!isActive) o.emplace("isActive", false);
    return json::Value(std::move(o));
}

std::optional<SiteSearch> SiteSearch::FromJson(const json::Value& v) {
    const json::Value* id = v.Find("id");
    const json::Value* name = v.Find("name");
    const json::Value* shortcut = v.Find("shortcut");
    const json::Value* urlTemplate = v.Find("urlTemplate");
    if (!id || !id->AsString() || !name || !name->AsString() || !shortcut || !shortcut->AsString() || !urlTemplate ||
        !urlTemplate->AsString()) {
        return std::nullopt;
    }
    auto uuid = NormalizeUuid(*id->AsString());
    if (!uuid) return std::nullopt;
    SiteSearch site{*uuid, *name->AsString(), *shortcut->AsString(), *urlTemplate->AsString(), std::nullopt, true};
    if (const json::Value* color = v.Find("color"); color && !color->IsNull()) {
        if (!color->AsString()) return std::nullopt;
        site.color = *color->AsString();
    }
    if (const json::Value* active = v.Find("isActive"); active && !active->IsNull()) {
        if (!active->AsBool()) return std::nullopt;
        site.isActive = *active->AsBool();
    }
    return site;
}

std::vector<SiteSearch> SiteSearches(const BrowserState& state, bool* readable) {
    if (readable) *readable = true;
    std::vector<SiteSearch> out;
    auto it = state.extra.find("siteSearches");
    if (it == state.extra.end() || it->second.IsNull()) return out;
    const json::Array* list = it->second.AsArray();
    if (!list) {
        if (readable) *readable = false;
        return {};
    }
    for (const json::Value& value : *list) {
        auto site = SiteSearch::FromJson(value);
        if (!site) {
            if (readable) *readable = false;
            return {};
        }
        out.push_back(std::move(*site));
    }
    return out;
}

void SetSiteSearches(BrowserState& state, const std::vector<SiteSearch>& sites) {
    json::Array array;
    for (const SiteSearch& site : sites) array.push_back(site.ToJson());
    state.extra.insert_or_assign("siteSearches", json::Value(std::move(array)));
}

namespace {

int Seeded(const BrowserState& state) {
    auto it = state.extra.find("siteSearchDefaultsSeeded");
    if (it == state.extra.end()) return 0;
    return static_cast<int>(it->second.AsInt().value_or(0));
}

void Seed(BrowserState& state, std::vector<SiteSearch>& sites) {
    const int seeded = Seeded(state);
    if (seeded >= kDefaultsVersion) return;
    const std::vector<SiteSearch> defaults = SiteSearch::ArcDefaults();
    if (seeded < 1) {
        std::vector<std::string> existing;
        for (const SiteSearch& site : sites) existing.push_back(unicode::Lowercased(site.shortcut));
        for (const SiteSearch& d : defaults) {
            if (std::find(existing.begin(), existing.end(), unicode::Lowercased(d.shortcut)) == existing.end()) sites.push_back(d);
        }
    }
    // Defaults seeded before they had colours. One the user changed keeps its favicon colour.
    for (SiteSearch& site : sites) {
        if (site.color) continue;
        for (const SiteSearch& d : defaults) {
            if (d.shortcut == site.shortcut && d.name == site.name && d.urlTemplate == site.urlTemplate) {
                site.color = d.color;
                break;
            }
        }
    }
    state.extra.insert_or_assign("siteSearchDefaultsSeeded", kDefaultsVersion);
}

}  // namespace

bool MergeSiteSearches(BrowserState& state, const std::vector<SiteSearch>& imported) {
    bool readable = true;
    std::vector<SiteSearch> sites = SiteSearches(state, &readable);
    if (!readable) return false;
    // The Mac seeds Arc's defaults when it reads a session, before an import merges.
    Seed(state, sites);
    for (const SiteSearch& site : imported) {
        const std::string shortcut = unicode::Lowercased(site.shortcut);
        auto it = std::find_if(sites.begin(), sites.end(), [&](const SiteSearch& s) { return unicode::Lowercased(s.shortcut) == shortcut; });
        if (it != sites.end()) *it = SiteSearch{it->id, site.name, site.shortcut, site.urlTemplate, site.color, site.isActive};
        else sites.push_back(site);
    }
    SetSiteSearches(state, sites);
    return true;
}

}  // namespace kite
