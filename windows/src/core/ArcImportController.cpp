// The model side of KiteMac's ArcImportController.swift; see ArcImportController.h.

#include "core/ArcImportController.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <ctime>
#include <set>
#include <thread>

#include "core/AirTrafficControl.h"
#include "core/Files.h"
#include "core/Plist.h"
#include "core/Profiles.h"
#include "core/SQLiteReader.h"

namespace kite::arc_import {

namespace fs = std::filesystem;

namespace {

constexpr const char* kHelp =
    "Choose Arc's folder (%LOCALAPPDATA%\\Packages\\TheBrowserCompany.Arc_\xE2\x80\xA6\\LocalCache\\Local\\Arc), "
    "or StorableSidebar.json in it.";

bool Exists(const fs::path& file) {
    std::error_code error;
    return fs::exists(file, error);
}

std::vector<std::string> FileNames(const fs::path& folder) {
    std::vector<std::string> names;
    std::error_code error;
    for (fs::directory_iterator it(folder, error), end; !error && it != end; it.increment(error)) names.push_back(PathText(it->path().filename()));
    return names;
}

bool Cancelled(const ReadOptions& options) { return options.cancel && options.cancel->load(); }

LoadError CancelledError() { return {std::nullopt, "Import from Arc stopped.", "The window closed while Arc's files were read."}; }

// "1100 MB", or "20 KB" under a megabyte; rounded up.
std::string Size(uint64_t bytes) {
    if (bytes >= (uint64_t{1} << 20)) return std::to_string((bytes + (1 << 20) - 1) >> 20) + " MB";
    return std::to_string((bytes + 1023) >> 10) + " KB";
}

// "too large: 1100 MB, Kite reads up to 1024 MB".
std::string TooLarge(uint64_t size, size_t cap) { return "too large: " + Size(size) + ", Kite reads up to " + Size(cap); }

// One sidebar file: its result, or why not (no failure: it couldn't be read at all; with
// `tooLarge`, past the cap).
struct SidebarRead {
    std::optional<Result> result;
    std::optional<Failure> failure;
    std::optional<uint64_t> tooLarge;
};

SidebarRead ReadSidebar(const fs::path& file, const ReadOptions& options) {
    auto read = ReadFileOrProblem(file, options.maxFileBytes);
    if (auto* problem = std::get_if<ReadProblem>(&read)) {
        SidebarRead out;
        if (problem->kind == ReadProblem::Kind::TooLarge) out.tooLarge = problem->size;
        return out;
    }
    auto parsed = Parse(std::get<std::string>(read), options.now);
    if (auto* failure = std::get_if<Failure>(&parsed)) return {std::nullopt, *failure, std::nullopt};
    return {std::move(std::get<Result>(parsed)), std::nullopt, std::nullopt};
}

// A file Arc keeps next to the sidebar: its text, or none, noting in `plan` why one that's
// there didn't read.
std::optional<std::string> ReadArcFile(const fs::path& file, const ReadOptions& options, Plan& plan) {
    auto read = ReadFileOrProblem(file, options.maxFileBytes);
    if (auto* text = std::get_if<std::string>(&read)) return std::move(*text);
    const ReadProblem& problem = std::get<ReadProblem>(read);
    if (problem.kind == ReadProblem::Kind::TooLarge) plan.unreadable.push_back({PathText(file.filename()), TooLarge(problem.size, options.maxFileBytes)});
    else if (problem.kind == ReadProblem::Kind::Unreadable) plan.unreadable.push_back({PathText(file.filename()), ""});
    return std::nullopt;
}

// Whether SQLite is in the middle of writing the database `journal` sits beside: a hot journal
// (IsHotJournal, its first 8 bytes). One that's there but can't be read counts as hot, so a
// half-written database is never trusted.
bool JournalIsHot(const fs::path& journal) {
    std::error_code error;
    if (!fs::exists(journal, error)) return static_cast<bool>(error);
    if (!fs::is_regular_file(journal, error)) return true;
    const auto size = fs::file_size(journal, error);
    if (error) return true;
    if (size == 0) return false;
    auto head = ReadFilePrefix(journal, 8);
    return !head || sqlite::IsHotJournal(*head);
}

std::string FileProblemText(const FileProblem& p) { return p.reason.empty() ? p.file : p.file + " (" + p.reason + ")"; }

// When a file was last written, as a Timestamp.
std::optional<Timestamp> Modified(const fs::path& file) {
    std::error_code error;
    const auto written = fs::last_write_time(file, error);
    if (error) return std::nullopt;
    // file_clock to system_clock by the clocks' offset now (clock_cast isn't everywhere yet).
    const auto system = std::chrono::system_clock::now() + (written - fs::file_time_type::clock::now());
    return FromUnixTime(std::chrono::duration<double>(system.time_since_epoch()).count());
}

LoadError NoSpaces() { return {Failure::NoSpaces, "There are no spaces to import.", "Arc's sidebar has no spaces with tabs in them."}; }

std::string Count(size_t n, const std::string& noun) { return std::to_string(n) + " " + noun + (n == 1 ? "" : "s"); }

// "a", "a and b", "a, b and c".
std::string List(const std::vector<std::string>& parts) {
    if (parts.empty()) return "";
    std::string out = parts[0];
    for (size_t i = 1; i < parts.size(); ++i) out += (i + 1 == parts.size() ? " and " : ", ") + parts[i];
    return out;
}

bool IsUntitled(const Plan& plan, const Space& space) { return plan.sidebar.result.untitledSpaceIDs.contains(space.id); }
bool Imports(const Plan& plan, const Space& space, bool includeUntitled) { return includeUntitled || !IsUntitled(plan, space); }

// The Arc profiles of the spaces that import, in the order the spaces use them.
std::vector<std::string> ImportedProfiles(const Plan& plan, bool includeUntitled) {
    if (!includeUntitled) return plan.sidebar.result.NamedSpaceProfiles();
    std::vector<std::string> out;
    for (const Space& space : plan.sidebar.result.spaces) {
        const std::string profile = SpaceProfile(space).value_or(Profile::kDefaultDirectory);
        if (std::find(out.begin(), out.end(), profile) == out.end()) out.push_back(profile);
    }
    return out;
}

int CountFolders(const std::vector<PinnedItem>& items) {
    int n = 0;
    for (const PinnedItem& item : items) {
        if (auto* folder = std::get_if<Folder>(&item.value)) n += 1 + CountFolders(folder->items);
    }
    return n;
}

// The routes that will come over: to a space that imports or one Kite already has.
std::optional<LinkRouting> ShownRoutes(const Plan& plan, const BrowserState& state, bool includeUntitled) {
    if (!plan.routes) return std::nullopt;
    std::set<std::string> ids;
    for (const Space& space : plan.sidebar.result.spaces) {
        if (Imports(plan, space, includeUntitled)) ids.insert(space.id);
    }
    for (const Space& space : state.spaces) ids.insert(space.id);
    return plan.routes->Keeping(ids);
}

std::string IconsNote(size_t n) {
    const bool one = n == 1;
    return std::to_string(n) + " space icon" + (one ? " is" : "s are") + " from Arc's own icon set, which Kite doesn't have, so " +
           (one ? "it gets" : "they get") + " a stand-in.";
}

json::Value Skipped(const std::string& kind, std::optional<size_t> count, const std::string& reason) {
    json::Object o{{"kind", kind}, {"reason", reason}};
    if (count) o.emplace("count", *count);
    return json::Value(std::move(o));
}

}  // namespace

// Date.formatted(date: .long, time: .shortened) in English: "November 1, 2026 at 9:05 PM".
std::string BackupDateText(Timestamp t) {
    static constexpr const char* kMonths[] = {"January", "February", "March",     "April",   "May",      "June",
                                              "July",    "August",   "September", "October", "November", "December"};
    const std::time_t unix = static_cast<std::time_t>(t + 978307200.0);
    std::tm local{};
#ifdef _WIN32
    if (localtime_s(&local, &unix) != 0) return "an earlier date";
#else
    if (!localtime_r(&unix, &local)) return "an earlier date";
#endif
    if (local.tm_mon < 0 || local.tm_mon > 11) return "an earlier date";
    const int hour = local.tm_hour % 12 == 0 ? 12 : local.tm_hour % 12;
    char minutes[8];
    std::snprintf(minutes, sizeof minutes, "%02d", local.tm_min);
    return std::string(kMonths[local.tm_mon]) + " " + std::to_string(local.tm_mday) + ", " + std::to_string(local.tm_year + 1900) + " at " +
           std::to_string(hour) + ":" + minutes + (local.tm_hour < 12 ? " AM" : " PM");
}

std::optional<fs::path> ArcDirectory(const std::optional<fs::path>& supportOverride, const std::optional<fs::path>& arcDataOverride,
                                     const std::optional<fs::path>& localAppData) {
    if (supportOverride && arcDataOverride && !arcDataOverride->empty()) return *arcDataOverride;
    if (!localAppData || localAppData->empty()) return std::nullopt;
    std::vector<fs::path> packages;
    std::error_code error;
    for (fs::directory_iterator it(*localAppData / "Packages", error), end; !error && it != end; it.increment(error)) {
        if (PathText(it->path().filename()).starts_with("TheBrowserCompany.Arc_")) packages.push_back(it->path());
    }
    std::sort(packages.begin(), packages.end());
    for (const fs::path& package : packages) {
        const fs::path folder = package / "LocalCache" / "Local" / "Arc";
        if (fs::is_directory(folder, error)) return folder;
    }
    return std::nullopt;
}

bool LooksLikeArc(const fs::path& folder) {
    const auto names = FileNames(folder);
    return std::find(names.begin(), names.end(), "User Data") != names.end() &&
           std::any_of(names.begin(), names.end(), [](const std::string& n) { return n.starts_with("StorableSidebar"); });
}

std::variant<Sidebar, LoadError> LoadSidebar(const fs::path& folder, const ReadOptions& options) {
    const auto candidates = SidebarCandidates(FileNames(folder));
    auto current = ReadSidebar(folder / candidates[0], options);
    for (int attempt = 0; attempt < 2 && !Cancelled(options); ++attempt) {
        // Only a cut-short file can be different a moment later.
        if (current.result || current.failure != Failure::NotJSON) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        current = ReadSidebar(folder / candidates[0], options);
    }
    if (current.result) return Sidebar{std::move(*current.result), candidates[0], false, std::nullopt};
    if (!TriesBackup(current.failure)) return NoSpaces();
    for (size_t i = 1; i < candidates.size(); ++i) {
        if (Cancelled(options)) return CancelledError();
        auto backup = ReadSidebar(folder / candidates[i], options);
        if (backup.result) {
            // When its contents were last written, which can be well before the name's date.
            auto when = Modified(folder / candidates[i]);
            if (!when) when = BackupDate(candidates[i]);
            return Sidebar{std::move(*backup.result), candidates[i], true, when,
                           current.tooLarge ? TooLarge(*current.tooLarge, options.maxFileBytes) : std::string()};
        }
    }
    if (current.tooLarge) {
        return LoadError{std::nullopt, candidates[0] + " is too large for Kite to read (" + TooLarge(*current.tooLarge, options.maxFileBytes) + ").", kHelp,
                         true};
    }
    return LoadError{current.failure, "That folder has no Arc sidebar Kite can read.", kHelp};
}

std::variant<Plan, LoadError> ReadAuto(const std::optional<fs::path>& arcDirectory, const ReadOptions& options) {
    std::error_code error;
    if (!arcDirectory || !fs::is_directory(*arcDirectory, error)) return LoadError{std::nullopt, "Kite couldn't find Arc's data.", kHelp};
    auto loaded = LoadSidebar(*arcDirectory, options);
    if (auto* failed = std::get_if<LoadError>(&loaded)) {
        // No spaces, too large or stopped say so; anything else is the Mac's "couldn't read".
        if (failed->failure == Failure::NoSpaces || failed->tooLarge || Cancelled(options)) return *failed;
        return LoadError{failed->failure, "Kite couldn't read Arc's data.", kHelp};
    }
    Plan plan = ReadPlan(std::move(std::get<Sidebar>(loaded)), *arcDirectory, options);
    if (Cancelled(options)) return CancelledError();
    return plan;
}

std::variant<Plan, LoadError> ReadPicked(const fs::path& picked, const std::optional<fs::path>& arcDirectory, const ReadOptions& options) {
    std::error_code error;
    const bool isFolder = fs::is_directory(picked, error);
    fs::path folder = isFolder ? picked : picked.parent_path();
    if (isFolder) {
        // The folder holding Arc's: the Arc folder in it.
        if (!LooksLikeArc(folder) && LooksLikeArc(folder / "Arc")) folder /= "Arc";
    } else if (!LooksLikeArc(folder) && arcDirectory) {
        // A copy kept elsewhere: the other files still come from Arc's own folder.
        folder = *arcDirectory;
    }
    std::variant<Sidebar, LoadError> loaded = LoadError{};
    if (isFolder) {
        loaded = LoadSidebar(folder, options);
    } else {
        auto read = ReadSidebar(picked, options);
        if (read.result) {
            loaded = Sidebar{std::move(*read.result), PathText(picked.filename()), false, std::nullopt};
        } else if (read.tooLarge) {
            return LoadError{std::nullopt, PathText(picked.filename()) + " is too large for Kite to read (" + TooLarge(*read.tooLarge, options.maxFileBytes) + ").",
                             kHelp, true};
        } else {
            loaded = LoadError{read.failure, "", ""};
        }
    }
    if (auto* failed = std::get_if<LoadError>(&loaded)) {
        if (failed->failure == Failure::NoSpaces) return NoSpaces();
        if (Cancelled(options) || failed->tooLarge) return *failed;
        if (!isFolder) return LoadError{failed->failure, PathText(picked.filename()) + " isn't Arc's sidebar.", kHelp};
        return LoadError{failed->failure, "That folder has no Arc sidebar Kite can read.", kHelp};
    }
    Plan plan = ReadPlan(std::move(std::get<Sidebar>(loaded)), folder, options);
    if (Cancelled(options)) return CancelledError();
    return plan;
}

Plan ReadPlan(Sidebar sidebar, const fs::path& folder, const ReadOptions& options) {
    Plan plan;
    plan.sidebar = std::move(sidebar);
    plan.folder = folder;
    if (Cancelled(options)) return plan;
    // Arc keeps Site Search where Chromium does: the keywords table of the profile's Web Data.
    // A hot journal beside it means Arc is writing it, and the file may be half changed.
    const fs::path webDataFile = folder / "User Data" / "Default" / "Web Data";
    fs::path journal = webDataFile;
    journal += "-journal";
    if (JournalIsHot(journal)) {
        plan.unreadable.push_back({"Web Data", "Arc is writing it: quit Arc and import again"});
    } else if (auto webData = ReadArcFile(webDataFile, options, plan)) {
        if (auto sites = ParseSiteSearches(*webData)) plan.siteSearches = std::move(*sites);
        else plan.unreadable.push_back({"Web Data", ""});
    }
    if (Cancelled(options)) return plan;
    if (auto text = ReadArcFile(folder / "StorableKeyBindings.json", options, plan)) {
        if (auto bindings = ParseKeyBindings(*text)) plan.keyBindings = std::move(*bindings);
        else plan.unreadable.push_back({"StorableKeyBindings.json", ""});
    }
    if (Cancelled(options)) return plan;
    if (auto text = ReadArcFile(folder / "StorableArchiveItems.json", options, plan)) plan.archive = ParseArchive(*text);
    if (Cancelled(options)) return plan;
    if (auto text = ReadArcFile(folder / "StorableLinkRouting.json", options, plan)) {
        plan.routes = ParseLinkRouting(*text);
        if (!plan.routes) plan.unreadable.push_back({"StorableLinkRouting.json", ""});
    }
    if (Cancelled(options)) return plan;
    if (auto text = ReadArcFile(folder / "User Data" / "Local State", options, plan)) plan.profileNames = ParseProfileNames(*text);
    // Arc for Windows' settings: Foundation's defaults for company.thebrowser.arc, an XML plist
    // next to the Arc folder. A hand-made folder (KITE_ARC_DATA_PATH) may hold it, or the Mac's
    // company.thebrowser.Browser.plist, itself.
    for (const fs::path& file : {folder.parent_path() / "company.thebrowser.arc.plist", folder / "company.thebrowser.arc.plist",
                                 folder / "company.thebrowser.Browser.plist"}) {
        std::error_code error;
        if (!fs::exists(file, error)) continue;
        auto text = ReadArcFile(file, options, plan);
        if (!text) break;
        auto defaults = plist::ParseXml(*text);
        if (defaults && defaults->AsObject()) plan.settings = Settings::FromDefaults(*defaults);
        else plan.unreadable.push_back({PathText(file.filename()), ""});
        break;
    }
    return plan;
}

std::pair<int, int> UntitledCounts(const Plan& plan) {
    int spaces = 0, tabs = 0;
    for (const Space& space : plan.sidebar.result.spaces) {
        if (!IsUntitled(plan, space)) continue;
        ++spaces;
        tabs += static_cast<int>(space.AllTabs().size());
    }
    return {spaces, tabs};
}

bool IncludesUntitled(const Plan& plan, ImportOptions options) {
    if (options.includeUntitled) return *options.includeUntitled;
    const Result& result = plan.sidebar.result;
    return result.untitledSpaceIDs.size() == result.spaces.size();
}

std::vector<std::string> ConfirmLines(const Plan& plan, const BrowserState& state, bool includeUntitled) {
    const Result& result = plan.sidebar.result;
    const auto brought = ImportedProfiles(plan, includeUntitled);
    // Counts leave out unnamed spaces unless they'd come over; the choice gives their own.
    size_t spaces = 0, tabs = 0, reimported = 0, icons = 0;
    for (const Space& space : result.spaces) {
        if (!Imports(plan, space, includeUntitled)) continue;
        if (state.SpaceIndex(space.id)) ++reimported;
        ++spaces;
        tabs += space.AllTabs().size();
        if (result.iconsReplaced.contains(space.id)) ++icons;
    }
    std::vector<std::string> parts{Count(spaces, "space")};
    if (auto favorites = result.FavoritesIn(brought); !favorites.empty()) parts.push_back(Count(favorites.size(), "favorite"));
    parts.push_back(Count(tabs, "tab"));
    if (result.folderCount > 0) parts.push_back(Count(static_cast<size_t>(result.folderCount), "folder"));
    if (result.splitCount > 0) parts.push_back(Count(static_cast<size_t>(result.splitCount), "split view"));
    std::vector<std::string> lines{"Found " + List(parts) + "."};
    const auto [untitledSpaces, untitledTabs] = UntitledCounts(plan);
    if (untitledSpaces > 0 && includeUntitled && untitledSpaces == static_cast<int>(result.spaces.size())) {
        lines.push_back("Arc has no named spaces, so " +
                        std::string(untitledSpaces == 1 ? "its unnamed space comes over" : "its unnamed spaces come over") +
                        ", named \xE2\x80\x9C" "Arc Space\xE2\x80\x9D.");
    }
    if (plan.sidebar.isBackup) {
        const std::string why = plan.sidebar.currentTooLarge.empty()
                                    ? "Kite couldn't read Arc's current sidebar file"
                                    : "Arc's current sidebar file is too large for Kite to read (" + plan.sidebar.currentTooLarge + ")";
        lines.push_back(why + ", so this is from the newest backup of it Kite could read, made " +
                        (plan.sidebar.backup ? BackupDateText(*plan.sidebar.backup) : std::string("an earlier date")) +
                        ". Changes since then aren't in it.");
    }
    const auto shownRoutes = ShownRoutes(plan, state, includeUntitled);
    std::vector<std::string> extras;
    if (!plan.archive.empty()) extras.push_back(Count(plan.archive.size(), "archived tab"));
    if (!plan.siteSearches.empty()) extras.push_back(Count(plan.siteSearches.size(), "Site Search shortcut"));
    if (!plan.keyBindings.empty()) extras.push_back(Count(plan.keyBindings.size(), "keyboard shortcut change"));
    if (shownRoutes && !shownRoutes->rules.empty()) extras.push_back(Count(shownRoutes->rules.size(), "Air Traffic Control route"));
    if (!plan.settings.IsEmpty()) {
        const auto names = plan.settings.Names();
        std::string joined;
        for (const auto& n : names) joined += (joined.empty() ? "" : ", ") + n;
        extras.push_back(Count(names.size(), "Arc setting") + " (" + joined + ")");
    }
    if (!extras.empty()) lines.push_back("Also imports " + List(extras) + ".");
    if (plan.archive.size() > BrowserState::kArchiveLimit) {
        lines.push_back("Kite's archive keeps the latest " + std::to_string(BrowserState::kArchiveLimit) +
                        " tabs, so older archived tabs are left out.");
    }
    if (plan.routes && plan.routes->profileRoutes > 0) {
        const int n = plan.routes->profileRoutes;
        lines.push_back(Count(static_cast<size_t>(n), "Air Traffic Control route") + " to an Arc profile " + (n == 1 ? "is" : "are") +
                        " left out: Kite's routes open in a space or Little Kite.");
    }
    if (plan.routes && plan.routes->unreadable > 0) {
        const int n = plan.routes->unreadable;
        lines.push_back("Kite couldn't read " + Count(static_cast<size_t>(n), "Air Traffic Control route") + ", so " +
                        (n == 1 ? "it's" : "they're") + " left out.");
    }
    if (plan.routes && shownRoutes && plan.routes->rules.size() > shownRoutes->rules.size()) {
        lines.push_back("Routes to a space that isn't imported are left out.");
    }
    if (shownRoutes && shownRoutes->defaultSpace) {
        const std::string& id = *shownRoutes->defaultSpace;
        auto found = std::find_if(result.spaces.begin(), result.spaces.end(), [&](const Space& s) { return s.id == id; });
        const Space* space = found != result.spaces.end() ? &*found : nullptr;
        if (!space) {
            if (auto index = state.SpaceIndex(id)) space = &state.spaces[*index];
        }
        if (space) lines.push_back("Links from other apps that no route catches open in " + space->name + ", as in Arc.");
    }
    if (std::any_of(brought.begin(), brought.end(), [](const std::string& p) { return p != Profile::kDefaultDirectory; })) {
        const auto existing = ExistingProfilesForArc(state, brought, plan.profileNames);
        std::vector<std::string> made;
        for (const std::string& p : brought) {
            if (!existing.contains(p)) made.push_back("\xE2\x80\x9C" + ArcProfileName(p, plan.profileNames) + "\xE2\x80\x9D");
        }
        std::string line = "Your spaces use " + Count(brought.size(), "Arc profile") + ".";
        if (!made.empty()) line += " Kite makes " + std::string(made.size() == 1 ? "a profile" : "profiles") + " for " + List(made) + ".";
        if (made.size() < brought.size()) {
            line += made.empty() ? " They go into Kite profiles you already have." : " The others go into Kite profiles you already have.";
        }
        lines.push_back(line + " Sign-ins don't carry over, so you'll sign in to sites again.");
    }
    if (!includeUntitled && std::any_of(result.profiles.begin(), result.profiles.end(), [&](const std::string& p) {
            return std::find(brought.begin(), brought.end(), p) == brought.end();
        })) {
        lines.push_back("A profile only unnamed spaces use comes over, with its favorites, only if you include them.");
    }
    if (!plan.unreadable.empty()) {
        std::vector<std::string> files;
        for (const FileProblem& p : plan.unreadable) files.push_back(FileProblemText(p));
        lines.push_back("Kite couldn't read " + List(files) + ", so what's in " + (files.size() == 1 ? "it" : "them") + " is left out.");
    }
    if (icons > 0) lines.push_back(IconsNote(icons));
    lines.insert(lines.end(), result.notes.begin(), result.notes.end());
    lines.push_back(reimported > 0 ? Count(reimported, "space") +
                                         " imported before will be replaced with Arc's current version, including changes you made to them in Kite."
                                   : "Importing again later replaces these spaces with Arc's current version, including changes you make to them in Kite.");
    if (shownRoutes && !shownRoutes->rules.empty()) lines.push_back("Importing again also replaces the Air Traffic Control routes that came from Arc.");
    return lines;
}

Imported Import(BrowserState& state, const Plan& plan, ImportOptions options) {
    const Result& result = plan.sidebar.result;
    const bool includeUntitled = IncludesUntitled(plan, options);
    Imported out;

    std::vector<Space> spaces;
    size_t icons = 0;
    for (const Space& space : result.spaces) {
        if (!Imports(plan, space, includeUntitled)) continue;
        spaces.push_back(space);
        if (result.iconsReplaced.contains(space.id)) ++icons;
    }
    const auto [untitledSpaces, untitledTabs] = UntitledCounts(plan);
    if (untitledSpaces > 0 && includeUntitled) {
        const bool noneNamed = !options.includeUntitled;
        out.notes.push_back(Count(static_cast<size_t>(untitledSpaces), "unnamed space") + " (" + Count(static_cast<size_t>(untitledTabs), "tab") +
                            ") came over, named \xE2\x80\x9C" "Arc Space\xE2\x80\x9D, " +
                            (noneNamed ? "because Arc has no named spaces." : "as asked."));
    } else if (untitledSpaces > 0) {
        out.skipped.push_back(Skipped("unnamedSpaces", static_cast<size_t>(untitledSpaces),
                                      "Arc has no name for " + std::string(untitledSpaces == 1 ? "it" : "them") + " (" +
                                          Count(static_cast<size_t>(untitledTabs), "tab") + "); --include-unnamed brings them"));
    }
    const ArcMerge merged = MergeArc(state, spaces, result.favoritesByProfile, plan.profileNames);

    int siteSearches = 0;
    if (!plan.siteSearches.empty()) {
        if (MergeSiteSearches(state, plan.siteSearches)) siteSearches = static_cast<int>(plan.siteSearches.size());
        else out.skipped.push_back(Skipped("siteSearches", plan.siteSearches.size(), "the session's own Site Searches don't read"));
    }
    const int archived = MergeArchive(state, plan.archive);
    if (static_cast<size_t>(archived) < plan.archive.size()) {
        out.skipped.push_back(Skipped("archivedTabs", plan.archive.size() - static_cast<size_t>(archived),
                                      "imported before, or older than the latest " + std::to_string(BrowserState::kArchiveLimit)));
    }
    Apply(state, plan.settings);
    // Arc's own setting, else its Air Traffic Control default: the Mac keeps it as an app setting.
    if (plan.settings.opensExternalLinksInLittleKite || (plan.routes && plan.routes->defaultOpensInLittleKite)) {
        out.skipped.push_back(Skipped("littleKiteSetting", std::nullopt, "Kite for Windows has no Little Kite yet"));
    }

    out.keyBindings = plan.keyBindings;
    if (plan.routes) {
        // To the spaces Kite has now.
        std::set<std::string> ids;
        for (const Space& space : state.spaces) ids.insert(space.id);
        LinkRouting kept = plan.routes->Keeping(ids);
        if (plan.routes->profileRoutes > 0) {
            out.skipped.push_back(Skipped("routesToProfiles", static_cast<size_t>(plan.routes->profileRoutes),
                                          "Kite's routes open in a space or Little Kite"));
        }
        if (plan.routes->unreadable > 0) {
            out.skipped.push_back(Skipped("routesUnreadable", static_cast<size_t>(plan.routes->unreadable), "Kite couldn't read them"));
        }
        if (kept.rules.size() < plan.routes->rules.size()) {
            out.skipped.push_back(Skipped("routesToOtherSpaces", plan.routes->rules.size() - kept.rules.size(), "their space isn't imported"));
        }
        if (!kept.IsEmpty()) out.routes = std::move(kept);
    }

    for (const auto& [kind, count] : result.skippedKinds) {
        out.skipped.push_back(Skipped("sidebarItem:" + kind, static_cast<size_t>(count), "Kite has no such sidebar item"));
    }
    if (result.repeatedItems > 0) {
        out.skipped.push_back(Skipped("repeatedSidebarItems", static_cast<size_t>(result.repeatedItems),
                                      "listed again in childrenIds (a repeat or a loop), or under a parent that isn't its own"));
    }
    if (result.itemsTooDeep > 0) {
        out.skipped.push_back(Skipped("deepSidebarItems", static_cast<size_t>(result.itemsTooDeep),
                                      "nested more than " + std::to_string(kMaxDepth) + " levels deep"));
    }
    if (icons > 0) {
        out.skipped.push_back(Skipped("spaceIcons", icons, "from Arc's own icon set, which Kite doesn't have; a stand-in instead"));
        out.notes.push_back(IconsNote(icons));
    }
    if (!merged.fellBack.empty()) {
        out.skipped.push_back(Skipped("profiles", merged.fellBack.size(), "no Kite profile could be made for them, so their spaces went to Default"));
    }
    for (const FileProblem& p : plan.unreadable) {
        json::Object o{{"kind", "file"}, {"file", p.file}, {"reason", p.reason.empty() ? std::string("doesn't read") : p.reason}};
        out.skipped.push_back(json::Value(std::move(o)));
    }
    out.skipped.push_back(Skipped("history", std::nullopt, "Kite for Windows has no history yet"));
    out.skipped.push_back(Skipped("signIns", std::nullopt, "Arc's cookies aren't imported on Windows yet"));
    out.skipped.push_back(Skipped("extensions", std::nullopt, "Kite for Windows has no extensions yet"));
    out.notes.insert(out.notes.end(), result.notes.begin(), result.notes.end());

    // What came over, for the spaces that imported.
    size_t pinned = 0, unpinned = 0, splits = 0;
    int folders = 0;
    for (const Space& space : spaces) {
        pinned += space.Pinned().size();
        unpinned += space.tabs.size();
        folders += CountFolders(space.pinnedItems);
        splits += space.splits.size();
    }
    json::Array settings;
    for (const std::string& name : plan.settings.Names()) {
        if (name != "Open links from other apps in Little Arc") settings.push_back(name);
    }
    out.found = json::Object{{"spaces", result.spaces.size()},
                             {"unnamedSpaces", result.untitledSpaceIDs.size()},
                             {"tabs", result.tabCount},
                             {"folders", result.folderCount},
                             {"splits", result.splitCount},
                             {"favorites", result.Favorites().size()},
                             {"profiles", result.profiles.size()},
                             {"archivedTabs", plan.archive.size()},
                             {"siteSearches", plan.siteSearches.size()},
                             {"keyBindings", plan.keyBindings.size()},
                             {"routes", plan.routes ? plan.routes->rules.size() : size_t{0}}};
    out.imported = json::Object{{"spaces", merged.added + merged.updated},
                                {"spacesAdded", merged.added},
                                {"spacesUpdated", merged.updated},
                                {"unnamedSpaces", includeUntitled ? untitledSpaces : 0},
                                {"pinnedTabs", pinned},
                                {"tabs", unpinned},
                                {"folders", folders},
                                {"splits", splits},
                                {"favorites", merged.favoritesAdded},
                                {"profiles", merged.profiles.size()},
                                {"newProfiles", json::Array(merged.newProfiles.begin(), merged.newProfiles.end())},
                                {"archivedTabs", archived},
                                {"siteSearches", siteSearches},
                                {"keyBindings", 0},
                                {"routes", 0},
                                {"settings", json::Value(std::move(settings))}};
    out.source = json::Object{{"file", plan.sidebar.file}, {"backup", plan.sidebar.isBackup}};
    return out;
}

void WriteProfileFiles(Imported& out, const fs::path& profileDirectory) {
    // Shortcut changes into keybindings.json, as the Mac's KeyBindingsStore.merge.
    if (!out.keyBindings.empty()) {
        const fs::path file = profileDirectory / "keybindings.json";
        std::optional<KeyBindings> bindings = KeyBindings{};
        if (auto text = ReadFile(file)) bindings = KeyBindings::FromText(*text);
        else if (Exists(file)) bindings.reset();
        if (!bindings) {
            out.skipped.push_back(Skipped("keyBindings", out.keyBindings.size(), "keybindings.json doesn't read, so it's left as it is"));
        } else {
            for (const KeyBindingOverride& o : out.keyBindings) bindings->Set(o);
            if (std::string error = WriteFileAtomically(file, json::Write(bindings->ToJson())); error.empty()) {
                out.imported.insert_or_assign("keyBindings", out.keyBindings.size());
            } else {
                out.skipped.push_back(Skipped("keyBindings", out.keyBindings.size(), error));
            }
        }
    }
    // Routes into LinkRouting.json, as the Mac's AirTrafficControlStore.
    if (out.routes) {
        const fs::path file = profileDirectory / "LinkRouting.json";
        std::optional<air_traffic::State> atc = air_traffic::State{};
        if (auto text = ReadFile(file)) {
            auto value = json::ParseValue(*text);
            atc = value ? air_traffic::State::FromJson(*value) : std::nullopt;
        } else if (Exists(file)) {
            atc.reset();
        }
        if (!atc) {
            out.skipped.push_back(Skipped("routes", out.routes->rules.size(), "LinkRouting.json doesn't read, so it's left as it is"));
        } else {
            Merge(*atc, *out.routes);
            if (std::string error = WriteFileAtomically(file, json::Write(atc->ToJson())); error.empty()) {
                out.imported.insert_or_assign("routes", out.routes->rules.size());
            } else {
                out.skipped.push_back(Skipped("routes", out.routes->rules.size(), error));
            }
        }
    }
    out.keyBindings.clear();
    out.routes.reset();
}

json::Value Summary(const Imported& imported) {
    return json::Object{{"source", json::Value(imported.source)},
                        {"found", json::Value(imported.found)},
                        {"imported", json::Value(imported.imported)},
                        {"skipped", json::Value(imported.skipped)},
                        {"notes", json::Value(imported.notes)}};
}

}  // namespace kite::arc_import
