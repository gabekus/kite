// The sidebar's row menus and the edits only they make: SidebarContextMenu.swift (tabsToArchive,
// archiveTabs, canDuplicateFolder, duplicateFolder, createNestedFolder, canTurnFolderIntoSpace,
// turnFolderIntoSpace), LinkFormat.swift (markdown), BrowserState+Automation.swift
// (claudeMayCreateSpace), SplitView.swift ([PinnedItem].insertItem(_:after:)), and the menus of
// SidebarListCells.swift (TabRowCell, FolderRowCell, addLiveFolderItems, addCopyLinkItems,
// addArchiveTabsItems, addEditPinnedPage) and SidebarFavorites.swift (FavoritePaneView). See
// SidebarContextMenu.h.

#include "core/SidebarContextMenu.h"

#include <algorithm>
#include <set>
#include <utility>

#include "core/PinnedTree.h"
#include "core/SpaceIcon.h"
#include "core/Unicode.h"
#include "core/Uuid.h"

namespace kite {

namespace {

// Swift's Character.isNewline, by the character's first scalar (a newline never combines).
bool IsNewline(char32_t c) { return (c >= 0x0A && c <= 0x0D) || c == 0x85 || c == 0x2028 || c == 0x2029; }

std::string ReplaceAll(std::string text, std::string_view from, std::string_view to) {
    for (size_t at = text.find(from); at != std::string::npos; at = text.find(from, at + to.size())) text.replace(at, from.size(), to);
    return text;
}

// [PinnedItem].insertItem(_:after:): right after `neighbor`, in whichever list (at any depth) holds it.
bool InsertAfter(std::vector<PinnedItem>& items, PinnedItem& item, const std::string& neighbor) {
    for (size_t i = 0; i < items.size(); ++i) {
        if (items[i].Id() == neighbor) {
            items.insert(items.begin() + static_cast<std::ptrdiff_t>(i) + 1, std::move(item));
            return true;
        }
        if (auto* folder = std::get_if<Folder>(&items[i].value); folder && InsertAfter(folder->items, item, neighbor)) return true;
    }
    return false;
}

// The space whose pinned items hold folder `id`, and the folder.
std::optional<std::pair<size_t, const Folder*>> FindFolderInSpaces(const BrowserState& state, const std::string& id) {
    for (size_t s = 0; s < state.spaces.size(); ++s) {
        if (const Folder* folder = pinned_tree::FindFolder(state.spaces[s].pinnedItems, id)) return std::pair{s, folder};
    }
    return std::nullopt;
}

// A plain folder: no Claude folder or live folder in it, all the way down.
bool Plain(const Folder& folder) {
    if (folder.ephemeral == true || folder.live) return false;
    return std::all_of(folder.items.begin(), folder.items.end(), [](const PinnedItem& item) {
        const auto* inner = std::get_if<Folder>(&item.value);
        return !inner || Plain(*inner);
    });
}

// duplicateFolder's copy: fresh ids, not loaded (lastActiveAt now), live folders left out.
std::optional<PinnedItem> Copy(const PinnedItem& item, Timestamp now) {
    if (const auto* tab = std::get_if<Tab>(&item.value)) {
        Tab copy;
        copy.id = NewUuid();
        copy.url = tab->url;
        copy.title = tab->title;
        copy.faviconURL = tab->faviconURL;
        copy.lastActiveAt = now;
        copy.pinnedURL = tab->pinnedURL;
        copy.customTitle = tab->customTitle;
        return PinnedItem{std::move(copy)};
    }
    const Folder& folder = std::get<Folder>(item.value);
    if (folder.live) return std::nullopt;
    Folder copy;
    copy.id = NewUuid();
    copy.name = folder.name;
    copy.isExpanded = folder.isExpanded;
    copy.ephemeral = folder.ephemeral;
    for (const PinnedItem& inner : folder.items) {
        if (auto copied = Copy(inner, now)) copy.items.push_back(std::move(*copied));
    }
    return PinnedItem{std::move(copy)};
}

// Space.labelWithIcon: "🏠 Personal", or just the name when the icon isn't an emoji.
std::string LabelWithIcon(const Space& space) {
    const bool text = !space.icon.empty() && !space.icon.starts_with(kSymbolIconPrefix) && !space.icon.starts_with(kImageIconPrefix);
    return text ? space.icon + " " + space.name : space.name;
}

using C = SidebarMenuItem::Command;

SidebarMenuItem Item(C command, std::string title, bool enabled = true) {
    SidebarMenuItem item;
    item.command = command;
    item.title = std::move(title);
    item.enabled = enabled;
    return item;
}

SidebarMenuItem Submenu(C command, std::string title, std::vector<SidebarMenuItem> items, bool enabled = true) {
    SidebarMenuItem item = Item(command, std::move(title), enabled);
    item.submenu = true;
    item.items = std::move(items);
    return item;
}

const SidebarMenuItem kSeparator{};

// addEditPinnedPage: Arc's "Edit Pinned Page" submenu. Edit… is Arc's dialog (ArcDialog, W19).
SidebarMenuItem EditPinnedPage() {
    return Submenu(C::EditPinnedPage, "Edit Pinned Page",
                   {Item(C::EditPinnedURL, "Edit\xE2\x80\xA6", false), Item(C::ReplacePinnedURL, "Replace Pinned URL with Current")});
}

}  // namespace

// MARK: LinkFormat

std::string MarkdownLink(std::string_view title, std::string_view url) {
    const std::string_view trimmed = unicode::Trim(title);
    const std::string_view text = trimmed.empty() ? url : trimmed;
    std::string escaped;
    for (const std::u32string& character : unicode::Characters(text)) {
        if (character == U"\\" || character == U"[" || character == U"]") escaped += '\\';
        // A newline inside the link text breaks most renderers.
        escaped += IsNewline(character.front()) ? std::string(" ") : unicode::Encode(character);
    }
    std::string destination = ReplaceAll(ReplaceAll(ReplaceAll(std::string(url), "(", "%28"), ")", "%29"), " ", "%20");
    return "[" + escaped + "](" + destination + ")";
}

std::optional<std::string> MarkdownLink(const Tab& tab) {
    if (!tab.url) return std::nullopt;
    return MarkdownLink(tab.DisplayTitle(), *tab.url);
}

std::string MarkdownLinkList(const std::vector<const Tab*>& tabs) {
    std::string out;
    for (const Tab* tab : tabs) {
        const std::optional<std::string> link = MarkdownLink(*tab);
        if (!link) continue;
        if (!out.empty()) out += '\n';
        out += *link;
    }
    return out;
}

bool ClaudeMayCreateSpace(std::string_view name) {
    // CharacterSet.whitespaces: White_Space but the newlines (Zs and tab).
    std::u32string scalars;
    for (char32_t c : unicode::Decode(name)) scalars += c;
    const auto space = [](char32_t c) { return unicode::IsWhitespace(c) && !IsNewline(c); };
    size_t begin = 0, end = scalars.size();
    while (begin < end && space(scalars[begin])) ++begin;
    while (end > begin && space(scalars[end - 1])) --end;
    // localizedCaseInsensitiveCompare with "Claude".
    return unicode::Lowercased(unicode::Encode(std::u32string_view(scalars).substr(begin, end - begin))) != "claude";
}

// MARK: BrowserState's menu edits

std::vector<std::string> BrowserState::TabsToArchive(ArchiveTabsRelative which, const std::string& id) const {
    const auto location = Location(id);
    if (!location || location->section != TabSection::Unpinned || !location->space) return {};
    const Space& space = spaces[*location->space];
    std::vector<std::string> row{id};
    for (const SplitView& split : space.splits) {
        if (std::find(split.tabIDs.begin(), split.tabIDs.end(), id) != split.tabIDs.end()) {
            row = split.tabIDs;
            break;
        }
    }
    const auto inRow = [&](const Tab& tab) { return std::find(row.begin(), row.end(), tab.id) != row.end(); };
    std::optional<size_t> first, last;
    for (size_t i = 0; i < space.tabs.size(); ++i) {
        if (!inRow(space.tabs[i])) continue;
        if (!first) first = i;
        last = i;
    }
    if (!first) return {};
    std::vector<std::string> out;
    for (size_t i = 0; i < space.tabs.size(); ++i) {
        const bool take = which == ArchiveTabsRelative::Others  ? !inRow(space.tabs[i])
                          : which == ArchiveTabsRelative::Above ? i < *first
                                                                : i > *last;
        if (take) out.push_back(space.tabs[i].id);
    }
    return out;
}

std::vector<Tab> BrowserState::ArchiveTabs(ArchiveTabsRelative which, const std::string& id, Timestamp now) {
    const std::vector<std::string> ids = TabsToArchive(which, id);
    const auto location = Location(id);
    if (ids.empty() || !location || !location->space) return {};
    Space& space = spaces[*location->space];
    const std::set<std::string> going(ids.begin(), ids.end());
    // archiveToday(_:inSpace:): in their sidebar order, each with its place in Today.
    std::vector<Tab> tabs;
    std::vector<ClosedTab> closed;
    for (size_t i = 0; i < space.tabs.size(); ++i) {
        if (!going.contains(space.tabs[i].id)) continue;
        tabs.push_back(space.tabs[i]);
        closed.push_back(ClosedTab{space.tabs[i], space.id, static_cast<long long>(i), std::nullopt, std::nullopt, std::nullopt, {}});
    }
    AppendToArchive(std::move(closed), ArchiveReason::Manual, now);
    std::erase_if(space.tabs, [&](const Tab& tab) { return going.contains(tab.id); });
    if (space.selectedTabID && going.contains(*space.selectedTabID)) space.selectedTabID = id;
    NormalizeSplits();
    return tabs;
}

bool BrowserState::CanDuplicateFolder(const std::string& id) const {
    const auto found = FindFolderInSpaces(*this, id);
    return found && found->second->ephemeral != true && !found->second->live;
}

std::optional<std::string> BrowserState::DuplicateFolder(const std::string& id, Timestamp now) {
    if (!CanDuplicateFolder(id)) return std::nullopt;
    const auto found = FindFolderInSpaces(*this, id);
    std::optional<PinnedItem> copy = Copy(PinnedItem{*found->second}, now);
    if (!copy) return std::nullopt;
    std::string copyID = copy->Id();
    if (!InsertAfter(spaces[found->first].pinnedItems, *copy, id)) return std::nullopt;
    return copyID;
}

std::optional<std::string> BrowserState::CreateNestedFolder(const std::string& id, std::string name) {
    for (Space& space : spaces) {
        Folder* folder = pinned_tree::FindFolder(space.pinnedItems, id);
        if (!folder) continue;
        Folder nested;
        nested.id = NewUuid();
        nested.name = std::move(name);
        std::string nestedID = nested.id;
        folder->items.push_back(PinnedItem{std::move(nested)});
        folder->isExpanded = true;
        return nestedID;
    }
    return std::nullopt;
}

bool BrowserState::CanTurnFolderIntoSpace(const std::string& id) const {
    const auto found = FindFolderInSpaces(*this, id);
    return found && ClaudeMayCreateSpace(found->second->name) && !TabsIn(found->second->items).empty() && Plain(*found->second);
}

std::optional<std::string> BrowserState::TurnFolderIntoSpace(const std::string& id) {
    if (!CanTurnFolderIntoSpace(id)) return std::nullopt;
    const size_t s = FindFolderInSpaces(*this, id)->first;
    std::optional<Folder> folder = pinned_tree::RemoveFolder(spaces[s].pinnedItems, id);
    if (!folder) return std::nullopt;
    std::set<std::string> moved;
    for (const Tab* tab : TabsIn(folder->items)) moved.insert(tab->id);
    const Space source = spaces[s];
    // insertSpace(name:icon:theme:profile:at:): right after the folder's space, selected, with no
    // icon and the source's own `profile` (not the one it falls back to).
    Space space{NewUuid(), folder->name, "", source.theme, {}, {}, std::nullopt, {}, {}};
    if (auto profile = source.extra.find("profile"); profile != source.extra.end() && profile->second.AsString()) {
        space.extra.emplace("profile", *profile->second.AsString());
    }
    std::string spaceID = space.id;
    for (const SplitView& split : source.splits) {
        if (std::all_of(split.tabIDs.begin(), split.tabIDs.end(), [&](const std::string& tab) { return moved.contains(tab); })) {
            space.splits.push_back(split);
        }
    }
    const bool selectedMoved = source.selectedTabID && moved.contains(*source.selectedTabID);
    const std::vector<const Tab*> folderTabs = TabsIn(folder->items);
    space.selectedTabID = selectedMoved ? source.selectedTabID
                          : folderTabs.empty() ? std::nullopt
                                               : std::optional(folderTabs.front()->id);
    space.pinnedItems = std::move(folder->items);
    const size_t n = s + 1;
    spaces.insert(spaces.begin() + static_cast<std::ptrdiff_t>(n), std::move(space));
    selectedSpaceID = spaceID;
    if (selectedMoved) {
        const std::vector<const Tab*> left = spaces[s].AllTabs();
        spaces[s].selectedTabID = left.empty() ? std::nullopt : std::optional(left.front()->id);
    }
    NormalizeSplits();
    return spaceID;
}

// MARK: The menus

std::vector<SidebarMenuItem> TabMenu(const BrowserState& state, const std::string& tabID) {
    const auto location = state.Location(tabID);
    if (!location || location->section == TabSection::Favorite || !location->space) return {};
    const Tab& tab = *state.TabAt(*location);
    const bool pinned = location->section == TabSection::Pinned;
    std::vector<SidebarMenuItem> menu;
    // (Stop Claude and a separator first while Claude drives the tab: no automation on Windows.)
    menu.push_back(Item(C::AddToFavorites, "Add to Favorites"));
    menu.push_back(Item(C::TogglePin, pinned ? "Unpin Tab" : "Pin Tab"));
    // SidebarSpaceList's canReset: pinned && hasLeftPinnedURL.
    if (pinned && tab.HasLeftPinnedURL()) {
        menu.push_back(Item(C::BackToPinnedURL, "Back to Pinned URL"));
        menu.push_back(Item(C::SeparateFromPinnedTab, "Separate From Pinned Tab"));
    }
    if (pinned && tab.pinnedURL) menu.push_back(EditPinnedPage());
    // addCopyLinkItems: greyed out for a tab with no page yet.
    menu.push_back(Item(C::CopyLink, "Copy Link", tab.url.has_value()));
    menu.push_back(Item(C::CopyLinkAsMarkdown, "Copy link as Markdown", MarkdownLink(tab).has_value()));
    menu.push_back(Item(C::RenameTab, "Rename\xE2\x80\xA6"));
    // (Mute Tab / Unmute Tab while it plays or is muted: Windows doesn't follow pages' sound yet.)
    menu.push_back(kSeparator);
    // Arc's Add Split View on the tab that's on screen (visibleTabs: the selected split's panes, or
    // the selected tab), Open in Split View on one that isn't. Split view isn't ported.
    const Tab* selected = state.SelectedTab();
    bool visible = selected && selected->id == tabID;
    if (selected && !visible) {
        if (const SplitView* split = state.SplitContaining(selected->id)) {
            visible = std::find(split->tabIDs.begin(), split->tabIDs.end(), tabID) != split->tabIDs.end();
        }
    }
    menu.push_back(visible ? Item(C::AddSplitView, "Add Split View", false) : Item(C::OpenInSplitView, "Open in Split View", false));
    menu.push_back(Item(C::DuplicateTab, "Duplicate"));
    // SidebarMenu+MoveMenu: the root spaces, all but the tab's own enabled on the Mac. Windows can't
    // move a tab between spaces yet (Arc's cross-profile warning comes with it).
    std::vector<SidebarMenuItem> spaces;
    for (const Space& space : state.spaces) {
        SidebarMenuItem item = Item(C::MoveToSpace, LabelWithIcon(space), false);
        item.target = space.id;
        spaces.push_back(std::move(item));
    }
    menu.push_back(Submenu(C::MoveTo, "Move to", std::move(spaces), false));
    menu.push_back(kSeparator);
    menu.push_back(Item(C::CloseTab, pinned ? "Unload Tab" : "Close Tab"));
    // addArchiveTabsItems: Today's rows only, each greyed out with nothing on its side.
    if (location->section == TabSection::Unpinned) {
        using R = BrowserState::ArchiveTabsRelative;
        menu.push_back(Item(C::ArchiveOthers, "Archive Other Tabs", !state.TabsToArchive(R::Others, tabID).empty()));
        menu.push_back(Item(C::ArchiveBelow, "Archive Tabs Below", !state.TabsToArchive(R::Below, tabID).empty()));
        menu.push_back(Item(C::ArchiveAbove, "Archive Tabs Above", !state.TabsToArchive(R::Above, tabID).empty()));
    }
    return menu;
}

std::vector<SidebarMenuItem> FolderMenu(const BrowserState& state, const std::string& folderID) {
    const auto found = FindFolderInSpaces(state, folderID);
    if (!found) return {};
    const Folder& folder = *found->second;
    if (folder.live) {
        // addLiveFolderItems, with what Windows can show: live folders don't refresh here yet, so
        // their status line, filters and Repositories ▸ aren't built, and Refresh and Delete Live
        // Folder are disabled.
        return {Item(C::RefreshLiveFolder, "Refresh", false), kSeparator, Item(C::DeleteLiveFolder, "Delete Live Folder", false)};
    }
    std::vector<SidebarMenuItem> menu;
    // (Stop Claude and a separator while Claude works in it: no automation on Windows.) Claude's
    // folders are never copied or turned into a space.
    const bool claudeFolder = folder.ephemeral == true;
    if (!claudeFolder) {
        menu.push_back(Item(C::DuplicateFolder, "Duplicate", state.CanDuplicateFolder(folderID)));
        menu.push_back(kSeparator);
    }
    // Arc builds Archive Folder or Delete; Kite's archive holds tabs, not folders, so it's Delete.
    menu.push_back(Item(C::DeleteFolder, "Delete"));
    menu.push_back(kSeparator);
    menu.push_back(Item(C::NewNestedFolder, "New Nested Folder\xE2\x80\xA6"));
    if (!claudeFolder && ClaudeMayCreateSpace(folder.name)) {
        menu.push_back(Item(C::TurnFolderIntoSpace, "Turn \xE2\x80\x9C" + folder.name + "\xE2\x80\x9D into Space",
                            state.CanTurnFolderIntoSpace(folderID)));
    }
    const std::vector<const Tab*> tabs = TabsIn(folder.items);
    const bool links = std::any_of(tabs.begin(), tabs.end(), [](const Tab* tab) { return tab->url.has_value(); });
    menu.push_back(Item(C::CopyAllLinks, "Copy All Links", links));
    menu.push_back(Item(C::CopyAllLinksAsMarkdown, "Copy All Links as Markdown", links));
    // Arc's builder has no separator marker here; Kite keeps the one it had (inferred from grouping).
    menu.push_back(kSeparator);
    menu.push_back(Item(C::RenameFolder, "Rename\xE2\x80\xA6"));
    return menu;
}

std::vector<SidebarMenuItem> FavoriteMenu(const BrowserState& state, const std::string& tabID) {
    const auto location = state.Location(tabID);
    if (!location || location->section != TabSection::Favorite) return {};
    const Tab& tab = *state.TabAt(*location);
    std::vector<SidebarMenuItem> menu;
    menu.push_back(Item(C::RemoveFromFavorites, "Remove from Favorites"));
    if (tab.pinnedURL) menu.push_back(EditPinnedPage());
    // Always enabled here (FavoritePaneView's menu doesn't grey it out); with no page it copies nothing.
    menu.push_back(Item(C::CopyLink, "Copy Link"));
    menu.push_back(kSeparator);
    menu.push_back(Item(C::CloseTab, "Unload Tab"));
    return menu;
}

std::vector<SidebarMenuItem> SidebarMenu(const BrowserState& state, SidebarMenuKind kind, const std::string& id) {
    switch (kind) {
    case SidebarMenuKind::Tab: return TabMenu(state, id);
    case SidebarMenuKind::Folder: return FolderMenu(state, id);
    case SidebarMenuKind::Favorite: return FavoriteMenu(state, id);
    }
    return {};
}

std::string SidebarMenuLine(const std::vector<SidebarMenuItem>& items) {
    const auto entry = [](const SidebarMenuItem& item) {
        if (item.command == C::Separator) return std::string("---");
        return item.enabled ? item.title : "(" + item.title + ")";
    };
    std::string line;
    for (const SidebarMenuItem& item : items) {
        if (!line.empty()) line += " | ";
        if (!item.submenu) {
            line += entry(item);
            continue;
        }
        std::string title = item.title + " \xE2\x96\xB8";  // ▸
        if (!item.items.empty()) {
            std::string inner;
            for (const SidebarMenuItem& sub : item.items) {
                if (!inner.empty()) inner += " / ";
                inner += entry(sub);
            }
            title += " [" + inner + "]";
        }
        line += item.enabled ? title : "(" + title + ")";
    }
    return line;
}

const SidebarMenuItem* PickSidebarMenuItem(const std::vector<SidebarMenuItem>& items, std::string_view pick) {
    constexpr std::string_view kArrow = " \xE2\x96\xB8 ";
    for (const SidebarMenuItem& item : items) {
        if (item.command != C::Separator && !item.submenu && item.enabled && item.title == pick) return &item;
    }
    const size_t arrow = pick.find(kArrow);
    if (arrow == std::string_view::npos) return nullptr;
    const std::string_view parent = pick.substr(0, arrow), child = pick.substr(arrow + kArrow.size());
    for (const SidebarMenuItem& item : items) {
        if (!item.submenu || !item.enabled || item.title != parent) continue;
        for (const SidebarMenuItem& sub : item.items) {
            if (sub.command != C::Separator && sub.enabled && sub.title == child) return &sub;
        }
    }
    return nullptr;
}

std::optional<SidebarMenuTarget> SidebarMenuTargetAt(const std::vector<SidebarRow>& rows, float width, float height, float scroll,
                                                     float x, float y, float listTop) {
    const SidebarHit hit = SidebarHitTest(rows, width, height, scroll, x, y, listTop);
    switch (hit.target) {
    case SidebarHit::Target::Row:
    case SidebarHit::Target::PinnedChevron:
    case SidebarHit::Target::CloseButton:
    case SidebarHit::Target::ResetButton: break;
    default: return std::nullopt;
    }
    if (hit.row >= rows.size()) return std::nullopt;
    const SidebarRow& row = rows[hit.row];
    switch (row.kind) {
    case SidebarRow::Kind::Header: return SidebarMenuTarget{SidebarMenuTarget::Kind::Space, row.id};
    case SidebarRow::Kind::Tab: return SidebarMenuTarget{SidebarMenuTarget::Kind::Tab, row.id};
    case SidebarRow::Kind::Folder: return SidebarMenuTarget{SidebarMenuTarget::Kind::Folder, row.id};
    default: return std::nullopt;  // New Tab and the divider build no menu
    }
}

FolderDeletion FolderDeletionOf(const BrowserState& state, const std::string& folderID) {
    const Folder* folder = state.FolderByID(folderID);
    if (!folder || folder->live) return {};
    return {true, "Delete your \xE2\x80\x9C" + folder->name + "\xE2\x80\x9D folder?", "Deleting this folder will archive the tabs inside it.",
            "Delete Folder"};
}

}  // namespace kite
