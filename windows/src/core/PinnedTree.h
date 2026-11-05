#pragma once
// The pinned section's tree of tabs and folders, as the model's edits walk it: the Mac's
// [PinnedItem] helpers (Models.swift's updateTab, removeTab and updateFolder;
// BrowserState+Automation.swift's removeFolder, folders(inSpace:) and dropEmptyEphemeralFolders;
// PinnedURL.swift's contains(tab:) and expandFolders(containing:)). Core-internal: closing
// (TabClosing.cpp), pinning and folders (TabEditing.cpp) and pinned URLs (PinnedURL.cpp) share it.
// Each walk is depth first and stops at the first match, O(items) at most.

#include <optional>
#include <string>
#include <vector>

#include "core/Models.h"

namespace kite::pinned_tree {

const Folder* FindFolder(const std::vector<PinnedItem>& items, const std::string& id);
Folder* FindFolder(std::vector<PinnedItem>& items, const std::string& id);
// The folder, at any depth, whose own items hold `id` (a tab or folder).
const Folder* ParentFolder(const std::vector<PinnedItem>& items, const std::string& id);
// Takes the tab out of the tree, at any depth ([PinnedItem].removeTab).
std::optional<Tab> RemoveTab(std::vector<PinnedItem>& items, const std::string& id);
// Takes the folder (with everything in it) out of the tree, at any depth.
std::optional<Folder> RemoveFolder(std::vector<PinnedItem>& items, const std::string& id);
// Claude's folders (ephemeral) left empty go, from the inside out.
void DropEmptyEphemeralFolders(std::vector<PinnedItem>& items);
// Every folder in the tree, depth first (folders(inSpace:)).
void CollectFolders(const std::vector<PinnedItem>& items, std::vector<const Folder*>& out);
// Whether the item is the tab, or a folder holding it at any depth (PinnedItem.contains(tab:)).
bool Contains(const PinnedItem& item, const std::string& tabID);
// Opens every folder on the way down to the tab. Whether the tab was found.
bool ExpandFolders(std::vector<PinnedItem>& items, const std::string& tabID);

}  // namespace kite::pinned_tree
