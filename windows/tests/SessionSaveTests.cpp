// Saving the session as it changes (W11): ports of KiteCore's PageEventSaveTests (the save
// delays), SessionBackupTests and StoreFileTests (KiteCoreTests.swift, PageEventSaveTests.swift,
// StoreFileTests.swift), each named after the Swift test it comes from, plus the background
// writer's edge cases the Mac doesn't test.

#include <algorithm>
#include <atomic>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <functional>
#include <memory>
#include <set>
#include <sstream>
#include <thread>

#include "Check.h"
#include "core/Models.h"
#include "core/SessionBackups.h"
#include "core/SessionSaveDelay.h"
#include "core/SessionStore.h"
#include "core/SessionWriter.h"
#include "core/StoreFile.h"
#include "core/Uuid.h"

using namespace kite;
namespace fs = std::filesystem;

namespace {

fs::path TempDir() {
    fs::path dir = fs::temp_directory_path() / ("kite-save-test-" + NewUuid());
    fs::create_directories(dir);
    return dir;
}

std::string ReadText(const fs::path& path) { return store_file::Read(path).value_or(""); }

void WriteText(const fs::path& path, const std::string& text) {
    fs::create_directories(path.parent_path());
    std::ofstream(path, std::ios::binary | std::ios::trunc) << text;
}

std::string Name(const fs::path& path) {
    auto u8 = path.filename().u8string();
    return std::string(u8.begin(), u8.end());
}

size_t CountNamed(const fs::path& dir, std::string_view part) {
    size_t n = 0;
    std::error_code error;
    for (fs::directory_iterator it(dir, error), end; !error && it != end; it.increment(error)) {
        n += Name(it->path()).find(part) != std::string::npos;
    }
    return n;
}

// SessionBackupTests' fixture: made once per test, since each new state has new ids and the
// tests compare them. state(tabs: n) has n tabs opened at 1_700_000_000.
struct Backups {
    fs::path dir = TempDir();
    SessionStore store{dir / "session.json"};
    static constexpr double start = 1'700'000'000;
    static constexpr double hour = SessionBackups::kInterval;
    std::vector<BrowserState> states;

    explicit Backups(int count = 3) {
        for (int tabs = 0; tabs < count; ++tabs) {
            BrowserState state = BrowserState::MakeDefault(std::nullopt);
            for (int i = 0; i < tabs; ++i) state.OpenTab("https://kite.example/" + std::to_string(i), std::nullopt, true, FromUnixTime(start));
            states.push_back(std::move(state));
        }
    }
    ~Backups() {
        std::error_code ignored;
        fs::remove_all(dir, ignored);
    }
    const BrowserState& State(int tabs) const { return states[static_cast<size_t>(tabs)]; }
    std::optional<SessionBackups::Backup> BackUp(int tabs, SessionBackups::Kind kind, double date) {
        auto result = store.Backups().BackUp(SessionStore::EncodeFile(State(tabs)), kind, date);
        CHECK(result.error.empty());
        return result.made;
    }
    std::optional<SessionBackups::Backup> BackUp(int tabs, double date) { return BackUp(tabs, SessionBackups::Kind::Hourly, date); }
    void Write(const std::string& text, const std::string& name) {
        WriteText(store.Backups().Directory() / fs::path(std::u8string(name.begin(), name.end())), text);
    }
};

// A test's clock for the writer, which may outlive any one stack frame (its `now` must not
// capture by reference): shared with the writer's copy of it.
struct TestClock {
    std::shared_ptr<std::atomic<double>> time;
    explicit TestClock(double start) : time(std::make_shared<std::atomic<double>>(start)) {}
    TestClock& operator=(double t) {
        time->store(t);
        return *this;
    }
    std::function<double()> Fn() const {
        return [time = time] { return time->load(); };
    }
};

size_t TabCount(const BrowserState& state) {
    size_t n = 0;
    for (const Space& space : state.spaces) n += space.AllTabs().size();
    return n;
}

}  // namespace

// MARK: The save delays (PageEventSaveTests.swift)

// PageEventSaveTests.pageEventsWaitLongerAndNeverPushBackAWaitingSave
TEST(pageEventsWaitLongerAndNeverPushBackAWaitingSave) {
    CHECK(Seconds(SessionSaveDelay::PageEvent) > Seconds(SessionSaveDelay::Soon));
    // Nothing waiting: each arms its own delay.
    CHECK(Rearm(SessionSaveDelay::Soon, std::nullopt) == 1.0);
    CHECK(Rearm(SessionSaveDelay::PageEvent, std::nullopt) == 10.0);
    // A ticking title leaves the waiting save alone, so it still lands.
    CHECK(!Rearm(SessionSaveDelay::PageEvent, SessionSaveDelay::PageEvent));
    CHECK(!Rearm(SessionSaveDelay::PageEvent, SessionSaveDelay::Soon));
    // A sidebar change brings a waiting page save forward, and debounces as before.
    CHECK(Rearm(SessionSaveDelay::Soon, SessionSaveDelay::PageEvent) == 1.0);
    CHECK(Rearm(SessionSaveDelay::Soon, SessionSaveDelay::Soon) == 1.0);
}

// PageEventSaveTests.pendingSaveWiresTheRearmRules
TEST(pendingSaveWiresTheRearmRules) {
    PendingSave save;
    CHECK(save.Arm(SessionSaveDelay::PageEvent) == 10.0);
    CHECK(save.pending == SessionSaveDelay::PageEvent);
    // Ticks while it waits leave it alone.
    CHECK(!save.Arm(SessionSaveDelay::PageEvent));
    CHECK(save.pending == SessionSaveDelay::PageEvent);
    // A navigation or sidebar change brings it forward; ticks then leave that alone too.
    CHECK(save.Arm(SessionSaveDelay::Soon) == 1.0);
    CHECK(save.pending == SessionSaveDelay::Soon);
    CHECK(!save.Arm(SessionSaveDelay::PageEvent));
    CHECK(save.Arm(SessionSaveDelay::Soon) == 1.0);
    save.Saved();
    CHECK(!save.pending);
    CHECK(save.Arm(SessionSaveDelay::PageEvent) == 10.0);
}

TEST(manyChangesWithinTheDelayCoalesceIntoOneSave) {
    // A hundred sidebar changes 10 ms apart: one save, a second after the last.
    std::vector<SaveChange> changes;
    for (int i = 0; i < 100; ++i) changes.push_back({i * 0.01, SessionSaveDelay::Soon});
    SaveReplay replay = ReplaySaves(changes);
    CHECK(replay.saves.size() == 1);
    CHECK(replay.saves.size() == 1 && std::abs(replay.saves[0].at - 1.99) < 1e-9);
    // Changes a delay apart save each time.
    replay = ReplaySaves({{0, SessionSaveDelay::Soon}, {1, SessionSaveDelay::Soon}, {2.5, SessionSaveDelay::Soon}});
    CHECK(replay.saves.size() == 3);
}

TEST(aTitleChangeUsesTheLongerDelay) {
    SaveSchedule schedule;
    CHECK(schedule.Changed(SessionSaveDelay::PageEvent, 100) == 10.0);
    CHECK(schedule.DueAt() == 110.0);
    // The page keeps ticking: the save it armed stays due at 110, never pushed back.
    for (int t = 101; t < 110; ++t) CHECK(!schedule.Changed(SessionSaveDelay::PageEvent, t));
    CHECK(schedule.DueAt() == 110.0 && schedule.Pending() == SessionSaveDelay::PageEvent);
    // A title every second for a minute still saves every ten seconds.
    std::vector<SaveChange> ticks;
    for (int t = 0; t < 60; ++t) ticks.push_back({static_cast<double>(t), SessionSaveDelay::PageEvent});
    SaveReplay replay = ReplaySaves(ticks);
    CHECK(replay.saves.size() == 6);
    for (size_t i = 0; i < replay.saves.size(); ++i) {
        CHECK(replay.saves[i].at == 10.0 * static_cast<double>(i + 1));
        CHECK(replay.saves[i].kind == SessionSaveDelay::PageEvent);
    }
    // A navigation while a title save waits brings it forward to a second.
    replay = ReplaySaves({{0, SessionSaveDelay::PageEvent}, {2, SessionSaveDelay::Soon}}, 5);
    CHECK(replay.saves.size() == 1 && replay.saves[0].at == 3.0 && replay.saves[0].kind == SessionSaveDelay::Soon);
    CHECK(!replay.pending && !replay.dueAt);
    // What's waiting part-way: kitecore save-schedule's pending state.
    replay = ReplaySaves({{0, SessionSaveDelay::PageEvent}, {4, SessionSaveDelay::PageEvent}}, 5);
    CHECK(replay.saves.empty() && replay.pending == SessionSaveDelay::PageEvent && replay.dueAt == 10.0);
    CHECK(SessionSaveDelayFromRaw(RawValue(SessionSaveDelay::PageEvent)) == SessionSaveDelay::PageEvent);
    CHECK(!SessionSaveDelayFromRaw("later"));
}

// MARK: Atomic writes (StoreFile.swift, SessionStore.save)

// StoreFileTests.aMissingFileIsNotAnError, for the session (the one store Windows has)
TEST(aMissingSessionIsNotAnError) {
    fs::path dir = TempDir();
    SessionStore store(dir / "session.json");
    auto load = store.Load();
    CHECK(std::holds_alternative<SessionStore::Missing>(load));
    CHECK(SessionStore::MaySave(load));
    CHECK(CountNamed(dir, ".corrupt-") == 0);
    CHECK(!fs::exists(dir / "Backups"));
    fs::remove_all(dir);
}

TEST(aCrashMidWriteLeavesThePreviousFileIntact) {
    fs::path dir = TempDir();
    SessionStore store(dir / "session.json");
    BrowserState before = BrowserState::MakeDefault();
    CHECK(store.Save(before).empty());
    const std::string saved = ReadText(store.File());
    // What a crash mid-write leaves: half of the next file in the temp file, the session as it was.
    BrowserState after = before;
    after.OpenTab("https://kite.example/after");
    const std::string next = SessionStore::EncodeFile(after);
    const fs::path leftover = dir / "session.json.0badf00d-7.tmp";
    WriteText(leftover, next.substr(0, next.size() / 2));
    auto load = store.Load();
    CHECK(std::holds_alternative<BrowserState>(load) && std::get<BrowserState>(load) == before);
    CHECK(ReadText(store.File()) == saved);
    // The next write goes through a temp of its own and leaves none; the leftover goes once
    // it's old enough that no write can still be using it.
    CHECK(store.Save(after).empty());
    CHECK(ReadText(store.File()) == next);
    CHECK(CountNamed(dir, ".tmp") == 1);
    WriteText(dir / "notes.tmp", "not a temp of Kite's");
    CHECK(store_file::RemoveStaleTemps(dir, std::chrono::hours(1)) == 0);
    CHECK(store_file::RemoveStaleTemps(dir, std::chrono::seconds(0)) == 1);
    CHECK(fs::exists(dir / "notes.tmp"));
    fs::remove(dir / "notes.tmp");
    CHECK(store_file::IsTempName("session.json.0badf00d-7.tmp") && store_file::IsTempName(Name(store_file::NextTempPath(store.File()))));
    // The one name writes used before W11 is a temp too, so a leftover of it goes as well.
    CHECK(store_file::IsTempName("session.json.tmp"));
    for (const char* other : {".json.tmp", "notes.tmp", "session.json.0badf00d-.tmp", "session.json.0badf0-7.tmp", "0badf00d-7.tmp",
                              "session.json.0badf00g-7.tmp"}) {
        CHECK(!store_file::IsTempName(other));
    }
    CHECK(CountNamed(dir, ".tmp") == 0 && fs::exists(store.File()));
    // A write that fails part-way (here its temp file can't be made) leaves the file as it was.
    const fs::path inTheWay = store_file::NextTempPath(store.File());
    fs::create_directories(inTheWay / "in-the-way");
    CHECK(!store.Save(before).empty());
    CHECK(ReadText(store.File()) == next);
    fs::remove_all(dir);
}

TEST(aSaveMakesNoBackupOnItsOwn) {
    // SessionStore::Save is the plain write (kitecore, an importer): backups are the writer's.
    fs::path dir = TempDir();
    SessionStore store(dir / "session.json");
    CHECK(store.Save(BrowserState::MakeDefault()).empty());
    CHECK(!fs::exists(dir / "Backups"));
    fs::remove_all(dir);
}

// MARK: Backups (SessionBackupTests in KiteCoreTests.swift)

// SessionBackupTests.backsUpChangesAtMostOncePerInterval
TEST(backsUpChangesAtMostOncePerInterval) {
    Backups b(4);
    CHECK(Name(b.store.Backups().Directory()) == "Backups");
    CHECK(b.BackUp(1, b.start));
    // Too soon, then the same bytes, then a change after the interval.
    CHECK(!b.BackUp(2, b.start + 60));
    CHECK(!b.BackUp(1, b.start + b.hour));
    auto second = b.BackUp(2, b.start + b.hour);
    CHECK(second && Name(second->file) == "session.2023-11-14-23-13-20-000.json");
    // Launch and restore backups skip the interval, and name their kind.
    auto launch = b.BackUp(3, SessionBackups::Kind::Launch, b.start + b.hour + 1);
    CHECK(launch && Name(launch->file) == "session.2023-11-14-23-13-21-000.launch.json");
    auto all = b.store.Backups().All();
    CHECK(all.size() == 3);
    if (all.size() != 3) return;
    CHECK(all[0].kind == SessionBackups::Kind::Launch && all[1].kind == SessionBackups::Kind::Hourly &&
          all[2].kind == SessionBackups::Kind::Hourly);
    CHECK(SessionBackups::State(all[1]) == b.State(2));
    auto summary = SessionBackups::SummaryOf(all[1]);
    CHECK(summary.spaceCount == BrowserState::MakeDefault().spaces.size());
    CHECK(summary.tabCount == TabCount(b.State(2)));
}

// SessionBackupTests.hourlyBackupsDontPushOutLaunchBackups
TEST(hourlyBackupsDontPushOutLaunchBackups) {
    Backups b(80);
    for (size_t i = 0; i < SessionBackups::kLaunchesKept + 3; ++i) {
        b.BackUp(static_cast<int>(i), SessionBackups::Kind::Launch, b.start + static_cast<double>(i));
    }
    for (int i = 0; i < 40; ++i) b.BackUp(40 + i, b.start + 100 + i * b.hour);
    auto all = b.store.Backups().All();
    const auto launches = std::count_if(all.begin(), all.end(), [](auto& x) { return x.kind == SessionBackups::Kind::Launch; });
    const auto hourly = std::count_if(all.begin(), all.end(), [](auto& x) { return x.kind == SessionBackups::Kind::Hourly; });
    CHECK(static_cast<size_t>(launches) == SessionBackups::kLaunchesKept);
    CHECK(hourly == 40);
    // The newest launches are the ones kept.
    auto oldestLaunch = std::find_if(all.rbegin(), all.rend(), [](auto& x) { return x.kind == SessionBackups::Kind::Launch; });
    CHECK(oldestLaunch != all.rend() && oldestLaunch->date == b.start + 3);
    // Files that aren't backups are left alone.
    b.Write("", "notes.txt");
    b.store.Backups().Prune(b.start + 100 + 39 * b.hour);
    CHECK(fs::exists(b.store.Backups().Directory() / "notes.txt"));
}

// SessionBackupTests.hourlyBackupsThinToOneADayThenExpire
TEST(hourlyBackupsThinToOneADayThenExpire) {
    Backups b(3);
    // Every 6 hours for 40 days.
    for (int i = 0; i < 160; ++i) b.BackUp(i % 2 == 0 ? 1 : 2, b.start + i * 6 * b.hour);
    const double now = b.start + 159 * 6 * b.hour;
    std::vector<SessionBackups::Backup> recent, older;
    for (const auto& backup : b.store.Backups().All()) {
        if (backup.kind != SessionBackups::Kind::Hourly) continue;
        (now - backup.date <= SessionBackups::kHourlyKeptFor ? recent : older).push_back(backup);
    }
    CHECK(recent.size() == 9);
    std::set<std::string> days;
    for (const auto& backup : older) {
        CHECK(now - backup.date <= SessionBackups::kDailyKeptFor);
        days.insert(SessionBackups::Stamp(backup.date).substr(0, 10));
    }
    CHECK(days.size() == older.size());
    CHECK(older.size() >= 27 && older.size() <= 29);
}

// SessionBackupTests.futureStampsDontBlockBackupsOrRestores (the backups; Restore Data isn't
// ported yet)
TEST(futureStampsDontBlockBackups) {
    Backups b(10);
    b.BackUp(1, b.start);
    // A backup stamped a year ahead (the clock went back, or a copied folder).
    b.Write(SessionStore::EncodeFile(b.State(9)), "session.2024-11-14-00-00-00-000.json");
    CHECK(b.BackUp(2, b.start + b.hour));
    auto ordered = b.store.Backups().Ordered(b.start + b.hour);
    CHECK(!ordered.empty() && ordered.front().date == b.start + b.hour);
    CHECK(!ordered.empty() && ordered.back().date > b.start + b.hour);
    auto newest = b.store.Backups().NewestValid(b.start + b.hour);
    CHECK(newest && newest->second == b.State(2));
}

// SessionBackupTests.corruptSessionFallsBackToNewestValidBackup
TEST(corruptSessionFallsBackToNewestValidBackup) {
    Backups b(3);
    b.BackUp(1, b.start);
    b.BackUp(2, b.start + b.hour);
    // The newest backup is damaged too, so the one before it is used.
    b.Write("{nope", "session.2023-11-15-00-00-00-000.json");
    auto all = b.store.Backups().All();
    CHECK(!all.empty() && !SessionBackups::SummaryOf(all[0]).IsRestorable());
    WriteText(b.store.File(), "{nope");
    std::optional<SessionBackups::Backup> recoveredFrom;
    // Recovered as of now: the stamps are in 2023.
    auto loaded = b.store.Load(SessionStore::Unreadable::MoveAside, &recoveredFrom);
    CHECK(std::holds_alternative<BrowserState>(loaded) && std::get<BrowserState>(loaded) == b.State(2));
    CHECK(recoveredFrom && recoveredFrom->date == b.start + b.hour);
    CHECK(CountNamed(b.dir, "corrupt") == 1);
}

// SessionBackupTests.sessionWithNoSpacesIsCorruptNotACrash
TEST(sessionWithNoSpacesIsCorruptNotACrash) {
    Backups b(2);
    const std::string empty = R"({"version":1,"state":{"spaces":[]}})";
    WriteText(b.store.File(), empty);
    CHECK(std::holds_alternative<SessionStore::Error>(b.store.Load()));
    b.BackUp(1, b.start);
    WriteText(b.store.File(), empty);
    auto loaded = b.store.Load();
    CHECK(std::holds_alternative<BrowserState>(loaded) && std::get<BrowserState>(loaded) == b.State(1));
}

// SessionBackupTests.fallbackSkipsTheStateARestoreReplaced, with the restore backup written
// directly (Restore Data isn't ported yet)
TEST(fallbackSkipsTheStateARestoreReplaced) {
    Backups b(5);
    b.BackUp(1, b.start);
    b.BackUp(4, SessionBackups::Kind::Restore, b.start + 60);
    // The newest backup is the rejected 4-tab state; a damaged session comes back as the other.
    auto all = b.store.Backups().All();
    CHECK(!all.empty() && all.front().kind == SessionBackups::Kind::Restore);
    WriteText(b.store.File(), "{nope");
    auto loaded = b.store.Load();
    CHECK(std::holds_alternative<BrowserState>(loaded) && std::get<BrowserState>(loaded) == b.State(1));
    // With only a restore backup left, it's still better than nothing.
    for (const auto& backup : b.store.Backups().All()) {
        if (backup.kind == SessionBackups::Kind::Hourly) fs::remove(backup.file);
    }
    WriteText(b.store.File(), "{nope");
    loaded = b.store.Load();
    CHECK(std::holds_alternative<BrowserState>(loaded) && std::get<BrowserState>(loaded) == b.State(4));
}

// SessionBackupTests.eachKindKeepsItsOwnCopy
TEST(eachKindKeepsItsOwnCopy) {
    Backups b(2);
    b.BackUp(1, b.start);
    // The same bytes as the newest hourly backup still get a launch backup, and then a restore one.
    CHECK(b.BackUp(1, SessionBackups::Kind::Launch, b.start + 1));
    CHECK(!b.BackUp(1, SessionBackups::Kind::Launch, b.start + 2));
    CHECK(b.BackUp(1, SessionBackups::Kind::Restore, b.start + 3));
    auto all = b.store.Backups().All();
    CHECK(all.size() == 3 && all[0].kind == SessionBackups::Kind::Restore && all[1].kind == SessionBackups::Kind::Launch &&
          all[2].kind == SessionBackups::Kind::Hourly);
}

// SessionBackupTests.stampsRoundTripInUTC
TEST(stampsRoundTripInUTC) {
    const double date = 1'700'000'000.257;
    CHECK(SessionBackups::Stamp(date) == "2023-11-14-22-13-20-257");
    auto parsed = SessionBackups::DateFromStamp("2023-11-14-22-13-20-257");
    CHECK(parsed && std::abs(*parsed - date) < 0.0005);
    CHECK(SessionBackups::Stamp(0) == "1970-01-01-00-00-00-000");
    for (const char* junk : {"2023-11-14-22-13-20", "2023-13-14-22-13-20-000", "2023-11-14-22-13-20-0x0", "+023-11-14-22-13-20-000"}) {
        CHECK(!SessionBackups::DateFromStamp(junk));
    }
}

TEST(stampsKeepTheCalendarHonest) {
    // Leap days exist only in leap years; times before 1970 still have their milliseconds.
    CHECK(SessionBackups::DateFromStamp("2024-02-29-12-00-00-000"));
    CHECK(!SessionBackups::DateFromStamp("2023-02-29-12-00-00-000"));
    CHECK(!SessionBackups::DateFromStamp("1900-02-29-12-00-00-000"));
    CHECK(SessionBackups::DateFromStamp("2000-02-29-12-00-00-000"));
    CHECK(!SessionBackups::DateFromStamp("2023-11-14-24-00-00-000"));
    // Floored, so half a second before 1970 is 1969's last second. The Mac's stamp truncates
    // (quotientAndRemainder) and writes 1970-01-01-00-00-00-500 there: a known difference, for
    // a clock set before 1970 only.
    CHECK(SessionBackups::Stamp(-0.5) == "1969-12-31-23-59-59-500");
    CHECK(SessionBackups::DateFromStamp(SessionBackups::Stamp(951825600)) == 951825600.0);  // 2000-02-29
}

TEST(onlyBackupNamesCountAsBackups) {
    Backups b(2);
    for (const char* name : {"session.json", "session.2023-11-14-22-13-20-000.hourly.json", "session.2023-11-14-22-13-20-000.later.json",
                             "session.2023-11-14-22-13-20-000.launch.extra.json", "other.2023-11-14-22-13-20-000.json",
                             "session.2023-11-14-22-13-20-000.json.tmp"}) {
        b.Write("{}", name);
    }
    CHECK(b.store.Backups().All().empty());
    b.Write("{}", "session.2023-11-14-22-13-20-000.restore.json");
    CHECK(b.store.Backups().All().size() == 1);
}

// MARK: The background writer (BrowserStore.saveNow and its backup queue)

TEST(theWriterWritesTheSnapshotAndAnHourlyBackup) {
    Backups b(3);
    TestClock clock{b.start};
    SessionWriter writer(b.store, true, clock.Fn());
    writer.Save(b.State(1));
    CHECK(writer.Flush().empty());
    auto loaded = b.store.Load();
    CHECK(std::holds_alternative<BrowserState>(loaded) && std::get<BrowserState>(loaded) == b.State(1));
    auto stats = writer.Stats();
    CHECK(stats.written == 1 && stats.backups == 1 && !stats.pending && stats.lastBytes == ReadText(b.store.File()).size());
    auto all = b.store.Backups().All();
    CHECK(all.size() == 1 && all[0].kind == SessionBackups::Kind::Hourly && SessionBackups::State(all[0]) == b.State(1));
}

TEST(aWriteStillPendingAtQuitIsFlushed) {
    Backups b(3);
    {
        SessionWriter writer(b.store);
        writer.Save(b.State(1));
        // The window closes: its final save is handed over and the writer goes at once.
        writer.Save(b.State(2));
    }
    auto loaded = b.store.Load();
    CHECK(std::holds_alternative<BrowserState>(loaded) && std::get<BrowserState>(loaded) == b.State(2));
}

TEST(snapshotsHandedOverQuicklyCoalesceAndTheLastOneLands) {
    Backups b(1);
    SessionWriter writer(b.store);
    BrowserState state = b.State(0);
    for (int i = 0; i < 200; ++i) {
        state.OpenTab("https://kite.example/" + std::to_string(i));
        writer.Save(state);
    }
    CHECK(writer.Flush().empty());
    auto stats = writer.Stats();
    // Every snapshot is written, found unchanged or dropped for a newer one; the last one lands.
    CHECK(stats.handedOver == 200);
    CHECK(stats.written + stats.unchanged + stats.superseded == 200);
    CHECK(stats.written >= 1 && stats.written <= 200);
    auto loaded = b.store.Load();
    CHECK(std::holds_alternative<BrowserState>(loaded) && std::get<BrowserState>(loaded) == state);
}

TEST(anUnchangedSnapshotIsNotWrittenAgain) {
    Backups b(2);
    SessionWriter writer(b.store);
    writer.Save(b.State(1));
    writer.Flush();
    const auto written = fs::last_write_time(b.store.File());
    writer.Save(b.State(1));
    writer.Flush();
    auto stats = writer.Stats();
    CHECK(stats.written == 1 && stats.unchanged == 1);
    CHECK(fs::last_write_time(b.store.File()) == written);
}

TEST(aBackupIsRotatedAtMostOncePerHour) {
    Backups b(1);
    TestClock clock{b.start};
    SessionWriter writer(b.store, true, clock.Fn());
    BrowserState state = b.State(0);
    // A change a minute for 59 minutes: 59 writes, one hourly backup.
    for (int minute = 0; minute < 59; ++minute) {
        clock = b.start + minute * 60;
        state.OpenTab("https://kite.example/" + std::to_string(minute));
        writer.Save(state);
        writer.Flush();
    }
    CHECK(writer.Stats().written == 59);
    CHECK(b.store.Backups().All().size() == 1);
    // The hour after the first, the next save makes the second.
    clock = b.start + b.hour;
    state.OpenTab("https://kite.example/hour");
    writer.Save(state);
    writer.Flush();
    CHECK(b.store.Backups().All().size() == 2);
    // A new writer (a relaunch) reads the newest date from the folder, so it doesn't add one early.
    // A fresh store, as a relaunch has: nothing cached from this run.
    SessionWriter again(SessionStore(b.store.File()), true, [t = b.start + b.hour + 60] { return t; });
    state.OpenTab("https://kite.example/relaunch");
    again.Save(state);
    again.Flush();
    CHECK(b.store.Backups().All().size() == 2);
}

TEST(theLaunchBackupIsTheSessionAsFound) {
    Backups b(3);
    TestClock clock{b.start};
    SessionWriter writer(b.store, true, clock.Fn());
    writer.BackUpLaunch(b.State(1));
    writer.Save(b.State(2));
    writer.Flush();
    auto all = b.store.Backups().All();
    // The launch backup, and (the same second, so ordered by name) the hourly one of the change.
    CHECK(all.size() == 2);
    bool launchFound = false;
    for (const auto& backup : all) {
        if (backup.kind == SessionBackups::Kind::Launch) launchFound = SessionBackups::State(backup) == b.State(1);
    }
    CHECK(launchFound);
    // 40 launches keep the newest 30.
    for (int i = 0; i < 40; ++i) {
        clock = b.start + 10 + i;
        writer.BackUpLaunch(b.State(i % 2 + 1));
        writer.Flush();
    }
    size_t launches = 0;
    for (const auto& backup : b.store.Backups().All()) launches += backup.kind == SessionBackups::Kind::Launch;
    CHECK(launches == SessionBackups::kLaunchesKept);
}

TEST(aWriterThatMayNotSaveWritesNothing) {
    Backups b(2);
    WriteText(b.store.File(), "locked, say");
    {
        SessionWriter writer(b.store, false);
        writer.BackUpLaunch(b.State(1));
        writer.Save(b.State(1));
        CHECK(writer.Flush().empty());
        CHECK(writer.Stats().handedOver == 0);
    }
    CHECK(ReadText(b.store.File()) == "locked, say");
    CHECK(!fs::exists(b.store.Backups().Directory()));
}

TEST(aFailedWriteIsReportedAndTheNextOneRetries) {
    Backups b(3);
    SessionWriter writer(b.store);
    writer.Save(b.State(1));
    writer.Flush();
    const fs::path inTheWay = store_file::NextTempPath(b.store.File());
    fs::create_directories(inTheWay / "in-the-way");
    writer.Save(b.State(2));
    CHECK(!writer.Flush().empty());
    CHECK(std::get<BrowserState>(b.store.Load(SessionStore::Unreadable::Leave)) == b.State(1));
    fs::remove_all(inTheWay);
    // The same state again is written, not taken for the last write.
    writer.Save(b.State(2));
    CHECK(writer.Flush().empty());
    CHECK(std::get<BrowserState>(b.store.Load(SessionStore::Unreadable::Leave)) == b.State(2));
}

// BrowserStore.saveNow backs up after every save, an unchanged one included: a session that
// stopped changing inside the hour still gets its hourly backup on the next save after it.
TEST(anUnchangedSaveStillTakesTheHourlyBackup) {
    Backups b(3);
    TestClock clock{b.start};
    SessionWriter writer(b.store, true, clock.Fn());
    writer.Save(b.State(1));
    writer.Flush();
    clock = b.start + 60;
    writer.Save(b.State(2));  // written; too soon for a backup
    writer.Flush();
    CHECK(b.store.Backups().All().size() == 1);
    clock = b.start + b.hour + 1;
    writer.Save(b.State(2));  // unchanged: no write, but the backup is due
    writer.Flush();
    auto stats = writer.Stats();
    CHECK(stats.written == 2 && stats.unchanged == 1 && stats.backups == 2);
    auto all = b.store.Backups().All();
    CHECK(all.size() == 2 && !all.empty() && SessionBackups::State(all[0]) == b.State(2));
    // Bytes the newest backup already holds aren't offered again.
    clock = b.start + 3 * b.hour;
    writer.Save(b.State(2));
    writer.Flush();
    CHECK(b.store.Backups().All().size() == 2);
    auto same = b.store.Backups().BackUp(SessionStore::EncodeFile(b.State(2)), SessionBackups::Kind::Hourly, b.start + 3 * b.hour);
    CHECK(!same.made && same.sameAsNewest && same.error.empty());
}

TEST(anErrorThatNoLongerStandsIsNotReported) {
    Backups b(3);
    SessionWriter writer(b.store);
    writer.Save(b.State(1));
    writer.Flush();
    const fs::path inTheWay = store_file::NextTempPath(b.store.File());
    fs::create_directories(inTheWay / "in-the-way");
    writer.Save(b.State(2));
    CHECK(!writer.Flush().empty());
    fs::remove_all(inTheWay);
    // Back to what the file still holds: nothing to write, and the failed write no longer matters.
    writer.Save(b.State(1));
    CHECK(writer.Flush().empty());
    CHECK(std::get<BrowserState>(b.store.Load(SessionStore::Unreadable::Leave)) == b.State(1));
}

TEST(aFlushIsBounded) {
    Backups b(2);
    SessionWriter writer(b.store);
    // Nothing waiting: at once, whatever the bound.
    CHECK(writer.Flush(std::chrono::milliseconds(0)).empty());
    writer.Save(b.State(1));
    CHECK(writer.Flush(std::chrono::milliseconds(5000)).empty());
    CHECK(fs::exists(b.store.File()));
}

// Two writers of one file at once (a Kite quitting while the next one starts, two threads):
// each has its own temp, so every write goes through whole, and the file is one of them.
TEST(twoWritersOfOneFileNeverShareATemp) {
    fs::path dir = TempDir();
    const fs::path file = dir / "session.json";
    const std::string a(64 * 1024, 'a'), bytes(48 * 1024, 'b');
    std::atomic<int> failures{0};
    auto writeMany = [&](const std::string& text) {
        for (int i = 0; i < 100; ++i) {
            if (!store_file::WriteAtomically(file, text).empty()) ++failures;
        }
    };
    std::thread first(writeMany, std::cref(a)), second(writeMany, std::cref(bytes));
    first.join();
    second.join();
    CHECK(failures == 0);
    const std::string result = ReadText(file);
    CHECK(result == a || result == bytes);
    CHECK(CountNamed(dir, ".tmp") == 0);
    // And two session writers: whichever lands last, the file is a whole session.
    Backups b(3);
    {
        SessionWriter one(b.store), two(SessionStore(b.store.File()));
        // Each alternates, so every save is a write, and the two overlap.
        for (int i = 0; i < 20; ++i) {
            one.Save(b.State(1 + i % 2));
            two.Save(b.State(2 - i % 2));
            if (i % 5 == 4) {
                one.Flush();
                two.Flush();
            }
        }
        CHECK(one.Flush().empty() && two.Flush().empty());
    }
    auto loaded = b.store.Load(SessionStore::Unreadable::Leave);
    CHECK(std::holds_alternative<BrowserState>(loaded) &&
          (std::get<BrowserState>(loaded) == b.State(1) || std::get<BrowserState>(loaded) == b.State(2)));
    CHECK(CountNamed(b.dir, ".tmp") == 0);
    fs::remove_all(dir);
}

// The 15-minute auto-archive pass that archived nothing (the Mac's always mutates, so it saves
// and backs up): the hourly backup of what was last written, with nothing copied or written.
TEST(anOfferedBackupNeedsNoWrite) {
    Backups b(2);
    TestClock clock{b.start};
    SessionWriter writer(b.store, true, clock.Fn());
    // Nothing written yet this run: the caller saves instead.
    CHECK(!writer.OfferBackup());
    writer.Save(b.State(1));
    writer.Flush();
    CHECK(b.store.Backups().All().size() == 1);
    clock = b.start + 60;
    writer.Save(b.State(0));  // written, too soon for a backup
    writer.Flush();
    clock = b.start + b.hour + 60;
    CHECK(writer.OfferBackup());
    CHECK(writer.Flush().empty());
    auto stats = writer.Stats();
    CHECK(stats.written == 2 && stats.unchanged == 0 && stats.handedOver == 2 && stats.backups == 2);
    auto all = b.store.Backups().All();
    CHECK(all.size() == 2 && !all.empty() && SessionBackups::State(all[0]) == b.State(0));
    // A writer that mustn't save offers nothing.
    SessionWriter blocked(b.store, false);
    CHECK(!blocked.OfferBackup());
}

TEST(aWorkerStillWritingAtTheEndIsHandedToOnStuck) {
    // The backup's clock blocks the worker after session.json is written, as a hung disk would.
    Backups b(2);
    auto gate = std::make_shared<std::atomic<bool>>(false);
    auto stuck = std::make_shared<std::atomic<int>>(0);
    {
        SessionWriter writer(b.store, true, [gate] {
            while (!*gate) std::this_thread::sleep_for(std::chrono::milliseconds(1));
            return Backups::start;
        });
        writer.OnStuck([stuck] { ++*stuck; });
        writer.Save(b.State(1));
        CHECK(!writer.Flush(std::chrono::milliseconds(50)).empty());
        // The destructor doesn't wait again after the timed-out Flush: OnStuck runs at once.
    }
    CHECK(*stuck == 1);
    CHECK(std::get<BrowserState>(b.store.Load(SessionStore::Unreadable::Leave)) == b.State(1));
    // The worker let go finishes on its own, with its own reference to the shared state.
    *gate = true;
    for (int i = 0; i < 500 && b.store.Backups().All().empty(); ++i) std::this_thread::sleep_for(std::chrono::milliseconds(10));
    CHECK(b.store.Backups().All().size() == 1);
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
}

// A Flush that timed out just short of the write's end: once the worker has nothing left, the
// destructor joins it, and OnStuck (which ends the app's process) doesn't run.
TEST(aWriteThatFinishedAfterATimedOutFlushIsNotStuck) {
    Backups b(2);
    auto gate = std::make_shared<std::atomic<bool>>(false);
    auto stuck = std::make_shared<std::atomic<int>>(0);
    {
        SessionWriter writer(b.store, true, [gate] {
            while (!*gate) std::this_thread::sleep_for(std::chrono::milliseconds(1));
            return Backups::start;
        });
        writer.OnStuck([stuck] { ++*stuck; });
        writer.Save(b.State(1));
        CHECK(!writer.Flush(std::chrono::milliseconds(50)).empty());
        CHECK(writer.Writing());
        *gate = true;
        for (int i = 0; i < 500 && writer.Writing(); ++i) std::this_thread::sleep_for(std::chrono::milliseconds(10));
        CHECK(!writer.Writing());
    }
    CHECK(*stuck == 0);
    CHECK(b.store.Backups().All().size() == 1);
}
