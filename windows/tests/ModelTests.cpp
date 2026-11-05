// Ports of KiteCore's BrowserState, SessionStore and Models tests (KiteCoreTests.swift),
// plus the shared session fixture (Tests/Fixtures/session-v1.json) the Mac suite also loads.

#include <filesystem>
#include <fstream>
#include <sstream>

#include "Check.h"
#include "core/Models.h"
#include "core/SessionStore.h"
#include "core/Uuid.h"

using namespace kite;
namespace fs = std::filesystem;

namespace {

std::string ReadFile(const fs::path& path) {
    std::ifstream in(path, std::ios::binary);
    std::stringstream s;
    s << in.rdbuf();
    return s.str();
}

BrowserState LoadFixture() {
    auto parsed = json::Parse(ReadFile(fs::path(KITE_FIXTURES_DIR) / "session-v1.json"));
    CHECK(std::holds_alternative<json::Value>(parsed));
    const json::Value* state = std::get<json::Value>(parsed).Find("state");
    CHECK(state != nullptr);
    auto decoded = DecodeBrowserState(*state);
    CHECK(decoded.has_value());
    return decoded ? *decoded : BrowserState::MakeDefault();
}

fs::path TempDir() {
    fs::path dir = fs::temp_directory_path() / ("kite-test-" + NewUuid());
    fs::create_directories(dir);
    return dir;
}

}  // namespace

TEST(decodesTheSharedFixture) {
    BrowserState state = LoadFixture();
    CHECK(state.spaces.size() == 2);
    CHECK(state.spaces[0].name == "Personal");
    CHECK(state.SelectedSpace().name == "Work");
    CHECK(state.searchEngine == "duckDuckGo");
    CHECK(state.Favorites().size() == 1 && state.Favorites()[0].title == "Mail");
    auto pinned = state.spaces[0].Pinned();
    CHECK(pinned.size() == 2);
    CHECK(pinned[0]->DisplayTitle() == "Docs");
    CHECK(pinned[1]->DisplayTitle() == "Renamed");
    CHECK(state.spaces[0].tabs[0].DisplayTitle() == "example.com");
    // The second space uses the pre-folders `pinned` array and has no `tint`.
    CHECK(state.spaces[1].Pinned().size() == 1 && state.spaces[1].Pinned()[0]->title == "Old pinned");
    CHECK(state.spaces[1].theme.tint == Theme::kDefaultTint);
    CHECK(state.spaces[1].extra.count("about") == 1);
    CHECK(state.extra.count("adblockAllowedHosts") == 1);
}

TEST(fixtureRoundTripsWithoutLosingMacOnlyFields) {
    BrowserState state = LoadFixture();
    json::Value encoded = Encode(state);
    auto again = DecodeBrowserState(encoded);
    CHECK(again.has_value() && *again == state);
    // Members Windows doesn't model yet are written back as they were.
    CHECK(encoded.Find("darkPages") && *encoded.Find("darkPages")->AsString() == "matchSystem");
    CHECK(encoded.Find("spaces")->AsArray()->at(1).Find("about") != nullptr);
    // The legacy `pinned` array is rewritten as pinnedItems, like the Mac does.
    CHECK(encoded.Find("spaces")->AsArray()->at(1).Find("pinned") == nullptr);
    CHECK(encoded.Find("spaces")->AsArray()->at(1).Find("pinnedItems") != nullptr);
}

TEST(pinnedItemsUseSwiftEnumCoding) {
    BrowserState state = LoadFixture();
    json::Value item = Encode(state.spaces[0].pinnedItems[1]);
    const json::Value* folder = item.Find("folder");
    CHECK(folder && folder->Find("_0") && folder->Find("_0")->Find("name"));
}

// Swift's JSONDecoder refuses a number a Float can't hold, and a tint of the wrong type.
TEST(themeFloatsMustFitAFloat) {
    auto parse = [](const char* text) { return DecodeTheme(std::get<json::Value>(json::Parse(text))); };
    CHECK(parse(R"({"colors":[{"r":1,"g":0,"b":0}],"grain":0.3})").has_value());
    CHECK(!parse(R"({"colors":[{"r":1e39,"g":0,"b":0}],"grain":0.3})"));
    CHECK(!parse(R"({"colors":[{"r":1,"g":0,"b":0}],"grain":-1e300})"));
    CHECK(!parse(R"({"colors":[{"r":1,"g":0,"b":0}],"grain":0.3,"tint":"x"})"));
    CHECK(parse(R"({"colors":[{"r":1,"g":0,"b":0}],"grain":0.3,"tint":null})")->tint == Theme::kDefaultTint);
}

TEST(setFavoritesWritesTheCurrentProfilesGrid) {
    BrowserState state = BrowserState::MakeDefault(std::nullopt);
    Tab tab;
    tab.id = NewUuid();
    state.SetFavorites({tab});
    CHECK(state.favoritesByProfile.count("Default") == 1 && state.Favorites().size() == 1);
    state.SetFavorites({});
    CHECK(state.favoritesByProfile.empty() && state.Favorites().empty());  // empty grids have no entry
}

// Swift's synthesized enum decoding looks only at the case keys.
TEST(pinnedItemsIgnoreUnknownKeysButNeedOneCase) {
    auto parse = [](const char* text) { return DecodePinnedItem(std::get<json::Value>(json::Parse(text))); };
    const char* tab = R"({"tab":{"_0":{"id":"C1D2E3F4-A5B6-4C7D-8E9F-0A1B2C3D4E5F","title":"T","lastActiveAt":0}},"x":1})";
    CHECK(parse(tab).has_value());
    CHECK(!parse(R"({"x":1})"));
    CHECK(!parse(R"({"tab":{"_0":{}},"folder":{"_0":{}}})"));
}

TEST(themeFloatsAreWrittenLikeSwift) {
    std::string text = json::Write(Encode(Theme::Make({{0.1f, 0.2f, 0.3f}}, 0.35f, 0.55f)));
    CHECK(text == R"({"colors":[{"b":0.3,"g":0.2,"r":0.1}],"grain":0.35,"tint":0.55})");
}

TEST(makeDefaultHasPersonalAndWork) {
    BrowserState state = BrowserState::MakeDefault();
    CHECK(state.spaces.size() == 2);
    CHECK(state.spaces[0].name == "Personal" && state.spaces[1].name == "Work");
    CHECK(state.SelectedTab() && state.SelectedTab()->url == std::optional<std::string>("https://www.wikipedia.org"));
    CHECK(IsUuid(state.spaces[0].id) && state.spaces[0].id != state.spaces[1].id);
    CHECK(BrowserState::MakeDefault(std::nullopt).SelectedTab() == nullptr);
}

// KiteCoreTests.swift BrowserStateTests.openTabSelectsAndGoesOnTop
TEST(openTabSelectsAndGoesOnTop) {
    BrowserState state = BrowserState::MakeDefault();
    std::string first = state.OpenTab("https://a.example");
    std::string second = state.OpenTab("https://b.example");
    CHECK(state.SelectedSpace().tabs[0].id == second);
    CHECK(state.SelectedSpace().tabs[1].id == first);
    CHECK(state.SelectedTab() && state.SelectedTab()->id == second);
}

TEST(openTabInAnotherSpaceSwitchesToIt) {
    BrowserState state = BrowserState::MakeDefault();
    std::string work = state.spaces[1].id;
    state.OpenTab("https://w.example", work);
    CHECK(state.selectedSpaceID == work);
    state.OpenTab("https://bg.example", state.spaces[0].id, /*select=*/false);
    CHECK(state.selectedSpaceID == work);
}

TEST(selectingAFavoriteKeepsTheSpace) {
    BrowserState state = LoadFixture();
    std::string space = state.selectedSpaceID;
    state.Select(state.Favorites()[0].id, 100);
    CHECK(state.selectedSpaceID == space);
    CHECK(state.Favorites()[0].lastActiveAt == 100);
    state.Select(state.spaces[0].Pinned()[1]->id, 200);  // inside a folder
    CHECK(state.selectedSpaceID == state.spaces[0].id);
    CHECK(state.SelectedTab() && state.SelectedTab()->lastActiveAt == 200);
}

// FolderTests' shape (a folder inside a folder), selecting the innermost tab.
TEST(selectsATabInANestedFolder) {
    BrowserState state = BrowserState::MakeDefault(std::nullopt);
    Tab outerTab, innerTab;
    outerTab.id = NewUuid();
    innerTab.id = NewUuid();
    Folder inner{NewUuid(), "Inner", true, {PinnedItem{innerTab}}, std::nullopt, std::nullopt, {}};
    Folder outer{NewUuid(), "Reading", true, {PinnedItem{outerTab}, PinnedItem{inner}}, std::nullopt, std::nullopt, {}};
    state.spaces[1].pinnedItems.push_back(PinnedItem{outer});
    state.Select(innerTab.id, 300);
    CHECK(state.selectedSpaceID == state.spaces[1].id);
    CHECK(state.SelectedTab() && state.SelectedTab()->id == innerTab.id && state.SelectedTab()->lastActiveAt == 300);
    auto location = state.Location(innerTab.id);
    CHECK(location && location->section == TabSection::Pinned && location->index == 1);
    CHECK(state.FindTabByID(outerTab.id) && state.FindTabByID(outerTab.id)->lastActiveAt == 0);
}

// Every UI-gate state is a session both apps read.
TEST(helixStatesDecode) {
    int count = 0;
    for (const auto& entry : fs::directory_iterator(fs::path(KITE_STATES_DIR))) {
        if (entry.path().extension() != ".json") continue;
        auto parsed = json::Parse(ReadFile(entry.path()));
        CHECK(std::holds_alternative<json::Value>(parsed));
        const json::Value* state = std::holds_alternative<json::Value>(parsed) ? std::get<json::Value>(parsed).Find("state") : nullptr;
        CHECK(state && DecodeBrowserState(*state));
        ++count;
    }
    CHECK(count >= 1);
}

// KiteCoreTests.swift BrowserStateTests.spacesCycleAndSelectionFollowsTab (cycling part)
TEST(spacesCycle) {
    BrowserState state = BrowserState::MakeDefault();
    std::string added = state.AddSpace("Third", "", Theme::Presets()[2]);
    CHECK(state.selectedSpaceID == added);
    state.SelectAdjacentSpace(1);
    CHECK(state.SelectedSpaceIndex() == 0);
    state.SelectAdjacentSpace(-1);
    CHECK(state.SelectedSpaceIndex() == 2);
    state.SelectSpace("not a space");
    CHECK(state.SelectedSpaceIndex() == 2);
    // selectSpace(at:): by position, and nothing past the last (Space 9 with three spaces).
    state.SelectSpaceAt(0);
    CHECK(state.SelectedSpaceIndex() == 0);
    state.SelectSpaceAt(8);
    CHECK(state.SelectedSpaceIndex() == 0);
}

TEST(sidebarTabsAreFavoritesPinnedThenUnpinned) {
    BrowserState state = LoadFixture();
    auto tabs = state.SidebarTabs(0);
    CHECK(tabs.size() == 4);
    CHECK(tabs[0]->title == "Mail" && tabs[1]->title == "Docs" && tabs[2]->title == "Shop" && tabs[3]->url == std::optional<std::string>("https://example.com/"));
}

// KiteCoreTests.swift SessionStoreTests.roundTripsAndQuarantinesCorruptFiles
TEST(sessionRoundTripsAndQuarantinesCorruptFiles) {
    fs::path dir = TempDir();
    SessionStore store(dir / "session.json");
    CHECK(std::holds_alternative<SessionStore::Missing>(store.Load()));

    BrowserState state = BrowserState::MakeDefault();
    state.OpenTab("https://kite.example", std::nullopt, true, FromUnixTime(1700000000));
    CHECK(store.Save(state).empty());
    auto loaded = store.Load();
    CHECK(std::holds_alternative<BrowserState>(loaded) && std::get<BrowserState>(loaded) == state);

    std::ofstream(dir / "session.json", std::ios::trunc) << "{nope";
    auto broken = store.Load();
    CHECK(std::holds_alternative<SessionStore::Error>(broken));
    CHECK(!fs::exists(dir / "session.json"));
    bool quarantined = false;
    for (const auto& entry : fs::directory_iterator(dir)) {
        if (entry.path().filename().u8string().find(u8"corrupt") != std::u8string::npos) quarantined = true;
    }
    CHECK(quarantined);
    fs::remove_all(dir);
}

TEST(lookingAtAnUnreadableSessionLeavesItInPlace) {
    fs::path dir = TempDir();
    SessionStore store(dir / "session.json");
    std::ofstream(dir / "session.json", std::ios::trunc) << "{nope";
    auto result = store.Load(SessionStore::Unreadable::Leave);
    CHECK(std::holds_alternative<SessionStore::Error>(result));
    CHECK(fs::exists(dir / "session.json"));
    CHECK(!SessionStore::MaySave(result));
    fs::remove_all(dir);
}

TEST(quarantineNeverReplacesAnEarlierBackup) {
    fs::path dir = TempDir();
    SessionStore store(dir / "session.json");
    for (int i = 0; i < 3; ++i) {
        std::ofstream(dir / "session.json", std::ios::trunc) << "{nope" << i;
        auto result = store.Load();
        CHECK(std::holds_alternative<SessionStore::Error>(result) && std::get<SessionStore::Error>(result).quarantinedTo);
    }
    int backups = 0;
    for (const auto& entry : fs::directory_iterator(dir)) backups += entry.path().filename().u8string().find(u8"corrupt") != std::u8string::npos;
    CHECK(backups == 3);
    fs::remove_all(dir);
}

TEST(loadsASessionWithAByteOrderMark) {
    fs::path dir = TempDir();
    SessionStore store(dir / "session.json");
    CHECK(store.Save(BrowserState::MakeDefault()).empty());
    std::string text = "\xEF\xBB\xBF" + ReadFile(dir / "session.json");
    std::ofstream(dir / "session.json", std::ios::binary | std::ios::trunc) << text;
    CHECK(std::holds_alternative<BrowserState>(store.Load()));
    fs::remove_all(dir);
}

TEST(savedSessionHasTheMacEnvelope) {
    fs::path dir = TempDir();
    SessionStore store(dir / "session.json");
    CHECK(store.Save(BrowserState::MakeDefault()).empty());
    auto parsed = json::Parse(ReadFile(dir / "session.json"));
    const json::Value& root = std::get<json::Value>(parsed);
    CHECK(root.Find("version") && root.Find("version")->AsInt() == 1);
    CHECK(root.Find("state") && root.Find("state")->Find("spaces"));
    CHECK(!fs::exists(dir / "session.json.tmp"));
    fs::remove_all(dir);
}

TEST(neverSavesOverASessionItCouldNotMoveAside) {
    CHECK(SessionStore::MaySave(SessionStore::LoadResult{SessionStore::Missing{}}));
    CHECK(SessionStore::MaySave(SessionStore::LoadResult{BrowserState::MakeDefault()}));
    CHECK(SessionStore::MaySave(SessionStore::LoadResult{SessionStore::Error{"bad", fs::path("x.corrupt-1.json")}}));
    CHECK(!SessionStore::MaySave(SessionStore::LoadResult{SessionStore::Error{"locked", std::nullopt}}));
}

TEST(unreadableSessionIsNotQuarantinedWhenItCannotBeOpened) {
    // A directory where session.json should be: it can't be read as a file.
    fs::path dir = TempDir();
    fs::create_directories(dir / "session.json" / "inner");
    SessionStore store(dir / "session.json");
    auto result = store.Load();
    CHECK(std::holds_alternative<SessionStore::Error>(result));
    // Whatever happened to it, Kite must not save over something still in place.
    if (fs::exists(dir / "session.json")) CHECK(!SessionStore::MaySave(result));
    fs::remove_all(dir);
}

TEST(fixtureRoundTripsAtTheJsonLevel) {
    auto parsed = json::Parse(ReadFile(fs::path(KITE_FIXTURES_DIR) / "session-v1.json"));
    json::Value original = *std::get<json::Value>(parsed).Find("state");
    json::Value encoded = Encode(*DecodeBrowserState(original));
    // The only expected differences: legacy `pinned` → `pinnedItems`, whose tab takes its page as
    // its pinned URL (the Mac decoder's syncPinnedURLs), and the default `tint`.
    json::Object expected = *original.AsObject();
    json::Array spaces = *expected["spaces"].AsArray();
    json::Object work = *spaces[1].AsObject();
    json::Array items;
    for (const auto& legacy : *work["pinned"].AsArray()) {
        json::Object tab = *legacy.AsObject();
        tab["pinnedURL"] = tab["url"];
        items.push_back(json::Value(json::Object{{"tab", json::Value(json::Object{{"_0", json::Value(std::move(tab))}})}}));
    }
    work.erase("pinned");
    work["pinnedItems"] = json::Value(std::move(items));
    json::Object theme = *work["theme"].AsObject();
    theme["tint"] = json::Value(0.55);  // Theme.defaultTint, written as Swift writes the Float
    work["theme"] = json::Value(std::move(theme));
    spaces[1] = json::Value(std::move(work));
    expected["spaces"] = json::Value(std::move(spaces));
    CHECK(json::Write(encoded) == json::Write(json::Value(std::move(expected))));
}

TEST(favoritesFollowTheSpacesProfile) {
    BrowserState state = LoadFixture();  // selected space: Work
    state.extra["profiles"] = json::Value(json::Array{json::Value(json::Object{{"directory", "Profile 1"}, {"name", "Work"}})});
    Tab workFavorite;
    workFavorite.id = NewUuid();
    workFavorite.title = "Work mail";
    state.favoritesByProfile["Profile 1"] = {workFavorite};
    state.spaces[1].extra["profile"] = json::Value("Profile 1");
    state.spaces[1].selectedTabID = workFavorite.id;
    CHECK(state.SelectedProfileDirectory() == "Profile 1");
    CHECK(state.SidebarTabs(1).front()->title == "Work mail");
    CHECK(state.SelectedTab() && state.SelectedTab()->id == workFavorite.id);
    CHECK(state.Location(workFavorite.id).has_value());
    // The Default grid isn't visible from a Profile 1 space.
    CHECK(!state.Location(state.favoritesByProfile["Default"][0].id));
    // A space whose profile was deleted counts as Default.
    state.spaces[1].extra["profile"] = json::Value("Gone");
    CHECK(state.SelectedProfileDirectory() == "Default");

    state.spaces[1].extra["profile"] = json::Value("Profile 1");
    json::Value encoded = Encode(state);
    CHECK(encoded.Find("profileFavorites") && encoded.Find("profileFavorites")->Find("Profile 1"));
    CHECK(encoded.Find("favorites")->AsArray()->size() == 1);
    CHECK(*DecodeBrowserState(encoded) == state);
}

TEST(nullOptionalsCountAsMissingLikeDecodeIfPresent) {
    BrowserState state = LoadFixture();
    json::Value v = Encode(state);
    v.AsObject()->insert_or_assign("favorites", json::Value());
    json::Array spaces = *v.Find("spaces")->AsArray();
    spaces[0].AsObject()->insert_or_assign("pinnedItems", json::Value());
    spaces[0].AsObject()->insert_or_assign("selectedTabID", json::Value());
    v.AsObject()->insert_or_assign("spaces", json::Value(std::move(spaces)));
    auto decoded = DecodeBrowserState(v);
    CHECK(decoded.has_value());
    if (decoded) {
        CHECK(decoded->spaces[0].pinnedItems.empty());
        CHECK(decoded->favoritesByProfile.empty());
    }
}

TEST(uuidsAreNormalizedAndValidatedLikeFoundation) {
    BrowserState state = LoadFixture();
    json::Value v = Encode(state);
    json::Array spaces = *v.Find("spaces")->AsArray();
    std::string lower = "c1d2e3f4-a5b6-4c7d-8e9f-0a1b2c3d4e5f";
    spaces[0].AsObject()->insert_or_assign("selectedTabID", json::Value(lower));
    v.AsObject()->insert_or_assign("spaces", json::Value(spaces));
    v.AsObject()->insert_or_assign("selectedSpaceID", json::Value(state.spaces[0].id));
    auto decoded = DecodeBrowserState(v);
    CHECK(decoded && decoded->SelectedTab() && decoded->SelectedTab()->id == "C1D2E3F4-A5B6-4C7D-8E9F-0A1B2C3D4E5F");

    spaces[0].AsObject()->insert_or_assign("id", json::Value("not-a-uuid"));
    v.AsObject()->insert_or_assign("spaces", json::Value(spaces));
    CHECK(!DecodeBrowserState(v));
}

TEST(saveReplacesAnExistingSession) {
    fs::path dir = TempDir();
    SessionStore store(dir / "session.json");
    BrowserState first = BrowserState::MakeDefault();
    CHECK(store.Save(first).empty());
    BrowserState second = first;
    second.OpenTab("https://second.example");
    CHECK(store.Save(second).empty());
    auto loaded = store.Load();
    CHECK(std::holds_alternative<BrowserState>(loaded) && std::get<BrowserState>(loaded) == second);
    fs::remove_all(dir);
}

TEST(openAndSelectIgnoreUnknownIds) {
    BrowserState state = BrowserState::MakeDefault();
    BrowserState before = state;
    state.Select("00000000-0000-4000-8000-000000000000");
    CHECK(state == before);
    state.OpenTab("https://x.example", std::string("00000000-0000-4000-8000-000000000000"));  // unknown space: current one
    CHECK(state.SelectedSpaceIndex() == 0 && state.spaces[0].tabs.size() == 2);
}
