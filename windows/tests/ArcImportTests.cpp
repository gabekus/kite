// Ports of KiteCore's ArcImportTests (ArcImport.swift, BrowserState.mergeArc), case for case,
// each named after its Swift test, then the cases Arc for Windows' StorableSidebar.json adds.
// The fixtures are hand-made in Arc's shape: never anyone's real Arc data.

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <set>

#include "Check.h"
#include "core/ArcImport.h"
#include "core/Profiles.h"
#include "core/SupportDirectory.h"
#include "core/Url.h"
#include "core/Uuid.h"

using namespace kite;
using json::Array;
using json::Object;
using json::Value;

namespace {

std::string Id(int n) {
    char buffer[40];
    std::snprintf(buffer, sizeof buffer, "00000000-0000-4000-8000-%012d", n);
    return buffer;
}

Value Title(const std::optional<std::string>& title) { return title ? Value(*title) : Value(); }

Value TabItem(int n, int parent, std::optional<std::string> title = std::nullopt) {
    return Object{{"id", Id(n)}, {"parentID", Id(parent)}, {"title", Title(title)}, {"childrenIds", Array{}},
                  {"data", Object{{"tab", Object{{"savedURL", "https://site" + std::to_string(n) + ".example/"},
                                                 {"savedTitle", "Site " + std::to_string(n)},
                                                 {"timeLastActiveAt", 1.0}}}}}};
}

Value Node(int n, Value kind, std::vector<int> children, std::optional<std::string> title = std::nullopt) {
    Array ids;
    for (int c : children) ids.push_back(Id(c));
    return Object{{"id", Id(n)}, {"title", Title(title)}, {"childrenIds", Value(std::move(ids))}, {"data", std::move(kind)}};
}

Value Container(const std::string& type, Value payload) { return Object{{"itemContainer", Object{{"containerType", Object{{type, std::move(payload)}}}}}}; }

Array Flat(const std::vector<Value>& items) {
    Array out;
    for (const Value& item : items) {
        out.push_back(*item.Find("id"));
        out.push_back(item);
    }
    return out;
}

// Mirrors the shape of a real (Mac) StorableSidebar.json: ArcImportTests.fixture.
std::string Fixture() {
    Value personal = Object{
        {"id", Id(1)}, {"title", "Personal"},
        {"customInfo", Object{{"iconType", Object{{"emoji_v2", "\xF0\x9F\x8F\x83"}, {"emoji", 127939}}}}},  // 🏃
        {"profile", Object{{"default", true}}},
        {"containerIDs", Array{"pinned", Id(10), "unpinned", Id(11)}},
    };
    Value gradient = Object{{"baseColors", Array{Object{{"red", 1.0}, {"green", 0.5}, {"blue", 0.0}, {"alpha", 1}, {"colorSpace", "extendedSRGB"}},
                                                 Object{{"red", 0.0}, {"green", 0.25}, {"blue", 1.2}, {"alpha", 1}, {"colorSpace", "extendedSRGB"}}}},
                            {"modifiers", Object{{"noiseFactor", 0.2}, {"overlay", "grain"}}}};
    Value theme = Object{{"background", Object{{"single", Object{{"_0", Object{{"style", Object{{"color", Object{{"_0", Object{{"blendedGradient", Object{{"_0", gradient}}}}}}}}}}}}}}},
                         {"intensityFactor", 0.8},
                         {"translucencyStyle", Object{{"light", Object{}}}}};
    Value work = Object{
        {"id", Id(2)}, {"title", "Work"},
        {"customInfo", Object{{"windowTheme", theme}}},
        {"profile", Object{{"custom", Object{{"_0", Object{{"directoryBasename", "Profile 3"}, {"machineID", "m"}}}}}}},
        {"containerIDs", Array{"pinned", Id(20), "unpinned", Id(21)}},
    };
    std::vector<Value> items{
        Node(10, Container("spaceItems", Object{{"_0", Id(1)}}), {100, 101, 104}),
        TabItem(100, 10, "Renamed"),
        Node(101, Object{{"list", Object{}}}, {102, 103}, "Folder"),
        TabItem(102, 101),
        Node(103, Object{{"list", Object{}}}, {105}, "Nested"),
        TabItem(105, 103),
        Node(104, Object{{"splitView", Object{{"layoutOrientation", "horizontal"}, {"itemWidthFactors", Array{Id(106), 0.6}}}}}, {106, 107}),
        TabItem(106, 104),
        TabItem(107, 104),
        Node(11, Container("spaceItems", Object{{"_0", Id(1)}}), {110, 112, 111}),
        TabItem(110, 11),
        Node(112, Object{{"splitView", Object{{"layoutOrientation", "vertical"}}}}, {113, 114, 115}),
        TabItem(113, 112),
        TabItem(114, 112),
        TabItem(115, 112),
        Node(111, Object{{"easel", Object{}}}, {}),
        Node(30, Container("topApps", Object{{"_0", Object{{"default", true}}}}), {300}),
        TabItem(300, 30),
        Node(31, Container("topApps", Object{{"_0", Object{{"custom", Object{}}}}}), {310, 311}),
        TabItem(310, 31),
        // Arc keeps one grid per profile, so the same site can be in two of them.
        Object{{"id", Id(311)}, {"childrenIds", Array{}}, {"data", Object{{"tab", Object{{"savedURL", "https://site300.example/"}, {"savedTitle", "Site 300"}}}}}},
        Node(20, Container("spaceItems", Object{{"_0", Id(2)}}), {}),
        Node(21, Container("spaceItems", Object{{"_0", Id(2)}}), {210}),
        TabItem(210, 21),
    };
    Value root = Object{
        {"version", 1},
        {"sidebar", Object{{"containers", Array{
            Object{{"global", Object{}}},
            Object{{"spaces", Array{Id(1), personal, Id(2), work}},
                   {"items", Flat(items)},
                   {"topAppsContainerIDs", Array{Object{{"default", true}}, Id(30),
                                                 Object{{"custom", Object{{"_0", Object{{"directoryBasename", "Profile 3"}}}}}}, Id(31)}}},
            Object{{"littleBrowser", Object{}}},
        }}}},
    };
    return json::Write(root);
}

arc_import::Result Parsed(const std::string& text = Fixture(), Timestamp now = Now()) {
    auto parsed = arc_import::Parse(text, now);
    auto* result = std::get_if<arc_import::Result>(&parsed);
    CHECK(result);
    return result ? *result : arc_import::Result{};
}

std::optional<arc_import::Failure> FailureOf(const std::string& text) {
    auto parsed = arc_import::Parse(text);
    if (auto* f = std::get_if<arc_import::Failure>(&parsed)) return *f;
    return std::nullopt;
}

std::vector<std::string> Titles(const std::vector<Tab>& tabs) {
    std::vector<std::string> out;
    for (const Tab& t : tabs) out.push_back(t.title);
    return out;
}

std::vector<std::string> Titles(const std::vector<const Tab*>& tabs) {
    std::vector<std::string> out;
    for (const Tab* t : tabs) out.push_back(t->title);
    return out;
}

const Space* SpaceWithID(const BrowserState& state, const std::string& id) {
    auto index = state.SpaceIndex(id);
    return index ? &state.spaces[*index] : nullptr;
}

std::optional<std::string> ProfileOf(const BrowserState& state, const std::string& spaceID) {
    const Space* space = SpaceWithID(state, spaceID);
    return space ? SpaceProfile(*space) : std::nullopt;
}

std::vector<std::string> ProfileNames(const BrowserState& state) {
    std::vector<std::string> out;
    for (const Profile& p : Profiles(state)) out.push_back(p.name);
    return out;
}

BrowserState Fresh() { return BrowserState::MakeDefault(std::nullopt); }

Profile Created(BrowserState& state, const std::string& name) {
    auto made = CreateProfile(state, name);
    CHECK(std::holds_alternative<Profile>(made));
    return std::holds_alternative<Profile>(made) ? std::get<Profile>(made) : Profile{};
}

bool Near(double a, double b) { return std::abs(a - b) < 0.001; }

}  // namespace

TEST(ArcImport_importsSpacesFoldersFavoritesAndThemes) {
    const Timestamp now = FromUnixTime(1'800'000'000);
    const auto result = Parsed(Fixture(), now);
    CHECK(result.spaces.size() == 2);
    if (result.spaces.size() != 2) return;
    CHECK(result.spaces[0].name == "Personal" && result.spaces[1].name == "Work");

    const Space& personal = result.spaces[0];
    CHECK(personal.id == Id(1));
    CHECK(personal.icon == "\xF0\x9F\x8F\x83");
    std::vector<std::string> hosts;
    for (const Tab& tab : personal.tabs) hosts.push_back(tab.url ? url::Host(*tab.url).value_or("") : "");
    CHECK((hosts == std::vector<std::string>{"site110.example", "site113.example", "site114.example", "site115.example"}));
    CHECK(personal.selectedTabID == personal.tabs.front().id);

    // Renamed tab, nested folder, and a split view's tabs side by side.
    CHECK(personal.pinnedItems.size() == 4);
    if (personal.pinnedItems.size() != 4) return;
    const Tab* renamed = std::get_if<Tab>(&personal.pinnedItems[0].value);
    const Folder* folder = std::get_if<Folder>(&personal.pinnedItems[1].value);
    const Tab* left = std::get_if<Tab>(&personal.pinnedItems[2].value);
    const Tab* right = std::get_if<Tab>(&personal.pinnedItems[3].value);
    CHECK(renamed && folder && left && right);
    if (!renamed || !folder || !left || !right) return;
    CHECK((result.profiles == std::vector<std::string>{"Default", "Profile 3"}));
    CHECK((Titles(result.favoritesByProfile.at("Default")) == std::vector<std::string>{"Site 300"}));
    CHECK((Titles(result.favoritesByProfile.at("Profile 3")) == std::vector<std::string>{"Site 310", "Site 300"}));
    CHECK((Titles(result.Favorites()) == std::vector<std::string>{"Site 300", "Site 310", "Site 300"}));
    CHECK(!SpaceProfile(personal));
    CHECK(SpaceProfile(result.spaces[1]) == "Profile 3");
    CHECK(renamed->customTitle == "Renamed");
    CHECK(renamed->DisplayTitle() == "Renamed");
    CHECK(folder->name == "Folder");
    CHECK((Titles(TabsIn(folder->items)) == std::vector<std::string>{"Site 102", "Site 105"}));
    const Folder* nested = folder->items.size() == 2 ? std::get_if<Folder>(&folder->items[1].value) : nullptr;
    CHECK(nested && nested->name == "Nested");
    CHECK(left->title == "Site 106" && right->title == "Site 107");

    // Splits: the pinned one keeps Arc's widths, the unpinned one its orientation.
    CHECK(personal.splits.size() == 2);
    if (personal.splits.size() != 2) return;
    const SplitView& pinnedSplit = personal.splits[0];
    CHECK(pinnedSplit.id == Id(104));
    CHECK((pinnedSplit.tabIDs == std::vector<std::string>{left->id, right->id}));
    CHECK(pinnedSplit.orientation == "horizontal");
    const auto factors = pinnedSplit.NormalizedFactors();
    CHECK(factors.size() == 2 && Near(factors[0], 0.6) && Near(factors[1], 0.4));
    const SplitView& unpinnedSplit = personal.splits[1];
    CHECK((unpinnedSplit.tabIDs == std::vector<std::string>{personal.tabs[1].id, personal.tabs[2].id, personal.tabs[3].id}));
    CHECK(unpinnedSplit.orientation == "vertical");
    CHECK(unpinnedSplit.NormalizedFactors().size() == 3);
    // The splits survive Kite's own clean-up.
    BrowserState state = Fresh();
    MergeImported(state, result.spaces);
    state.NormalizeSplits();
    CHECK(SpaceWithID(state, personal.id) && SpaceWithID(state, personal.id)->splits.size() == 2);

    const Space& work = result.spaces[1];
    CHECK(work.pinnedItems.empty());
    CHECK((work.theme.colors == std::vector<ThemeColor>{{1, 0.5f, 0}, {0, 0.25f, 1}}));
    CHECK(Near(work.theme.grain, 0.2));
    CHECK(Near(work.theme.tint, Theme::kDefaultTint * 0.8));

    // Imported tabs count as fresh so auto-archive doesn't sweep them.
    bool fresh = true;
    for (const Space& space : result.spaces) {
        for (const Tab* tab : space.AllTabs()) fresh = fresh && tab->lastActiveAt == now;
    }
    for (const Tab& tab : result.Favorites()) fresh = fresh && tab.lastActiveAt == now;
    CHECK(fresh);
    CHECK(result.tabCount == 13);
    CHECK(result.folderCount == 2);
    CHECK(result.splitCount == 2);
    auto noted = [&](const std::string& text) {
        return std::any_of(result.notes.begin(), result.notes.end(), [&](const std::string& n) { return n.find(text) != std::string::npos; });
    };
    CHECK(noted("1 split view is stacked"));
    CHECK(noted("easel"));
}

TEST(ArcImport_fillsInMissingSplitWidths) {
    auto factors = [](std::vector<std::optional<double>> known) -> std::optional<std::vector<double>> {
        auto f = arc_import::SplitWidthFactors(known);
        if (!f) return std::nullopt;
        for (double& x : *f) x = std::round(x * 1000) / 1000;
        return f;
    };
    CHECK((factors({0.6, std::nullopt}) == std::vector<double>{0.6, 0.4}));
    CHECK((factors({0.5, std::nullopt, std::nullopt}) == std::vector<double>{0.5, 0.25, 0.25}));
    CHECK((factors({0.3, 0.7}) == std::vector<double>{0.3, 0.7}));
    CHECK(!factors({std::nullopt, std::nullopt}));
    CHECK(!factors({1.2, std::nullopt}));
}

TEST(ArcImport_idsAreUniqueAcrossTheImport) {
    const auto result = Parsed();
    std::vector<std::string> ids;
    for (const Space& space : result.spaces) {
        ids.push_back(space.id);
        for (const Tab* tab : space.AllTabs()) ids.push_back(tab->id);
    }
    for (const Tab& tab : result.Favorites()) ids.push_back(tab.id);
    CHECK(std::set<std::string>(ids.begin(), ids.end()).size() == ids.size());
}

TEST(ArcImport_reimportReplacesSameSpaces) {
    BrowserState state = Fresh();
    const auto first = Parsed();
    const ArcMerge merged = MergeArc(state, first.spaces, first.favoritesByProfile);
    CHECK(merged.added == 2 && merged.updated == 0);
    const auto second = Parsed();
    const ArcMerge again = MergeArc(state, second.spaces, second.favoritesByProfile);
    CHECK(again.added == 0 && again.updated == 2);
    CHECK(again.newProfiles.empty());
    CHECK(state.spaces.size() == 4);
    CHECK(Profiles(state).size() == 1);
    CHECK(state.Favorites().size() == 1);
    CHECK(state.SelectedSpace().name == "Personal");
}

TEST(ArcImport_eachArcProfileBecomesAKiteProfile) {
    BrowserState state = Fresh();
    const auto result = Parsed();
    const ArcMerge merged = MergeArc(state, result.spaces, result.favoritesByProfile, {{"Default", "Personal"}, {"Profile 3", "Work stuff"}});
    CHECK((ProfileNames(state) == std::vector<std::string>{"Work stuff"}));
    const Profile work = Profiles(state).empty() ? Profile{} : Profiles(state).front();
    CHECK((merged.newProfiles == std::vector<std::string>{work.directory}));
    CHECK((merged.profiles == std::map<std::string, std::string>{{"Default", "Default"}, {"Profile 3", work.directory}}));
    CHECK(!ProfileOf(state, result.spaces[0].id));
    CHECK(ProfileOf(state, result.spaces[1].id) == work.directory);
    // Each grid goes to its own profile; a site in both stays in both.
    CHECK((Titles(state.favoritesByProfile["Default"]) == std::vector<std::string>{"Site 300"}));
    CHECK((Titles(state.favoritesByProfile[work.directory]) == std::vector<std::string>{"Site 310", "Site 300"}));

    // Renamed in Kite: importing again keeps the space's profile instead of making another.
    CHECK(!RenameProfile(state, work.directory, "Job"));
    const ArcMerge again = MergeArc(state, Parsed().spaces, {}, {{"Profile 3", "Work stuff"}});
    CHECK(again.newProfiles.empty());
    CHECK((ProfileNames(state) == std::vector<std::string>{"Job"}));
    CHECK(ProfileOf(state, result.spaces[1].id) == work.directory);
}

TEST(ArcImport_arcProfilesMatchKiteProfilesByName) {
    BrowserState state = Fresh();
    const Profile existing = Created(state, "work STUFF");
    const auto result = Parsed();
    const ArcMerge merged = MergeArc(state, result.spaces, {}, {{"Profile 3", "Work stuff"}});
    CHECK(merged.newProfiles.empty());
    CHECK(Profiles(state).size() == 1 && Profiles(state).front().directory == existing.directory);
    CHECK(ProfileOf(state, result.spaces[1].id) == existing.directory);
}

TEST(ArcImport_unnamedOrUnusedArcProfiles) {
    const auto result = Parsed();
    // No name from Arc's Local State: the profile is named after its folder.
    BrowserState state = Fresh();
    MergeArc(state, result.spaces, {}, {{"Profile 3", "  "}});
    CHECK((ProfileNames(state) == std::vector<std::string>{"Profile 3"}));

    // A profile only a left-out space used isn't made, and its favorites stay behind.
    BrowserState personalOnly = Fresh();
    const ArcMerge merged = MergeArc(personalOnly, {result.spaces[0]}, result.favoritesByProfile, {{"Profile 3", "Work stuff"}});
    CHECK(Profiles(personalOnly).empty());
    CHECK((merged.profiles == std::map<std::string, std::string>{{"Default", "Default"}}));
    CHECK(personalOnly.favoritesByProfile.size() == 1 && personalOnly.favoritesByProfile.contains("Default"));
}

TEST(ArcImport_defaultFavoritesComeEvenWithNoDefaultSpace) {
    const auto result = Parsed();
    BrowserState state = Fresh();
    const ArcMerge merged = MergeArc(state, {result.spaces[1]}, result.favoritesByProfile);
    CHECK(merged.profiles.at("Default") == "Default");
    CHECK((Titles(state.favoritesByProfile["Default"]) == std::vector<std::string>{"Site 300"}));
    CHECK((Titles(result.FavoritesIn({"Profile 3"})) == std::vector<std::string>{"Site 310", "Site 300", "Site 300"}));
}

TEST(ArcImport_reimportLeavesSpacesWhereTheUserPutThem) {
    const auto result = Parsed();
    const std::map<std::string, std::string> names{{"Profile 3", "Work"}};
    BrowserState state = Fresh();
    MergeArc(state, result.spaces, result.favoritesByProfile, names);
    const Profile work = Profiles(state).front();
    const Profile other = Created(state, "Other");
    SetProfile(state, other.directory, result.spaces[1].id);
    SetProfile(state, other.directory, result.spaces[0].id);

    const ArcMerge again = MergeArc(state, result.spaces, result.favoritesByProfile, names);
    // The spaces stay put; Work's favorites still go to Work.
    CHECK(ProfileOf(state, result.spaces[1].id) == other.directory);
    CHECK(ProfileOf(state, result.spaces[0].id) == other.directory);
    CHECK(again.profiles.at("Profile 3") == work.directory);
    CHECK(!state.favoritesByProfile.contains(other.directory));

    // Work emptied and renamed: Arc's profile still goes there, not to a new "Work".
    std::erase_if(state.spaces, [&](const Space& s) { return s.id == result.spaces[1].id; });
    CHECK(!RenameProfile(state, work.directory, "Job"));
    const ArcMerge third = MergeArc(state, result.spaces, {}, names);
    CHECK(third.newProfiles.empty());
    CHECK(ProfileOf(state, result.spaces[1].id) == work.directory);
}

TEST(ArcImport_spacesFromAnImportBeforeProfilesMoveToTheirProfile) {
    const auto result = Parsed();
    BrowserState state = Fresh();
    // As the import did before it knew profiles: everything in Default.
    std::vector<Space> unplaced = result.spaces;
    for (Space& space : unplaced) SetSpaceProfile(space, std::nullopt);
    MergeImported(state, unplaced);
    const ArcMerge merged = MergeArc(state, result.spaces, {}, {{"Profile 3", "Work"}});
    CHECK(ProfileOf(state, result.spaces[1].id) == merged.profiles.at("Profile 3"));
    CHECK(merged.newProfiles.size() == 1);
}

TEST(ArcImport_sameNamedArcProfilesStayApart) {
    std::vector<Space> spaces = Parsed().spaces;
    Space third = spaces[1];
    third.id = NewUuid();
    SetSpaceProfile(third, "Profile 4");
    spaces.push_back(third);
    BrowserState state = Fresh();
    const ArcMerge merged = MergeArc(state, spaces, {}, {{"Profile 3", "Work"}, {"Profile 4", "work"}});
    CHECK((ProfileNames(state) == std::vector<std::string>{"Work", "work (Arc)"}));
    CHECK(merged.profiles.at("Profile 3") != merged.profiles.at("Profile 4"));
}

TEST(ArcImport_aDeletedProfilesFolderIsntReusedForArc) {
    const auto result = Parsed();
    BrowserState state = Fresh();
    MergeArc(state, result.spaces, {}, {{"Profile 3", "Work"}});
    const std::string work = Profiles(state).front().directory;
    std::erase_if(state.spaces, [&](const Space& s) { return s.id == result.spaces[1].id; });
    CHECK(DeleteProfile(state, work));
    ForgetRetiredProfiles(state, {work});
    const Profile shopping = Created(state, "Shopping");
    CHECK(shopping.directory == work);

    const ArcMerge again = MergeArc(state, result.spaces, {}, {{"Profile 3", "Work"}});
    CHECK(again.newProfiles.size() == 1);
    CHECK(again.profiles.at("Profile 3") != shopping.directory);
    CHECK(ProfileOf(state, result.spaces[1].id) == again.profiles.at("Profile 3"));
}

TEST(ArcImport_arcProfileMapSurvivesARelaunch) {
    BrowserState state = Fresh();
    MergeArc(state, Parsed().spaces, {}, {{"Profile 3", "Work"}});
    // Through the session's text, as a relaunch reads it.
    auto parsed = json::Parse(json::Write(Encode(state)));
    auto* value = std::get_if<Value>(&parsed);
    auto decoded = value ? DecodeBrowserState(*value) : std::nullopt;
    CHECK(decoded);
    if (!decoded) return;
    CHECK((ArcProfileMap(*decoded) == std::map<std::string, std::string>{{"Profile 3", Profiles(state).front().dataStoreID}}));
}

TEST(ArcImport_flagsUntitledSpaces) {
    const std::string space = R"({"id": ")" + Id(5) + R"(", "containerIDs": ["unpinned", ")" + Id(50) + R"("]})";
    const std::string items = json::Write(Value(Flat({Node(50, Object{{"itemContainer", Object{}}}, {500}), TabItem(500, 50)})));
    const std::string root = R"({"sidebar": {"containers": [{"spaces": [")" + Id(5) + R"(", )" + space + R"(], "items": )" + items + "}]}}";
    const auto result = Parsed(root);
    CHECK(result.spaces.size() == 1 && result.spaces[0].name == "Arc Space");
    CHECK(result.untitledSpaceIDs == std::set<std::string>{result.spaces[0].id});
    CHECK(Parsed().untitledSpaceIDs.empty());
}

TEST(ArcImport_picksTheSidebarFileThenItsNewestBackup) {
    const std::vector<std::string> names{"StorableArchive.json", "StorableSidebar.2024-11-21-17-40-41-080.json", "StorableSidebar.json",
                                         "StorableSidebar.2026-11-01-21-05-17-932.json", "StorableSidebarX.txt"};
    CHECK((arc_import::SidebarCandidates(names) ==
           std::vector<std::string>{"StorableSidebar.json", "StorableSidebar.2026-11-01-21-05-17-932.json", "StorableSidebar.2024-11-21-17-40-41-080.json"}));
    // Tried even when the folder couldn't be listed.
    CHECK((arc_import::SidebarCandidates({}) == std::vector<std::string>{"StorableSidebar.json"}));
}

TEST(ArcImport_aBackupOnlyWhenTheCurrentSidebarCantBeRead) {
    CHECK(arc_import::TriesBackup(arc_import::Failure::NotJSON));
    CHECK(arc_import::TriesBackup(arc_import::Failure::NotArcSidebar));
    // The file couldn't be read at all (CocoaError(.fileReadNoPermission) on the Mac).
    CHECK(arc_import::TriesBackup(std::nullopt));
    // No spaces is what Arc has now; an older backup isn't used instead.
    CHECK(!arc_import::TriesBackup(arc_import::Failure::NoSpaces));
}

TEST(ArcImport_readsABackupsDate) {
    auto date = arc_import::BackupDate("StorableSidebar.2026-11-01-21-05-17-932.json");
    CHECK(date);
    if (!date) return;
    const std::time_t unix = static_cast<std::time_t>(*date + 978307200.0);
    std::tm local{};
#ifdef _WIN32
    localtime_s(&local, &unix);
#else
    localtime_r(&unix, &local);
#endif
    CHECK(local.tm_year + 1900 == 2026 && local.tm_mon + 1 == 11 && local.tm_mday == 1 && local.tm_hour == 21 && local.tm_min == 5);
    CHECK(!arc_import::BackupDate("StorableSidebar.json"));
}

TEST(ArcImport_rejectsOtherFiles) {
    CHECK(FailureOf("{}") == arc_import::Failure::NotArcSidebar);
    // Cut short, as a file read while it's written would be.
    CHECK(FailureOf(Fixture().substr(0, 200)) == arc_import::Failure::NotJSON);
    CHECK(FailureOf(R"({"sidebar":{"containers":[]}})") == arc_import::Failure::NoSpaces);
}

// MARK: Cycles, repeats and depth (the Mac's PR #362, ArcImportTests.swift, case for case)

namespace {

// Spaces whose pinned section is item n*10 and unpinned section item n*10 + 1, in Arc profile
// folder `profiles[n]` (Default if none); `items` are the rest (ArcImportTests.sidebar).
arc_import::Result Sidebar(const std::vector<Value>& items, const std::vector<int>& spaces = {1},
                           const std::map<int, std::string>& profiles = {}, const Array& favorites = {}) {
    Array spaceList;
    for (int n : spaces) {
        Object profile;
        if (auto folder = profiles.find(n); folder != profiles.end()) {
            Object inner;
            inner.emplace("directoryBasename", folder->second);
            inner.emplace("machineID", "m");
            Object custom;
            custom.emplace("_0", Value(std::move(inner)));
            profile.emplace("custom", Value(std::move(custom)));
        } else {
            profile.emplace("default", Value(true));
        }
        Object space;
        space.emplace("id", Id(n));
        space.emplace("title", "Space " + std::to_string(n));
        space.emplace("profile", Value(std::move(profile)));
        Array containers;
        containers.push_back(Value("pinned"));
        containers.push_back(Value(Id(n * 10)));
        containers.push_back(Value("unpinned"));
        containers.push_back(Value(Id(n * 10 + 1)));
        space.emplace("containerIDs", Value(std::move(containers)));
        spaceList.push_back(Value(Id(n)));
        spaceList.push_back(Value(std::move(space)));
    }
    Object container;
    container.emplace("spaces", Value(std::move(spaceList)));
    container.emplace("items", Value(Flat(items)));
    container.emplace("topAppsContainerIDs", Value(favorites));
    Array containerList;
    containerList.push_back(Value(std::move(container)));
    Object sidebar;
    sidebar.emplace("containers", Value(std::move(containerList)));
    Object root;
    root.emplace("sidebar", Value(std::move(sidebar)));
    return Parsed(json::Write(Value(std::move(root))));
}

Value FolderItem(int n, std::vector<int> children, std::optional<int> parent = std::nullopt) {
    Value folder = Node(n, Object{{"list", Object{}}}, std::move(children), "Folder " + std::to_string(n));
    if (parent) folder.AsObject()->insert_or_assign("parentID", Id(*parent));
    return folder;
}
Value SplitItem(int n, std::vector<int> children) {
    return Node(n, Object{{"splitView", Object{{"layoutOrientation", "horizontal"}}}}, std::move(children));
}
Value ContainerItem(int n, std::vector<int> children) { return Node(n, Object{{"itemContainer", Object{}}}, std::move(children)); }

using Notes = std::vector<std::string>;

const Folder* FirstFolder(const std::vector<PinnedItem>& items) {
    return items.empty() ? nullptr : std::get_if<Folder>(&items.front().value);
}

}  // namespace

TEST(ArcImport_aSelfParentingFolderImportsOnce) {
    const auto result = Sidebar({
        ContainerItem(10, {100, 101}),
        TabItem(100, 10),
        FolderItem(101, {101, 102}, 101),
        TabItem(102, 101),
        ContainerItem(11, {}),
    });
    const auto& pinned = result.spaces[0].pinnedItems;
    const Folder* folder = pinned.size() == 2 ? std::get_if<Folder>(&pinned[1].value) : nullptr;
    CHECK(folder);
    CHECK((Titles(TabsIn(pinned)) == std::vector<std::string>{"Site 100", "Site 102"}));
    CHECK(folder && folder->items.size() == 1);
    CHECK(result.folderCount == 1);
    CHECK(result.tabCount == 2);
    CHECK((result.notes == Notes{"Skipped 1 repeated or circular sidebar entry."}));
}

TEST(ArcImport_aTwoCycleImportsEachFolderOnce) {
    const auto result = Sidebar({
        // Each folder's parentID names the other, so neither may claim the other first.
        ContainerItem(10, {101}),
        FolderItem(101, {102, 103}, 102),
        FolderItem(102, {101, 104}, 101),
        TabItem(103, 101),
        TabItem(104, 102),
        // The same cycle outside the pinned section, where folders flatten.
        ContainerItem(11, {111}),
        FolderItem(111, {112, 113}),
        FolderItem(112, {111, 114}),
        TabItem(113, 111),
        TabItem(114, 112),
    });
    const Space& space = result.spaces[0];
    const Folder* outer = space.pinnedItems.size() == 1 ? FirstFolder(space.pinnedItems) : nullptr;
    const Folder* inner = outer && outer->items.size() == 2 ? FirstFolder(outer->items) : nullptr;
    CHECK(outer && inner);
    if (!outer || !inner) return;
    CHECK(outer->name == "Folder 101");
    CHECK(inner->name == "Folder 102");
    CHECK((Titles(TabsIn(inner->items)) == std::vector<std::string>{"Site 104"}));
    CHECK((Titles(TabsIn(outer->items)) == std::vector<std::string>{"Site 104", "Site 103"}));
    CHECK((Titles(space.tabs) == std::vector<std::string>{"Site 114", "Site 113"}));
    CHECK(result.folderCount == 2);
    CHECK(result.tabCount == 4);
    CHECK((result.notes == Notes{"Skipped 2 repeated or circular sidebar entries."}));
}

TEST(ArcImport_aCycleThroughASplitImportsEachTabOnce) {
    // Split 400 holds tab 401 and folder 402, which lists the split again.
    const auto result = Sidebar({
        ContainerItem(10, {400}),
        SplitItem(400, {401, 402}),
        TabItem(401, 400),
        FolderItem(402, {400, 403}),
        TabItem(403, 402),
        ContainerItem(11, {}),
    });
    const Space& space = result.spaces[0];
    const auto tabs = TabsIn(space.pinnedItems);
    CHECK((Titles(tabs) == std::vector<std::string>{"Site 401", "Site 403"}));
    CHECK(space.splits.size() == 1 && tabs.size() == 2 && space.splits[0].tabIDs == (std::vector<std::string>{tabs[0]->id, tabs[1]->id}));
    CHECK(result.tabCount == 2);
    CHECK((result.notes == Notes{"Skipped 1 repeated or circular sidebar entry."}));
}

TEST(ArcImport_aChildListedTwiceImportsOnce) {
    // Forty folders that each list the next one twice: 2^40 copies of the last tab if repeats
    // were followed.
    std::vector<Value> items{
        ContainerItem(10, {100, 100, 101}),
        TabItem(100, 10),
        FolderItem(101, {102, 102, 100}),
        TabItem(102, 101),
        ContainerItem(11, {110, 110, 200}),
        TabItem(110, 11),
        TabItem(240, 239),
    };
    for (int i = 0; i < 40; ++i) items.push_back(FolderItem(200 + i, {201 + i, 201 + i}));
    const auto result = Sidebar(items);
    const Space& space = result.spaces[0];
    CHECK(space.pinnedItems.size() == 2);
    CHECK((Titles(TabsIn(space.pinnedItems)) == std::vector<std::string>{"Site 100", "Site 102"}));
    CHECK((Titles(space.tabs) == std::vector<std::string>{"Site 110", "Site 240"}));
    std::set<std::string> ids;
    for (const Tab* tab : space.AllTabs()) ids.insert(tab->id);
    CHECK(ids.size() == space.AllTabs().size());
    CHECK(result.tabCount == 4);
    // Tab 100 under folder 101 isn't counted: it went to its home, losing nothing.
    CHECK((result.notes == Notes{"Skipped 43 repeated or circular sidebar entries."}));
}

TEST(ArcImport_aChildListedUnderTwoParentsGoesToItsParentID) {
    // Tab 100 was moved from space 1's folder to space 2's, and the old listing stayed.
    const auto result = Sidebar({
        ContainerItem(10, {101}),
        FolderItem(101, {100}),
        ContainerItem(11, {}),
        ContainerItem(20, {201}),
        FolderItem(201, {100}),
        TabItem(100, 201),
        ContainerItem(21, {}),
    }, {1, 2});
    CHECK(result.spaces.size() == 2);
    if (result.spaces.size() != 2) return;
    const Folder* old = FirstFolder(result.spaces[0].pinnedItems);
    const Folder* current = FirstFolder(result.spaces[1].pinnedItems);
    CHECK(old && current);
    if (!old || !current) return;
    CHECK(old->items.empty());
    CHECK((Titles(TabsIn(current->items)) == std::vector<std::string>{"Site 100"}));
    CHECK(result.tabCount == 1);
    CHECK(result.notes.empty());
}

TEST(ArcImport_anOrphanedParentIDParentDoesNotDropTheChild) {
    // Tab 100 names folder 201 as its parent, but no space reaches 201.
    const auto result = Sidebar({
        ContainerItem(10, {101}),
        FolderItem(101, {100}),
        FolderItem(201, {100}),
        TabItem(100, 201),
        ContainerItem(11, {}),
    });
    const Folder* folder = FirstFolder(result.spaces[0].pinnedItems);
    CHECK(folder && Titles(TabsIn(folder->items)) == std::vector<std::string>{"Site 100"});
    CHECK(result.tabCount == 1);
    CHECK(result.notes.empty());
}

TEST(ArcImport_aParentIDParentBelowTheChildDoesNotDropIt) {
    // Folder 101 names 103 as its parent, but 103 is inside it (101 > 102 > 103 > 101).
    const auto result = Sidebar({
        ContainerItem(10, {101}),
        FolderItem(101, {102}, 103),
        FolderItem(102, {103}),
        FolderItem(103, {101, 104}),
        TabItem(104, 103),
        ContainerItem(11, {}),
    });
    CHECK((Titles(TabsIn(result.spaces[0].pinnedItems)) == std::vector<std::string>{"Site 104"}));
    CHECK(result.folderCount == 3);
    CHECK((result.notes == Notes{"Skipped 1 repeated or circular sidebar entry."}));
}

TEST(ArcImport_aChildOfAnItemThatDoesntNestImportsUnderTheFolder) {
    // Easel 500 lists tabs 502 and 503 ahead of folder 501, and 502 names it as its parent, but
    // the import never goes into an easel.
    Value unparented = TabItem(503, 0);
    unparented.AsObject()->erase("parentID");
    const auto result = Sidebar({
        ContainerItem(10, {}),
        ContainerItem(11, {500, 501}),
        Node(500, Object{{"easel", Object{}}}, {502, 503}),
        FolderItem(501, {502, 503}),
        TabItem(502, 500),
        unparented,
    });
    CHECK((Titles(result.spaces[0].tabs) == std::vector<std::string>{"Site 502", "Site 503"}));
    CHECK((result.notes == Notes{"Skipped unsupported sidebar items: easel."}));
}

TEST(ArcImport_aFavoriteAlsoInASpaceIsInBoth) {
    // Tab 300 names the favorites grid as its parent; the space still keeps it.
    Object fallback;
    fallback.emplace("default", Value(true));
    Array favorites;
    favorites.push_back(Value(std::move(fallback)));
    favorites.push_back(Value(Id(30)));
    const auto result = Sidebar({
        ContainerItem(10, {300}),
        ContainerItem(11, {}),
        ContainerItem(30, {300}),
        TabItem(300, 30),
    }, {1}, {}, favorites);
    CHECK((Titles(TabsIn(result.spaces[0].pinnedItems)) == std::vector<std::string>{"Site 300"}));
    CHECK((result.favoritesByProfile.contains("Default") && Titles(result.favoritesByProfile.at("Default")) == std::vector<std::string>{"Site 300"}));
    CHECK(result.notes.empty());
}

TEST(ArcImport_profilesSharingAFavoritesGridBothGetIt) {
    Object fallback;
    fallback.emplace("default", Value(true));
    Object inner;
    inner.emplace("directoryBasename", "Profile 3");
    Object zero;
    zero.emplace("_0", Value(std::move(inner)));
    Object custom;
    custom.emplace("custom", Value(std::move(zero)));
    Array favorites;
    favorites.push_back(Value(std::move(fallback)));
    favorites.push_back(Value(Id(30)));
    favorites.push_back(Value(std::move(custom)));
    favorites.push_back(Value(Id(30)));
    const auto result = Sidebar({
        ContainerItem(10, {}),
        ContainerItem(11, {}),
        ContainerItem(20, {}),
        ContainerItem(21, {}),
        ContainerItem(30, {300}),
        TabItem(300, 30),
    }, {1, 2}, {{2, "Profile 3"}}, favorites);
    CHECK((result.profiles == std::vector<std::string>{"Default", "Profile 3"}));
    CHECK((result.favoritesByProfile.contains("Default") && Titles(result.favoritesByProfile.at("Default")) == std::vector<std::string>{"Site 300"}));
    CHECK((result.favoritesByProfile.contains("Profile 3") && Titles(result.favoritesByProfile.at("Profile 3")) == std::vector<std::string>{"Site 300"}));
    CHECK(result.notes.empty());
}

TEST(ArcImport_aVeryDeepChainStopsAtTheCap) {
    // Ten thousand folders, each inside the last, with a tab at the bottom.
    const int depth = 10'000;
    std::vector<Value> items{
        ContainerItem(10, {1000}),
        TabItem(1000 + depth, 999 + depth),
        ContainerItem(11, {1000 + depth + 1}),
        TabItem(1000 + depth + 1, 11),
    };
    for (int i = 0; i < depth; ++i) items.push_back(FolderItem(1000 + i, {1001 + i}));
    const auto result = Sidebar(items);
    int levels = 0;
    const std::vector<PinnedItem>* level = &result.spaces[0].pinnedItems;
    while (const Folder* folder = FirstFolder(*level)) {
        ++levels;
        level = &folder->items;
    }
    CHECK(levels == arc_import::kMaxDepth);
    CHECK(level->empty());
    CHECK(result.folderCount == arc_import::kMaxDepth);
    CHECK((Titles(result.spaces[0].tabs) == std::vector<std::string>{"Site " + std::to_string(1000 + depth + 1)}));
    // Every folder below the cap, and the tab at the bottom.
    const int cut = depth - arc_import::kMaxDepth + 1;
    CHECK((result.notes == Notes{std::to_string(cut) + " items nested more than 64 levels deep were left out."}));
}

TEST(ArcImport_aSplitInAFolderAtTheCap) {
    // Folders down to level 61. The last holds split 2000 (level 62, its tabs at 63: kept) and
    // folder 1062 (level 62), whose split 3000 puts its tabs at 64, past the cap.
    CHECK(arc_import::kMaxDepth == 64);
    std::vector<Value> items{
        ContainerItem(10, {1000}),
        FolderItem(1061, {2000, 1062}),
        SplitItem(2000, {2001, 2002}),
        TabItem(2001, 2000),
        TabItem(2002, 2000),
        FolderItem(1062, {3000}),
        SplitItem(3000, {3001, 3002}),
        TabItem(3001, 3000),
        TabItem(3002, 3000),
        ContainerItem(11, {}),
    };
    for (int i = 0; i < 61; ++i) items.push_back(FolderItem(1000 + i, {1001 + i}));
    const auto result = Sidebar(items);
    const Space& space = result.spaces[0];
    const auto tabs = TabsIn(space.pinnedItems);
    CHECK((Titles(tabs) == std::vector<std::string>{"Site 2001", "Site 2002"}));
    CHECK(space.splits.size() == 1 && tabs.size() == 2 && space.splits[0].tabIDs == (std::vector<std::string>{tabs[0]->id, tabs[1]->id}));
    CHECK(result.splitCount == 1);
    CHECK(result.folderCount == 63);
    CHECK((result.notes == Notes{"2 items nested more than 64 levels deep were left out."}));
}

// Windows' additions.

TEST(ArcImport_reviewersSelfParentingFolderNoLongerOverflows) {
    // Reviewer B's PoC input (cycle.json), which overflowed the stack before the fix.
    const auto result = Parsed(R"({"sidebar":{"containers":[{"spaces":[{"id":"00000000-0000-4000-8000-000000000001","title":"S",)"
                               R"("containerIDs":["pinned","P"]}],"items":[{"id":"P","childrenIds":["F"],"data":{"itemContainer":{}}},)"
                               R"({"id":"F","title":"Loop","childrenIds":["F"],"data":{"list":{}}}]}]}})");
    CHECK(result.spaces.size() == 1 && result.spaces[0].pinnedItems.size() == 1 && result.folderCount == 1 && result.repeatedItems == 1);
    CHECK((result.notes == Notes{"Skipped 1 repeated or circular sidebar entry."}));
}

TEST(ArcImport_aTabsChildrenAreNeverFollowed) {
    // Only folders and split views expand: a tab that lists children (a damaged file) is a tab.
    Value tab = TabItem(100, 10);
    tab.AsObject()->insert_or_assign("childrenIds", Array{Id(101)});
    const auto result = Sidebar({ContainerItem(10, {100}), tab, TabItem(101, 100), ContainerItem(11, {})});
    CHECK((Titles(TabsIn(result.spaces[0].pinnedItems)) == std::vector<std::string>{"Site 100"}));
    CHECK(result.tabCount == 1 && result.notes.empty());
}

// MARK: Arc for Windows (and edge cases the Mac doesn't test)

namespace {

// The Mac fixture's Personal space in Arc for Windows' shape: its containers as
// newContainerIDs only, an icon from Arc's icon set, and the members Arc for Windows adds.
std::string WindowsFixture(bool bothContainerLists, const std::string& icon) {
    Array containers{Object{{"pinned", Object{}}}, Id(10), Object{{"unpinned", Object{{"_0", Object{{"shared", Object{}}}}}}}, Id(11)};
    Object space{{"id", Id(1)}, {"title", "Personal"}, {"customInfo", Object{{"iconType", Object{{"icon", icon}}}}},
                 {"newContainerIDs", containers}, {"profile", Object{{"default", true}}}};
    if (bothContainerLists) space.emplace("containerIDs", Array{"unpinned", Id(11), "pinned", Id(10)});
    auto windowsTab = [](int n, int parent) {
        Value tab = TabItem(n, parent);
        Object o = *tab.AsObject();
        o.emplace("createdAt", 800000000.25);
        o.emplace("isUnread", false);
        o.emplace("originatingDevice", "DEVICE");
        Object data = *o.at("data").AsObject();
        Object inner = *data.at("tab").AsObject();
        inner.erase("timeLastActiveAt");
        inner.emplace("savedMuteStatus", "allowAudio");
        data.insert_or_assign("tab", Value(std::move(inner)));
        o.insert_or_assign("data", Value(std::move(data)));
        return Value(std::move(o));
    };
    std::vector<Value> items{
        Node(10, Container("spaceItems", Object{{"_0", Id(1)}}), {100, 104}),
        windowsTab(100, 10),
        Node(104, Object{{"splitView", Object{{"customInfo", Value()}, {"focusItemID", Value()}, {"itemWidthFactors", Array{}},
                                              {"layoutOrientation", "horizontal"}, {"timeLastActiveAt", Value()}}}}, {106, 107}),
        windowsTab(106, 104),
        windowsTab(107, 104),
        Node(11, Container("spaceItems", Object{{"_0", Id(1)}}), {110}),
        windowsTab(110, 11),
        Node(30, Container("topApps", Object{{"_0", Object{{"default", true}}}}), {300}),
        windowsTab(300, 30),
    };
    Value root = Object{
        {"firebaseSyncState", Object{{"publishInProgress", false}, {"syncHealthStatus", Object{{"off", Object{}}}}}},
        {"sidebar", Object{{"containers", Array{Object{{"global", Object{}}},
                                                Object{{"spaces", Array{Id(1), Value(std::move(space))}},
                                                       {"items", Flat(items)},
                                                       {"topAppsContainerIDs", Array{Object{{"default", true}}, Id(30)}}}}}}},
        {"version", 1},
    };
    return json::Write(root);
}

}  // namespace

TEST(ArcImportWindows_readsNewContainerIDsAndArcIcons) {
    for (bool both : {false, true}) {
        const auto result = Parsed(WindowsFixture(both, "star"));
        CHECK(result.spaces.size() == 1);
        if (result.spaces.empty()) continue;
        const Space& space = result.spaces[0];
        // "star" isn't one of Kite's symbols, "star.fill" is: Arc's icon set drops the fill.
        CHECK(space.icon == "symbol:star.fill");
        CHECK((Titles(space.Pinned()) == std::vector<std::string>{"Site 100", "Site 106", "Site 107"}));
        CHECK((Titles(space.tabs) == std::vector<std::string>{"Site 110"}));
        CHECK(space.splits.size() == 1 && space.splits[0].widthFactors == (std::vector<double>{0.5, 0.5}));
        CHECK((Titles(result.favoritesByProfile.at("Default")) == std::vector<std::string>{"Site 300"}));
        CHECK(result.iconsReplaced.empty() && result.notes.empty());
    }
}

TEST(ArcImportWindows_anIconKiteDoesntHaveGetsTheStandIn) {
    const auto result = Parsed(WindowsFixture(false, "nosuchicon"));
    CHECK(result.spaces.size() == 1 && result.spaces[0].icon == "\xF0\x9F\x8C\x80");  // the first fallback, 🌀
    // Recorded by space, so the import counts only the spaces that come over (its note too).
    CHECK(result.iconsReplaced == std::set<std::string>{Id(1)});
}

TEST(ArcImportWindows_theFixtureFolderSidebar) {
    // The hand-made Arc for Windows folder the CLI test imports.
    std::ifstream in(std::filesystem::path(KITE_ARC_FIXTURE_DIR) / "StorableSidebar.json", std::ios::binary);
    const std::string text{std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
    const auto result = Parsed(text);
    CHECK(result.spaces.size() == 2);
    if (result.spaces.size() != 2) return;
    const Space& reading = result.spaces[0];
    CHECK(reading.name == "Reading" && reading.icon == "symbol:book.fill");
    CHECK((reading.theme.colors == std::vector<ThemeColor>{{0.2f, 0.4f, 0.6f}}));
    CHECK(Near(reading.theme.grain, 0.1) && reading.theme.tint == 1);  // opaque
    CHECK((Titles(reading.Pinned()) == std::vector<std::string>{"Inbox", "Guide", "Left", "Right"}));
    CHECK((Titles(reading.tabs) == std::vector<std::string>{"Today", "A Video"}));
    CHECK(reading.splits.size() == 1);
    CHECK(result.untitledSpaceIDs == std::set<std::string>{Id(2)});
    CHECK(result.spaces[1].name == "Arc Space" && SpaceProfile(result.spaces[1]) == "Profile 1");
    CHECK(result.iconsReplaced == std::set<std::string>{Id(2)} && result.skippedKinds == (std::map<std::string, int>{{"easel", 1}}));
    CHECK((result.profiles == std::vector<std::string>{"Default", "Profile 1"}));
    CHECK(result.tabCount == 9 && result.folderCount == 1 && result.splitCount == 1);
}

TEST(ArcImport_edgeCases) {
    // An address URL(string:) refuses is no address; an emoji code that isn't a scalar is no icon.
    Value space = Object{{"id", Id(1)}, {"title", "S"}, {"customInfo", Object{{"iconType", Object{{"emoji", 0xD800}}}}},
                         {"containerIDs", Array{"unpinned", Id(11)}}};
    Value bad = Object{{"id", Id(110)}, {"childrenIds", Array{}}, {"data", Object{{"tab", Object{{"savedURL", "https://a b.example/"}}}}}};
    // childrenIds with one that isn't a string reads as none (`as? [String]`).
    Value odd = Object{{"id", Id(111)}, {"childrenIds", Array{Id(110), 5}}, {"data", Object{{"list", Object{}}}}};
    std::vector<Value> items{Node(11, Container("spaceItems", Object{{"_0", Id(1)}}), {110, 111}), bad, odd};
    Value root = Object{{"sidebar", Object{{"containers", Array{Object{{"spaces", Array{space}}, {"items", Flat(items)}}}}}}};
    const auto result = Parsed(json::Write(root));
    CHECK(result.spaces.size() == 1);
    if (result.spaces.empty()) return;
    CHECK(result.spaces[0].icon == "\xF0\x9F\x8C\x80");
    CHECK(result.spaces[0].tabs.size() == 1 && !result.spaces[0].tabs[0].url && result.spaces[0].tabs[0].title.empty());
    CHECK(!arc_import::IsURL("") && !arc_import::IsURL("https://x/\t") && arc_import::IsURL("https://x.example/a?b=c#d"));
    CHECK(!arc_import::BackupDate("StorableSidebar.2026-02-31-10-00-00-000.json"));
}

TEST(ArcImport_aContainerKeyGivenTwiceTakesItsLastValue) {
    Value space = Object{{"id", Id(1)}, {"title", "S"}, {"containerIDs", Array{"unpinned", Id(11), "unpinned", Id(12)}}};
    std::vector<Value> items{ContainerItem(11, {110}), TabItem(110, 11), ContainerItem(12, {120}), TabItem(120, 12)};
    Value root = Object{{"sidebar", Object{{"containers", Array{Object{{"spaces", Array{space}}, {"items", Flat(items)}}}}}}};
    CHECK((Titles(Parsed(json::Write(root)).spaces[0].tabs) == std::vector<std::string>{"Site 120"}));
}

TEST(ArcImport_mergeGivesPinnedTabsTheirPinnedURL) {
    // BrowserImport.merge(imported:) runs syncPinnedURLs.
    BrowserState state = Fresh();
    const auto result = Parsed();
    MergeImported(state, result.spaces);
    const Space* personal = SpaceWithID(state, Id(1));
    CHECK(personal);
    if (!personal) return;
    bool all = true;
    for (const Tab* tab : personal->Pinned()) all = all && tab->pinnedURL == tab->url;
    CHECK(all);
    CHECK(!personal->tabs.front().pinnedURL);
    CHECK(state.selectedSpaceID == Id(1));
    // ...and takes it off unpinned tabs, so pinning one again pins the page it's on then.
    BrowserState again = Fresh();
    std::vector<Space> spaces = result.spaces;
    spaces[0].tabs.front().pinnedURL = "https://old.example/";
    MergeImported(again, spaces);
    CHECK(!SpaceWithID(again, Id(1))->tabs.front().pinnedURL);
}

// Runs against a real Arc file when KITE_ARC_SIDEBAR points at one (importsRealArcFile). Prints
// counts only, never names or addresses.
TEST(ArcImport_importsRealArcFile) {
    const auto path = EnvironmentPath("KITE_ARC_SIDEBAR");
    if (!path) return;
    std::ifstream in(*path, std::ios::binary);
    const std::string text{std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
    const auto result = Parsed(text);
    std::printf("Arc import: %zu spaces, %zu favorites, %d tabs, %d folders\n", result.spaces.size(), result.Favorites().size(),
                result.tabCount, result.folderCount);
    CHECK(!result.spaces.empty());
}
