// Closing, archiving and reopening tabs: BrowserState.close, reopenClosed, archiveStaleTabs
// and appendToArchive (BrowserState.swift), removePinnedTab and isInEphemeralFolder
// (BrowserState+Automation.swift), normalizeSplits and SplitView.remove (SplitView.swift),
// and the Mac's PagePool closeRequested (a page that closed itself).

#include <algorithm>
#include <set>

#include "core/Models.h"
#include "core/PinnedTree.h"

namespace kite {

using pinned_tree::DropEmptyEphemeralFolders;
using pinned_tree::FindFolder;
using pinned_tree::IsEmptyEphemeralFolder;
using pinned_tree::ParentFolder;
using pinned_tree::RemoveFolder;
using pinned_tree::RemoveTab;

namespace {

// The pinned tree without the stale tabs in Claude's folders, and without the Claude folders
// that leaves empty. Ordinary folders and pinned tabs stay (archivingStaleEphemeralTabs).
template <typename Archive>
void ArchiveStaleEphemeralTabs(std::vector<PinnedItem>& items, bool inEphemeral, const std::optional<std::string>& selected,
                               Timestamp cutoff, const Archive& archive) {
    // Each item is visited first, then the ones that go are erased (an erase_if predicate
    // mustn't change what it looks at).
    std::vector<bool> goes(items.size(), false);
    for (size_t i = 0; i < items.size(); ++i) {
        if (Tab* tab = std::get_if<Tab>(&items[i].value)) {
            if (!inEphemeral || tab->id == selected || !(tab->lastActiveAt < cutoff)) continue;
            archive(*tab);
            goes[i] = true;
            continue;
        }
        Folder& folder = std::get<Folder>(items[i].value);
        ArchiveStaleEphemeralTabs(folder.items, inEphemeral || folder.ephemeral == true, selected, cutoff, archive);
        goes[i] = IsEmptyEphemeralFolder(items[i]);
    }
    size_t kept = 0;
    for (size_t i = 0; i < items.size(); ++i) {
        if (goes[i]) continue;
        if (kept != i) items[kept] = std::move(items[i]);
        ++kept;
    }
    items.erase(items.begin() + static_cast<std::ptrdiff_t>(kept), items.end());
}

std::vector<double> EqualFactors(size_t count) {
    return count ? std::vector<double>(count, 1.0 / static_cast<double>(count)) : std::vector<double>{};
}

std::vector<SplitView> Normalized(const std::vector<SplitView>& splits, const std::set<std::string>& members) {
    std::set<std::string> claimed;
    std::vector<SplitView> kept;
    for (SplitView split : splits) {
        // SplitView::Remove for each id that goes, in one pass: the others share its width.
        const auto goes = [&](const std::string& id) { return !members.contains(id) || claimed.contains(id); };
        if (std::any_of(split.tabIDs.begin(), split.tabIDs.end(), goes)) {
            const std::vector<double> factors = split.NormalizedFactors();
            std::vector<std::string> ids;
            std::vector<double> widths;
            for (size_t i = 0; i < split.tabIDs.size(); ++i) {
                if (goes(split.tabIDs[i])) continue;
                ids.push_back(std::move(split.tabIDs[i]));
                widths.push_back(factors[i]);
            }
            if (split.expandedTabID && goes(*split.expandedTabID)) split.expandedTabID.reset();
            double total = 0;
            for (double f : widths) total += f;
            if (total > 0) {
                for (double& f : widths) f /= total;
            } else {
                widths = EqualFactors(ids.size());
            }
            split.tabIDs = std::move(ids);
            split.widthFactors = std::move(widths);
        }
        claimed.insert(split.tabIDs.begin(), split.tabIDs.end());
        if (split.tabIDs.size() >= 2) kept.push_back(std::move(split));
    }
    return kept;
}

}  // namespace

bool Tab::IsBlank() const {
    auto blank = [](const std::optional<std::string>& address) { return !address || *address == "about:blank"; };
    return blank(url) && blank(pinnedURL);
}

std::vector<double> SplitView::NormalizedFactors() const {
    const bool usable = widthFactors.size() == tabIDs.size() &&
                        std::all_of(widthFactors.begin(), widthFactors.end(), [](double f) { return f > 0; });
    if (!usable) return EqualFactors(tabIDs.size());
    double total = 0;
    for (double f : widthFactors) total += f;
    std::vector<double> out;
    for (double f : widthFactors) out.push_back(f / total);
    return out;
}

void SplitView::Remove(const std::string& tabID) {
    auto it = std::find(tabIDs.begin(), tabIDs.end(), tabID);
    if (it == tabIDs.end()) return;
    const size_t i = static_cast<size_t>(it - tabIDs.begin());
    std::vector<double> factors = NormalizedFactors();
    if (expandedTabID == tabID) expandedTabID.reset();
    tabIDs.erase(it);
    factors.erase(factors.begin() + static_cast<std::ptrdiff_t>(i));
    double total = 0;
    for (double f : factors) total += f;
    if (total > 0) {
        for (double& f : factors) f /= total;
        widthFactors = std::move(factors);
    } else {
        widthFactors = EqualFactors(tabIDs.size());
    }
}

const SplitView* BrowserState::SplitContaining(const std::string& tabID) const {
    for (const Space& space : spaces) {
        for (const SplitView& split : space.splits) {
            if (std::find(split.tabIDs.begin(), split.tabIDs.end(), tabID) != split.tabIDs.end()) return &split;
        }
    }
    if (auto it = favoriteSplitsByProfile.find(SelectedProfileDirectory()); it != favoriteSplitsByProfile.end()) {
        for (const SplitView& split : it->second) {
            if (std::find(split.tabIDs.begin(), split.tabIDs.end(), tabID) != split.tabIDs.end()) return &split;
        }
    }
    return nullptr;
}

void BrowserState::NormalizeSplits() {
    for (Space& space : spaces) {
        if (space.splits.empty()) continue;
        std::set<std::string> members;
        for (const Tab* tab : space.AllTabs()) members.insert(tab->id);
        space.splits = Normalized(space.splits, members);
    }
    for (auto it = favoriteSplitsByProfile.begin(); it != favoriteSplitsByProfile.end();) {
        std::set<std::string> members;
        if (auto grid = favoritesByProfile.find(it->first); grid != favoritesByProfile.end()) {
            for (const Tab& tab : grid->second) members.insert(tab.id);
        }
        it->second = Normalized(it->second, members);
        it = it->second.empty() ? favoriteSplitsByProfile.erase(it) : std::next(it);
    }
}

bool BrowserState::ClosesForGood(const std::string& tabID) const {
    const Tab* tab = FindTabByID(tabID);
    return tab && (tab->splitPane == true || tab->IsBlank());
}

bool BrowserState::IsInEphemeralFolder(const std::string& tabID) const {
    auto location = Location(tabID);
    if (!location || !location->space) return false;
    const Folder* parent = ParentFolder(spaces[*location->space].pinnedItems, tabID);
    return parent && parent->ephemeral == true;
}

bool BrowserState::ShowsCloseButton(const std::string& tabID) const {
    return !IsInEphemeralFolder(tabID) || ClosesForGood(tabID);
}

bool BrowserState::RemovePinnedTab(std::string tabID, bool droppingEmptyFolder) {
    auto location = Location(tabID);
    if (!location || location->section != TabSection::Pinned || !location->space) return false;
    Space& space = spaces[*location->space];
    std::optional<std::string> parent;
    if (const Folder* folder = ParentFolder(space.pinnedItems, tabID)) parent = folder->id;
    if (!RemoveTab(space.pinnedItems, tabID)) return false;
    if (droppingEmptyFolder && parent) {
        const Folder* folder = FindFolder(space.pinnedItems, *parent);
        if (folder && folder->items.empty()) {
            RemoveFolder(space.pinnedItems, *parent);
            DropEmptyEphemeralFolders(space.pinnedItems);
        }
    }
    if (space.selectedTabID == tabID) {
        const auto all = space.AllTabs();
        space.selectedTabID = all.empty() ? std::nullopt : std::optional<std::string>(all.front()->id);
    }
    NormalizeSplits();
    return true;
}

void BrowserState::AppendToArchive(std::vector<ClosedTab> tabs, ArchiveReason reason, Timestamp now) {
    for (ClosedTab& closed : tabs) {
        if (!closed.archivedAt) closed.archivedAt = now;
        if (!closed.reason) closed.reason = reason;
        archived.push_back(std::move(closed));
    }
    if (archived.size() > kArchiveLimit) archived.erase(archived.begin(), archived.end() - static_cast<std::ptrdiff_t>(kArchiveLimit));
}

CloseOutcome BrowserState::Close(std::string tabID) {
    const auto location = Location(tabID);
    if (!location) return CloseOutcome::NotFound;
    const size_t s = location->space.value_or(SelectedSpaceIndex());
    std::vector<std::string> ordered;
    for (const Tab* tab : SidebarTabs(s)) ordered.push_back(tab->id);
    const bool wasSelected = spaces[s].selectedTabID == tabID;
    // Closing a pane keeps the rest of its split on screen: the pane before it, or the one
    // after when it was first.
    std::optional<std::string> splitNeighbor;
    if (const SplitView* split = SplitContaining(tabID)) {
        const auto at = std::find(split->tabIDs.begin(), split->tabIDs.end(), tabID);
        std::vector<std::string> rest;
        for (const std::string& id : split->tabIDs) {
            if (id != tabID) rest.push_back(id);
        }
        const size_t i = static_cast<size_t>(at - split->tabIDs.begin());
        if (!rest.empty()) splitNeighbor = rest[i > 0 ? i - 1 : 0];
    }
    auto remember = [&](ClosedTab closed) {
        recentlyClosed.push_back(closed);
        if (recentlyClosed.size() > kRecentlyClosedLimit) {
            recentlyClosed.erase(recentlyClosed.begin(), recentlyClosed.end() - static_cast<std::ptrdiff_t>(kRecentlyClosedLimit));
        }
        // In Arc, closing a tab archives it: it stays findable in the archive.
        AppendToArchive({std::move(closed)});
    };

    CloseOutcome outcome;
    if (location->section != TabSection::Unpinned && ClosesForGood(tabID)) {
        // A pane added next to a pinned tab (or one that never had a page) goes like an
        // unpinned tab instead of staying as an empty row, with a Claude folder it leaves empty.
        const Tab tab = *TabAt(*location);
        if (location->section == TabSection::Favorite) {
            std::vector<Tab> grid = Favorites();
            grid.erase(grid.begin() + static_cast<std::ptrdiff_t>(location->index));
            SetFavorites(std::move(grid));
        } else {
            RemovePinnedTab(tabID, IsInEphemeralFolder(tabID));
        }
        if (!tab.IsBlank()) {
            ClosedTab closed{tab, spaces[s].id, 0, std::nullopt, std::nullopt, std::nullopt, {}};
            closed.tab.splitPane.reset();
            remember(std::move(closed));
        }
        outcome = CloseOutcome::Removed;
    } else if (location->section != TabSection::Unpinned) {
        outcome = CloseOutcome::Unloaded;
    } else {
        auto& tabs = spaces[s].tabs;
        Tab tab = std::move(tabs[location->index]);
        tabs.erase(tabs.begin() + static_cast<std::ptrdiff_t>(location->index));
        remember(ClosedTab{std::move(tab), spaces[s].id, static_cast<long long>(location->index), std::nullopt, std::nullopt,
                           std::nullopt, {}});
        outcome = CloseOutcome::Removed;
    }

    // An unloaded pinned tab or favorite leaves its split too, or it would come back blank.
    if (location->section != TabSection::Unpinned && SplitContaining(tabID)) {
        auto leave = [&](std::vector<SplitView>& splits) {
            for (SplitView& split : splits) split.Remove(tabID);
        };
        for (Space& space : spaces) leave(space.splits);
        if (auto it = favoriteSplitsByProfile.find(SelectedProfileDirectory()); it != favoriteSplitsByProfile.end()) leave(it->second);
    }

    if (wasSelected && splitNeighbor) {
        spaces[s].selectedTabID = splitNeighbor;
    } else if (wasSelected) {
        // The tab that slides into this one's place, else the one above it.
        const auto at = std::find(ordered.begin(), ordered.end(), tabID);
        const size_t position = at == ordered.end() ? 0 : static_cast<size_t>(at - ordered.begin());
        std::vector<std::string> remaining;
        for (const std::string& id : ordered) {
            if (id != tabID) remaining.push_back(id);
        }
        spaces[s].selectedTabID =
            remaining.empty() ? std::nullopt : std::optional<std::string>(remaining[std::min(position, remaining.size() - 1)]);
    }
    NormalizeSplits();
    return outcome;
}

std::optional<std::string> BrowserState::ReopenLastClosed(Timestamp now) {
    if (recentlyClosed.empty()) return std::nullopt;
    return ReopenClosed(recentlyClosed.back().tab.id, now);
}

std::optional<std::string> BrowserState::ReopenClosed(std::string tabID, Timestamp now) {
    auto it = std::find_if(recentlyClosed.rbegin(), recentlyClosed.rend(), [&](const ClosedTab& c) { return c.tab.id == tabID; });
    if (it == recentlyClosed.rend()) return std::nullopt;
    ClosedTab closed = std::move(*it);
    recentlyClosed.erase(std::next(it).base());
    const size_t s = SpaceIndex(closed.spaceID).value_or(SelectedSpaceIndex());
    Tab tab = std::move(closed.tab);
    tab.lastActiveAt = now;
    // It's open again, so it's no longer in the archive.
    std::erase_if(archived, [&](const ClosedTab& c) { return c.tab.id == tab.id; });
    auto& tabs = spaces[s].tabs;
    const size_t at = static_cast<size_t>(std::clamp<long long>(closed.index, 0, static_cast<long long>(tabs.size())));
    const std::string id = tab.id;
    tabs.insert(tabs.begin() + static_cast<std::ptrdiff_t>(at), std::move(tab));
    spaces[s].selectedTabID = id;
    selectedSpaceID = spaces[s].id;
    return id;
}

std::vector<Tab> BrowserState::ArchiveStaleTabs(double interval, Timestamp now) {
    std::vector<Tab> removed;
    std::vector<ClosedTab> archive;  // appended once, in the Mac's order
    const Timestamp cutoff = now - interval;
    for (Space& space : spaces) {
        const std::optional<std::string> selected = space.selectedTabID;
        std::vector<Tab> kept;
        for (size_t index = 0; index < space.tabs.size(); ++index) {
            Tab& tab = space.tabs[index];
            if (tab.id != selected && tab.lastActiveAt < cutoff) {
                removed.push_back(tab);
                archive.push_back(ClosedTab{std::move(tab), space.id, static_cast<long long>(index), std::nullopt, std::nullopt, std::nullopt, {}});
            } else {
                kept.push_back(std::move(tab));
            }
        }
        space.tabs = std::move(kept);
        ArchiveStaleEphemeralTabs(space.pinnedItems, false, selected, cutoff, [&](const Tab& tab) {
            removed.push_back(tab);
            archive.push_back(ClosedTab{tab, space.id, 0, std::nullopt, std::nullopt, std::nullopt, {}});
        });
    }
    AppendToArchive(std::move(archive), ArchiveReason::Auto, now);
    NormalizeSplits();
    return removed;
}

std::optional<double> BrowserState::ArchiveAfterSeconds() const {
    static const std::map<std::string, double, std::less<>> seconds{
        {"oneHour", 3600.0},           {"sixHours", 6 * 3600.0},          {"twelveHours", 12 * 3600.0},
        {"twentyFourHours", 24 * 3600.0}, {"sevenDays", 7 * 24 * 3600.0}, {"thirtyDays", 30 * 24 * 3600.0}};
    auto it = seconds.find(archiveAfter);
    if (it == seconds.end()) return std::nullopt;
    return it->second;
}

void BrowserState::PageClosedItself(std::string tabID, std::optional<std::string> openerTabID) {
    const Tab* selected = SelectedTab();
    const bool wasSelected = selected && selected->id == tabID;
    Close(tabID);
    if (wasSelected && openerTabID && Location(*openerTabID)) Select(*openerTabID);
}

}  // namespace kite
