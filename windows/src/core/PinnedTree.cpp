// See PinnedTree.h.

#include "core/PinnedTree.h"

#include <algorithm>

namespace kite::pinned_tree {

namespace {

// Shared by the const and non-const overloads, so neither needs a const_cast.
template <typename Items>
auto* FindFolderIn(Items& items, const std::string& id) {
    using FolderPtr = decltype(std::get_if<Folder>(&items.front().value));
    for (auto& item : items) {
        auto* folder = std::get_if<Folder>(&item.value);
        if (!folder) continue;
        if (folder->id == id) return folder;
        if (FolderPtr found = FindFolderIn(folder->items, id)) return found;
    }
    return FolderPtr{nullptr};
}

bool IsEmptyEphemeralFolder(const PinnedItem& item) {
    const Folder* folder = std::get_if<Folder>(&item.value);
    return folder && folder->ephemeral == true && folder->items.empty();
}

}  // namespace

const Folder* FindFolder(const std::vector<PinnedItem>& items, const std::string& id) { return FindFolderIn(items, id); }
Folder* FindFolder(std::vector<PinnedItem>& items, const std::string& id) { return FindFolderIn(items, id); }

const Folder* ParentFolder(const std::vector<PinnedItem>& items, const std::string& id) {
    for (const PinnedItem& item : items) {
        const Folder* folder = std::get_if<Folder>(&item.value);
        if (!folder) continue;
        for (const PinnedItem& child : folder->items) {
            if (child.Id() == id) return folder;
        }
        if (const Folder* found = ParentFolder(folder->items, id)) return found;
    }
    return nullptr;
}

std::optional<Tab> RemoveTab(std::vector<PinnedItem>& items, const std::string& id) {
    for (auto it = items.begin(); it != items.end(); ++it) {
        if (Tab* tab = std::get_if<Tab>(&it->value); tab && tab->id == id) {
            Tab removed = std::move(*tab);
            items.erase(it);
            return removed;
        }
        if (Folder* folder = std::get_if<Folder>(&it->value)) {
            if (auto removed = RemoveTab(folder->items, id)) return removed;
        }
    }
    return std::nullopt;
}

std::optional<Folder> RemoveFolder(std::vector<PinnedItem>& items, const std::string& id) {
    for (auto it = items.begin(); it != items.end(); ++it) {
        Folder* folder = std::get_if<Folder>(&it->value);
        if (!folder) continue;
        if (folder->id == id) {
            Folder removed = std::move(*folder);
            items.erase(it);
            return removed;
        }
        if (auto removed = RemoveFolder(folder->items, id)) return removed;
    }
    return std::nullopt;
}

void DropEmptyEphemeralFolders(std::vector<PinnedItem>& items) {
    for (PinnedItem& item : items) {
        if (Folder* folder = std::get_if<Folder>(&item.value)) DropEmptyEphemeralFolders(folder->items);
    }
    std::erase_if(items, IsEmptyEphemeralFolder);
}

void CollectFolders(const std::vector<PinnedItem>& items, std::vector<const Folder*>& out) {
    for (const PinnedItem& item : items) {
        const Folder* folder = std::get_if<Folder>(&item.value);
        if (!folder) continue;
        out.push_back(folder);
        CollectFolders(folder->items, out);
    }
}

bool Contains(const PinnedItem& item, const std::string& tabID) {
    if (const Tab* tab = std::get_if<Tab>(&item.value)) return tab->id == tabID;
    const auto& items = std::get<Folder>(item.value).items;
    return std::any_of(items.begin(), items.end(), [&](const PinnedItem& child) { return Contains(child, tabID); });
}

bool ExpandFolders(std::vector<PinnedItem>& items, const std::string& tabID) {
    for (PinnedItem& item : items) {
        if (const Tab* tab = std::get_if<Tab>(&item.value)) {
            if (tab->id == tabID) return true;
            continue;
        }
        Folder& folder = std::get<Folder>(item.value);
        if (!Contains(item, tabID)) continue;
        folder.isExpanded = true;
        ExpandFolders(folder.items, tabID);
        return true;
    }
    return false;
}

}  // namespace kite::pinned_tree
