// See Sidebar.h.

#include "core/Sidebar.h"

#include <algorithm>
#include <cctype>

#include "core/Url.h"

namespace kite {

namespace {

constexpr const char* kCollapsedKey = "spacesWithCollapsedPinnedSections";

// The ids in the Mac's Set<UUID>, as the session stores it (an array of UUID strings).
std::vector<std::string> CollapsedSpaces(const BrowserState& state) {
    std::vector<std::string> out;
    auto found = state.extra.find(kCollapsedKey);
    if (found == state.extra.end()) return out;
    if (const json::Array* ids = found->second.AsArray()) {
        for (const json::Value& id : *ids) {
            if (const std::string* text = id.AsString()) out.push_back(*text);
        }
    }
    return out;
}

// UUIDs compare as the Mac's do: by value, so case doesn't matter.
bool SameID(const std::string& a, const std::string& b) {
    return a.size() == b.size() && std::equal(a.begin(), a.end(), b.begin(), [](char x, char y) {
               auto upper = [](char c) { return c >= 'a' && c <= 'z' ? static_cast<char>(c - 'a' + 'A') : c; };
               return upper(x) == upper(y);
           });
}

std::string Lower(std::string text) {
    for (char& c : text) {
        if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    }
    return text;
}

namespace M = sidebar_metrics;

SidebarRow TabRow(const Tab& tab, bool pinned, bool selected, int depth) {
    SidebarRow row;
    row.kind = SidebarRow::Kind::Tab;
    row.id = tab.id;
    row.depth = depth;
    row.title = tab.DisplayTitle();
    row.pinned = pinned;
    row.selected = selected;
    row.favicon = FaviconSourceOf(tab.url, tab.faviconURL);
    return row;
}

void AppendPinned(const std::vector<PinnedItem>& items, int depth, const std::optional<std::string>& selectedID,
                  std::vector<SidebarRow>& rows) {
    for (const PinnedItem& item : items) {
        if (const Tab* tab = std::get_if<Tab>(&item.value)) {
            rows.push_back(TabRow(*tab, true, selectedID && *selectedID == tab->id, depth));
            continue;
        }
        const Folder& folder = std::get<Folder>(item.value);
        SidebarRow row;
        row.kind = SidebarRow::Kind::Folder;
        row.id = folder.id;
        row.depth = depth;
        row.title = folder.name;
        row.expanded = folder.isExpanded;
        rows.push_back(std::move(row));
        if (folder.isExpanded) {
            AppendPinned(folder.items, depth + 1, selectedID, rows);
        } else if (selectedID) {
            // Like Arc, a collapsed folder still shows its selected tab, from however deep in it.
            for (const Tab* tab : TabsIn(folder.items)) {
                if (tab->id == *selectedID) rows.push_back(TabRow(*tab, true, true, depth + 1));
            }
        }
    }
}

}  // namespace

bool IsPinnedSectionCollapsed(const BrowserState& state, const std::string& spaceID) {
    const auto ids = CollapsedSpaces(state);
    return std::any_of(ids.begin(), ids.end(), [&](const std::string& id) { return SameID(id, spaceID); });
}

void TogglePinnedSection(BrowserState& state, const std::string& spaceID) {
    if (!state.SpaceIndex(spaceID)) return;
    std::vector<std::string> ids = CollapsedSpaces(state);
    auto found = std::find_if(ids.begin(), ids.end(), [&](const std::string& id) { return SameID(id, spaceID); });
    if (found != ids.end()) {
        ids.erase(found);
    } else {
        ids.push_back(spaceID);
    }
    json::Array array;
    for (std::string& id : ids) array.emplace_back(std::move(id));
    // The Mac always writes the set, empty or not.
    state.extra[kCollapsedKey] = json::Value(std::move(array));
}

std::vector<PinnedItem> ShownPinnedItems(const BrowserState& state, const Space& space) {
    if (!IsPinnedSectionCollapsed(state, space.id)) return space.pinnedItems;
    std::vector<PinnedItem> shown;
    if (!space.selectedTabID) return shown;
    for (const Tab* tab : space.Pinned()) {
        if (tab->id == *space.selectedTabID) shown.push_back(PinnedItem{*tab});
    }
    return shown;
}

std::optional<InternalPage> InternalPageOf(const std::optional<std::string>& url) {
    if (!url || url::Scheme(*url) != "kite") return std::nullopt;
    const std::string host = Lower(url::Host(*url).value_or(""));
    if (host == "history") return InternalPage::History;
    if (host == "archive") return InternalPage::Archive;
    if (host == "site-settings") return InternalPage::SiteSettings;
    if (host == "settings") return InternalPage::Settings;
    if (host == "search-engines") return InternalPage::SearchEngines;
    return std::nullopt;
}

FaviconSource FaviconSourceOf(const std::optional<std::string>& page, const std::optional<std::string>& icon) {
    FaviconSource source;
    source.symbol = InternalPageOf(page);
    if (icon) {
        source.url = icon;
    } else if (page) {
        const auto scheme = url::Scheme(*page);
        const auto host = url::Host(*page);
        // The host alone, port dropped, as the Mac builds "scheme://host/favicon.ico". An IPv6
        // host would need its brackets back, which the Mac doesn't add: its URL is nil there.
        if ((scheme == "http" || scheme == "https") && host && !host->empty() && host->find(':') == std::string::npos) {
            source.url = *scheme + "://" + *host + "/favicon.ico";
        }
    }
    return source;
}

bool LooksLikeSvg(std::string_view bytes) {
    // After any byte-order mark and whitespace, an element (an XML declaration and comments
    // count), with an <svg> element in the first 4KB.
    const std::string_view head = bytes.substr(0, 4096);
    size_t at = head.starts_with("\xEF\xBB\xBF") ? 3 : 0;
    while (at < head.size() && std::isspace(static_cast<unsigned char>(head[at]))) ++at;
    return at < head.size() && head[at] == '<' && head.find("<svg") != std::string_view::npos;
}

std::string AddressFieldText(const BrowserState& state) {
    const Tab* tab = state.SelectedTab();
    if (tab && tab->url) {
        if (auto host = url::Host(*tab->url); host && !host->empty()) return *host;
    }
    return "Search or enter URL";
}

std::vector<SidebarRow> SidebarRows(const BrowserState& state, size_t spaceIndex) {
    std::vector<SidebarRow> rows;
    if (spaceIndex >= state.spaces.size()) return rows;
    const Space& space = state.spaces[spaceIndex];

    SidebarRow header;
    header.kind = SidebarRow::Kind::Header;
    header.id = space.id;
    header.title = space.name;
    header.icon = space.icon;
    header.hasPinned = !space.pinnedItems.empty();
    header.pinnedCollapsed = IsPinnedSectionCollapsed(state, space.id);
    const bool collapsed = header.pinnedCollapsed;
    rows.push_back(std::move(header));

    // ShownPinnedItems, walked in place (this runs on every page event).
    if (!collapsed) {
        AppendPinned(space.pinnedItems, 0, space.selectedTabID, rows);
    } else if (space.selectedTabID) {
        for (const Tab* tab : space.Pinned()) {
            if (tab->id == *space.selectedTabID) rows.push_back(TabRow(*tab, true, true, 0));
        }
    }

    // The Mac also shows it when Tidy Tabs could run, which needs Claude (not on Windows yet).
    if (!space.pinnedItems.empty() || !space.tabs.empty()) {
        SidebarRow divider;
        divider.kind = SidebarRow::Kind::Divider;
        divider.id = space.id;
        divider.showsLine = !space.pinnedItems.empty();
        rows.push_back(std::move(divider));
    }
    SidebarRow newTab;
    newTab.kind = SidebarRow::Kind::NewTab;
    newTab.id = space.id;
    newTab.title = "New Tab";
    rows.push_back(std::move(newTab));
    for (const Tab& tab : space.tabs) {
        rows.push_back(TabRow(tab, false, space.selectedTabID && *space.selectedTabID == tab.id, 0));
    }

    float top = 0;
    for (SidebarRow& row : rows) {
        switch (row.kind) {
        case SidebarRow::Kind::Header: row.height = M::kHeaderHeight + M::kListTopSpacer; break;
        case SidebarRow::Kind::Divider: row.height = M::kDividerRowHeight; break;
        default: row.height = M::kRowPitch; break;
        }
        row.top = top;
        top += row.height;
    }
    return rows;
}

float SidebarListBottom(float height) { return std::max(M::kHeaderAreaHeight, height - M::kBottomBarHeight); }

float SidebarContentHeight(const std::vector<SidebarRow>& rows) { return rows.empty() ? 0 : rows.back().top + rows.back().height; }

float SidebarMaxScroll(const std::vector<SidebarRow>& rows, float height) {
    return std::max(0.0f, SidebarContentHeight(rows) - (SidebarListBottom(height) - M::kHeaderAreaHeight));
}

std::optional<size_t> SidebarRowAt(const std::vector<SidebarRow>& rows, float width, float height, float scroll, float x, float y) {
    if (x < M::kPadding || x >= width - M::kPadding || y < M::kHeaderAreaHeight || y >= SidebarListBottom(height)) return std::nullopt;
    const float at = y - M::kHeaderAreaHeight + scroll;
    for (size_t i = 0; i < rows.size(); ++i) {
        if (at >= rows[i].top && at < rows[i].top + rows[i].height) return i;
    }
    return std::nullopt;
}

SidebarHit SidebarHitTest(const std::vector<SidebarRow>& rows, float width, float height, float scroll, float x, float y) {
    using Target = SidebarHit::Target;
    // The field's text button: all of it but the 2pt at its end (SidebarHeader's textArea, with
    // no buttons in the field yet).
    if (y >= M::kUrlFieldTop && y < M::kHeaderAreaHeight && x >= M::kPadding && x < width - M::kPadding - 2) {
        return {Target::AddressField, 0};
    }
    const auto index = SidebarRowAt(rows, width, height, scroll, x, y);
    if (!index) return {};
    const SidebarRow& row = rows[*index];
    const float inRow = y - M::kHeaderAreaHeight + scroll - row.top;
    switch (row.kind) {
    case SidebarRow::Kind::Header: {
        // The chevron's 26pt button, 1pt in from the row's end.
        const float right = width - M::kPadding - (M::kIconInset - M::kPadding);
        if (row.hasPinned && x >= right - M::kHeaderIconSize && x < right && inRow >= M::kHeaderIconTop &&
            inRow < M::kHeaderIconTop + M::kHeaderIconSize) {
            return {Target::PinnedChevron, *index};
        }
        return {Target::Row, *index};
    }
    case SidebarRow::Kind::Divider: return {};
    default: {
        const float pillTop = (M::kRowPitch - M::kPillHeight) / 2;
        if (inRow < pillTop || inRow >= pillTop + M::kPillHeight) return {};
        return {Target::Row, *index};
    }
    }
}

}  // namespace kite
