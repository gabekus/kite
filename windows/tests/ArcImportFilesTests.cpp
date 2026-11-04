// Ports of KiteCore's ArcArchiveSettingsImportTests (the archive and settings cases; its
// history cases wait for a history store), ArcKeyBindingsImportTests and
// ArcLinkRoutingImportTests, case for case, each named after its Swift test. Then what Kite for
// Windows adds: Arc for Windows' settings plist, the Web Data reader behind Site Search (the
// Mac uses the system's SQLite), and ArcImportController's folder handling and import, on the
// hand-made Arc for Windows folder in tests/fixtures (never anyone's real data).

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>

#include "Check.h"
#include "core/AirTrafficControl.h"
#include "core/ArcImportController.h"
#include "core/ArcImportFiles.h"
#include "core/Plist.h"
#include "core/Profiles.h"
#include "core/SQLiteReader.h"
#include "core/SessionStore.h"
#include "core/SiteSearch.h"
#include "core/Uuid.h"

using namespace kite;
using namespace kite::arc_import;
using json::Array;
using json::Object;
using json::Value;
namespace fs = std::filesystem;
using M = KeyShortcut::Modifier;

namespace {

std::string Id(int n) {
    char buffer[40];
    std::snprintf(buffer, sizeof buffer, "00000000-0000-4000-8000-%012d", n);
    return buffer;
}

std::string Read(const fs::path& file) {
    std::ifstream in(file, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

fs::path ArcFixture() { return fs::path(KITE_ARC_FIXTURE_DIR); }

// A fresh folder under the system's temp directory, removed when the test ends.
struct TempDir {
    fs::path path;
    TempDir() {
        path = fs::temp_directory_path() / ("kite-arc-test-" + NewUuid());
        fs::create_directories(path);
    }
    ~TempDir() {
        std::error_code ignored;
        fs::remove_all(path, ignored);
    }
};

void Write(const fs::path& file, const std::string& text) {
    fs::create_directories(file.parent_path());
    std::ofstream out(file, std::ios::binary);
    out << text;
}

std::vector<std::string> TabTitles(const std::vector<ClosedTab>& tabs) {
    std::vector<std::string> out;
    for (const ClosedTab& t : tabs) out.push_back(t.tab.title);
    return out;
}

// MARK: ArcArchiveSettingsImportTests's fixtures

Value Archived(int n, double at, Value source, std::optional<std::string> title = std::nullopt) {
    return Object{{"archivedAt", at},
                  {"reason", "manual"},
                  {"source", std::move(source)},
                  {"sidebarItem", Object{{"id", Id(n)}, {"title", title ? Value(*title) : Value()}, {"childrenIds", Array{}}, {"parentID", Value()},
                                         {"data", Object{{"tab", Object{{"savedURL", "https://archived" + std::to_string(n) + ".example/"},
                                                                        {"savedTitle", "Archived " + std::to_string(n)},
                                                                        {"timeLastActiveAt", at - 60}}}}}}}};
}

std::string ArchiveFixture() {
    std::vector<Value> entries{Archived(2, 800'000'200, Object{{"littleArc", Object{}}}),
                               Archived(1, 800'000'100, Object{{"space", Object{{"_0", Id(9)}}}}, "Renamed"),
                               Archived(3, 800'000'300, Object{{"unknown", Object{}}})};
    Array items;
    for (const Value& e : entries) {
        items.push_back(*e.Find("sidebarItem")->Find("id"));
        items.push_back(e);
    }
    items.push_back(Id(4));
    items.push_back(Object{{"archivedAt", 1.0}, {"sidebarItem", Object{{"id", Id(4)}, {"data", Object{{"list", Object{}}}}}}});
    return json::Write(Object{{"version", 1}, {"items", std::move(items)}});
}

ClosedTab OwnArchived(const std::string& spaceID) {
    ClosedTab closed;
    closed.tab.id = NewUuid();
    closed.tab.url = "https://own.example/";
    closed.spaceID = spaceID;
    return closed;
}

}  // namespace

TEST(ArcArchiveSettingsImport_importsArchivedTabsOldestFirst) {
    const auto tabs = ParseArchive(ArchiveFixture());
    CHECK((TabTitles(tabs) == std::vector<std::string>{"Renamed", "Archived 2", "Archived 3"}));
    if (tabs.size() != 3) return;
    CHECK(tabs[0].tab.id == Id(1));
    CHECK(tabs[0].spaceID == Id(9));
    CHECK(tabs[1].spaceID == kNoSpace);
    CHECK(tabs[0].tab.lastActiveAt == 800'000'040);
    // As the Mac's: no archive date or reason of Kite's own.
    CHECK(!tabs[0].archivedAt && !tabs[0].reason && tabs[0].index == 0);
    CHECK(ParseArchive("{}").empty());
}

TEST(ArcArchiveSettingsImport_archiveMergeGoesBeforeKitesOwnAndSkipsRepeats) {
    BrowserState state = BrowserState::MakeDefault(std::nullopt);
    const ClosedTab own = OwnArchived(state.selectedSpaceID);
    state.archived = {own};
    const auto imported = ParseArchive(ArchiveFixture());
    CHECK(MergeArchive(state, imported) == 3);
    CHECK(MergeArchive(state, imported) == 0);
    std::vector<std::string> ids, expected;
    for (const ClosedTab& c : state.archived) ids.push_back(c.tab.id);
    for (const ClosedTab& c : imported) expected.push_back(c.tab.id);
    expected.push_back(own.tab.id);
    CHECK(ids == expected);
}

TEST(ArcArchiveSettingsImport_archiveMergeKeepsTheNewestWithinTheLimit) {
    BrowserState state = BrowserState::MakeDefault(std::nullopt);
    std::vector<ClosedTab> many;
    for (size_t i = 0; i < BrowserState::kArchiveLimit + 10; ++i) many.push_back(OwnArchived(kNoSpace));
    CHECK(MergeArchive(state, many) == static_cast<int>(BrowserState::kArchiveLimit));
    CHECK(state.archived.front().tab.id == many[10].tab.id);
    CHECK(state.archived.back().tab.id == many.back().tab.id);
}

TEST(ArcArchiveSettingsImport_readsArcSettings) {
    const Value defaults = Object{
        {"shouldWarnBeforeQuitting", false},
        {"openExternalLinksInLittleBrowserEnabled", true},
        {"autoArchiveTimeThresholdsPerProfile",
         R"({"thresholds":[{"custom":{"_0":{"directoryBasename":"Profile 1"}}},"oneHour",{"default":{}},{"sevenDays":{}}]})"},
    };
    const Settings settings = Settings::FromDefaults(defaults);
    CHECK((settings == Settings{false, true, "sevenDays"}));
    CHECK(settings.Names().size() == 3);

    BrowserState state = BrowserState::MakeDefault(std::nullopt);
    Apply(state, settings);
    CHECK(state.extra.at("asksBeforeQuitting") == Value(false));
    CHECK(state.archiveAfter == "sevenDays");
}

TEST(ArcArchiveSettingsImport_arcDefaultsLeaveKiteAlone) {
    // Arc's untouched defaults: no thresholds, no other keys.
    CHECK(Settings::FromDefaults(Object{{"autoArchiveTimeThresholdsPerProfile", R"({"thresholds":[]})"}}).IsEmpty());
    // With only another profile's threshold, Kite's single setting takes it.
    CHECK(ArchiveInterval(Value(R"({"thresholds":[{"custom":{}},"thirtyDays"]})")) == "thirtyDays");
    CHECK(!ArchiveInterval(Value("not json")));
    CHECK(!Settings::FromDefaults(Object{{"shouldWarnBeforeQuitting", "yes"}}).warnsBeforeQuitting);
}

TEST(ArcSettingsWindows_readsArcForWindowsPlist) {
    // Arc for Windows keeps Foundation's defaults as an XML plist next to its folder.
    auto defaults = plist::ParseXml(Read(ArcFixture().parent_path() / "company.thebrowser.arc.plist"));
    CHECK(defaults && defaults->AsObject());
    if (!defaults) return;
    CHECK(*defaults->Find("launchCount") == Value(12));
    CHECK((*defaults->Find("recentThings") == Value(Array{"one & two", 1.5})));
    CHECK(*defaults->Find("tidyTabsEnabled") == Value(false));
    CHECK((Settings::FromDefaults(*defaults) == Settings{true, std::nullopt, "sevenDays"}));
    CHECK(!plist::ParseXml("<plist><dict><key>a</key></dict></plist>"));
    CHECK(!plist::ParseXml("bplist00"));
    CHECK((plist::ParseXml("<plist version=\"1.0\"><array><string>&#x41;&#66;<![CDATA[<c>]]></string><dict/></array></plist>") ==
           Value(Array{"AB<c>", Object{}})));
}

// MARK: ArcKeyBindingsImportTests

namespace {

// The shape of Arc 1.169's StorableKeyBindings.json.
constexpr const char* kKeyBindings = R"({
    "userOverrides": [
        {
            "priority": "promptAfterConsumedByWebView",
            "default": {
                "typeTravelTriggers": ["Add Split View", "Split"],
                "priority": "promptAfterConsumedByWebView",
                "shortcut": {"deviceIndependentModifierFlags": 393216, "keyEquivalent": "="}
            },
            "state": {"valid": {"_0": {"keyEquivalent": "l", "deviceIndependentModifierFlags": 1048576}}},
            "action": {"name": "Add Split View", "identifier": "addSplitView"},
            "source": "userDefined"
        },
        {
            "priority": "overrideWebView",
            "default": {"shortcut": {"deviceIndependentModifierFlags": 1048576, "keyEquivalent": "l"}, "priority": "overrideWebView"},
            "state": {"unset": {}},
            "action": {"identifier": "addressBar", "name": "Open Command Bar"},
            "source": "userDefined"
        },
        {
            "priority": "low",
            "default": {"shortcut": {"deviceIndependentModifierFlags": 1572864, "keyEquivalent": "→"}, "priority": "low"},
            "state": {"valid": {"_0": {"deviceIndependentModifierFlags": 1179648, "keyEquivalent": "s"}}},
            "action": {"identifier": "focusNextSpace", "name": "Next Space"},
            "source": "userDefined"
        },
        {
            "priority": "low",
            "default": {"shortcut": {"deviceIndependentModifierFlags": 1048576, "keyEquivalent": "x"}, "priority": "low"},
            "state": {"somethingNew": {}},
            "action": {"identifier": "futureThing", "name": "Future Thing"},
            "source": "userDefined"
        }
    ],
    "version": 1
})";

std::vector<KeyBindingOverride> KeyOverrides(std::string_view text) {
    auto parsed = ParseKeyBindings(text);
    CHECK(parsed);
    return parsed.value_or(std::vector<KeyBindingOverride>{});
}

}  // namespace

TEST(ArcKeyBindingsImport_readsArcOverrides) {
    using S = KeyBindingOverride::Source;
    CHECK((KeyOverrides(kKeyBindings) == std::vector<KeyBindingOverride>{
                                             {"addSplitView", KeyShortcut("l", {M::Command}), S::Arc},
                                             {"openLocation", std::nullopt, S::Arc},
                                             {"nextSpace", KeyShortcut("s", {M::Shift, M::Command}), S::Arc},
                                         }));
}

TEST(ArcKeyBindingsImport_bringsAcrossOnlyChangedPriorities) {
    constexpr const char* changed = R"({"userOverrides": [{
        "priority": "low",
        "default": {"shortcut": {"deviceIndependentModifierFlags": 1048576, "keyEquivalent": "d"}, "priority": "promptAfterConsumedByWebView"},
        "state": {"valid": {"_0": {"keyEquivalent": "d", "deviceIndependentModifierFlags": 1048576}}},
        "action": {"identifier": "pinTab", "name": "Pin/Unpin Tab"},
        "source": "userDefined"
    }], "version": 1})";
    CHECK((KeyOverrides(changed) ==
           std::vector<KeyBindingOverride>{{"pinTab", KeyShortcut("d", {M::Command}), KeyBindingOverride::Source::Arc, KeyShortcutPriority::Low}}));
    // Unchanged priorities (all of the main fixture's) stay Kite's defaults.
    const auto all = KeyOverrides(kKeyBindings);
    CHECK(std::all_of(all.begin(), all.end(), [](const KeyBindingOverride& o) { return !o.priority; }));
}

TEST(ArcKeyBindingsImport_decodesModifiersAndArrows) {
    CHECK(ArcShortcut("\xE2\x86\x92", 1572864) == KeyShortcut("right", {M::Option, M::Command}));  // →
    // Caps Lock and other bits are ignored.
    CHECK(ArcShortcut("=", 393216 | 1 << 16) == KeyShortcut("=", {M::Control, M::Shift}));
    // The AppKit function-key character for an arrow (Windows' addition: the Mac doesn't test it).
    CHECK(ArcShortcut("\xEF\x9C\x80", (1 << 20) | (1 << 23)) == KeyShortcut("up", {M::Command}));  // U+F700 with fn
}

TEST(ArcKeyBindingsImport_skipsShortcutsThatWouldFireWhileTyping) {
    // fn E (Emoji & Symbols) must not come across as a bare E.
    CHECK(!ArcShortcut("e", 1 << 23));
    CHECK(!ArcShortcut("e", 0));
    CHECK(!ArcShortcut("E", 1 << 17));
    CHECK(!ArcShortcut("ab", 1 << 20));
}

TEST(ArcKeyBindingsImport_importedOverridesFreeArcsKeys) {
    const KeyBindings bindings(KeyOverrides(kKeyBindings));
    const auto resolved = bindings.Resolve({
        {"openLocation", KeyShortcut("l", {M::Command})},
        {"nextSpace", KeyShortcut("s", {M::Shift, M::Command})},
        {"savePageAs", std::nullopt},
    });
    CHECK(resolved.at("openLocation") == std::nullopt);
    CHECK(resolved.at("nextSpace") == KeyShortcut("s", {M::Shift, M::Command}));
}

TEST(ArcKeyBindingsImport_oneMalformedOverrideAndNoneImport) {
    // JSONDecoder fails the whole file, so the Mac imports none (its try? gives []).
    CHECK(!ParseKeyBindings(R"({"userOverrides": [{"action": {"identifier": "a"}, "state": {"valid": {"_0": {"keyEquivalent": 1}}}}]})"));
    CHECK(!ParseKeyBindings(R"({"version": 1})"));
    CHECK(ParseKeyBindings(R"({"userOverrides": []})")->empty());
}

// MARK: ArcLinkRoutingImportTests

namespace {

const std::string kSpace = "00000000-0000-4000-8000-000000000002";
const std::string kRule = "00000000-0000-4000-8000-0000000000A1";

Value Component(const std::string& style, const std::string& pattern) {
    return Object{{"id", NewUuid()}, {"componentType", Object{{"urlMatch", Object{{"_0", Object{{style, Object{}}}}, {"_1", pattern}}}}}};
}

Value ToSpace(const std::string& id) { return Object{{"space", Object{{"_0", Object{{"space", Object{{"_0", id}}}}}}}}; }

// Mirrors the shape of a real StorableLinkRouting.json.
std::string RoutingFixture() {
    return json::Write(Object{
        {"version", 1},
        {"rules", Array{
            Object{{"id", "00000000-0000-4000-8000-0000000000a1"}, {"sourceComponents", Array{Component("contains", "spotify"), Component("matches", "figma.com")}},
                   {"destination", ToSpace(kSpace)}},
            Object{{"id", NewUuid()}, {"sourceComponents", Array{Component("contains", "zoom.us")}},
                   {"destination", Object{{"littleArc", Object{{"_0", Object{{"mostRecent", Object{}}}}}}}}},
            Object{{"id", NewUuid()}, {"sourceComponents", Array{Component("contains", "notion")}}, {"destination", Object{{"mostRecent", Object{}}}}},
            Object{{"id", NewUuid()}, {"sourceComponents", Array{Component("contains", "bank")}},
                   {"destination", Object{{"profile", Object{{"_0", Object{{"custom", Object{{"_0", Object{{"directoryBasename", "Profile 1"}}}}}}}}}}}},
        }},
        {"defaultDestination", Object{{"littleArc", Object{{"_0", Object{{"mostRecent", Object{}}}}}}}},
    });
}

LinkRouting Routes(const std::string& text) {
    auto parsed = ParseLinkRouting(text);
    CHECK(parsed);
    return parsed.value_or(LinkRouting{});
}

using air_traffic::Destination;

}  // namespace

TEST(ArcLinkRoutingImport_readsArcRoutes) {
    const LinkRouting result = Routes(RoutingFixture());
    CHECK(result.rules.size() == 3);
    CHECK(result.profileRoutes == 1);
    CHECK(result.unreadable == 0);
    if (result.rules.size() != 3) return;
    const auto& first = result.rules[0];
    CHECK(first.id == kRule);
    CHECK(first.destination == Destination::InSpace(kSpace));
    CHECK(first.components.size() == 2 && first.components[0].style == air_traffic::MatchStyle::Contains &&
          first.components[1].style == air_traffic::MatchStyle::Matches);
    CHECK(first.components[0].pattern == "spotify" && first.components[1].pattern == "figma.com");
    CHECK(result.rules[1].destination == Destination::Little());
    CHECK(result.rules[2].destination == Destination::MostRecent());
    // A Little Arc default is the Little Kite setting, not a stored default.
    CHECK(result.defaultOpensInLittleKite == true);
    CHECK(!result.defaultSpace);

    // Routed as in Arc once the space is imported.
    air_traffic::State state;
    Merge(state, result);
    CHECK(!state.defaultDestination);
    CHECK(state.DestinationFor("https://open.spotify.com/track/1", {kSpace}, false) == Destination::InSpace(kSpace));
}

TEST(ArcLinkRoutingImport_importingAgainReplacesArcsRoutesAndKeepsKites) {
    const LinkRouting result = Routes(RoutingFixture());
    const air_traffic::Rule own{NewUuid(), {{NewUuid(), air_traffic::MatchStyle::Contains, "github"}}, Destination::Little()};
    air_traffic::State state;
    state.rules = {own};
    CHECK(Merge(state, result) == 3);
    LinkRouting changed = result;
    changed.rules[0].components[0].pattern = "music";
    CHECK(Merge(state, changed) == 0);
    CHECK(state.rules.size() == 4);
    CHECK(state.rules[0] == own);
    CHECK(state.rules[1].components[0].pattern == "music");
}

TEST(ArcLinkRoutingImport_noDefaultKeepsKites) {
    const LinkRouting result = Routes(R"({"version": 1, "rules": []})");
    CHECK(result.IsEmpty());
    air_traffic::State state;
    state.defaultDestination = Destination::InSpace(NewUuid());
    const air_traffic::State before = state;
    Merge(state, result);
    CHECK(state == before);
    CHECK(!ParseLinkRouting("[]"));
}

TEST(ArcLinkRoutingImport_aSpaceDefaultIsKeptAndMostRecentIsTheSetting) {
    const std::string space = NewUuid();
    const LinkRouting result = Routes(json::Write(Object{{"defaultDestination", ToSpace(space)}}));
    CHECK(result.defaultSpace == space);
    air_traffic::State state;
    Merge(state, result);
    CHECK(state.defaultDestination == Destination::InSpace(space));
    // Only kept while that space is in Kite.
    CHECK(!result.Keeping({}).defaultSpace);

    const LinkRouting later = Routes(R"({"rules": [], "defaultDestination": {"mostRecent": {}}})");
    CHECK(later.defaultOpensInLittleKite == false);
    // Arc's default changed since: the space default from the first import goes.
    Merge(state, later);
    CHECK(!state.defaultDestination);
}

TEST(ArcLinkRoutingImport_leavesOutWhatKiteCantReadOrOpen) {
    const std::string space = NewUuid();
    const std::string text = json::Write(Object{{"rules", Array{
        // Bare style names read too.
        Object{{"id", NewUuid()}, {"sourceComponents", Array{Object{{"componentType", Object{{"urlMatch", Object{{"_0", "matches"}, {"_1", "a.com"}}}}}}}},
               {"destination", ToSpace(space)}},
        // No id: a second import couldn't replace it.
        Object{{"sourceComponents", Array{Component("contains", "b")}}, {"destination", Object{{"mostRecent", Object{}}}}},
        // A style Kite doesn't know.
        Object{{"id", NewUuid()}, {"sourceComponents", Array{Component("regex", "c")}}, {"destination", Object{{"mostRecent", Object{}}}}},
        // A destination Kite doesn't know.
        Object{{"id", NewUuid()}, {"sourceComponents", Array{Component("contains", "d")}}, {"destination", Object{{"window", Object{}}}}},
        // To a space that isn't imported.
        Object{{"id", NewUuid()}, {"sourceComponents", Array{Component("contains", "e")}}, {"destination", ToSpace(NewUuid())}},
    }}});
    const LinkRouting result = Routes(text);
    CHECK(result.unreadable == 3);
    CHECK(result.rules.size() == 2);
    if (result.rules.empty()) return;
    CHECK(result.rules[0].components.front().style == air_traffic::MatchStyle::Matches);
    const LinkRouting kept = result.Keeping({space});
    CHECK(kept.rules.size() == 1 && kept.rules[0].destination == Destination::InSpace(space));
}

TEST(AirTrafficControl_linkRoutingJsonHasTheMacsShape) {
    // AirTrafficControlStore's JSONEncoder: synthesized Codable, Swift's enum encoding.
    air_traffic::State state;
    state.rules = {{Id(1), {{Id(2), air_traffic::MatchStyle::Matches, "x.com"}}, Destination::InSpace(Id(3))},
                   {Id(4), {{Id(5), air_traffic::MatchStyle::Contains, "y"}}, Destination::Little()}};
    state.defaultDestination = Destination::MostRecent();
    const std::string expected =
        R"({"defaultDestination":{"mostRecentSpace":{}},"rules":[{"components":[{"id":")" + Id(2) + R"(","pattern":"x.com","style":"matches"}],)"
        R"("destination":{"space":{"_0":")" + Id(3) + R"("}},"id":")" + Id(1) + R"("},{"components":[{"id":")" + Id(5) +
        R"(","pattern":"y","style":"contains"}],"destination":{"littleKite":{}},"id":")" + Id(4) + R"("}],"version":1})";
    CHECK(json::Write(state.ToJson()) == expected);
    auto parsed = json::Parse(expected);
    CHECK(air_traffic::State::FromJson(std::get<Value>(parsed)) == state);
    CHECK(state.DestinationFor("https://www.x.com/", {Id(3)}, false) == Destination::InSpace(Id(3)));
    CHECK(state.DestinationFor("https://www.x.com/", {}, false) == Destination::MostRecent());
    CHECK(state.DestinationFor("file:///y", {}, true) == Destination::MostRecent());
}

// MARK: Site Search (KiteMac's ArcSiteSearchImport.read, over Kite's own SQLite reader)

namespace {

std::vector<std::string> Shortcuts(const std::vector<SiteSearch>& sites) {
    std::vector<std::string> out;
    for (const SiteSearch& s : sites) out.push_back(s.shortcut);
    return out;
}

}  // namespace

TEST(ArcSiteSearchImport_readsTheShortcutsTheUserMadeOrTurnedOn) {
    auto sites = ParseSiteSearches(Read(ArcFixture() / "User Data" / "Default" / "Web Data"));
    CHECK(sites);
    if (!sites) return;
    // Oldest first (a missing date first), prepopulated and auto-added ones left out, and ones
    // that need Chromium's own substitution or aren't web pages skipped.
    CHECK((Shortcuts(*sites) == std::vector<std::string>{"nd", "on.example.test", "kd", "same", "off", "long"}));
    if (sites->size() != 6) return;
    CHECK((*sites)[2].name == "Kite Docs" && (*sites)[2].urlTemplate == "https://docs.kite.example/search?q=%s");
    // Written before is_active existed: its DEFAULT 0, which isn't "off" (2).
    CHECK((*sites)[2].isActive);
    CHECK(!(*sites)[4].isActive);
    // The long one spills onto overflow pages.
    CHECK((*sites)[5].urlTemplate.size() == std::string("https://long.example.test/search?q=%s&pad=").size() + 3000);
}

TEST(ArcSiteSearchImport_withoutIsActiveKeepsTheUsersOwn) {
    auto sites = ParseSiteSearches(Read(fs::path(KITE_TEST_FIXTURES_DIR) / "legacy-web-data.sqlite"));
    CHECK(sites);
    if (!sites) return;
    CHECK((Shortcuts(*sites) == std::vector<std::string>{"mt", "kd"}));
    CHECK(std::all_of(sites->begin(), sites->end(), [](const SiteSearch& s) { return s.isActive; }));
}

TEST(SQLiteReader_readsTablesAndRefusesWhatIsntOne) {
    const std::string file = Read(ArcFixture() / "User Data" / "Default" / "Web Data");
    auto table = sqlite::ReadTable(file, "KEYWORDS");
    CHECK(table && table->rows.size() == 70);
    if (!table) return;
    CHECK(table->Column("is_active") == table->columns.size() - 3);
    // The rowid alias (INTEGER PRIMARY KEY) reads as the rowid.
    CHECK(std::get<int64_t>(table->rows[0][*table->Column("id")]) == 1);
    auto meta = sqlite::ReadTable(file, "meta");
    CHECK(meta && meta->rows.size() == 1 && std::get<std::string>(meta->rows[0][1]) == "130");
    CHECK(!sqlite::ReadTable(file, "nosuchtable"));
    CHECK(!sqlite::ReadTable("not a database", "keywords"));
    // Cut short anywhere, it gives up rather than reading past the end.
    for (size_t size : {size_t{100}, size_t{1024}, size_t{1500}, size_t{4096}, file.size() - 1}) {
        auto cut = sqlite::ReadTable(std::string_view(file).substr(0, size), "keywords");
        CHECK(!cut || cut->rows.size() <= 70);
    }
    // Garbage in every page after the header: no crash, no rows from nowhere.
    std::string scrambled = file;
    for (size_t i = 1024; i < scrambled.size(); ++i) scrambled[i] = static_cast<char>((i * 131) & 0xFF);
    auto garbage = sqlite::ReadTable(scrambled, "keywords");
    CHECK(!garbage || garbage->rows.size() <= 70);
}

TEST(SQLiteReader_parsesColumnDefinitions) {
    auto columns = sqlite::ParseColumns(
        "CREATE TABLE \"t\" (id INTEGER PRIMARY KEY, [odd name] TEXT DEFAULT 'it''s', `n` INTEGER DEFAULT -3, x REAL DEFAULT 1.5,"
        " y, CONSTRAINT pk UNIQUE (y), z VARCHAR(10, 2) NOT NULL, w INTEGER DEFAULT 0)");
    CHECK(columns && columns->size() == 7);
    if (!columns || columns->size() != 7) return;
    CHECK((*columns)[0].name == "id" && (*columns)[0].rowidAlias);
    CHECK((*columns)[1].name == "odd name" && (*columns)[1].defaultValue == sqlite::SqlValue(std::string("it's")));
    CHECK((*columns)[2].name == "n" && (*columns)[2].defaultValue == sqlite::SqlValue(int64_t{-3}));
    CHECK((*columns)[3].defaultValue == sqlite::SqlValue(1.5));
    CHECK((*columns)[4].name == "y" && std::holds_alternative<std::monostate>((*columns)[4].defaultValue));
    CHECK((*columns)[5].name == "z" && (*columns)[6].name == "w");
    CHECK(!sqlite::ParseColumns("CREATE TABLE t"));
}

TEST(SiteSearch_mergeSeedsArcsDefaultsThenReplacesByShortcut) {
    // The Mac seeds Arc's defaults when it reads any session; an import then merges.
    BrowserState state = BrowserState::MakeDefault(std::nullopt);
    auto imported = SiteSearch::FromChromium("Tube", "YouTube.com", "https://tube.example/?q={searchTerms}");
    CHECK(imported);
    if (!imported) return;
    CHECK(imported->urlTemplate == "https://tube.example/?q=%s");
    CHECK(MergeSiteSearches(state, {*imported}));
    const auto sites = SiteSearches(state);
    CHECK(sites.size() == SiteSearch::ArcDefaults().size());
    auto tube = std::find_if(sites.begin(), sites.end(), [](const SiteSearch& s) { return s.shortcut == "YouTube.com"; });
    CHECK(tube != sites.end() && tube->name == "Tube" && tube->id != imported->id && !tube->color);
    CHECK(state.extra.at("siteSearchDefaultsSeeded") == Value(2));
    // The JSON the Mac writes: no isActive while it's on, a colour when there is one.
    CHECK(json::Write(sites[0].ToJson()) == R"({"color":"0F9D58","id":")" + sites[0].id +
                                                R"(","name":"Google Drive","shortcut":"drive.google.com","urlTemplate":"https://drive.google.com/drive/search?q=%s"})");
    // Merged again: no repeats.
    CHECK(MergeSiteSearches(state, {*imported}) && SiteSearches(state).size() == sites.size());
    CHECK(!SiteSearch::FromChromium("x", "", "https://x/?q={searchTerms}"));
    CHECK(!SiteSearch::FromChromium("x", "x", "https://x/"));
    CHECK(!SiteSearch::FromChromium("x", "x", "ftp://x/{searchTerms}"));
}

// MARK: ArcImportController (folder, backups, the import)

TEST(ArcImportController_findsArcForWindowsFolder) {
    const fs::path localAppData = fs::path(KITE_TEST_FIXTURES_DIR) / "arc-windows";
    const auto found = ArcDirectory(std::nullopt, std::nullopt, localAppData);
    CHECK(found && fs::equivalent(*found, ArcFixture()));
    // A test run's own folder, only with KITE_SUPPORT_PATH too, as on the Mac.
    CHECK(ArcDirectory(fs::path("support"), fs::path("hand-made"), localAppData) == fs::path("hand-made"));
    CHECK(ArcDirectory(std::nullopt, fs::path("hand-made"), localAppData) == found);
    CHECK(!ArcDirectory(std::nullopt, std::nullopt, fs::path(KITE_TEST_FIXTURES_DIR)));
    CHECK(LooksLikeArc(ArcFixture()));
    CHECK(!LooksLikeArc(ArcFixture() / "User Data"));
}

TEST(ArcImportController_fallsBackToTheNewestBackupThatReads) {
    TempDir dir;
    const std::string good = Read(ArcFixture() / "StorableSidebar.json");
    fs::create_directories(dir.path / "User Data");
    Write(dir.path / "StorableSidebar.json", good.substr(0, 300));  // cut short, as mid-write
    Write(dir.path / "StorableSidebar.2026-10-02-08-00-00-000.json", "{\"sidebar\": 1}");
    Write(dir.path / "StorableSidebar.2026-10-01-08-00-00-000.json", good);
    auto loaded = LoadSidebar(dir.path);
    auto* sidebar = std::get_if<Sidebar>(&loaded);
    CHECK(sidebar && sidebar->file == "StorableSidebar.2026-10-01-08-00-00-000.json" && sidebar->isBackup && sidebar->backup);
    if (sidebar) {
        auto plan = ReadPlan(*sidebar, dir.path);
        const auto lines = ConfirmLines(plan, BrowserState::MakeDefault(std::nullopt));
        CHECK(std::any_of(lines.begin(), lines.end(), [](const std::string& l) { return l.find("newest backup") != std::string::npos; }));
    }

    // No spaces is Arc's current state: no backup instead.
    Write(dir.path / "StorableSidebar.json", R"({"sidebar":{"containers":[]}})");
    auto empty = LoadSidebar(dir.path);
    auto* error = std::get_if<LoadError>(&empty);
    CHECK(error && error->failure == Failure::NoSpaces && error->message == "There are no spaces to import.");

    // Nothing that reads at all.
    fs::remove(dir.path / "StorableSidebar.2026-10-01-08-00-00-000.json");
    Write(dir.path / "StorableSidebar.json", "not json");
    auto none = LoadSidebar(dir.path);
    error = std::get_if<LoadError>(&none);
    CHECK(error && error->failure == Failure::NotJSON && error->message == "That folder has no Arc sidebar Kite can read.");
}

TEST(ArcImportController_takesAPickedFolderOrFile) {
    TempDir dir;
    // The folder holding Arc's: the Arc folder in it.
    fs::copy(ArcFixture(), dir.path / "Arc", fs::copy_options::recursive);
    auto plan = ReadPicked(dir.path, std::nullopt);
    auto* read = std::get_if<Plan>(&plan);
    CHECK(read && fs::equivalent(read->folder, dir.path / "Arc") && read->sidebar.result.spaces.size() == 2);
    // A copy of the sidebar kept elsewhere: the other files come from Arc's own folder.
    Write(dir.path / "copy" / "sidebar copy.json", Read(ArcFixture() / "StorableSidebar.json"));
    plan = ReadPicked(dir.path / "copy" / "sidebar copy.json", ArcFixture());
    read = std::get_if<Plan>(&plan);
    CHECK(read && fs::equivalent(read->folder, ArcFixture()) && read->archive.size() == 2 && read->sidebar.file == "sidebar copy.json" &&
          !read->sidebar.isBackup);
    if (read) {
        const auto lines = ConfirmLines(*read, BrowserState::MakeDefault(std::nullopt));
        CHECK(std::none_of(lines.begin(), lines.end(), [](const std::string& l) { return l.find("backup") != std::string::npos; }));
    }
    // That isn't Arc's sidebar file.
    Write(dir.path / "copy" / "notes.json", R"({"notes": []})");
    plan = ReadPicked(dir.path / "copy" / "notes.json", ArcFixture());
    auto* error = std::get_if<LoadError>(&plan);
    CHECK(error && error->message == "notes.json isn't Arc's sidebar." && error->failure == Failure::NotArcSidebar);
    // A folder with no sidebar in it.
    plan = ReadPicked(dir.path / "copy", ArcFixture());
    error = std::get_if<LoadError>(&plan);
    CHECK(error && error->message == "That folder has no Arc sidebar Kite can read.");
    // --auto with no Arc for Windows on the machine.
    auto none = ReadAuto(std::nullopt);
    CHECK(std::holds_alternative<LoadError>(none) && std::get<LoadError>(none).message == "Kite couldn't find Arc's data.");
}

TEST(ArcImportController_importsTheFixtureFolder) {
    TempDir profile;
    auto read = ReadAuto(ArcFixture(), FromUnixTime(1'800'000'000));
    CHECK(std::holds_alternative<Plan>(read));
    if (!std::holds_alternative<Plan>(read)) return;
    const Plan& plan = std::get<Plan>(read);
    CHECK(plan.siteSearches.size() == 6 && plan.keyBindings.size() == 2 && plan.archive.size() == 2 && plan.routes && plan.unreadable.empty());
    CHECK((plan.profileNames == std::map<std::string, std::string>{{"Default", "Me"}, {"Profile 1", "Side Project"}}));
    CHECK((plan.settings == Settings{true, std::nullopt, "sevenDays"}));

    BrowserState state = BrowserState::MakeDefault(std::nullopt);
    const auto lines = ConfirmLines(plan, state);
    CHECK(lines.size() >= 3 && lines[0] == "Found 1 space, 1 favorite, 6 tabs, 1 folder and 1 split view.");
    CHECK(lines[1] == "Also imports 2 archived tabs, 6 Site Search shortcuts, 2 keyboard shortcut changes, 1 Air Traffic Control route and "
                      "2 Arc settings (Warn before quitting, Archive tabs after: 7 days).");
    CHECK(UntitledCounts(plan) == std::make_pair(1, 1));

    const Value summary = Import(state, plan, profile.path);
    const Value* imported = summary.Find("imported");
    CHECK(imported && *imported->Find("spaces") == Value(1) && *imported->Find("pinnedTabs") == Value(4) && *imported->Find("tabs") == Value(2) &&
          *imported->Find("folders") == Value(1) && *imported->Find("splits") == Value(1) && *imported->Find("favorites") == Value(1) &&
          *imported->Find("archivedTabs") == Value(2) && *imported->Find("siteSearches") == Value(6) && *imported->Find("keyBindings") == Value(2) &&
          *imported->Find("routes") == Value(1));
    const Value* skipped = summary.Find("skipped");
    auto skippedKind = [&](const std::string& kind) {
        for (const Value& s : *skipped->AsArray()) {
            if (*s.Find("kind") == Value(kind)) return s.Find("count") ? static_cast<int>(*s.Find("count")->AsInt()) : -1;
        }
        return 0;
    };
    CHECK(skippedKind("unnamedSpaces") == 1 && skippedKind("routesToProfiles") == 1 && skippedKind("sidebarItem:easel") == 1 &&
          skippedKind("spaceIcons") == 1 && skippedKind("history") == -1);

    // The session: the space where it was, Arc's settings, the archive and Site Search.
    CHECK(state.spaces.size() == 3 && state.selectedSpaceID == Id(1));
    CHECK(state.archiveAfter == "sevenDays" && state.extra.at("asksBeforeQuitting") == Value(true));
    CHECK(state.archived.size() == 2 && state.archived[0].tab.title == "Renamed Old");
    CHECK(SiteSearches(state).size() == SiteSearch::ArcDefaults().size() + 6);
    CHECK(Profiles(state).empty());  // the unnamed space's profile isn't made
    // keybindings.json and LinkRouting.json, as the Mac's stores keep them.
    auto bindings = KeyBindings::FromText(Read(profile.path / "keybindings.json"));
    CHECK(bindings && bindings->UserOverrides().size() == 2 && bindings->Override("openLocation") && !bindings->Override("openLocation")->shortcut);
    auto routing = json::Parse(Read(profile.path / "LinkRouting.json"));
    auto atc = std::holds_alternative<Value>(routing) ? air_traffic::State::FromJson(std::get<Value>(routing)) : std::nullopt;
    CHECK(atc && atc->rules.size() == 1 && atc->rules[0].destination == Destination::InSpace(Id(1)) && !atc->defaultDestination);

    // Saved and read back, as the Mac would read it.
    SessionStore store(profile.path / "session.json");
    CHECK(store.Save(state).empty());
    auto loaded = store.Load();
    CHECK(std::holds_alternative<BrowserState>(loaded) && std::get<BrowserState>(loaded) == state);

    // Again, with the unnamed space: Arc's Profile 1 becomes a Kite profile with its favorites.
    const Value again = Import(state, plan, profile.path, {.includeUntitled = true});
    CHECK(*again.Find("imported")->Find("spacesAdded") == Value(1) && *again.Find("imported")->Find("spacesUpdated") == Value(1));
    CHECK(Profiles(state).size() == 1 && Profiles(state)[0].name == "Side Project");
    CHECK(state.favoritesByProfile.at(Profiles(state)[0].directory).size() == 1);
    CHECK(*again.Find("imported")->Find("archivedTabs") == Value(0) && SiteSearches(state).size() == SiteSearch::ArcDefaults().size() + 6);
    CHECK(bindings && KeyBindings::FromText(Read(profile.path / "keybindings.json"))->UserOverrides().size() == 2);
}

TEST(ArcImportController_leavesFilesThatDontReadAlone) {
    TempDir profile;
    Write(profile.path / "keybindings.json", "{broken");
    auto read = ReadAuto(ArcFixture());
    CHECK(std::holds_alternative<Plan>(read));
    if (!std::holds_alternative<Plan>(read)) return;
    BrowserState state = BrowserState::MakeDefault(std::nullopt);
    const Value summary = Import(state, std::get<Plan>(read), profile.path);
    CHECK(Read(profile.path / "keybindings.json") == "{broken");
    CHECK(*summary.Find("imported")->Find("keyBindings") == Value(0));
}
