#pragma once
// Import from Arc, from Arc's folder to the session: the model side of KiteMac's
// ArcImportController.swift, which both Kite.exe (a command) and `kitecore import-arc` run.
// Finding Arc's folder (or taking a picked one), reading its sidebar with the backup fallback,
// reading the other files, the confirmation's lines, and the import itself.
//
// The session's changes go into the BrowserState the caller saves; the shortcut changes and Air
// Traffic Control routes go into the profile's keybindings.json and LinkRouting.json, as the
// Mac's KeyBindingsStore and AirTrafficControlStore keep them; each Arc profile's history goes
// into the history of the Kite profile its spaces went to (MergeHistories, core/HistoryStore.h).
//
// Reading takes a moment (Arc's files, the Web Data and History databases), so the app runs
// Read* off its UI thread. Delete with ArcImport.h once Arc has shut down.

#include <atomic>
#include <chrono>
#include <cstddef>
#include <filesystem>
#include <map>
#include <optional>
#include <string>
#include <variant>
#include <vector>

#include "core/ArcHistoryImport.h"
#include "core/ArcImport.h"
#include "core/ArcImportFiles.h"
#include "core/HistoryStore.h"
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
    // For a backup: why the current file didn't do, when it's too large ("too large: …").
    std::string currentTooLarge;
};
// Arc's files are read whole, up to this: the Mac reads any size, and Arc can't export them
// again after it shuts down, so the cap is far above any real file (an archive grows with every
// auto-archive). A file past it is reported as too large, never as missing.
inline constexpr size_t kMaxArcFileBytes = size_t{1} << 30;

// How Arc's files are read: imported tabs' time, the size cap (tests make it small), and a flag
// the app sets to stop a read whose window is closing (checked between files, and before each
// leaf page of a History).
struct ReadOptions {
    Timestamp now = Now();
    size_t maxFileBytes = kMaxArcFileBytes;
    const std::atomic<bool>* cancel = nullptr;
    // Whether to read each profile's History: not when there's no history to put it in (the
    // Mac's incognito windows).
    bool history = true;
    // The most pages read from each profile's History (History::kMaxEntries; tests make it small).
    size_t maxHistoryEntries = History::kMaxEntries;
};

// Why no sidebar imported, in the Mac's words. `failure` none: no file could be read.
struct LoadError {
    std::optional<Failure> failure;
    std::string message;
    std::string detail;
    bool tooLarge = false;  // the sidebar is past ReadOptions::maxFileBytes
    bool internal = false;  // the read itself failed (out of memory, say): no folder would help
};
// An exception out of a read (ReadAuto, ReadPicked) as a LoadError: callers on a worker catch
// everything, so a crafted file can never end the process.
LoadError ReadFailed(const char* what);

// Arc's sidebar from `folder`: StorableSidebar.json, read again a moment later if it was cut
// short (Arc writing it), then Arc's dated backups newest first. Failing that, why the current
// file didn't import.
std::variant<Sidebar, LoadError> LoadSidebar(const std::filesystem::path& folder, const ReadOptions& options = {});

// A file next to the sidebar that's there but didn't come over, and why ("too large: …", "Arc
// is writing it…"; empty when it just doesn't read).
struct FileProblem {
    std::string file;
    std::string reason;
    bool operator==(const FileProblem&) const = default;
};

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
    // Each Arc profile's history (Default and the profiles the sidebar's spaces use), by Arc
    // profile folder: the ones whose History read.
    std::map<std::string, HistoryRead> histories;
    size_t historyCap = History::kMaxEntries;  // the most read from each (ReadOptions::maxHistoryEntries)
    // Files that are there but didn't come over, for the confirmation and the summary.
    std::vector<FileProblem> unreadable;
};

// --auto, and the app's first try: Arc's folder. A missing folder is a LoadError too.
std::variant<Plan, LoadError> ReadAuto(const std::optional<std::filesystem::path>& arcDirectory, const ReadOptions& options = {});
// A picked path: Arc's folder, the folder holding it, or a sidebar file of any name (the other
// files then come from Arc's own folder, `arcDirectory`, when the file's isn't Arc's).
std::variant<Plan, LoadError> ReadPicked(const std::filesystem::path& picked, const std::optional<std::filesystem::path>& arcDirectory,
                                         const ReadOptions& options = {});
// The rest of Arc's files, for a sidebar read from `folder`.
Plan ReadPlan(Sidebar sidebar, const std::filesystem::path& folder, const ReadOptions& options = {});

// The unnamed spaces and their tabs, for the confirmation's choice.
std::pair<int, int> UntitledCounts(const Plan& plan);

struct ImportOptions {
    // Whether Arc's unnamed spaces come over. None: the Mac's default (left out), except when
    // Arc has no named space at all, as Arc for Windows often hasn't: then they're all there
    // is, and they come over (Kite for Windows' own choice).
    std::optional<bool> includeUntitled;
};
bool IncludesUntitled(const Plan& plan, ImportOptions options);

// What the Mac's confirmation says: what was found and what will and won't come over, one
// paragraph a line, counting the unnamed spaces when they'd come over.
std::vector<std::string> ConfirmLines(const Plan& plan, const BrowserState& state, bool includeUntitled);

// An import done in the session but not yet in the profile's other files.
struct Imported {
    json::Object source, found, imported;
    json::Array skipped, notes;
    std::vector<KeyBindingOverride> keyBindings;  // for keybindings.json
    std::optional<LinkRouting> routes;            // for LinkRouting.json, to spaces Kite has
    // For MergeHistories: each Arc profile's pages with the Kite profile folder they go to (two
    // Arc profiles can go to one).
    struct PendingHistory {
        std::string kiteProfile;
        std::vector<HistoryEntry> entries;
    };
    std::vector<PendingHistory> histories;
};

// The import (the Mac's perform), in two steps so the session is saved before anything else is
// written: Import puts spaces, favorites and profiles, Site Search, the archive and Arc's
// settings into `state`. The caller saves the session, then WriteProfileFiles merges the
// shortcut changes and routes into `profileDirectory`'s keybindings.json and LinkRouting.json.
Imported Import(BrowserState& state, const Plan& plan, ImportOptions options = {});
void WriteProfileFiles(Imported& imported, const std::filesystem::path& profileDirectory);
// Then (in any order after Import) each Arc profile's history into its Kite profile's store, as
// the Mac's perform does (History::Merge: a page already there keeps the later visit and the
// higher count, so importing again doubles nothing). Counts what was new, and what Kite's
// 20,000-page cap then dropped, into the summary; the stores save at once. The stores must have
// been started (HistoryStores::Start). `waitForLoads`: how long to wait for their files to be
// read first, so the counts are against what they hold; false, and nothing merged, when they
// weren't read in that time. Zero (the app's) doesn't wait: a store whose file isn't read yet
// queues the pages and merges them over it once it is (new pages aren't counted then).
bool MergeHistories(Imported& imported, HistoryStores& stores,
                    std::chrono::milliseconds waitForLoads = std::chrono::milliseconds::zero());
// Counts per kind of what came over, what was skipped and why, and the notes. Never Arc's
// titles, addresses or names.
json::Value Summary(const Imported& imported);
// When a backup was last written, as the Mac's confirmation says it: "November 1, 2026 at 9:05 PM".
std::string BackupDateText(Timestamp time);

}  // namespace kite::arc_import
