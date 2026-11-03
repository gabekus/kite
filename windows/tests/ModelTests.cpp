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
    CHECK(state.favorites.size() == 1 && state.favorites[0].title == "Mail");
    auto pinned = state.spaces[0].Pinned();
    CHECK(pinned.size() == 2);
    CHECK(pinned[0].DisplayTitle() == "Docs");
    CHECK(pinned[1].DisplayTitle() == "Renamed");
    CHECK(state.spaces[0].tabs[0].DisplayTitle() == "example.com");
    // The second space uses the pre-folders `pinned` array and has no `tint`.
    CHECK(state.spaces[1].Pinned().size() == 1 && state.spaces[1].Pinned()[0].title == "Old pinned");
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
    state.Select(state.favorites[0].id, 100);
    CHECK(state.selectedSpaceID == space);
    CHECK(state.favorites[0].lastActiveAt == 100);
    state.Select(state.spaces[0].Pinned()[1].id, 200);  // inside a folder
    CHECK(state.selectedSpaceID == state.spaces[0].id);
    CHECK(state.SelectedTab() && state.SelectedTab()->lastActiveAt == 200);
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
}

TEST(sidebarTabsAreFavoritesPinnedThenUnpinned) {
    BrowserState state = LoadFixture();
    auto tabs = state.SidebarTabs(0);
    CHECK(tabs.size() == 4);
    CHECK(tabs[0].title == "Mail" && tabs[1].title == "Docs" && tabs[2].title == "Shop" && tabs[3].url == std::optional<std::string>("https://example.com/"));
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
        if (entry.path().filename().string().find("corrupt") != std::string::npos) quarantined = true;
    }
    CHECK(quarantined);
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
