// Browsing history (W25a): ports of KiteCore's HistoryTests (HistoryTests.swift),
// BrowsingDataTests.historyLosesOnlyPagesVisitedInTheRange, ArcArchiveSettingsImportTests'
// historyMergeKeepsLaterVisitsAndDoesNotDoubleCount and chromiumTimestamps, and
// PageEventSaveTests.cappedDebounceNeverWaitsPastItsMaximum, each named after the Swift test it
// comes from; then the shared fixture (Tests/Fixtures/history-v1.json), and what the Mac
// doesn't test: the file's strictness, copy-on-write snapshots, the search's index, the store's
// load, replay and save timing on its worker, and the command bar's history rows.

#include <algorithm>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>

#include "Check.h"
#include "core/CommandBar.h"
#include "core/History.h"
#include "core/HistoryStore.h"
#include "core/SessionSaveDelay.h"
#include "core/StoreFile.h"
#include "core/TextMatch.h"
#include "core/Unicode.h"
#include "core/Url.h"
#include "core/Uuid.h"

using namespace kite;
namespace fs = std::filesystem;

namespace {

// HistoryTests' `now`: 1_800_000_000 is 2027-01-15 08:00 UTC.
const Timestamp kNow = FromUnixTime(1'800'000'000);

fs::path TempDir() {
    fs::path dir = fs::temp_directory_path() / ("kite-history-test-" + NewUuid());
    fs::create_directories(dir);
    return dir;
}

std::string ReadText(const fs::path& path) { return store_file::Read(path).value_or(""); }

void WriteText(const fs::path& path, const std::string& text) {
    fs::create_directories(path.parent_path());
    std::ofstream(path, std::ios::binary | std::ios::trunc) << text;
}

std::vector<std::string> Titles(const std::vector<HistoryEntry>& entries) {
    std::vector<std::string> out;
    for (const auto& e : entries) out.push_back(e.title);
    return out;
}

std::vector<std::string> Urls(const std::vector<HistoryEntry>& entries) {
    std::vector<std::string> out;
    for (const auto& e : entries) out.push_back(e.url);
    return out;
}

std::vector<std::string> Keys(const History& history) { return Urls(history.Entries()); }

}  // namespace

// MARK: HistoryTests

TEST(recordsWebPagesOnly) {
    History history;
    history.RecordVisit("https://example.com/a", "A", kNow);
    history.RecordVisit("about:blank", "", kNow);
    history.RecordVisit("view-source:https://example.com", "", kNow);
    CHECK(history.Count() == 1);
}

TEST(repeatVisitsCountAndKeepTheTitle) {
    History history;
    const std::string url = "https://example.com/";
    history.RecordVisit(url, "", kNow);
    history.UpdateTitle(url, "Example Domain");
    history.RecordVisit(url, "", kNow + 60);
    auto entry = history.Find(url);
    CHECK(entry && entry->visitCount == 2);
    CHECK(entry && entry->title == "Example Domain");
    CHECK(entry && entry->lastVisit == kNow + 60);
}

TEST(searchRanksHostThenTitleThenFrecency) {
    History history;
    history.RecordVisit("https://github.com/gabekus/kite", "gabekus/kite", kNow);
    history.RecordVisit("https://news.ycombinator.com/", "Hacker News", kNow);
    history.RecordVisit("https://example.com/git", "Learn Git", kNow);
    CHECK(Urls(history.Search("git", 4, kNow)) == (std::vector<std::string>{"https://github.com/gabekus/kite", "https://example.com/git"}));
    auto hack = history.Search("hack", 4, kNow);
    CHECK(!hack.empty() && hack[0].title == "Hacker News");
    CHECK(history.Search("zzz", 4, kNow).empty());
    CHECK(history.Search("  ", 4, kNow).empty());
}

TEST(frequentAndRecentPagesWinTies) {
    History history;
    const std::string old = "https://docs.swift.org/old";
    const std::string often = "https://docs.swift.org/often";
    history.RecordVisit(old, "Swift docs", kNow - 60 * 86'400);
    for (int i = 0; i < 5; ++i) history.RecordVisit(often, "Swift docs", kNow - i);
    auto results = history.Search("swift", 4, kNow);
    CHECK(!results.empty() && results[0].url == often);
}

TEST(roundTripsThroughJSON) {
    History history;
    history.RecordVisit("https://example.com/", "Example", kNow);
    auto decoded = History::DecodeFile(history.EncodeFile());
    CHECK(std::holds_alternative<History>(decoded) && std::get<History>(decoded) == history);
}

TEST(pageGroupsByDayNewestFirstAndSearches) {
    const HistoryCalendar utc = HistoryCalendar::Utc();
    History history;
    history.RecordVisit("https://a.com/", "Alpha", kNow);
    history.RecordVisit("https://b.com/", "Beta", kNow + 3600);
    history.RecordVisit("https://c.com/x", "Gamma", kNow - 86'400);
    auto days = history.Days("", utc);
    CHECK(days.size() == 2);
    CHECK(days.size() == 2 && Titles(days[0].entries) == (std::vector<std::string>{"Beta", "Alpha"}));
    CHECK(days.size() == 2 && Titles(days[1].entries) == std::vector<std::string>{"Gamma"});
    CHECK(days.size() == 2 && days[1].start == utc.startOfDay(kNow - 86'400));
    // Title or URL, any case.
    auto gamma = history.Days("GAM", utc);
    CHECK(gamma.size() == 1 && Titles(gamma[0].entries) == std::vector<std::string>{"Gamma"});
    CHECK(history.Days("c.com/x", utc).size() == 1);
    CHECK(history.Days("zzz", utc).empty());
}

TEST(pageRemovesEntries) {
    History history;
    history.RecordVisit("https://a.com/", "A", kNow);
    history.RecordVisit("https://b.com/", "B", kNow);
    history.Remove({"https://a.com/"});
    CHECK(Keys(history) == std::vector<std::string>{"https://b.com/"});
}

TEST(dayHeadingsMatchChromium) {
    const HistoryCalendar utc = HistoryCalendar::Utc();
    const HistoryDay today{utc.startOfDay(kNow), {}};
    const HistoryDay yesterday{utc.startOfDay(kNow - 86'400), {}};
    const HistoryDay older{utc.startOfDay(kNow - 3 * 86'400), {}};
    CHECK(today.Heading(kNow, utc) == "Today - Friday, January 15, 2027");
    CHECK(yesterday.Heading(kNow, utc) == "Yesterday - Thursday, January 14, 2027");
    CHECK(older.Heading(kNow, utc) == "Tuesday, January 12, 2027");
}

// The Swift test's InternalPage half waits for the history page; history never records it.
TEST(internalPageURLs) {
    CHECK(!History::Records("kite://history"));
    CHECK(!History::Records("KITE://History"));
}

// MARK: BrowsingDataTests

TEST(historyLosesOnlyPagesVisitedInTheRange) {
    History history;
    const Timestamp now = Now();
    history.RecordVisit("https://old.example", "Old", now - 7200);
    history.RecordVisit("https://new.example", "New", now - 60);
    history.RemoveVisits(now - 3600);
    CHECK(Keys(history) == std::vector<std::string>{"https://old.example"});
    history.RemoveVisits(std::nullopt);
    CHECK(history.Empty());
}

// MARK: ArcArchiveSettingsImportTests

TEST(historyMergeKeepsLaterVisitsAndDoesNotDoubleCount) {
    History history;
    const std::string page = "https://page.example/";
    history.RecordVisit(page, "Kite title", FromUnixTime(2'000));
    const std::vector<HistoryEntry> imported{
        {page, "Arc title", FromUnixTime(1'000), 5},
        {"https://new.example/", "New", FromUnixTime(500), 2},
        {"file:///tmp/x", "Local", FromUnixTime(500), 1},
    };
    CHECK(history.Merge(imported) == 1);
    CHECK(history.Merge(imported) == 0);
    auto entry = history.Find(page);
    CHECK(entry && entry->title == "Kite title");
    CHECK(entry && entry->visitCount == 5);
    CHECK(entry && entry->lastVisit == FromUnixTime(2'000));
    CHECK(history.Count() == 2);
}

TEST(chromiumTimestamps) {
    // 2001-01-01 00:00:00 UTC in Chromium's microseconds since 1601.
    CHECK(History::ChromiumDate(12'622'780'800'000'000) == 0);
}

// MARK: PageEventSaveTests

TEST(cappedDebounceNeverWaitsPastItsMaximum) {
    CappedDebounce debounce{3, 30, std::nullopt};
    CHECK(debounce.Changed(100) == 3);
    // A title every second: the quiet wait, until the cap closes in.
    CHECK(debounce.Changed(101) == 3);
    CHECK(debounce.Changed(128) == 2);
    CHECK(debounce.Changed(129.5) == 0.5);
    CHECK(debounce.Changed(131) == 0);
    debounce.Saved();
    CHECK(!debounce.pendingSince);
    CHECK(debounce.Changed(140) == 3);
    CHECK(debounce.pendingSince == 140.0);
}

// MARK: The shared fixture

// Tests/Fixtures/history-v1.json, as the Mac's JSONEncoder writes it (escaped slashes, keys in
// no order, fractional dates); HistoryFixtureTests.swift loads the same file.
TEST(decodesTheSharedHistoryFixture) {
    const auto text = store_file::Read(fs::path(KITE_FIXTURES_DIR) / "history-v1.json");
    CHECK(text.has_value());
    if (!text) return;
    auto decoded = History::DecodeFile(*text);
    CHECK(std::holds_alternative<History>(decoded));
    if (!std::holds_alternative<History>(decoded)) return;
    const History& history = std::get<History>(decoded);
    CHECK(history.Count() == 3);
    auto kite = history.Find("https://github.com/gabekus/kite");
    CHECK(kite && kite->title == "gabekus/kite" && kite->visitCount == 4 && kite->lastVisit == 784111234.567891);
    auto untitled = history.Find("https://www.example.com/");
    CHECK(untitled && untitled->title.empty() && untitled->DisplayTitle() == "www.example.com");
    auto unicode = history.Find("https://ja.wikipedia.org/wiki/%E5%87%A7");
    CHECK(unicode && unicode->title == "凧 - Wikipedia");
    // Written back, it reads the same; HistoryFixtureTests.readsKiteForWindowsWriting reads these bytes on the Mac.
    CHECK(history.EncodeFile() ==
          R"({"history":{"entries":{"https://github.com/gabekus/kite":{"lastVisit":784111234.567891,"title":"gabekus/kite","url":"https://github.com/gabekus/kite","visitCount":4},)"
          R"("https://ja.wikipedia.org/wiki/%E5%87%A7":{"lastVisit":783999999.5,"title":"凧 - Wikipedia","url":"https://ja.wikipedia.org/wiki/%E5%87%A7","visitCount":2},)"
          R"("https://www.example.com/":{"lastVisit":784000000,"title":"","url":"https://www.example.com/","visitCount":1}}},"version":1})");
    auto again = History::DecodeFile(history.EncodeFile());
    CHECK(std::holds_alternative<History>(again) && std::get<History>(again) == history);
}

// MARK: The file

TEST(historyFileIsTheMacsShape) {
    History history;
    history.RecordVisit("https://example.com/a", "A \"quoted\" title", 800'000'000.25);
    history.RecordVisit("https://example.com/a", "", 800'000'001.5);
    history.RecordVisit("https://b.example/", "", 800'000'000);
    CHECK(history.EncodeFile() ==
          R"({"history":{"entries":{"https://b.example/":{"lastVisit":800000000,"title":"","url":"https://b.example/","visitCount":1},)"
          R"("https://example.com/a":{"lastVisit":800000001.5,"title":"A \"quoted\" title","url":"https://example.com/a","visitCount":2}}},)"
          R"("version":1})");
    CHECK(History().EncodeFile() == R"({"history":{"entries":{}},"version":1})");
}

TEST(historyFileIsAsStrictAsTheMacsDecoder) {
    const auto reads = [](const std::string& text) { return std::holds_alternative<History>(History::DecodeFile(text)); };
    const std::string entry = R"({"url":"https://a.example/","title":"A","lastVisit":1,"visitCount":1})";
    CHECK(reads(R"({"version":1,"history":{"entries":{"https://a.example/":)" + entry + "}}}"));
    // Members the Mac doesn't know are ignored, as JSONDecoder does.
    CHECK(reads(R"({"version":2,"extra":true,"history":{"entries":{},"more":1}})"));
    CHECK(!reads("not json"));
    CHECK(!reads(R"({"history":{"entries":{}}})"));                // no version
    CHECK(!reads(R"({"version":1.5,"history":{"entries":{}}})"));  // not an Int
    CHECK(!reads(R"({"version":1,"history":{}})"));                // no entries
    CHECK(!reads(R"({"version":1,"history":{"entries":{"x":{"url":"https://a.example/","title":"A","lastVisit":1}}}})"));
    CHECK(!reads(R"({"version":1,"history":{"entries":{"x":{"url":"https://a.example/","title":"A","lastVisit":1,"visitCount":1.5}}}})"));
    CHECK(!reads(R"({"version":1,"history":{"entries":{"x":{"url":"","title":"A","lastVisit":1,"visitCount":1}}}})"));
    CHECK(!reads(R"({"version":1,"history":{"entries":{"x":{"url":"https://a.example/","title":null,"lastVisit":1,"visitCount":1}}}})"));
}

TEST(anUnreadableHistoryFileIsMovedAsideNotOverwritten) {
    const fs::path dir = TempDir();
    const HistoryFile file(dir / "history.json");
    CHECK(std::holds_alternative<HistoryFile::Missing>(file.Load()));
    WriteText(file.File(), "{ broken");
    // kitecore's Leave: reported, left in place, and not to be saved over.
    auto left = file.Load(HistoryFile::Unreadable::Leave);
    CHECK(std::holds_alternative<HistoryFile::Error>(left) && !HistoryFile::MaySave(left));
    CHECK(ReadText(file.File()) == "{ broken");
    auto moved = file.Load();
    CHECK(std::holds_alternative<HistoryFile::Error>(moved) && HistoryFile::MaySave(moved));
    CHECK(!fs::exists(file.File()));
    const auto* error = std::get_if<HistoryFile::Error>(&moved);
    CHECK(error && error->quarantinedTo && ReadText(*error->quarantinedTo) == "{ broken");
    CHECK(error && error->quarantinedTo && error->quarantinedTo->filename().u8string().starts_with(u8"history.corrupt-"));
    fs::remove_all(dir);
}

// MARK: Recording

TEST(onlyURLsTheMacCanReadBackAreRecorded) {
    History history;
    history.RecordVisit("http://example.com/", "", kNow);
    history.RecordVisit("https://[::1]:8080/", "", kNow);
    // Foundation's URL(string:) is nil for these, which would make the Mac drop the whole file.
    history.RecordVisit("https://example.com:99999/", "", kNow);
    history.RecordVisit("https://[nope]/", "", kNow);
    // URL.scheme as written: the Mac doesn't record an uppercase scheme either.
    history.RecordVisit("HTTPS://example.com/", "", kNow);
    history.RecordVisit("data:text/html,hi", "", kNow);
    history.RecordVisit("file:///C:/x.html", "", kNow);
    CHECK(Keys(history) == (std::vector<std::string>{"http://example.com/", "https://[::1]:8080/"}));
}

TEST(aRepeatedTitleChangesNothing) {
    History history;
    history.RecordVisit("https://a.example/", "Inbox (3)", kNow);
    CHECK(!history.UpdatesTitle("https://a.example/", "Inbox (3)"));
    CHECK(!history.UpdateTitle("https://a.example/", "Inbox (3)"));
    CHECK(!history.UpdateTitle("https://a.example/", ""));
    CHECK(!history.UpdateTitle("https://unknown.example/", "Title"));
    CHECK(history.UpdateTitle("https://a.example/", "Inbox (4)"));
    CHECK(history.Find("https://a.example/")->title == "Inbox (4)");
    // A visit with a title keeps the old one only when its own is empty.
    history.RecordVisit("https://a.example/", "Inbox (5)", kNow + 1);
    CHECK(history.Find("https://a.example/")->title == "Inbox (5)");
}

TEST(theOldestGoPastTheCap) {
    History history;
    for (size_t i = 0; i < History::kMaxEntries; ++i) history.RecordVisit("https://e.example/" + std::to_string(i), "", static_cast<double>(i));
    CHECK(history.Count() == History::kMaxEntries);
    // One more: the newest nine tenths stay, as the Mac's prune(to: maxEntries * 9 / 10).
    history.RecordVisit("https://e.example/new", "", 1e9);
    CHECK(history.Count() == History::kMaxEntries * 9 / 10);
    CHECK(history.Find("https://e.example/new").has_value());
    CHECK(!history.Find("https://e.example/0").has_value());
    CHECK(!history.Find("https://e.example/2000").has_value());
    CHECK(history.Find("https://e.example/2001").has_value());
    // A merge past the cap keeps exactly the cap.
    std::vector<HistoryEntry> imported;
    for (int i = 0; i < 5000; ++i) imported.push_back({"https://i.example/" + std::to_string(i), "", 2e9 + i, 1});
    CHECK(history.Merge(imported) == 5000);
    CHECK(history.Count() == History::kMaxEntries);
    CHECK(history.Find("https://i.example/0").has_value());
}

TEST(aCopyIsASnapshot) {
    History history;
    for (int i = 0; i < 1000; ++i) history.RecordVisit("https://e.example/" + std::to_string(i), "Page", kNow);
    const History snapshot = history;
    history.RecordVisit("https://e.example/1", "Changed", kNow + 1);
    history.RecordVisit("https://e.example/new", "New", kNow + 1);
    history.Remove({"https://e.example/2"});
    CHECK(snapshot.Count() == 1000 && history.Count() == 1000);
    CHECK(snapshot.Find("https://e.example/1")->title == "Page" && snapshot.Find("https://e.example/1")->visitCount == 1);
    CHECK(history.Find("https://e.example/1")->title == "Changed" && history.Find("https://e.example/1")->visitCount == 2);
    CHECK(snapshot.Find("https://e.example/2") && !history.Find("https://e.example/2"));
    CHECK(!snapshot.Find("https://e.example/new") && history.Find("https://e.example/new"));
    CHECK(!(snapshot == history));
}

// MARK: Search

TEST(searchMatchesAsTheMacsScoreDoes) {
    const auto score = [](std::string url, std::string title) { return History::Score("kite", {std::move(url), std::move(title), 0, 1}); };
    CHECK(score("https://kite.example/", "") == 100);
    CHECK(score("https://www.kite.example/", "") == 100);        // "www." dropped
    CHECK(score("https://KITE.example/", "") == 100);            // the host lowercased
    CHECK(score("https://a.example/", "Kite for Windows") == 90);
    CHECK(score("https://a.example/", "Build a kite") == 75);
    CHECK(score("https://a.example/", "Skites") == 55);
    CHECK(score("https://a.example/kite", "Other") == 40);
    CHECK(!score("https://a.example/", "Other"));
    // Every "www." goes, not just a leading one (replacingOccurrences).
    CHECK(History::Score("foobar", {"https://foowww.bar.example/", "", 0, 1}) == 100);
}

TEST(searchFindsWhatTheIndexFoldsAndRanksByCharacters) {
    History history;
    history.RecordVisit("https://a.example/", "Café crème", kNow);
    history.RecordVisit("https://b.example/", "Cafe\xCC\x81 decomposed", kNow);  // e + U+0301
    history.RecordVisit("https://c.example/", "ÜBER alles", kNow);
    history.RecordVisit("https://foowww.bar.example/", "", kNow);
    history.RecordVisit("https://KITE.EXAMPLE/", "", kNow);
    // Canonically equivalent spellings match each other.
    CHECK(history.Search("café", 4, kNow).size() == 2);
    // "e" alone doesn't end inside "é" (a Character), so "caf" + "e" finds neither é...
    CHECK(history.Search("cafe", 4, kNow).empty());
    CHECK(Urls(history.Search("über", 4, kNow)) == std::vector<std::string>{"https://c.example/"});
    // The host with "www." removed from inside it, and an uppercase host.
    CHECK(Urls(history.Search("foobar", 4, kNow)) == std::vector<std::string>{"https://foowww.bar.example/"});
    CHECK(Urls(history.Search("kite", 4, kNow)) == std::vector<std::string>{"https://KITE.EXAMPLE/"});
    CHECK(history.Search("x", 0, kNow).empty());
}

// The index's matching (folded bytes and a Character bitmap) against text_match::Field, the
// command bar's tab matching, which folds the text every time: the same score for every pair.
TEST(theIndexMatchesCharactersAsFieldDoes) {
    using text_match::Field;
    const auto reference = [](const std::string& q, const HistoryEntry& entry) -> std::optional<int> {
        const text_match::Query query(q);
        const std::string host = text_match::ReplaceAll(unicode::Lowercased(url::Host(entry.url).value_or("")), "www.", "");
        const Field title(entry.title);
        if (Field(host).HasPrefix(query)) return 100;
        if (title.HasPrefix(query)) return 90;
        if (title.WordHasPrefix(query)) return 75;
        if (title.Contains(query)) return 55;
        if (Field(entry.url).Contains(query)) return 40;
        return std::nullopt;
    };
    const std::vector<std::string> titles{
        "Café crème", "Cafe\xCC\x81 au lait", "e\xCC\x81 alone", "naïve résumé", "ÜBER Straße", "東京 タワー", "한국어 위키",
        "\xE1\x84\x92\xE1\x85\xA1\xE1\x86\xAB jamo",  // a Hangul syllable written as jamo
        "👨‍👩‍👧 family", "🇯🇵 flag 🇺🇸", "line\r\nbreak", "tab\there", "x\xCC\x81y", "İstanbul", "ΑΣ σίγμα",
        "क्षत्रिय", "a-b_c.d", "", "Recipe", "recipe — index"};
    const std::vector<std::string> urls{"https://www.cafe.example/menu", "https://xn--caf-dma.example/", "https://KITE.example/A",
                                        "https://foowww.bar.example/", "https://b.example/%C3%A9"};
    const std::vector<std::string> queries{"caf", "café", "cafe", "e", "é", "na", "résumé", "über", "strasse", "straße", "東京", "タワー",
                                           "한", "하", "👨", "family", "🇯🇵", "flag", "line", "break", "\r", "x", "y", "i̇stanbul",
                                           "istanbul", "ασ", "σίγμα", "क्ष", "b", "c.d", "recipe", "index", "www", "kite", "foobar",
                                           "%c3", "menu", "a"};
    size_t disagreements = 0;
    for (const auto& title : titles) {
        for (const auto& url : urls) {
            const HistoryEntry entry{url, title, 0, 1};
            for (const auto& q : queries) {
                const std::string lowered = text_match::TrimmedLowercase(q);
                if (lowered.empty()) continue;
                if (History::Score(lowered, entry) != reference(lowered, entry)) {
                    ++disagreements;
                    std::fprintf(stderr, "  score differs: \"%s\" in \"%s\" %s\n", lowered.c_str(), title.c_str(), url.c_str());
                }
            }
        }
    }
    CHECK(disagreements == 0);
}

TEST(searchRanksAsTheScoreAndFrecencySay) {
    // Brute force against Score: the index only skips entries that can't match.
    History history;
    const char* titles[] = {"Recipes", "A recipe", "Pasta", "", "Recipe index", "Other"};
    for (int i = 0; i < 600; ++i) {
        const std::string url = "https://" + std::string(i % 3 ? "www." : "") + (i % 5 ? "site" : "recipes") + std::to_string(i) + ".example/" +
                                (i % 7 ? "a" : "recipe");
        for (int v = 0; v <= i % 4; ++v) history.RecordVisit(url, titles[i % 6], kNow - i * 3600.0);
    }
    for (const char* query : {"recipe", "re", "pasta", "site1", "ex", "r", "zz"}) {
        std::vector<std::pair<double, HistoryEntry>> expected;
        history.ForEach([&](const HistoryEntry& entry) {
            if (auto match = History::Score(query, entry)) {
                const double days = std::max(0.0, kNow - entry.lastVisit) / 86'400;
                expected.push_back({*match + std::log2(entry.visitCount + 1.0) * 8 - std::min(days, 90.0) / 3, entry});
            }
        });
        std::sort(expected.begin(), expected.end(), [](const auto& a, const auto& b) {
            if (a.first != b.first) return a.first > b.first;
            if (a.second.lastVisit != b.second.lastVisit) return a.second.lastVisit > b.second.lastVisit;
            return a.second.url < b.second.url;
        });
        std::vector<std::string> want;
        for (size_t i = 0; i < std::min<size_t>(10, expected.size()); ++i) want.push_back(expected[i].second.url);
        CHECK(Urls(history.Search(query, 10, kNow)) == want);
    }
}

// MARK: The store

namespace {

struct FakeClock {
    double now = 1000;
    std::function<double()> Function() {
        return [this] { return now; };
    }
};

}  // namespace

TEST(theStoreReplaysWhatHappenedBeforeItsFileWasRead) {
    const fs::path dir = TempDir();
    History saved;
    saved.RecordVisit("https://old.example/", "Old", kNow - 100);
    saved.RecordVisit("https://both.example/", "Both", kNow - 100);
    CHECK(HistoryFile(dir / "history.json").Save(saved).empty());
    FakeClock clock;
    HistoryStores stores(dir, clock.Function());
    HistoryStore& store = stores.ForProfile(BrowserState::kDefaultProfile);
    // Whether or not the worker has read the file yet, a visit now lands on top of it.
    store.RecordVisit("https://both.example/", "", kNow);
    store.RecordVisit("https://new.example/", "New", kNow);
    CHECK(stores.Flush().empty());
    CHECK(store.IsLoaded());
    CHECK(store.Get().Count() == 3);
    CHECK(store.Get().Find("https://both.example/")->visitCount == 2);
    CHECK(store.Get().Find("https://both.example/")->title == "Both");
    auto file = HistoryFile(dir / "history.json").Load();
    CHECK(std::holds_alternative<History>(file) && std::get<History>(file) == store.Get());
    fs::remove_all(dir);
}

TEST(theStoreSavesThreeSecondsAfterTheLastChangeAndAtLeastEveryThirty) {
    const fs::path dir = TempDir();
    FakeClock clock;
    HistoryStores stores(dir, clock.Function());
    HistoryStore& store = stores.ForProfile(BrowserState::kDefaultProfile);
    CHECK(stores.Flush().empty());  // the (missing) file read, and nothing to write
    CHECK(!stores.NextSaveIn());
    CHECK(!fs::exists(dir / "history.json"));
    store.RecordVisit("https://a.example/", "", kNow);
    CHECK(stores.NextSaveIn() == 3.0);
    // A title ticking every second: the quiet wait, until the cap closes in.
    for (int t = 1; t <= 28; ++t) {
        clock.now += 1;
        store.UpdateTitle("https://a.example/", "Tick " + std::to_string(t));
    }
    CHECK(stores.NextSaveIn() == 2.0);
    clock.now += 2;
    stores.SaveDue();
    CHECK(!stores.NextSaveIn());
    CHECK(stores.Flush().empty());
    auto file = HistoryFile(dir / "history.json").Load();
    CHECK(std::holds_alternative<History>(file) && std::get<History>(file).Find("https://a.example/")->title == "Tick 28");
    // A title the entry has saves nothing, and neither does a page history doesn't keep.
    store.UpdateTitle("https://a.example/", "Tick 28");
    store.RecordVisit("about:blank", "", kNow);
    CHECK(!stores.NextSaveIn());
    // Clearing saves at once.
    const auto writes = stores.Stats().writes;
    store.RemoveAll();
    CHECK(!stores.NextSaveIn());
    CHECK(stores.Flush().empty());
    CHECK(stores.Stats().writes == writes + 1);
    CHECK(ReadText(dir / "history.json") == History().EncodeFile());
    fs::remove_all(dir);
}

TEST(eachProfileHasItsOwnFile) {
    const fs::path dir = TempDir();
    FakeClock clock;
    HistoryStores stores(dir, clock.Function());
    CHECK(HistoryStores::FileFor(dir, "Default") == dir / "history.json");
    CHECK(HistoryStores::FileFor(dir, "Profile 2") == dir / "Chromium" / "Profile 2" / "Kite History.json");
    stores.ForProfile("Default").RecordVisit("https://default.example/", "", kNow);
    stores.ForProfile("Profile 2").RecordVisit("https://work.example/", "", kNow);
    CHECK(&stores.ForProfile("Profile 2") == &stores.ForProfile("Profile 2"));
    stores.ForProfile("Gone").RecordVisit("https://gone.example/", "", kNow);
    stores.ForgetProfile("Gone");
    CHECK(stores.Flush().empty());
    auto defaults = HistoryFile(dir / "history.json").Load();
    auto work = HistoryFile(dir / "Chromium" / "Profile 2" / "Kite History.json").Load();
    CHECK(std::holds_alternative<History>(defaults) && Keys(std::get<History>(defaults)) == std::vector<std::string>{"https://default.example/"});
    CHECK(std::holds_alternative<History>(work) && Keys(std::get<History>(work)) == std::vector<std::string>{"https://work.example/"});
    CHECK(!fs::exists(dir / "Chromium" / "Gone"));
    fs::remove_all(dir);
}

TEST(aFileThatWontReadIsNeverWrittenOver) {
    const fs::path dir = TempDir();
    // A folder where the file should be: it can't be read, and can't be moved aside as a file.
    fs::create_directories(dir / "history.json" / "inside");
    FakeClock clock;
    HistoryStores stores(dir, clock.Function());
    HistoryStore& store = stores.ForProfile("Default");
    store.RecordVisit("https://a.example/", "", kNow);
    CHECK(stores.Flush().empty());
    CHECK(!store.LoadError().empty());
    CHECK(fs::is_directory(dir / "history.json" / "inside"));
    CHECK(stores.Stats().writes == 0);
    // It still searches this run's visits.
    CHECK(store.Search("a.example", 4, kNow).size() == 1);
    fs::remove_all(dir);
}

TEST(aCorruptFileIsMovedAsideAndHistoryStartsFresh) {
    const fs::path dir = TempDir();
    WriteText(dir / "history.json", "{ broken");
    FakeClock clock;
    HistoryStores stores(dir, clock.Function());
    HistoryStore& store = stores.ForProfile("Default");
    store.RecordVisit("https://a.example/", "", kNow);
    CHECK(stores.Flush().empty());
    CHECK(!store.LoadError().empty());
    auto file = HistoryFile(dir / "history.json").Load();
    CHECK(std::holds_alternative<History>(file) && Keys(std::get<History>(file)) == std::vector<std::string>{"https://a.example/"});
    size_t corrupt = 0;
    for (const auto& item : fs::directory_iterator(dir)) corrupt += item.path().filename().u8string().starts_with(u8"history.corrupt-");
    CHECK(corrupt == 1);
    fs::remove_all(dir);
}

TEST(aFailedWriteIsTriedAgainAtTheFlush) {
    const fs::path dir = TempDir();
    FakeClock clock;
    HistoryStores stores(dir, clock.Function());
    // A file where the profile's Chromium folder should be: its history can't be written.
    WriteText(dir / "Chromium", "in the way");
    HistoryStore& store = stores.ForProfile("Profile 2");
    CHECK(stores.Flush().empty());
    store.RecordVisit("https://a.example/", "", kNow);
    stores.SaveNow();
    // Flush waits for that write, sees it failed, and tries again; it fails again.
    CHECK(!stores.Flush().empty());
    CHECK(stores.Stats().failedWrites >= 2);
    fs::remove(dir / "Chromium");
    CHECK(stores.Flush().empty());
    auto file = HistoryFile(dir / "Chromium" / "Profile 2" / "Kite History.json").Load();
    CHECK(std::holds_alternative<History>(file) && std::get<History>(file).Count() == 1);
    fs::remove_all(dir);
}

TEST(clearingBeforeTheFileIsReadClearsWhatItHeld) {
    const fs::path dir = TempDir();
    History saved;
    saved.RecordVisit("https://old.example/", "Old", kNow);
    CHECK(HistoryFile(dir / "history.json").Save(saved).empty());
    FakeClock clock;
    HistoryStores stores(dir, clock.Function());
    stores.ForProfile("Default").RemoveAll();
    CHECK(stores.Flush().empty());
    CHECK(stores.ForProfile("Default").Get().Empty());
    CHECK(ReadText(dir / "history.json") == History().EncodeFile());
    fs::remove_all(dir);
}

// MARK: The command bar's rows

namespace {

BrowserState OneTab(const std::string& url, const std::string& title) {
    BrowserState state = BrowserState::MakeDefault(std::nullopt);
    state.spaces.resize(1);
    state.selectedSpaceID = state.spaces[0].id;
    const std::string id = state.OpenTab(url, std::nullopt, true, 1);
    state.TabAt(*state.Location(id))->title = title;
    return state;
}

std::vector<std::string> Kinds(const std::vector<CommandSuggestion>& rows) {
    std::vector<std::string> out;
    for (const auto& row : rows) {
        switch (row.kind) {
        case CommandSuggestion::Kind::Open: out.push_back("open"); break;
        case CommandSuggestion::Kind::Search: out.push_back("search"); break;
        case CommandSuggestion::Kind::SwitchTab: out.push_back("tab:" + row.title); break;
        case CommandSuggestion::Kind::History: out.push_back("history:" + row.url); break;
        }
    }
    return out;
}

}  // namespace

TEST(theCommandBarShowsThreePagesFromHistoryAfterTheTabs) {
    BrowserState state = OneTab("https://recipes.example/open", "Recipes I have open");
    History history;
    history.RecordVisit("https://recipes.example/open", "Recipes I have open", kNow);  // a tab already: not again
    history.RecordVisit("https://recipes.example/a", "Recipe A", kNow);
    history.RecordVisit("https://www.recipes.example/b", "Recipe B", kNow - 1);
    history.RecordVisit("https://recipes.example/c", "", kNow - 2);
    history.RecordVisit("https://recipes.example/d", "Recipe D", kNow - 3);
    const auto rows = CommandBarSuggestions("recipe", state, CommandBarMode::NewTab, &history, kNow);
    CHECK(Kinds(rows) == (std::vector<std::string>{"search", "tab:Recipes I have open", "history:https://recipes.example/a",
                                                   "history:https://www.recipes.example/b", "history:https://recipes.example/c"}));
    // A page's title, then its host (without "www.") and path; an untitled page's host is its title.
    CHECK(rows.size() == 5 && rows[2].title == "Recipe A" && rows[2].subtitle == "recipes.example/a" && rows[2].detail.empty());
    CHECK(rows.size() == 5 && rows[3].subtitle == "recipes.example/b");
    CHECK(rows.size() == 5 && rows[4].title == "recipes.example" && rows[4].subtitle.empty());
    // Editing the address: the tab you're on isn't offered, nor is its page from history.
    CHECK(Kinds(CommandBarSuggestions("recipe", state, CommandBarMode::EditCurrent, &history, kNow)) ==
          (std::vector<std::string>{"search", "history:https://recipes.example/a", "history:https://www.recipes.example/b",
                                    "history:https://recipes.example/c"}));
    // No history: the rows as before.
    CHECK(Kinds(CommandBarSuggestions("recipe", state, CommandBarMode::NewTab)) ==
          (std::vector<std::string>{"search", "tab:Recipes I have open"}));
}

TEST(aURLsHistoryRowsComeBeforeTheSearchAndSkipTheOpenRow) {
    BrowserState state = OneTab("https://other.example/", "Other");
    History history;
    history.RecordVisit("https://recipes.example/", "Recipes home", kNow);
    history.RecordVisit("https://recipes.example/a", "Recipe A", kNow - 1);
    const auto rows = CommandBarSuggestions("recipes.example", state, CommandBarMode::NewTab, &history, kNow);
    // The Open row's URL has no "/": the Mac's URL comparison tells the two apart, so the home page stays.
    CHECK(!rows.empty() && rows[0].url == "https://recipes.example");
    CHECK(Kinds(rows) ==
          (std::vector<std::string>{"open", "history:https://recipes.example/", "history:https://recipes.example/a", "search"}));
    // Typed in full, the page the Open row opens isn't listed twice.
    CHECK(Kinds(CommandBarSuggestions("https://recipes.example/", state, CommandBarMode::NewTab, &history, kNow)) ==
          (std::vector<std::string>{"open", "history:https://recipes.example/a", "search"}));
}

TEST(historySubtitlesAreTheHostAndPath) {
    CHECK(HistorySubtitle({"https://www.github.com/gabekus/kite?tab=readme#top", "kite", 0, 1}) == "github.com/gabekus/kite");
    CHECK(HistorySubtitle({"https://example.com/", "Example", 0, 1}) == "example.com");
    CHECK(HistorySubtitle({"https://example.com", "Example", 0, 1}) == "example.com");
    CHECK(HistorySubtitle({"https://example.com/a%20b", "Example", 0, 1}) == "example.com/a%20b");
    CHECK(HistorySubtitle({"https://example.com/a", "", 0, 1}).empty());
}
