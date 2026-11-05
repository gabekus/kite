// Arc's pinned-URL behaviour, ported from the Mac's PinnedURL.swift: a pinned tab (or favorite)
// remembers the page it was pinned at, offers Back to Pinned URL once it has wandered off, and
// Tabs › Reset all tabs in this Space sends every pinned tab in the space home. See Models.h.

#include <algorithm>

#include "core/Favorites.h"
#include "core/Models.h"
#include "core/PinnedTree.h"
#include "core/Sidebar.h"
#include "core/URLInput.h"
#include "core/Unicode.h"
#include "core/Url.h"

namespace kite {

namespace {

// The page an address is on, for SamePage: URLComponents with the fragment dropped, http made
// https, the scheme and host lowercased, a leading "www." gone, and trailing slashes off the
// path ("/" alone is no path). An address with no host is compared whole.
std::string PageKey(std::string_view address) {
    const auto scheme = url::Scheme(address);
    if (!scheme || !url::Host(address)) return std::string(address);
    std::string_view rest = address.substr(scheme->size() + 3);  // past "scheme://"
    const size_t end = rest.find_first_of("/?#");
    std::string_view authority = rest.substr(0, end);
    rest = end == std::string_view::npos ? std::string_view{} : rest.substr(end);
    std::string key = *scheme == "http" ? std::string("https") : *scheme;
    key += "://";
    // The user and password, as typed.
    if (const size_t at = authority.rfind('@'); at != std::string_view::npos) {
        key += authority.substr(0, at + 1);
        authority.remove_prefix(at + 1);
    }
    // The host lowercased without "www.", then its port as typed.
    const size_t close = authority.find(']');
    const size_t colon = authority.find(':', close == std::string_view::npos ? 0 : close);
    std::string host = unicode::Lowercased(authority.substr(0, colon));
    if (host.starts_with("www.")) host.erase(0, 4);
    key += host;
    if (colon != std::string_view::npos) key += authority.substr(colon);
    // The path, then the query; no fragment.
    if (const size_t hash = rest.find('#'); hash != std::string_view::npos) rest = rest.substr(0, hash);
    const size_t question = rest.find('?');
    std::string_view path = rest.substr(0, question);
    while (path.size() > 1 && path.back() == '/') path.remove_suffix(1);
    if (path != "/") key += path;
    if (question != std::string_view::npos) key += rest.substr(question);
    return key;
}

// adopt(_:): a tab with no pinned URL takes its page, unless that's one of Kite's own or blank.
void Adopt(Tab& tab) {
    if (!tab.pinnedURL && tab.url && !InternalPageOf(tab.url) && *tab.url != "about:blank") tab.pinnedURL = tab.url;
}

void AdoptAll(std::vector<PinnedItem>& items) {
    for (PinnedItem& item : items) {
        if (Tab* tab = std::get_if<Tab>(&item.value)) Adopt(*tab);
        else AdoptAll(std::get<Folder>(item.value).items);
    }
}

}  // namespace

bool Tab::SamePage(std::string_view a, std::string_view b) { return PageKey(a) == PageKey(b); }

bool Tab::HasLeftPinnedURL() const { return pinnedURL && url && !SamePage(*url, *pinnedURL); }

void BrowserState::SyncPinnedURLs() {
    for (auto& [profile, grid] : favoritesByProfile) {
        for (Tab& tab : grid) Adopt(tab);
    }
    for (Space& space : spaces) {
        AdoptAll(space.pinnedItems);
        for (Tab& tab : space.tabs) tab.pinnedURL.reset();
    }
}

bool BrowserState::CanReset(const std::string& tabID) const {
    const auto location = Location(tabID);
    return location && location->section != TabSection::Unpinned && TabAt(*location)->HasLeftPinnedURL();
}

std::optional<std::string> BrowserState::ResetTab(const std::string& tabID) {
    if (!CanReset(tabID)) return std::nullopt;
    Tab* tab = TabAt(*Location(tabID));
    tab->url = tab->pinnedURL;
    return tab->pinnedURL;
}

bool BrowserState::HasPinnedURL(const std::string& tabID) const {
    const auto location = Location(tabID);
    return location && location->section != TabSection::Unpinned && TabAt(*location)->pinnedURL.has_value();
}

bool BrowserState::EditPinnedURL(const std::string& tabID, std::string_view input) {
    if (!HasPinnedURL(tabID)) return false;
    auto address = url_input::AsURL(input);
    if (!address) return false;
    TabAt(*Location(tabID))->pinnedURL = std::move(address);
    return true;
}

bool BrowserState::ReplacePinnedURLWithCurrent(const std::string& tabID) {
    if (!HasPinnedURL(tabID)) return false;
    Tab* tab = TabAt(*Location(tabID));
    if (!tab->url || InternalPageOf(tab->url)) return false;
    tab->pinnedURL = tab->url;
    return true;
}

std::vector<std::pair<std::string, std::string>> BrowserState::ResetPinnedTabs() {
    std::vector<std::string> ids;
    for (const Tab* tab : SelectedSpace().Pinned()) ids.push_back(tab->id);
    std::vector<std::pair<std::string, std::string>> reset;
    for (const std::string& id : ids) {
        if (auto home = ResetTab(id)) reset.emplace_back(id, std::move(*home));
    }
    return reset;
}

std::optional<std::string> BrowserState::SeparateFromPinnedTab(const std::string& tabID, Timestamp now, std::string id) {
    if (!CanReset(tabID)) return std::nullopt;
    const TabLocation location = *Location(tabID);
    const std::optional<std::string> away = TabAt(location)->url;
    const std::optional<std::string> space = location.space ? std::optional<std::string>(spaces[*location.space].id) : std::nullopt;
    ResetTab(tabID);
    return OpenTab(away, space, true, now, std::move(id));
}

std::optional<std::string> BrowserState::RevealTab(const std::string& tabID) {
    const auto location = Location(tabID);
    if (!location || !location->space) return std::nullopt;
    if (location->section == TabSection::Pinned) pinned_tree::ExpandFolders(spaces[*location->space].pinnedItems, tabID);
    return SidebarRowID(tabID);
}

std::optional<std::string> BrowserState::SidebarRowID(const std::string& tabID) const {
    const auto location = Location(tabID);
    if (!location || !location->space) return std::nullopt;
    const Space& space = spaces[*location->space];
    const bool pinned = location->section == TabSection::Pinned;
    std::vector<std::string> topLevel;
    std::optional<std::string> item;
    if (pinned) {
        for (const PinnedItem& top : space.pinnedItems) {
            topLevel.push_back(top.Id());
            if (!item && pinned_tree::Contains(top, tabID)) item = top.Id();
        }
    } else {
        for (const Tab& tab : space.tabs) topLevel.push_back(tab.id);
        item = tabID;
    }
    if (!item) return std::nullopt;
    for (const SidebarGroup& group : GroupBySplit(topLevel, space.splits)) {
        if (std::any_of(group.indices.begin(), group.indices.end(), [&](size_t i) { return topLevel[i] == *item; })) return group.id;
    }
    return std::nullopt;
}

}  // namespace kite
