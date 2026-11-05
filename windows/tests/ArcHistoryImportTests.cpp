// Import from Arc's history (W33a): core/ArcHistoryImport.h and its part of
// ArcImportController.h. The Mac has no Swift test of ArcHistoryImport or
// BrowserHistoryImport.chromium; the two of its tests this rests on,
// historyMergeKeepsLaterVisitsAndDoesNotDoubleCount and chromiumTimestamps
// (ArcArchiveSettingsImportTests.swift), are ported in HistoryTests.cpp. These check the Mac's
// query row by row (hidden = 0, last_visit_time > 0, newest first, LIMIT before the web-page
// filter, "" for no title, a count of at least 1, String(cString:)'s cut at NUL and repair of
// bad UTF-8), then what Kite for Windows adds: reading the file in place a page at a time, and
// refusing it while Arc may be changing it. Fixtures: scripts/make-history.py (invented data).

#include <algorithm>
#include <atomic>
#include <filesystem>
#include <fstream>
#include <iterator>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#include <share.h>
#include <sys/stat.h>
#endif

#include "Check.h"
#include "core/ArcHistoryImport.h"
#include "core/ArcImportController.h"
#include "core/HistoryStore.h"
#include "core/Profiles.h"
#include "core/SQLiteReader.h"
#include "core/Uuid.h"

using namespace kite;
using namespace kite::arc_import;
namespace fs = std::filesystem;

namespace {

fs::path Arc() { return fs::path(KITE_ARC_FIXTURE_DIR); }
fs::path DefaultHistory() { return Arc() / "User Data" / "Default" / "History"; }

std::string Read(const fs::path& file) {
    std::ifstream in(file, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}
void Write(const fs::path& file, const std::string& bytes) {
    fs::create_directories(file.parent_path());
    std::ofstream(file, std::ios::binary | std::ios::trunc).write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
}

struct TempDir {
    fs::path path;
    TempDir() {
        path = fs::temp_directory_path() / ("kite-arc-history-test-" + NewUuid());
        fs::create_directories(path);
    }
    ~TempDir() {
        std::error_code ignored;
        fs::remove_all(path, ignored);
    }
};

// A copy of the fixture's Arc folder, for the tests that put files beside its History.
fs::path CopyArc(const TempDir& dir) {
    const fs::path arc = dir.path / "Arc";
    fs::copy(Arc(), arc, fs::copy_options::recursive);
    return arc;
}

// 2026-10-01 00:00 UTC in Chromium's microseconds, plus `hours`: the fixture's times.
int64_t At(int hours) { return (int64_t{1790812800} + 11644473600) * 1'000'000 + int64_t{hours} * 3600 * 1'000'000; }

std::optional<HistoryRead> ReadFixture(const HistoryReadOptions& options = {}) {
    sqlite::FilePages pages(DefaultHistory());
    return ReadChromiumHistory(pages, options);
}

const HistoryEntry* Find(const HistoryRead& read, const std::string& url) {
    auto it = std::find_if(read.entries.begin(), read.entries.end(), [&](const HistoryEntry& e) { return e.url == url; });
    return it == read.entries.end() ? nullptr : &*it;
}

#ifdef _WIN32
// A file held open as a live writer holds it: SQLite's read-write handle sharing everything, or
// Chromium's lockfile (written, shared for reading only). Closed when it goes.
struct Held {
    int fd = -1;
    Held(const fs::path& file, bool likeLockfile) {
        _wsopen_s(&fd, file.c_str(), (likeLockfile ? _O_WRONLY | _O_CREAT : _O_RDWR) | _O_BINARY, likeLockfile ? _SH_DENYWR : _SH_DENYNO,
                  _S_IREAD | _S_IWRITE);
    }
    ~Held() {
        if (fd >= 0) _close(fd);
    }
};
#endif

int SkippedCount(const json::Value& summary, const std::string& kind) {
    const json::Value* skipped = summary.Find("skipped");
    if (!skipped || !skipped->AsArray()) return -1;
    for (const json::Value& s : *skipped->AsArray()) {
        if (s.Find("kind") && s.Find("kind")->AsString() && *s.Find("kind")->AsString() == kind) {
            return s.Find("count") ? static_cast<int>(s.Find("count")->AsNumber().value_or(-1)) : 0;
        }
    }
    return -1;
}
double ImportedCount(const Imported& imported, const std::string& key) {
    auto it = imported.imported.find(key);
    return it == imported.imported.end() ? -1 : it->second.AsNumber().value_or(-1);
}

}  // namespace

TEST(ArcHistoryImport_readsTheUrlsTableAsTheMacsQueryDoes) {
    auto read = ReadFixture();
    CHECK(read);
    if (!read) return;
    // 90 rows: 80 pages, then one of each kind.
    CHECK(read->rows == 90 && read->hidden == 1 && read->neverVisited == 1 && read->beyondCap == 0 && read->notWebPages == 2 &&
          read->tooLong == 0);
    CHECK(read->entries.size() == 86);
    // ORDER BY last_visit_time DESC.
    CHECK(std::is_sorted(read->entries.begin(), read->entries.end(),
                         [](const HistoryEntry& a, const HistoryEntry& b) { return a.lastVisit > b.lastVisit; }));
    CHECK(read->entries.front().url == "https://docs.kite.example/start" && read->entries.front().title == "Kite Docs" &&
          read->entries.front().visitCount == 3 && read->entries.front().lastVisit == History::ChromiumDate(At(500)));
    // max(1, visit_count).
    CHECK(Find(*read, "https://news.example.test/") && Find(*read, "https://news.example.test/")->visitCount == 1);
    // Left out: hidden = 1, last_visit_time 0, and what History::Records doesn't keep.
    CHECK(!Find(*read, "https://hidden.example.test/frame") && !Find(*read, "https://never.example.test/"));
    CHECK(!Find(*read, "chrome://settings/") && !Find(*read, "file:///C:/notes.txt"));
    // A URL spilling onto overflow pages reads whole.
    CHECK(Find(*read, "https://long.example.test/?pad=" + std::string(3000, 'x')));
    // A NULL title is "", and String(cString:) ends a title at a NUL and repairs bad UTF-8.
    CHECK(Find(*read, "https://untitled.example.test/") && Find(*read, "https://untitled.example.test/")->title.empty());
    CHECK(Find(*read, "https://nul.example.test/") && Find(*read, "https://nul.example.test/")->title == "Before");
    CHECK(Find(*read, "https://latin1.example.test/") && Find(*read, "https://latin1.example.test/")->title == "Caf\xEF\xBF\xBD");
}

TEST(ArcHistoryImport_urlsAreKeptAsTheMacsURLReadsThem) {
    // Chromium keeps `|` and `{` as typed; the Mac's URL(string:) percent-encodes them
    // (History::Normalized), so its history has the encoded URL, and the row already encoded is
    // the same page: one entry, the newer row's visit and title, the higher count.
    sqlite::FilePages pages(fs::path(KITE_TEST_FIXTURES_DIR) / "history-raw-urls.sqlite");
    auto read = ReadChromiumHistory(pages);
    CHECK(read);
    if (!read) return;
    CHECK(read->rows == 6 && read->sameURL == 2 && read->notWebPages == 0 && read->entries.size() == 4);
    if (read->entries.size() != 4) return;
    const HistoryEntry& pipes = read->entries[0];
    CHECK(pipes.url == "https://pipes.example.test/a%7Cb?q=%7Bx%7D" && pipes.title == "Raw" && pipes.visitCount == 5 &&
          pipes.lastVisit == History::ChromiumDate(At(20)));
    CHECK(read->entries[1].url == History::Normalized("https://braces.example.test/{id}#a|b") &&
          read->entries[1].url.find_first_of("{}|") == std::string::npos);
    // NSURL's rule is per part: a part that needs any encoding is encoded whole, its % too.
    // The newer row has no title: the older row's stays, as the Mac's merge keeps it.
    CHECK(read->entries[2].url == "https://notitle.example.test/x%7Cy" && read->entries[2].title == "Older" &&
          read->entries[2].visitCount == 4 && read->entries[2].lastVisit == History::ChromiumDate(At(3)));
    CHECK(read->entries[3].url == "https://pct.example.test/a%2520b%7Cc" &&
          read->entries[3].url == History::Normalized("https://pct.example.test/a%20b|c"));
    // What Merge keys them by is what was read: a second import finds them.
    History history;
    CHECK(history.Merge(read->entries) == 4 && history.Merge(read->entries) == 0);
    CHECK(history.Find("https://pipes.example.test/a%7Cb?q=%7Bx%7D"));
}

TEST(ArcHistoryImport_theCapIsTheNewestRowsBeforeTheWebPageFilter) {
    // The Mac's LIMIT comes before its filter: chrome://settings is among the newest three and
    // takes a place, so two pages come.
    HistoryReadOptions options;
    options.maxEntries = 3;
    auto read = ReadFixture(options);
    CHECK(read);
    if (!read) return;
    CHECK(read->entries.size() == 2 && read->notWebPages == 1 && read->beyondCap == 85);
    CHECK(read->entries[0].url == "https://docs.kite.example/start" && read->entries[1].url == "https://news.example.test/");
    // Every row is counted once.
    CHECK(read->hidden + read->neverVisited + read->beyondCap + read->notWebPages + read->entries.size() == read->rows);
}

TEST(ArcHistoryImport_inMemoryAndPageByPageReadTheSame) {
    const std::string bytes = Read(DefaultHistory());
    sqlite::MemoryPages memory(bytes);
    auto fromMemory = ReadChromiumHistory(memory);
    sqlite::FilePages file(DefaultHistory());
    auto fromFile = ReadChromiumHistory(file);
    CHECK(fromMemory && fromFile && fromMemory->entries == fromFile->entries);
    // Each page at most once (and the header): never more than the file.
    CHECK(file.BytesRead() <= bytes.size() + 100);
}

TEST(ArcHistoryImport_whatIsntAHistoryDatabaseReadsAsNone) {
    sqlite::FilePages webData(Arc() / "User Data" / "Default" / "Web Data");  // no urls table
    CHECK(!ReadChromiumHistory(webData));
    sqlite::MemoryPages text(std::string_view("not a database"));
    CHECK(!ReadChromiumHistory(text));
    // Cut short anywhere: none, or (when what's cut is no page of urls) all of it, never part.
    const std::string bytes = Read(DefaultHistory());
    for (size_t size : {size_t{100}, size_t{1024}, size_t{5000}}) {
        sqlite::MemoryPages cut(std::string_view(bytes).substr(0, size));
        CHECK(!ReadChromiumHistory(cut));
    }
    for (size_t size : {bytes.size() / 2, bytes.size() - 1024, bytes.size() - 1}) {
        sqlite::MemoryPages cut(std::string_view(bytes).substr(0, size));
        auto read = ReadChromiumHistory(cut);
        CHECK(!read || read->entries.size() == 86);
    }
    // Garbage after the schema page.
    std::string scrambled = bytes;
    for (size_t i = 2048; i < scrambled.size(); ++i) scrambled[i] = static_cast<char>((i * 131) & 0xFF);
    sqlite::MemoryPages garbage(scrambled);
    auto read = ReadChromiumHistory(garbage);
    CHECK(!read || read->entries.size() <= 86);
    // A table without one of the query's columns: the Mac's query doesn't run.
    sqlite::FilePages fixture(DefaultHistory());
    bool reached = false;
    auto scan = sqlite::ScanTable(
        fixture, "visits", [](const std::vector<std::string>& columns) { return std::find(columns.begin(), columns.end(), "hidden") != columns.end(); },
        [&](std::vector<sqlite::SqlValue>&) { return reached = true; });
    CHECK(scan && scan->stopped && !reached);
}

TEST(ArcHistoryImport_aScanStreamsStopsAndLeavesLongRowsUnread) {
    sqlite::FilePages pages(DefaultHistory());
    size_t seen = 0;
    sqlite::ScanOptions options;
    options.maxRecordBytes = 2000;  // the 3000-byte URL's row is past it
    auto scan = sqlite::ScanTable(
        pages, "urls", [](const std::vector<std::string>&) { return true; },
        [&](std::vector<sqlite::SqlValue>&) { return ++seen, true; }, options);
    CHECK(scan && scan->rows == 89 && scan->oversized == 1 && !scan->stopped && seen == 89);
    // The visitor ends it: not a failure.
    sqlite::FilePages again(DefaultHistory());
    seen = 0;
    scan = sqlite::ScanTable(
        again, "urls", [](const std::vector<std::string>&) { return true; }, [&](std::vector<sqlite::SqlValue>&) { return ++seen < 5; });
    CHECK(scan && scan->stopped && seen == 5);
    // A cancelled read gives nothing.
    std::atomic<bool> cancel{true};
    HistoryReadOptions cancelled;
    cancelled.cancel = &cancel;
    CHECK(!ReadFixture(cancelled));
}

TEST(ArcHistoryImport_theHeaderSaysWhichJournal) {
    const std::string bytes = Read(DefaultHistory());
    CHECK(sqlite::HeaderJournal(bytes) == sqlite::Journal::Rollback);
    std::string wal = bytes;
    wal[18] = wal[19] = 2;
    CHECK(sqlite::HeaderJournal(wal) == sqlite::Journal::WriteAheadLog);
    wal[19] = 1;
    CHECK(!sqlite::HeaderJournal(wal));
    CHECK(!sqlite::HeaderJournal("SQLite format 3"));
}

TEST(ArcHistoryImport_readsArcsFileOnlyWhenArcCantBeChangingIt) {
    TempDir dir;
    const fs::path arc = CopyArc(dir);
    const fs::path history = ArcHistoryFile(arc, "Default");
    CHECK(history == arc / "User Data" / "Default" / "History");
    auto read = ReadArcHistory(arc, "Default", kMaxArcFileBytes);
    CHECK(read.read && read.read->entries.size() == 86 && read.problem.empty());
    // No such profile, or no History in it: nothing, and no problem.
    auto missing = ReadArcHistory(arc, "Profile 9", kMaxArcFileBytes);
    CHECK(!missing.read && missing.problem.empty() && !missing.tooLarge && !missing.unreadable);

    // A lockfile nobody holds (Arc ended in a crash or a power cut, or has shut down for good)
    // is nothing.
    Write(arc / "User Data" / "lockfile", "");
    CHECK(ReadArcHistory(arc, "Default", kMaxArcFileBytes).read);
    fs::remove(arc / "User Data" / "lockfile");

    // A hot rollback journal with no writer: a write left half done. A finished (empty or
    // zeroed) one is nothing.
    const fs::path journal = history.string() + "-journal";
    Write(journal, std::string("\xD9\xD5\x05\xF9\x20\xA1\x63\xD7", 8) + std::string(504, '\0'));
    auto writing = ReadArcHistory(arc, "Default", kMaxArcFileBytes);
    CHECK(!writing.read && writing.problem == "Arc didn't finish its last write: open and quit Arc once, then import again");
    Write(journal, std::string(512, '\0'));
    CHECK(ReadArcHistory(arc, "Default", kMaxArcFileBytes).read);
    Write(journal, "");
    CHECK(ReadArcHistory(arc, "Default", kMaxArcFileBytes).read);

    // A write-ahead log with frames in it: committed pages may be there only.
    std::string walMode = Read(history);
    walMode[18] = walMode[19] = 2;
    Write(history, walMode);
    const fs::path wal = history.string() + "-wal";
    Write(wal, std::string(4096 + 32, '\x01'));
    auto logged = ReadArcHistory(arc, "Default", kMaxArcFileBytes);
    CHECK(!logged.read && logged.problem == "Arc didn't finish its last write: open and quit Arc once, then import again");
    // An empty one (checkpointed as the last connection closed): the file is all of it.
    Write(wal, "");
    auto checkpointed = ReadArcHistory(arc, "Default", kMaxArcFileBytes);
    CHECK(checkpointed.read && checkpointed.read->entries.size() == 86);
    fs::remove(wal);
    CHECK(ReadArcHistory(arc, "Default", kMaxArcFileBytes).read);

    // Changed while it was read (Arc started and wrote): left out, whatever came out.
    HistoryReadOptions racing;
    racing.afterRead = [&] { std::ofstream(history, std::ios::binary | std::ios::app) << std::string(1024, '\0'); };
    auto changed = ReadArcHistory(arc, "Default", kMaxArcFileBytes, racing);
    CHECK(!changed.read && changed.problem == "Arc changed it while Kite read it: quit Arc and import again");
    fs::resize_file(history, fs::file_size(history) - 1024);
    CHECK(ReadArcHistory(arc, "Default", kMaxArcFileBytes).read);

    // Past the cap, and not a database.
    auto large = ReadArcHistory(arc, "Default", 1024);
    CHECK(!large.read && large.tooLarge == fs::file_size(history));
    Write(history, "not a database at all, but longer than an SQLite header is, which is one hundred bytes long......");
    auto broken = ReadArcHistory(arc, "Default", kMaxArcFileBytes);
    CHECK(!broken.read && broken.unreadable && broken.problem.empty());
}

#ifdef _WIN32
TEST(ArcHistoryImport_aLiveWriterIsRefusedAndAStaleLockfileIsNot) {
    // What "Arc is running" rests on: a probe that opens the file for reading while denying
    // writers, which Windows refuses while a writer has it open. Arc itself is never launched.
    TempDir dir;
    const fs::path arc = CopyArc(dir);
    const fs::path history = ArcHistoryFile(arc, "Default");
    const std::string writing = "Arc is writing it: quit Arc and import again";
    {
        Held sqlite(history, false);  // History open for writing, as Chromium's HistoryBackend keeps it
        CHECK(sqlite.fd >= 0 && HasLiveWriter(history));
        auto read = ReadArcHistory(arc, "Default", kMaxArcFileBytes);
        CHECK(!read.read && read.problem == writing);
        // Web Data the same way: its own database is free, but Arc is running (the lockfile).
    }
    CHECK(!HasLiveWriter(history) && ReadArcHistory(arc, "Default", kMaxArcFileBytes).read);
    {
        Held lock(arc / "User Data" / "lockfile", true);  // Chromium's ProcessSingleton lockfile, held
        CHECK(lock.fd >= 0);
        auto read = ReadArcHistory(arc, "Default", kMaxArcFileBytes);
        CHECK(!read.read && read.problem == writing);
        auto plan = ReadAuto(arc);
        CHECK(std::holds_alternative<Plan>(plan) && std::get<Plan>(plan).siteSearches.empty() &&
              std::find(std::get<Plan>(plan).unreadable.begin(), std::get<Plan>(plan).unreadable.end(), FileProblem{"Web Data", writing}) !=
                  std::get<Plan>(plan).unreadable.end());
    }
    // Let go (and still there): stale, so nothing.
    CHECK(fs::exists(arc / "User Data" / "lockfile") && ReadArcHistory(arc, "Default", kMaxArcFileBytes).read);
    CHECK(!HasLiveWriter(arc / "User Data" / "no such file"));
}
#endif

TEST(ArcHistoryImport_aSchemaRowPastTheCapIsLeftUnread) {
    // A CREATE statement past kMaxSchemaRecordBytes (a 70 KB DEFAULT) is skipped without
    // reading its overflow pages, and the urls table after it still reads.
    sqlite::FilePages pages(fs::path(KITE_TEST_FIXTURES_DIR) / "history-big-schema.sqlite");
    auto read = ReadChromiumHistory(pages);
    CHECK(read && read->entries.size() == 1);
    sqlite::FilePages again(fs::path(KITE_TEST_FIXTURES_DIR) / "history-big-schema.sqlite");
    auto pad = sqlite::ScanTable(
        again, "pad", [](const std::vector<std::string>&) { return true; }, [](std::vector<sqlite::SqlValue>&) { return true; });
    CHECK(!pad);
}

TEST(ArcImportController_readsEachProfilesHistoryAndCountsItInTheConfirmation) {
    auto plan = ReadAuto(Arc());
    CHECK(std::holds_alternative<Plan>(plan));
    if (!std::holds_alternative<Plan>(plan)) return;
    const Plan& p = std::get<Plan>(plan);
    CHECK(p.histories.size() == 2 && p.histories.at("Default").entries.size() == 86 && p.histories.at("Profile 1").entries.size() == 2);
    // The Mac's "Also imports ... N history pages": the profiles whose spaces come over and
    // Default. Profile 1 only has the unnamed space, so its pages count once it's included.
    BrowserState state;
    auto has = [](const std::vector<std::string>& lines, const std::string& text) {
        return std::any_of(lines.begin(), lines.end(), [&](const std::string& l) { return l.find(text) != std::string::npos; });
    };
    CHECK(has(ConfirmLines(p, state, false), "86 history pages"));
    CHECK(has(ConfirmLines(p, state, true), "88 history pages"));
    CHECK(has(ConfirmLines(p, state, false), "with its favorites and history, only if you include them"));
    // No history to put it in: not read.
    ReadOptions noHistory;
    noHistory.history = false;
    auto without = ReadAuto(Arc(), noHistory);
    CHECK(std::holds_alternative<Plan>(without) && std::get<Plan>(without).histories.empty());
    CHECK(!has(ConfirmLines(std::get<Plan>(without), state, false), "history page"));
}

TEST(ArcImportController_aProfileWhoseHistoryWontReadIsNamed) {
    TempDir dir;
    const fs::path arc = CopyArc(dir);
    Write(ArcHistoryFile(arc, "Default").string() + "-journal", std::string("\xD9\xD5\x05\xF9\x20\xA1\x63\xD7", 8) + std::string(504, '\0'));
    auto plan = ReadAuto(arc);
    CHECK(std::holds_alternative<Plan>(plan));
    if (!std::holds_alternative<Plan>(plan)) return;
    const Plan& p = std::get<Plan>(plan);
    CHECK(p.histories.size() == 1 && p.histories.contains("Profile 1"));
    const std::string unfinished = "Arc didn't finish its last write: open and quit Arc once, then import again";
    CHECK(std::find(p.unreadable.begin(), p.unreadable.end(), FileProblem{"Default/History", unfinished}) != p.unreadable.end());
    BrowserState state;
    auto lines = ConfirmLines(p, state, false);
    CHECK(std::any_of(lines.begin(), lines.end(), [&](const std::string& l) { return l.find("Default/History (" + unfinished + ")") != std::string::npos; }));
}

TEST(ArcImportController_historyGoesToTheKiteProfileItsSpacesWentTo) {
    TempDir dir;
    auto plan = ReadAuto(Arc());
    CHECK(std::holds_alternative<Plan>(plan));
    if (!std::holds_alternative<Plan>(plan)) return;
    const Plan& p = std::get<Plan>(plan);

    // A page Kite already has, visited later in Kite: it keeps Kite's visit and the higher count.
    // One Kite has with no title (visited later still) takes Arc's.
    {
        History mine;
        mine.RecordVisit("https://docs.kite.example/start", "Mine", History::ChromiumDate(At(900)));
        mine.RecordVisit("https://news.example.test/", "", History::ChromiumDate(At(950)));
        CHECK(HistoryFile(dir.path / "history.json").Save(mine).empty());
    }
    BrowserState state;
    ImportOptions everything;
    everything.includeUntitled = true;
    Imported imported = Import(state, p, everything);
    CHECK(imported.histories.size() == 2);
    {
        HistoryStores stores(dir.path);
        stores.Start();
        CHECK(MergeHistories(imported, stores, std::chrono::seconds(10)));
        stores.SaveNow();
        CHECK(stores.Flush(DeadlineAfter(std::chrono::seconds(10))).empty());
    }
    // 86 + 2 merged; the docs and news pages were in Default's history already (Profile 1's docs
    // page is new there).
    CHECK(ImportedCount(imported, "historyPages") == 88 && ImportedCount(imported, "historyPagesNew") == 86);
    const json::Value summary = Summary(imported);
    CHECK(SkippedCount(summary, "historyHidden") == 1 && SkippedCount(summary, "historyNeverVisited") == 1 &&
          SkippedCount(summary, "historyNotWebPages") == 2 && SkippedCount(summary, "historyProfilesLeftOut") == -1 &&
          SkippedCount(summary, "history") == -1);

    auto loaded = HistoryFile(dir.path / "history.json").Load(HistoryFile::Unreadable::Leave);
    CHECK(std::holds_alternative<History>(loaded));
    if (auto* history = std::get_if<History>(&loaded)) {
        CHECK(history->Count() == 86);  // 84 new, 2 Kite had
        auto docs = history->Find("https://docs.kite.example/start");
        CHECK(docs && docs->lastVisit == History::ChromiumDate(At(900)) && docs->visitCount == 3 && docs->title == "Mine");
        auto news = history->Find("https://news.example.test/");
        CHECK(news && news->title == "News" && news->lastVisit == History::ChromiumDate(At(950)));
    }
    // Profile 1's pages are in the Kite profile made for it.
    std::string made;
    for (const Profile& profile : AllProfiles(state)) {
        if (profile.name == "Side Project") made = profile.directory;
    }
    CHECK(!made.empty());
    auto side = HistoryFile(HistoryStores::FileFor(dir.path, made)).Load(HistoryFile::Unreadable::Leave);
    CHECK(std::holds_alternative<History>(side) && std::get<History>(side).Count() == 2);

    // Importing again doubles nothing.
    Imported again = Import(state, p, everything);
    {
        HistoryStores stores(dir.path);
        stores.Start();
        CHECK(MergeHistories(again, stores, std::chrono::seconds(10)));
        stores.SaveNow();
        CHECK(stores.Flush(DeadlineAfter(std::chrono::seconds(10))).empty());
    }
    CHECK(ImportedCount(again, "historyPages") == 88 && ImportedCount(again, "historyPagesNew") == 0);
}

TEST(ArcImportController_historyMergesOneProfileAPass) {
    // The app merges one profile a message; the counts add up across the passes.
    TempDir dir;
    auto plan = ReadAuto(Arc());
    CHECK(std::holds_alternative<Plan>(plan));
    if (!std::holds_alternative<Plan>(plan)) return;
    BrowserState state;
    ImportOptions everything;
    everything.includeUntitled = true;
    Imported imported = Import(state, std::get<Plan>(plan), everything);
    CHECK(imported.histories.size() == 2);
    HistoryStores stores(dir.path);
    stores.Start();
    CHECK(MergeHistories(imported, stores, std::chrono::seconds(10), 1));
    CHECK(imported.histories.size() == 1 && ImportedCount(imported, "historyPages") == 86 && ImportedCount(imported, "historyPagesNew") == 86);
    CHECK(MergeHistories(imported, stores, std::chrono::seconds(10), 1));
    CHECK(imported.histories.empty() && ImportedCount(imported, "historyPages") == 88 && ImportedCount(imported, "historyPagesNew") == 88);
    CHECK(MergeHistories(imported, stores, std::chrono::seconds(10), 1));  // nothing left: nothing changes
    CHECK(ImportedCount(imported, "historyPages") == 88);
    stores.SaveNow();
    CHECK(stores.Flush(DeadlineAfter(std::chrono::seconds(10))).empty());
}

TEST(ArcImportController_historyLeftOutWithItsProfileAndPrunedPastTheCap) {
    TempDir dir;
    auto plan = ReadAuto(Arc());
    CHECK(std::holds_alternative<Plan>(plan));
    if (!std::holds_alternative<Plan>(plan)) return;
    // Kite's history nearly full: 19,950 older pages of its own.
    {
        std::vector<HistoryEntry> own;
        for (int n = 0; n < 19'950; ++n) own.push_back({"https://own" + std::to_string(n) + ".example.test/", "", -1000.0 - n, 1});
        History mine;
        mine.Merge(own);
        CHECK(mine.Count() == 19'950 && HistoryFile(dir.path / "history.json").Save(mine).empty());
    }
    BrowserState state;
    Imported imported = Import(state, std::get<Plan>(plan));  // the unnamed space (Profile 1's) stays out
    CHECK(imported.histories.size() == 1);
    HistoryStores stores(dir.path);
    stores.Start();
    CHECK(MergeHistories(imported, stores, std::chrono::seconds(10)));
    stores.SaveNow();
    CHECK(stores.Flush(DeadlineAfter(std::chrono::seconds(10))).empty());
    const json::Value summary = Summary(imported);
    CHECK(SkippedCount(summary, "historyProfilesLeftOut") == 2);
    // 19,950 + 86 is past 20,000: the oldest 36 go.
    CHECK(ImportedCount(imported, "historyPagesNew") == 86 && SkippedCount(summary, "historyPruned") == 36);
    CHECK(stores.ForProfile(Profile::kDefaultDirectory).Get().Count() == History::kMaxEntries);
}

TEST(ArcImportController_kitesOwnUnreadableHistoryIsMovedAsideFirst) {
    // As at launch: the file that won't read goes aside (history.corrupt-<time>.json), and
    // Arc's history starts the new one.
    TempDir dir;
    Write(dir.path / "history.json", "{not json");
    auto plan = ReadAuto(Arc());
    CHECK(std::holds_alternative<Plan>(plan));
    if (!std::holds_alternative<Plan>(plan)) return;
    BrowserState state;
    Imported imported = Import(state, std::get<Plan>(plan));
    {
        HistoryStores stores(dir.path);
        stores.Start();
        CHECK(MergeHistories(imported, stores, std::chrono::seconds(10)));
        stores.SaveNow();
        CHECK(stores.Flush(DeadlineAfter(std::chrono::seconds(10))).empty());
    }
    CHECK(ImportedCount(imported, "historyPagesNew") == 86);
    size_t aside = 0;
    for (const auto& entry : fs::directory_iterator(dir.path)) aside += entry.path().filename().string().starts_with("history.corrupt-");
    CHECK(aside == 1);
}
