// Editing spaces: renameSpace, insertSpace, setSpaceIcon, deleteSpace and moveSpace
// (BrowserState+ArcCommands.swift) and createFolder (BrowserState+Automation.swift); then the
// space menu, Delete Space and New Space (SpaceEditing.h).

#include <algorithm>

#include "core/SpaceEditing.h"
#include "core/SpaceIcon.h"
#include "core/Unicode.h"
#include "core/Uuid.h"

namespace kite {

void BrowserState::RenameSpace(const std::string& id, std::string_view name) {
    const std::string_view trimmed = unicode::Trim(name);
    const auto s = SpaceIndex(id);
    if (!s || trimmed.empty()) return;
    spaces[*s].name = std::string(trimmed);
}

std::string BrowserState::InsertSpace(std::string name, std::string icon, Theme theme, std::optional<std::string> profile) {
    Space space{NewUuid(), std::move(name), std::move(icon), std::move(theme), {}, {}, std::nullopt, {}, {}};
    if (profile) space.extra.emplace("profile", *profile);
    const size_t at = SelectedSpaceIndex() + 1;
    selectedSpaceID = space.id;
    spaces.insert(spaces.begin() + static_cast<std::ptrdiff_t>(std::min(at, spaces.size())), std::move(space));
    return selectedSpaceID;
}

void BrowserState::SetSpaceIcon(const std::string& id, std::string_view icon) {
    const auto s = SpaceIndex(id);
    if (!s) return;
    const std::string_view trimmed = unicode::Trim(icon);
    if (trimmed.starts_with(kImageIconPrefix)) {
        if (!IsValidIconImageName(trimmed.substr(kImageIconPrefix.size()))) return;
        spaces[*s].icon = std::string(trimmed);
    } else if (trimmed.starts_with(kSymbolIconPrefix)) {
        spaces[*s].icon = std::string(trimmed);
    } else {
        // Swift's icon.first: one Character, however many scalars it takes.
        const std::vector<std::u32string> characters = unicode::Characters(trimmed);
        spaces[*s].icon = characters.empty() ? std::string() : unicode::Encode(characters.front());
    }
}

void BrowserState::DeleteSpace(std::string id) {
    const auto s = SpaceIndex(id);
    if (spaces.size() <= 1 || !s) return;
    const bool wasSelected = selectedSpaceID == id;
    spaces.erase(spaces.begin() + static_cast<std::ptrdiff_t>(*s));
    if (wasSelected) selectedSpaceID = spaces[*s > 0 ? *s - 1 : 0].id;
}

void BrowserState::MoveSpace(const std::string& id, size_t index) {
    const auto s = SpaceIndex(id);
    if (!s) return;
    Space space = std::move(spaces[*s]);
    spaces.erase(spaces.begin() + static_cast<std::ptrdiff_t>(*s));
    spaces.insert(spaces.begin() + static_cast<std::ptrdiff_t>(std::min(index, spaces.size())), std::move(space));
}

std::string BrowserState::CreateFolder(std::string name, size_t space) {
    if (space >= spaces.size()) return {};
    Folder folder;
    folder.id = NewUuid();
    folder.name = std::move(name);
    std::string id = folder.id;
    spaces[space].pinnedItems.push_back(PinnedItem{std::move(folder)});
    return id;
}

// MARK: The menu, Delete Space and New Space (SpaceEditing.h)

std::vector<SpaceMenuItem> SpaceMenu(const BrowserState& state, const std::string& spaceID) {
    if (!state.SpaceIndex(spaceID)) return {};
    using C = SpaceMenuItem::Command;
    const SpaceMenuItem separator{};
    return {
        {C::ChangeIcon, "Change Space Icon\xE2\x80\xA6", true, false},
        {C::Rename, "Rename Space\xE2\x80\xA6", true, false},
        {C::Describe, "What's This Space For?\xE2\x80\xA6", false, false},
        {C::EditTheme, "Edit Theme Color\xE2\x80\xA6", false, false},
        {C::SetProfile, "Set Profile", false, true},
        separator,
        {C::NewFolder, "New Folder", true, false},
        // Arc's binary lists Live Folders right after New Folder.
        {C::LiveFolders, "Live Folders", false, true},
        separator,
        {C::Delete, "Delete Space", state.spaces.size() >= 2, false},
    };
}

std::string SpaceMenuLine(const std::vector<SpaceMenuItem>& items) {
    std::string line;
    for (const SpaceMenuItem& item : items) {
        if (!line.empty()) line += " | ";
        if (item.command == SpaceMenuItem::Command::Separator) {
            line += "---";
            continue;
        }
        const std::string title = item.submenu ? item.title + " \xE2\x96\xB8" : item.title;  // ▸
        line += item.enabled ? title : "(" + title + ")";
    }
    return line;
}

SpaceDeletion DeletionOf(const BrowserState& state, const std::string& spaceID) {
    const auto s = state.SpaceIndex(spaceID);
    if (!s || state.spaces.size() < 2) return {};
    const Space& space = state.spaces[*s];
    if (space.AllTabs().empty()) return {SpaceDeletion::Kind::Now, {}, {}};
    return {SpaceDeletion::Kind::Ask, "Delete \xE2\x80\x9C" + space.name + "\xE2\x80\x9D?", "Its pinned and unpinned tabs are closed."};
}

std::optional<std::string> NewSpace(BrowserState& state, std::string_view name) {
    const std::string_view trimmed = unicode::Trim(name);
    if (trimmed.empty()) return std::nullopt;
    const Space& current = state.SelectedSpace();
    std::optional<std::string> profile;
    if (auto it = current.extra.find("profile"); it != current.extra.end() && it->second.AsString()) profile = *it->second.AsString();
    const Theme theme = current.theme;
    return state.InsertSpace(std::string(trimmed), "", theme, std::move(profile));
}

}  // namespace kite
