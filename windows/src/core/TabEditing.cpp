// Pinning, favorites, renaming, duplicating and folders: the Mac's BrowserState.togglePin and
// toggleFavorite (BrowserState.swift), duplicate, renameTab, deleteFolder and renameFolder
// (BrowserState+ArcCommands.swift), and folders(inSpace:), folder(matching:) and
// moveTab(_:toFolder:) (BrowserState+Automation.swift). See Models.h.

#include <algorithm>

#include "core/Models.h"
#include "core/PinnedTree.h"
#include "core/Unicode.h"
#include "core/Uuid.h"

namespace kite {

namespace {

// The current profile's grid, for editing; an emptied one loses its entry (as the Mac keeps no
// empty grids).
std::vector<Tab>& Grid(BrowserState& state) { return state.favoritesByProfile[state.SelectedProfileDirectory()]; }

void DropEmptyGrid(BrowserState& state) {
    if (auto it = state.favoritesByProfile.find(state.SelectedProfileDirectory()); it != state.favoritesByProfile.end() && it->second.empty()) {
        state.favoritesByProfile.erase(it);
    }
}

std::optional<std::string> FirstTab(const Space& space) {
    const auto all = space.AllTabs();
    return all.empty() ? std::nullopt : std::optional<std::string>(all.front()->id);
}

bool SameIDIgnoringCase(std::string_view a, std::string_view b) {
    return a.size() == b.size() && std::equal(a.begin(), a.end(), b.begin(), [](char x, char y) {
               auto upper = [](char c) { return c >= 'a' && c <= 'z' ? static_cast<char>(c - 'a' + 'A') : c; };
               return upper(x) == upper(y);
           });
}

}  // namespace

void BrowserState::TogglePin(const std::string& tabID) {
    const auto location = Location(tabID);
    if (!location || !location->space) return;
    const size_t s = *location->space;
    Space& space = spaces[s];
    if (const SplitView* split = SplitContaining(tabID)) {
        // A split pins and unpins as one item, keeping its panes together and in order.
        const std::vector<std::string> ids = split->tabIDs;
        std::vector<Tab> members;
        for (const std::string& member : ids) {
            if (auto it = std::find_if(space.tabs.begin(), space.tabs.end(), [&](const Tab& t) { return t.id == member; }); it != space.tabs.end()) {
                members.push_back(std::move(*it));
                space.tabs.erase(it);
            } else if (auto removed = pinned_tree::RemoveTab(space.pinnedItems, member)) {
                members.push_back(std::move(*removed));
            }
        }
        if (location->section == TabSection::Pinned) {
            space.tabs.insert(space.tabs.begin(), std::make_move_iterator(members.begin()), std::make_move_iterator(members.end()));
        } else {
            for (Tab& tab : members) {
                tab.splitPane.reset();
                space.pinnedItems.push_back(PinnedItem{std::move(tab)});
            }
        }
    } else if (location->section == TabSection::Pinned) {
        if (auto tab = pinned_tree::RemoveTab(space.pinnedItems, tabID)) space.tabs.insert(space.tabs.begin(), std::move(*tab));
    } else {
        Tab tab = std::move(space.tabs[location->index]);
        space.tabs.erase(space.tabs.begin() + static_cast<std::ptrdiff_t>(location->index));
        tab.splitPane.reset();
        space.pinnedItems.push_back(PinnedItem{std::move(tab)});
    }
    SyncPinnedURLs();
}

void BrowserState::ToggleFavorite(const std::string& tabID) {
    const auto location = Location(tabID);
    if (!location) return;
    switch (location->section) {
    case TabSection::Favorite: {
        std::vector<Tab>& grid = Grid(*this);
        Tab tab = std::move(grid[location->index]);
        grid.erase(grid.begin() + static_cast<std::ptrdiff_t>(location->index));
        DropEmptyGrid(*this);
        auto& tabs = spaces[SelectedSpaceIndex()].tabs;
        tabs.insert(tabs.begin(), std::move(tab));
        break;
    }
    case TabSection::Pinned:
        if (auto tab = pinned_tree::RemoveTab(spaces[*location->space].pinnedItems, tabID)) Grid(*this).push_back(std::move(*tab));
        break;
    case TabSection::Unpinned: {
        auto& tabs = spaces[*location->space].tabs;
        Tab tab = std::move(tabs[location->index]);
        tabs.erase(tabs.begin() + static_cast<std::ptrdiff_t>(location->index));
        Grid(*this).push_back(std::move(tab));
        break;
    }
    }
    NormalizeSplits();
    SyncPinnedURLs();
}

std::optional<std::string> BrowserState::Duplicate(const std::string& tabID, Timestamp now, std::string id) {
    const auto location = Location(tabID);
    if (!location) return std::nullopt;
    const size_t s = location->space.value_or(SelectedSpaceIndex());
    const Tab& original = *TabAt(*location);
    Tab copy;
    copy.id = id.empty() ? NewUuid() : std::move(id);
    copy.url = original.url;
    copy.title = original.title;
    copy.faviconURL = original.faviconURL;
    copy.customTitle = original.customTitle;
    copy.lastActiveAt = now;
    auto& tabs = spaces[s].tabs;
    const size_t index = std::min(location->section == TabSection::Unpinned ? location->index + 1 : 0, tabs.size());
    const std::string made = copy.id;
    tabs.insert(tabs.begin() + static_cast<std::ptrdiff_t>(index), std::move(copy));
    spaces[s].selectedTabID = made;
    selectedSpaceID = spaces[s].id;
    return made;
}

void BrowserState::RenameTab(const std::string& tabID, std::string_view name) {
    const auto location = Location(tabID);
    if (!location) return;
    const std::string_view trimmed = unicode::Trim(name);
    TabAt(*location)->customTitle = trimmed.empty() ? std::nullopt : std::optional<std::string>(trimmed);
}

void BrowserState::RenameFolder(const std::string& folderID, std::string_view name) {
    const std::string_view trimmed = unicode::Trim(name);
    if (trimmed.empty()) return;
    for (Space& space : spaces) {
        if (Folder* folder = pinned_tree::FindFolder(space.pinnedItems, folderID)) {
            folder->name = std::string(trimmed);
            return;
        }
    }
}

std::vector<Tab> BrowserState::DeleteFolder(const std::string& folderID) {
    for (Space& space : spaces) {
        auto folder = pinned_tree::RemoveFolder(space.pinnedItems, folderID);
        if (!folder) continue;
        std::vector<Tab> tabs;
        std::vector<ClosedTab> archive;
        for (const Tab* tab : TabsIn(folder->items)) {
            tabs.push_back(*tab);
            archive.push_back(ClosedTab{*tab, space.id, static_cast<long long>(archive.size()), std::nullopt, std::nullopt, std::nullopt, {}});
        }
        AppendToArchive(std::move(archive));
        if (space.selectedTabID && std::any_of(tabs.begin(), tabs.end(), [&](const Tab& t) { return t.id == *space.selectedTabID; })) {
            space.selectedTabID = FirstTab(space);
        }
        NormalizeSplits();
        return tabs;
    }
    return {};
}

bool BrowserState::MoveTabToFolder(std::string tabID, const std::string& folderID) {
    const auto location = Location(tabID);
    if (!location || !location->space) return false;
    const size_t from = *location->space;
    std::optional<size_t> to;
    for (size_t s = 0; s < spaces.size() && !to; ++s) {
        if (pinned_tree::FindFolder(spaces[s].pinnedItems, folderID)) to = s;
    }
    if (!to) return false;
    std::optional<Tab> tab;
    if (location->section == TabSection::Unpinned) {
        auto& tabs = spaces[from].tabs;
        tab = std::move(tabs[location->index]);
        tabs.erase(tabs.begin() + static_cast<std::ptrdiff_t>(location->index));
    } else {
        tab = pinned_tree::RemoveTab(spaces[from].pinnedItems, tabID);
    }
    if (!tab) return false;
    pinned_tree::FindFolder(spaces[*to].pinnedItems, folderID)->items.push_back(PinnedItem{std::move(*tab)});
    if (from != *to && spaces[from].selectedTabID == tabID) spaces[from].selectedTabID = FirstTab(spaces[from]);
    return true;
}

std::vector<const Folder*> BrowserState::Folders(size_t space) const {
    std::vector<const Folder*> out;
    if (space < spaces.size()) pinned_tree::CollectFolders(spaces[space].pinnedItems, out);
    return out;
}

std::optional<BrowserState::FolderMatch> BrowserState::FolderMatching(std::string_view idOrName) const {
    const std::string_view key = unicode::Trim(idOrName);
    const std::string loweredKey = unicode::Lowercased(key);
    std::vector<size_t> order{SelectedSpaceIndex()};
    for (size_t s = 0; s < spaces.size(); ++s) {
        if (s != order.front()) order.push_back(s);
    }
    for (size_t s : order) {
        for (const Folder* folder : Folders(s)) {
            if (SameIDIgnoringCase(folder->id, key) || unicode::Lowercased(folder->name) == loweredKey) return FolderMatch{s, folder};
        }
    }
    return std::nullopt;
}

}  // namespace kite
