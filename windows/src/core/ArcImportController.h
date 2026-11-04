#pragma once
// Import from Arc, from Arc's folder to the session: the model side of KiteMac's
// ArcImportController.swift, which both Kite.exe (a command) and `kitecore import-arc` run.
// Finding Arc's folder (or taking a picked one), reading its sidebar with the backup fallback,
// reading the other files, the confirmation's lines, and the import itself.
//
// The session's changes go into the BrowserState the caller saves; the shortcut changes and Air
// Traffic Control routes go into the profile's keybindings.json and LinkRouting.json, as the
// Mac's KeyBindingsStore and AirTrafficControlStore keep them.
//
// Reading takes a moment (Arc's files, the Web Data database), so the app runs Read* off its UI
// thread. Delete with ArcImport.h once Arc has shut down.

#include <filesystem>
#include <map>
#include <optional>
#include <string>
#include <variant>
#include <vector>

#include "core/ArcImport.h"
#include "core/ArcImportFiles.h"
#include "core/Json.h"
#include "core/Models.h"

namespace kite::arc_import {

// Where Arc keeps its data. A test run (KITE_SUPPORT_PATH set) can point KITE_ARC_DATA_PATH at
// a folder of hand-made files instead, as on the Mac. Otherwise Arc for Windows' folder in its
// package, %LOCALAPPDATA%\Packages\TheBrowserCompany.Arc_*\LocalCache\Local\Arc; none when
// there's no such package.
std::optional<std::filesystem::path> ArcDirectory(const std::optional<std::filesystem::path>& supportOverride,
                                                  const std::optional<std::filesystem::path>& arcDataOverride,
                                                  const std::optional<std::filesystem::path>& localAppData);
// Arc's own folder rather than somewhere a copy of one file was kept.
bool LooksLikeArc(const std::filesystem::path& folder);

// A sidebar that read: from `file` (StorableSidebar.json, a backup's name, or a picked file's),
// and for one of Arc's backups, when it was last written (none when that isn't known).
struct Sidebar {
    Result result;
    std::string file;
    bool isBackup = false;
    std::optional<Timestamp> backup;
};
// Why no sidebar imported, in the Mac's words. `failure` none: no file could be read.
struct LoadError {
    std::optional<Failure> failure;
    std::string message;
    std::string detail;
};

// Arc's sidebar from `folder`: StorableSidebar.json, read again a moment later if it was cut
// short (Arc writing it), then Arc's dated backups newest first. Failing that, why the current
// file didn't import.
std::variant<Sidebar, LoadError> LoadSidebar(const std::filesystem::path& folder, Timestamp now = Now());

// Everything Import from Arc reads, from the sidebar's folder (`folder`) and the files next to it.
struct Plan {
    Sidebar sidebar;
    std::filesystem::path folder;  // where the other files came from
    std::vector<SiteSearch> siteSearches;
    std::vector<KeyBindingOverride> keyBindings;
    std::vector<ClosedTab> archive;
    std::optional<LinkRouting> routes;
    std::map<std::string, std::string> profileNames;
    Settings settings;
    // Files that are there but didn't read, by name, for the summary.
    std::vector<std::string> unreadable;
};

// --auto, and the app's first try: Arc's folder. A missing folder is a LoadError too.
std::variant<Plan, LoadError> ReadAuto(const std::optional<std::filesystem::path>& arcDirectory, Timestamp now = Now());
// A picked path: Arc's folder, the folder holding it, or a sidebar file of any name (the other
// files then come from Arc's own folder, `arcDirectory`, when the file's isn't Arc's).
std::variant<Plan, LoadError> ReadPicked(const std::filesystem::path& picked, const std::optional<std::filesystem::path>& arcDirectory,
                                         Timestamp now = Now());
// The rest of Arc's files, for a sidebar read from `folder`.
Plan ReadPlan(Sidebar sidebar, const std::filesystem::path& folder);

// What the Mac's confirmation says: what was found and what will and won't come over, one
// paragraph a line, before the user picks whether to include the unnamed spaces.
std::vector<std::string> ConfirmLines(const Plan& plan, const BrowserState& state);
// The unnamed spaces and their tabs, for the confirmation's choice.
std::pair<int, int> UntitledCounts(const Plan& plan);

struct ImportOptions {
    bool includeUntitled = false;
};
// The import (the Mac's perform): spaces, favorites and profiles, Site Search, the archive and
// Arc's settings into `state`; shortcut changes and routes into `profileDirectory`'s files.
// Returns the summary: counts per kind of what came over, and what was skipped and why.
json::Value Import(BrowserState& state, const Plan& plan, const std::filesystem::path& profileDirectory, ImportOptions options = {});

}  // namespace kite::arc_import
