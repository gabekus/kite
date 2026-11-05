// See Sidebar.h.

#include "core/Sidebar.h"

#include <algorithm>
#include <cmath>
#include <cctype>

#include "core/SpaceBar.h"
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
    row.canReset = pinned && tab.HasLeftPinnedURL();
    row.renamed = tab.customTitle.has_value();
    return row;
}

// A pinned tab's close button (BrowserState.showsCloseButton): none for a tab Claude opened in
// its folders, unless it closes for good. Known from the walk, without looking the tab up.
bool PinnedShowsClose(const Tab& tab, bool inEphemeralFolder) {
    return !inEphemeralFolder || tab.splitPane == true || tab.IsBlank();
}

void AppendPinned(const BrowserState& state, const std::vector<PinnedItem>& items, bool ephemeral, int depth,
                  const std::optional<std::string>& selectedID, std::vector<SidebarRow>& rows) {
    for (const PinnedItem& item : items) {
        if (const Tab* tab = std::get_if<Tab>(&item.value)) {
            rows.push_back(TabRow(*tab, true, selectedID && *selectedID == tab->id, depth));
            rows.back().showsClose = PinnedShowsClose(*tab, ephemeral);
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
            AppendPinned(state, folder.items, folder.ephemeral == true, depth + 1, selectedID, rows);
        } else if (selectedID) {
            // Like Arc, a collapsed folder still shows its selected tab, from however deep in it.
            for (const Tab* tab : TabsIn(folder.items)) {
                if (tab->id != *selectedID) continue;
                // From however deep: one lookup for its own folder.
                rows.push_back(TabRow(*tab, true, true, depth + 1));
                rows.back().showsClose = state.ShowsCloseButton(tab->id);
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
    header.look = SpaceIconLookOf(space.icon, space.theme);
    header.hasPinned = !space.pinnedItems.empty();
    header.pinnedCollapsed = IsPinnedSectionCollapsed(state, space.id);
    const bool collapsed = header.pinnedCollapsed;
    rows.push_back(std::move(header));

    // ShownPinnedItems, walked in place (this runs on every page event).
    if (!collapsed) {
        AppendPinned(state, space.pinnedItems, false, 0, space.selectedTabID, rows);
    } else if (space.selectedTabID) {
        for (const Tab* tab : space.Pinned()) {
            if (tab->id != *space.selectedTabID) continue;
            rows.push_back(TabRow(*tab, true, true, 0));
            rows.back().showsClose = state.ShowsCloseButton(tab->id);
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

float SidebarListBottom(float height, float listTop) { return std::max(listTop, SpaceBarTop(height)); }

float SidebarContentHeight(const std::vector<SidebarRow>& rows) { return rows.empty() ? 0 : rows.back().top + rows.back().height; }

float SidebarMaxScroll(const std::vector<SidebarRow>& rows, float height) { return SidebarMaxScroll(rows, height, 0); }

float SidebarMaxScroll(const std::vector<SidebarRow>& rows, float height, float scale, float listTop) {
    const float limit = std::max(0.0f, SidebarContentHeight(rows) - (SidebarListBottom(height, listTop) - listTop));
    return scale > 0 ? std::floor(limit * scale) / scale : limit;
}

std::optional<size_t> SidebarRowAt(const std::vector<SidebarRow>& rows, float width, float height, float scroll, float x, float y,
                                   float listTop) {
    if (x < M::kPadding || x >= width - M::kPadding || y < listTop || y >= SidebarListBottom(height, listTop)) return std::nullopt;
    const float at = y - listTop + scroll;
    for (size_t i = 0; i < rows.size(); ++i) {
        if (at >= rows[i].top && at < rows[i].top + rows[i].height) return i;
    }
    return std::nullopt;
}

SidebarHit SidebarHitTest(const std::vector<SidebarRow>& rows, float width, float height, float scroll, float x, float y,
                          float listTop) {
    using Target = SidebarHit::Target;
    // The field's text button: all of it but the 2pt at its end (SidebarHeader's textArea, with
    // no buttons in the field yet).
    if (y >= M::kUrlFieldTop && y < M::kHeaderAreaHeight && x >= M::kPadding && x < width - M::kPadding - 2) {
        return {Target::AddressField, 0};
    }
    const auto index = SidebarRowAt(rows, width, height, scroll, x, y, listTop);
    if (!index) return {};
    const SidebarRow& row = rows[*index];
    const float inRow = y - listTop + scroll - row.top;
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
        // A tab's close button and Back to Pinned URL: 24pt each, from 6pt in from the pill's end,
        // centred in it. They show whenever the pointer is on the row, so they're there to press
        // whenever they're pointed at.
        if (row.kind == SidebarRow::Kind::Tab) {
            const TabRowTrailing trailing = TabRowTrailingOf(row, width, true);
            const float buttonTop = pillTop + (M::kPillHeight - M::kCloseButtonSize) / 2;
            const bool level = inRow >= buttonTop && inRow < buttonTop + M::kCloseButtonSize;
            if (level && trailing.close && x >= trailing.close->first && x < trailing.close->second) return {Target::CloseButton, *index};
            if (level && trailing.reset && x >= trailing.reset->first && x < trailing.reset->second) return {Target::ResetButton, *index};
        }
        return {Target::Row, *index};
    }
    }
}

std::optional<SidebarPress> SidebarPressAt(const std::vector<SidebarRow>& rows, float width, float height, float scroll, float x,
                                           float y, int clicks, bool activating, float listTop) {
    using Target = SidebarHit::Target;
    const SidebarHit hit = SidebarHitTest(rows, width, height, scroll, x, y, listTop);
    if (hit.target == Target::None) return std::nullopt;
    // Rows don't accept first mouse (NSView's default); the field and SymbolButtons (the
    // chevron, a tab's close button) do.
    if (activating && hit.target == Target::Row) return std::nullopt;
    SidebarPress press{hit.target, SidebarRow::Kind::Tab, {}, clicks};
    if (hit.target != Target::AddressField) {
        press.kind = rows[hit.row].kind;
        press.id = rows[hit.row].id;
    }
    return press;
}

SidebarTap SidebarRelease(const SidebarPress& press, const std::vector<SidebarRow>& rows, float width, float height, float scroll,
                          float x, float y, float listTop) {
    using Target = SidebarHit::Target;
    using Action = SidebarTap::Action;
    // The pressed row where it is now (the header, divider and New Tab share the space's id).
    auto pressedRow = [&]() -> std::optional<size_t> {
        for (size_t i = 0; i < rows.size(); ++i) {
            if (rows[i].kind == press.kind && rows[i].id == press.id) return i;
        }
        return std::nullopt;
    };
    switch (press.target) {
    case Target::AddressField:
        if (SidebarHitTest(rows, width, height, scroll, x, y, listTop).target == Target::AddressField) return {Action::EditAddress, {}, false};
        return {};
    case Target::PinnedChevron:
    case Target::CloseButton:
    case Target::ResetButton: {
        // A button acts when let go over itself (SymbolButton's mouseUp), whatever the clicks.
        const auto row = pressedRow();
        if (!row || SidebarHitTest(rows, width, height, scroll, x, y, listTop) != SidebarHit{press.target, *row}) return {};
        const Action action = press.target == Target::CloseButton   ? Action::CloseTab
                              : press.target == Target::ResetButton ? Action::ResetTab
                                                                    : Action::TogglePinnedSection;
        return {action, press.id, false};
    }
    case Target::Row: {
        const auto row = pressedRow();
        if (press.clicks > 1 || !row || SidebarRowAt(rows, width, height, scroll, x, y, listTop) != row) return {};
        const SidebarRow& r = rows[*row];
        switch (r.kind) {
        case SidebarRow::Kind::Tab: return {Action::SelectTab, r.id, false};
        case SidebarRow::Kind::Folder: return {Action::SetFolderExpanded, r.id, !r.expanded};
        case SidebarRow::Kind::NewTab: return {Action::NewTab, {}, false};
        case SidebarRow::Kind::Header:
        case SidebarRow::Kind::Divider: return {};
        }
        return {};
    }
    case Target::None: return {};
    }
    return {};
}

std::optional<std::string> SidebarRenameOnPress(const SidebarPress& press) {
    if (press.target != SidebarHit::Target::Row || press.kind != SidebarRow::Kind::Tab || press.clicks != 2) return std::nullopt;
    return press.id;
}

TabRowTrailing TabRowTrailingOf(const SidebarRow& row, float width, bool hovered) {
    // place(_:width:height:shown:): each button that shows takes its width from the end, then a gap.
    TabRowTrailing out;
    float end = width - M::kPadding - M::kCloseButtonEndInset;
    bool any = false;
    if (hovered && row.showsClose) {
        out.close = std::make_pair(end - M::kCloseButtonSize, end);
        end -= M::kCloseButtonSize + M::kTrailingGap;
        any = true;
    }
    if (hovered && row.canReset) {
        out.reset = std::make_pair(end - M::kResetButtonSize, end);
        end -= M::kResetButtonSize + M::kTrailingGap;
        any = true;
    }
    // The spacer after the title keeps the gap on both sides of it.
    out.titleEnd = any ? end - M::kTrailingGap : width - M::kPadding - M::kCloseButtonEndInset - M::kTrailingGap;
    return out;
}

namespace {

// Where the item `id` (a tab or folder) sits in the tree: found, and whether every folder above it
// is open.
struct TreePlace {
    bool found = false;
    bool open = true;
};
TreePlace PlaceIn(const std::vector<PinnedItem>& items, SidebarRow::Kind kind, const std::string& id) {
    for (const PinnedItem& item : items) {
        const bool isFolder = std::holds_alternative<Folder>(item.value);
        if (item.Id() == id && isFolder == (kind == SidebarRow::Kind::Folder)) return {true, true};
        if (!isFolder) continue;
        const Folder& folder = std::get<Folder>(item.value);
        TreePlace inside = PlaceIn(folder.items, kind, id);
        if (inside.found) return {true, inside.open && folder.isExpanded};
    }
    return {};
}

}  // namespace

bool SidebarShowsRow(const BrowserState& state, size_t space, SidebarRow::Kind kind, const std::string& id) {
    if (space >= state.spaces.size()) return false;
    const Space& s = state.spaces[space];
    switch (kind) {
    case SidebarRow::Kind::Header: return id == s.id;
    case SidebarRow::Kind::NewTab: return id == s.id;
    case SidebarRow::Kind::Divider: return id == s.id && (!s.pinnedItems.empty() || !s.tabs.empty());
    case SidebarRow::Kind::Tab:
        if (std::any_of(s.tabs.begin(), s.tabs.end(), [&](const Tab& tab) { return tab.id == id; })) return true;
        [[fallthrough]];
    case SidebarRow::Kind::Folder: {
        const TreePlace place = PlaceIn(s.pinnedItems, kind, id);
        if (!place.found) return false;
        // The selected pinned tab shows from under a closed folder or a collapsed section.
        const bool selected = kind == SidebarRow::Kind::Tab && s.selectedTabID == id;
        return selected || (place.open && !IsPinnedSectionCollapsed(state, s.id));
    }
    }
    return false;
}

}  // namespace kite
