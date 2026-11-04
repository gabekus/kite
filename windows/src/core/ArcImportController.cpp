// The model side of KiteMac's ArcImportController.swift; see ArcImportController.h.

#include "core/ArcImportController.h"

#include <algorithm>
#include <chrono>
#include <ctime>
#include <fstream>
#include <set>
#include <thread>

#include "core/AirTrafficControl.h"
#include "core/Plist.h"
#include "core/Profiles.h"

namespace kite::arc_import {

namespace fs = std::filesystem;

namespace {

constexpr const char* kHelp =
    "Choose Arc's folder (%LOCALAPPDATA%\\Packages\\TheBrowserCompany.Arc_\xE2\x80\xA6\\LocalCache\\Local\\Arc), "
    "or StorableSidebar.json in it.";

std::string Text(const fs::path& path) {
    auto u8 = path.u8string();
    return std::string(u8.begin(), u8.end());
}

std::optional<std::string> ReadFile(const fs::path& file) {
    std::error_code error;
    if (!fs::is_regular_file(file, error)) return std::nullopt;
    std::ifstream in(file, std::ios::binary);
    if (!in) return std::nullopt;
    return std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

std::vector<std::string> FileNames(const fs::path& folder) {
    std::vector<std::string> names;
    std::error_code error;
    for (fs::directory_iterator it(folder, error), end; !error && it != end; it.increment(error)) names.push_back(Text(it->path().filename()));
    return names;
}

// One sidebar file: its result, or why not (none: it couldn't be read at all).
std::variant<Result, std::optional<Failure>> ReadSidebar(const fs::path& file, Timestamp now) {
    auto text = ReadFile(file);
    if (!text) return std::optional<Failure>();
    auto parsed = Parse(*text, now);
    if (auto* failure = std::get_if<Failure>(&parsed)) return std::optional<Failure>(*failure);
    return std::move(std::get<Result>(parsed));
}

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

std::string DateText(Timestamp t) {
    const std::time_t unix = static_cast<std::time_t>(t + 978307200.0);
    std::tm local{};
#ifdef _WIN32
    if (localtime_s(&local, &unix) != 0) return "an earlier date";
#else
    if (!localtime_r(&unix, &local)) return "an earlier date";
#endif
    char buffer[64];
    if (!std::strftime(buffer, sizeof buffer, "%B %d, %Y at %H:%M", &local)) return "an earlier date";
    return buffer;
}

bool IsUntitled(const Plan& plan, const Space& space) { return plan.sidebar.result.untitledSpaceIDs.contains(space.id); }

int CountFolders(const std::vector<PinnedItem>& items) {
    int n = 0;
    for (const PinnedItem& item : items) {
        if (auto* folder = std::get_if<Folder>(&item.value)) n += 1 + CountFolders(folder->items);
    }
    return n;
}

// The routes that will come over: to a named space here or a space Kite already has.
std::optional<LinkRouting> ShownRoutes(const Plan& plan, const BrowserState& state) {
    if (!plan.routes) return std::nullopt;
    std::set<std::string> ids;
    for (const Space& space : plan.sidebar.result.spaces) {
        if (!IsUntitled(plan, space)) ids.insert(space.id);
    }
    for (const Space& space : state.spaces) ids.insert(space.id);
    return plan.routes->Keeping(ids);
}

std::string WriteAtomically(const fs::path& file, const std::string& text) {
    std::error_code error;
    fs::create_directories(file.parent_path(), error);
    fs::path temp = file;
    temp += ".tmp";
    {
        std::ofstream out(temp, std::ios::binary | std::ios::trunc);
        if (!out) return "couldn't write " + Text(temp);
        out.write(text.data(), static_cast<std::streamsize>(text.size()));
        out.flush();
        if (!out) return "couldn't write " + Text(temp);
    }
    fs::rename(temp, file, error);
    if (error) {
        std::error_code ignored;
        fs::remove(temp, ignored);
        return "couldn't replace " + Text(file) + ": " + error.message();
    }
    return {};
}

json::Value Skipped(const std::string& kind, std::optional<size_t> count, const std::string& reason) {
    json::Object o{{"kind", kind}, {"reason", reason}};
    if (count) o.emplace("count", *count);
    return json::Value(std::move(o));
}

}  // namespace

std::optional<fs::path> ArcDirectory(const std::optional<fs::path>& supportOverride, const std::optional<fs::path>& arcDataOverride,
                                     const std::optional<fs::path>& localAppData) {
    if (supportOverride && arcDataOverride && !arcDataOverride->empty()) return *arcDataOverride;
    if (!localAppData || localAppData->empty()) return std::nullopt;
    std::vector<fs::path> packages;
    std::error_code error;
    for (fs::directory_iterator it(*localAppData / "Packages", error), end; !error && it != end; it.increment(error)) {
        if (Text(it->path().filename()).starts_with("TheBrowserCompany.Arc_")) packages.push_back(it->path());
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

std::variant<Sidebar, LoadError> LoadSidebar(const fs::path& folder, Timestamp now) {
    const auto candidates = SidebarCandidates(FileNames(folder));
    auto current = ReadSidebar(folder / candidates[0], now);
    for (int attempt = 0; attempt < 2; ++attempt) {
        // Only a cut-short file can be different a moment later.
        auto* failure = std::get_if<std::optional<Failure>>(&current);
        if (!failure || *failure != Failure::NotJSON) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        current = ReadSidebar(folder / candidates[0], now);
    }
    if (auto* result = std::get_if<Result>(&current)) return Sidebar{std::move(*result), candidates[0], false, std::nullopt};
    const std::optional<Failure> failure = std::get<std::optional<Failure>>(current);
    if (!TriesBackup(failure)) return NoSpaces();
    for (size_t i = 1; i < candidates.size(); ++i) {
        auto backup = ReadSidebar(folder / candidates[i], now);
        if (auto* result = std::get_if<Result>(&backup)) {
            // When its contents were last written, which can be well before the name's date.
            auto when = Modified(folder / candidates[i]);
            if (!when) when = BackupDate(candidates[i]);
            return Sidebar{std::move(*result), candidates[i], true, when};
        }
    }
    return LoadError{failure, "That folder has no Arc sidebar Kite can read.", kHelp};
}

std::variant<Plan, LoadError> ReadAuto(const std::optional<fs::path>& arcDirectory, Timestamp now) {
    std::error_code error;
    if (!arcDirectory || !fs::is_directory(*arcDirectory, error)) return LoadError{std::nullopt, "Kite couldn't find Arc's data.", kHelp};
    auto loaded = LoadSidebar(*arcDirectory, now);
    if (auto* failed = std::get_if<LoadError>(&loaded)) {
        if (failed->failure == Failure::NoSpaces) return *failed;
        return LoadError{failed->failure, "Kite couldn't read Arc's data.", kHelp};
    }
    return ReadPlan(std::move(std::get<Sidebar>(loaded)), *arcDirectory);
}

std::variant<Plan, LoadError> ReadPicked(const fs::path& picked, const std::optional<fs::path>& arcDirectory, Timestamp now) {
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
        loaded = LoadSidebar(folder, now);
    } else {
        auto read = ReadSidebar(picked, now);
        if (auto* result = std::get_if<Result>(&read)) loaded = Sidebar{std::move(*result), Text(picked.filename()), false, std::nullopt};
        else loaded = LoadError{std::get<std::optional<Failure>>(read), "", ""};
    }
    if (auto* failed = std::get_if<LoadError>(&loaded)) {
        if (failed->failure == Failure::NoSpaces) return NoSpaces();
        if (!isFolder) return LoadError{failed->failure, Text(picked.filename()) + " isn't Arc's sidebar.", kHelp};
        return LoadError{failed->failure, "That folder has no Arc sidebar Kite can read.", kHelp};
    }
    return ReadPlan(std::move(std::get<Sidebar>(loaded)), folder);
}

Plan ReadPlan(Sidebar sidebar, const fs::path& folder) {
    Plan plan;
    plan.sidebar = std::move(sidebar);
    plan.folder = folder;
    // Arc keeps Site Search where Chromium does: the keywords table of the profile's Web Data.
    if (auto webData = ReadFile(folder / "User Data" / "Default" / "Web Data")) {
        if (auto sites = ParseSiteSearches(*webData)) plan.siteSearches = std::move(*sites);
        else plan.unreadable.push_back("Web Data");
    }
    if (auto text = ReadFile(folder / "StorableKeyBindings.json")) {
        if (auto bindings = ParseKeyBindings(*text)) plan.keyBindings = std::move(*bindings);
        else plan.unreadable.push_back("StorableKeyBindings.json");
    }
    if (auto text = ReadFile(folder / "StorableArchiveItems.json")) plan.archive = ParseArchive(*text);
    if (auto text = ReadFile(folder / "StorableLinkRouting.json")) {
        plan.routes = ParseLinkRouting(*text);
        if (!plan.routes) plan.unreadable.push_back("StorableLinkRouting.json");
    }
    if (auto text = ReadFile(folder / "User Data" / "Local State")) plan.profileNames = ParseProfileNames(*text);
    // Arc for Windows' settings: Foundation's defaults for company.thebrowser.arc, an XML plist
    // next to the Arc folder. A hand-made folder (KITE_ARC_DATA_PATH) may hold it, or the Mac's
    // company.thebrowser.Browser.plist, itself.
    for (const fs::path& file : {folder.parent_path() / "company.thebrowser.arc.plist", folder / "company.thebrowser.arc.plist",
                                 folder / "company.thebrowser.Browser.plist"}) {
        auto text = ReadFile(file);
        if (!text) continue;
        auto defaults = plist::ParseXml(*text);
        if (defaults && defaults->AsObject()) plan.settings = Settings::FromDefaults(*defaults);
        else plan.unreadable.push_back(Text(file.filename()));
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

std::vector<std::string> ConfirmLines(const Plan& plan, const BrowserState& state) {
    const Result& result = plan.sidebar.result;
    const auto named = result.NamedSpaceProfiles();
    // Counts leave out unnamed spaces; their choice gives their own.
    size_t spaces = 0, tabs = 0, reimported = 0;
    for (const Space& space : result.spaces) {
        if (state.SpaceIndex(space.id)) ++reimported;
        if (IsUntitled(plan, space)) continue;
        ++spaces;
        tabs += space.AllTabs().size();
    }
    std::vector<std::string> parts{Count(spaces, "space")};
    if (auto favorites = result.FavoritesIn(named); !favorites.empty()) parts.push_back(Count(favorites.size(), "favorite"));
    parts.push_back(Count(tabs, "tab"));
    if (result.folderCount > 0) parts.push_back(Count(static_cast<size_t>(result.folderCount), "folder"));
    if (result.splitCount > 0) parts.push_back(Count(static_cast<size_t>(result.splitCount), "split view"));
    std::vector<std::string> lines{"Found " + List(parts) + "."};
    if (plan.sidebar.isBackup) {
        lines.push_back("Kite couldn't read Arc's current sidebar file, so this is from the newest backup of it Kite could read, made " +
                        (plan.sidebar.backup ? DateText(*plan.sidebar.backup) : std::string("an earlier date")) +
                        ". Changes since then aren't in it.");
    }
    const auto shownRoutes = ShownRoutes(plan, state);
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
    if (std::any_of(named.begin(), named.end(), [](const std::string& p) { return p != Profile::kDefaultDirectory; })) {
        const auto existing = ExistingProfilesForArc(state, named, plan.profileNames);
        std::vector<std::string> made;
        for (const std::string& p : named) {
            if (!existing.contains(p)) made.push_back("\xE2\x80\x9C" + ArcProfileName(p, plan.profileNames) + "\xE2\x80\x9D");
        }
        std::string line = "Your spaces use " + Count(named.size(), "Arc profile") + ".";
        if (!made.empty()) line += " Kite makes " + std::string(made.size() == 1 ? "a profile" : "profiles") + " for " + List(made) + ".";
        if (made.size() < named.size()) {
            line += made.empty() ? " They go into Kite profiles you already have." : " The others go into Kite profiles you already have.";
        }
        lines.push_back(line + " Sign-ins don't carry over, so you'll sign in to sites again.");
    }
    if (std::any_of(result.profiles.begin(), result.profiles.end(),
                    [&](const std::string& p) { return std::find(named.begin(), named.end(), p) == named.end(); })) {
        lines.push_back("A profile only unnamed spaces use comes over, with its favorites, only if you include them.");
    }
    if (!plan.unreadable.empty()) {
        lines.push_back("Kite couldn't read " + List(plan.unreadable) + ", so what's in " + (plan.unreadable.size() == 1 ? "it" : "them") +
                        " is left out.");
    }
    lines.insert(lines.end(), result.notes.begin(), result.notes.end());
    lines.push_back(reimported > 0 ? Count(reimported, "space") +
                                         " imported before will be replaced with Arc's current version, including changes you made to them in Kite."
                                   : "Importing again later replaces these spaces with Arc's current version, including changes you make to them in Kite.");
    if (shownRoutes && !shownRoutes->rules.empty()) lines.push_back("Importing again also replaces the Air Traffic Control routes that came from Arc.");
    return lines;
}

json::Value Import(BrowserState& state, const Plan& plan, const fs::path& profileDirectory, ImportOptions options) {
    const Result& result = plan.sidebar.result;
    json::Array skipped;

    std::vector<Space> spaces;
    for (const Space& space : result.spaces) {
        if (options.includeUntitled || !IsUntitled(plan, space)) spaces.push_back(space);
    }
    const auto [untitledSpaces, untitledTabs] = UntitledCounts(plan);
    if (!options.includeUntitled && untitledSpaces > 0) {
        skipped.push_back(Skipped("unnamedSpaces", static_cast<size_t>(untitledSpaces),
                                  "Arc has no name for " + std::string(untitledSpaces == 1 ? "it" : "them") + " (" +
                                      Count(static_cast<size_t>(untitledTabs), "tab") + "); --include-unnamed brings them"));
    }
    const ArcMerge merged = MergeArc(state, spaces, result.favoritesByProfile, plan.profileNames);

    int siteSearches = 0;
    if (!plan.siteSearches.empty()) {
        if (MergeSiteSearches(state, plan.siteSearches)) siteSearches = static_cast<int>(plan.siteSearches.size());
        else skipped.push_back(Skipped("siteSearches", plan.siteSearches.size(), "the session's own Site Searches don't read"));
    }
    const int archived = MergeArchive(state, plan.archive);
    if (static_cast<size_t>(archived) < plan.archive.size()) {
        skipped.push_back(Skipped("archivedTabs", plan.archive.size() - static_cast<size_t>(archived),
                                  "imported before, or older than the latest " + std::to_string(BrowserState::kArchiveLimit)));
    }
    Apply(state, plan.settings);
    // Arc's own setting, else its Air Traffic Control default: the Mac keeps it as an app setting.
    if (plan.settings.opensExternalLinksInLittleKite || (plan.routes && plan.routes->defaultOpensInLittleKite)) {
        skipped.push_back(Skipped("littleKiteSetting", std::nullopt, "Kite for Windows has no Little Kite yet"));
    }

    // Shortcut changes, into keybindings.json, as the Mac's KeyBindingsStore.merge.
    size_t keyBindings = 0;
    if (!plan.keyBindings.empty()) {
        const fs::path file = profileDirectory / "keybindings.json";
        std::optional<KeyBindings> bindings = KeyBindings{};
        if (auto text = ReadFile(file)) bindings = KeyBindings::FromText(*text);
        if (!bindings) {
            skipped.push_back(Skipped("keyBindings", plan.keyBindings.size(), "keybindings.json doesn't read, so it's left as it is"));
        } else {
            for (const KeyBindingOverride& o : plan.keyBindings) bindings->Set(o);
            if (std::string error = WriteAtomically(file, json::Write(bindings->ToJson())); error.empty()) keyBindings = plan.keyBindings.size();
            else skipped.push_back(Skipped("keyBindings", plan.keyBindings.size(), error));
        }
    }

    // Routes to the spaces Kite now has, into LinkRouting.json (AirTrafficControlStore).
    size_t routes = 0;
    if (plan.routes) {
        std::set<std::string> ids;
        for (const Space& space : state.spaces) ids.insert(space.id);
        const LinkRouting kept = plan.routes->Keeping(ids);
        if (plan.routes->profileRoutes > 0) {
            skipped.push_back(Skipped("routesToProfiles", static_cast<size_t>(plan.routes->profileRoutes), "Kite's routes open in a space or Little Kite"));
        }
        if (plan.routes->unreadable > 0) skipped.push_back(Skipped("routesUnreadable", static_cast<size_t>(plan.routes->unreadable), "Kite couldn't read them"));
        if (kept.rules.size() < plan.routes->rules.size()) {
            skipped.push_back(Skipped("routesToOtherSpaces", plan.routes->rules.size() - kept.rules.size(), "their space isn't imported"));
        }
        if (!kept.IsEmpty()) {
            const fs::path file = profileDirectory / "LinkRouting.json";
            std::optional<air_traffic::State> atc = air_traffic::State{};
            if (auto text = ReadFile(file)) {
                auto parsed = json::Parse(*text);
                auto* value = std::get_if<json::Value>(&parsed);
                atc = value ? air_traffic::State::FromJson(*value) : std::nullopt;
            }
            if (!atc) {
                skipped.push_back(Skipped("routes", kept.rules.size(), "LinkRouting.json doesn't read, so it's left as it is"));
            } else {
                Merge(*atc, kept);
                if (std::string error = WriteAtomically(file, json::Write(atc->ToJson())); error.empty()) routes = kept.rules.size();
                else skipped.push_back(Skipped("routes", kept.rules.size(), error));
            }
        }
    }

    for (const auto& [kind, count] : result.skippedKinds) {
        skipped.push_back(Skipped("sidebarItem:" + kind, static_cast<size_t>(count), "Kite has no such sidebar item"));
    }
    if (result.iconsReplaced > 0) {
        skipped.push_back(Skipped("spaceIcons", static_cast<size_t>(result.iconsReplaced), "from Arc's own icon set, which Kite doesn't have; a stand-in instead"));
    }
    if (!merged.fellBack.empty()) {
        skipped.push_back(Skipped("profiles", merged.fellBack.size(), "no Kite profile could be made for them, so their spaces went to Default"));
    }
    for (const std::string& file : plan.unreadable) skipped.push_back(Skipped("file", std::nullopt, file + " doesn't read"));
    skipped.push_back(Skipped("history", std::nullopt, "Kite for Windows has no history yet"));
    skipped.push_back(Skipped("signIns", std::nullopt, "Arc's cookies aren't imported on Windows yet"));
    skipped.push_back(Skipped("extensions", std::nullopt, "Kite for Windows has no extensions yet"));

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
    json::Array newProfiles(merged.newProfiles.begin(), merged.newProfiles.end());
    json::Array notes(result.notes.begin(), result.notes.end());
    json::Object source{{"file", plan.sidebar.file}, {"backup", plan.sidebar.isBackup}};
    return json::Object{
        {"source", json::Value(std::move(source))},
        {"found", json::Object{{"spaces", result.spaces.size()},
                               {"unnamedSpaces", result.untitledSpaceIDs.size()},
                               {"tabs", result.tabCount},
                               {"folders", result.folderCount},
                               {"splits", result.splitCount},
                               {"favorites", result.Favorites().size()},
                               {"profiles", result.profiles.size()},
                               {"archivedTabs", plan.archive.size()},
                               {"siteSearches", plan.siteSearches.size()},
                               {"keyBindings", plan.keyBindings.size()},
                               {"routes", plan.routes ? plan.routes->rules.size() : size_t{0}}}},
        {"imported", json::Object{{"spaces", merged.added + merged.updated},
                                  {"spacesAdded", merged.added},
                                  {"spacesUpdated", merged.updated},
                                  {"pinnedTabs", pinned},
                                  {"tabs", unpinned},
                                  {"folders", folders},
                                  {"splits", splits},
                                  {"favorites", merged.favoritesAdded},
                                  {"profiles", merged.profiles.size()},
                                  {"newProfiles", json::Value(std::move(newProfiles))},
                                  {"archivedTabs", archived},
                                  {"siteSearches", siteSearches},
                                  {"keyBindings", keyBindings},
                                  {"routes", routes},
                                  {"settings", json::Value(std::move(settings))}}},
        {"skipped", json::Value(std::move(skipped))},
        {"notes", json::Value(std::move(notes))},
    };
}

}  // namespace kite::arc_import
