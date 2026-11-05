// history-bench: what browsing history costs, measured on the app's own path (core/History.h,
// core/HistoryStore.h) with ENTRIES pages (default 20,000, the Mac's cap) in a temp folder of its
// own, never a profile. It prints JSON: a visit's and a title's cost on the UI thread, the
// snapshot a save hands over and the first visit after it, the prune at the cap (with the
// writer holding a snapshot, and once it has let go), the command bar's rows for what's typed,
// reading and writing the file on the worker, and the memory a history holds.
//
// Memory is counted two ways. This executable counts every allocation (its own operator new,
// which is why the bench isn't part of kitecore): the bytes asked for, and those bytes with the
// heap's usual cost per block (16 bytes, and a size rounded up to 16) for what the heap really
// takes. On Windows it also reports the process's private bytes before and after, which also
// hold the file's parse while it's read, so they're an upper bound.
//
//   history-bench [ENTRIES]

#include <algorithm>
#include <atomic>
#include <charconv>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <new>
#include <optional>
#include <string>
#include <vector>

#include "core/CommandBar.h"
#include "core/History.h"
#include "core/HistoryStore.h"
#include "core/Json.h"
#include "core/TextMatch.h"
#include "core/Uuid.h"

#ifdef _WIN32
#include <windows.h>
#include <psapi.h>
#endif

using namespace kite;

namespace {
std::atomic<long long> gLiveBytes{0};
std::atomic<long long> gLiveBlocks{0};
std::atomic<long long> gHeapBytes{0};  // with the heap's cost per block
constexpr size_t kAllocationHeader = 16;
long long HeapCost(size_t size) { return static_cast<long long>(kAllocationHeader + (size + 15) / 16 * 16); }
}  // namespace

void* operator new(std::size_t size) {
    void* block = std::malloc(size + kAllocationHeader);
    if (!block) throw std::bad_alloc();
    *static_cast<std::size_t*>(block) = size;
    gLiveBytes += static_cast<long long>(size);
    gHeapBytes += HeapCost(size);
    ++gLiveBlocks;
    return static_cast<char*>(block) + kAllocationHeader;
}

void operator delete(void* pointer) noexcept {
    if (!pointer) return;
    char* block = static_cast<char*>(pointer) - kAllocationHeader;
    const size_t size = *reinterpret_cast<std::size_t*>(block);
    gLiveBytes -= static_cast<long long>(size);
    gHeapBytes -= HeapCost(size);
    --gLiveBlocks;
    std::free(block);
}

void operator delete(void* pointer, std::size_t) noexcept { operator delete(pointer); }

namespace {

double PrivateBytes() {
#ifdef _WIN32
    PROCESS_MEMORY_COUNTERS_EX counters{};
    counters.cb = sizeof counters;
    if (GetProcessMemoryInfo(GetCurrentProcess(), reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&counters), sizeof counters)) {
        return static_cast<double>(counters.PrivateUsage);
    }
#endif
    return 0;
}

// Pages that look like a year of browsing: a few hundred sites, paths and titles of ordinary
// words, a fifth of the words not ASCII (accents, CJK, a dash), visit counts falling off.
struct BenchPages {
    uint64_t seed = 0x4B495445;  // 'KITE'
    uint64_t Next() {
        seed = seed * 6364136223846793005ull + 1442695040888963407ull;
        return seed >> 33;
    }
    std::string Word() {
        static constexpr const char* kWords[] = {
            "recipe", "kite",  "windows", "github", "issue",    "pull",  "review", "music", "piano", "chord",   "weather",
            "news",   "market", "board",  "design", "swift",    "chromium", "build", "release", "notes", "travel", "train",
            "map",    "rice",  "pasta",   "seafood", "beef",    "garden", "photo", "video", "docs",  "guide",   "how",
            "to",     "best",  "2026",    "index",  "home",     "about", "account", "orders", "cart", "search"};
        static constexpr const char* kUnicode[] = {"café", "über", "東京", "—", "naïve", "crème", "日本語", "Ñandú"};
        if (Next() % 10 < 2) return kUnicode[Next() % std::size(kUnicode)];
        return kWords[Next() % std::size(kWords)];
    }
    HistoryEntry Page(size_t i, Timestamp now) {
        const size_t site = Next() % 400;
        std::string url = "https://" + std::string(site % 3 ? "www." : "") + "site" + std::to_string(site) + ".example/";
        const size_t depth = 1 + Next() % 3;
        for (size_t d = 0; d < depth; ++d) {
            // Paths percent-encode, as Chromium's do: ASCII words only.
            std::string a = Word(), b = Word();
            if (!text_match::IsAscii(a)) a = "page";
            if (!text_match::IsAscii(b)) b = "item";
            url += (d ? "/" : "") + a + "-" + b;
        }
        url += "-" + std::to_string(i);
        if (Next() % 3 == 0) url += "?ref=" + Word() + "&id=" + std::to_string(Next() % 100000);
        if (!text_match::IsAscii(url)) url = "https://site" + std::to_string(site) + ".example/q-" + std::to_string(i);
        std::string title;
        const size_t words = 3 + Next() % 7;
        for (size_t w = 0; w < words; ++w) title += (w ? " " : "") + Word();
        if (title[0] >= 'a' && title[0] <= 'z') title[0] = static_cast<char>(title[0] - 32);
        if (Next() % 12 == 0) title.clear();
        const int64_t visits = 1 + static_cast<int64_t>(Next() % 100 < 70 ? 0 : Next() % 40);
        return {std::move(url), std::move(title), now - static_cast<double>(Next() % (365 * 86'400)), visits};
    }
};

struct Timings {
    std::vector<double> micros;
    void Add(double value) { micros.push_back(value); }
    json::Value Summary() {
        if (micros.empty()) return json::Value(nullptr);
        std::sort(micros.begin(), micros.end());
        const auto at = [&](double q) { return micros[std::min(micros.size() - 1, static_cast<size_t>(q * static_cast<double>(micros.size())))]; };
        return json::Value(json::Object{{"median", std::round(at(0.5) * 100) / 100},
                                        {"p99", std::round(at(0.99) * 100) / 100},
                                        {"max", std::round(micros.back() * 100) / 100},
                                        {"runs", static_cast<double>(micros.size())}});
    }
};

template <class F>
double MicrosOf(F&& f) {
    const auto start = std::chrono::steady_clock::now();
    f();
    return std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - start).count();
}

int Bench(size_t count) {
    std::error_code ignored;
    const std::filesystem::path folder = std::filesystem::temp_directory_path(ignored) / ("kite-history-bench-" + NewUuid());
    struct Cleanup {
        std::filesystem::path folder;
        ~Cleanup() {
            std::error_code ignored;
            std::filesystem::remove_all(folder, ignored);
        }
    } cleanup{folder};
    std::filesystem::create_directories(folder, ignored);
    const Timestamp now = Now();

    // The file, written as the Mac's JSONEncoder would (a file can hold more than kMaxEntries:
    // the store trims it to the cap as it reads it, on its worker).
    BenchPages pages;
    std::string text = R"({"version":1,"history":{"entries":{)";
    std::vector<std::string> urls;
    for (size_t i = 0; i < count; ++i) {
        HistoryEntry page = pages.Page(i, now);
        if (i) text += ',';
        json::AppendString(text, page.url);
        text += R"(:{"url":)";
        json::AppendString(text, page.url);
        text += R"(,"title":)";
        json::AppendString(text, page.title);
        text += R"(,"lastVisit":)" + json::Write(json::Value(page.lastVisit)) + R"(,"visitCount":)" + std::to_string(page.visitCount) + "}";
        urls.push_back(std::move(page.url));
    }
    text += "}}}";
    const HistoryFile file(folder / "history.json");
    if (std::string error = file.Write(text); !error.empty()) {
        std::fprintf(stderr, "history-bench: %s\n", error.c_str());
        return 4;
    }
    const size_t fileBytes = text.size();
    text.clear();
    text.shrink_to_fit();

    // Memory: what one History of these pages holds, once the file's text and parse are gone.
    const long long bytesBefore = gLiveBytes.load(), heapBefore = gHeapBytes.load(), blocksBefore = gLiveBlocks.load();
    const double privateBefore = PrivateBytes();
    std::optional<History> held;
    const double loadMicros = MicrosOf([&] {
        auto loaded = file.Load(HistoryFile::Unreadable::Leave);
        if (auto* history = std::get_if<History>(&loaded)) held = std::move(*history);
    });
    if (!held) {
        std::fputs("history-bench: the file didn't read\n", stderr);
        return 3;
    }
    const double privateAfter = PrivateBytes();
    const long long heldBytes = gLiveBytes.load() - bytesBefore, heapBytes = gHeapBytes.load() - heapBefore,
                    heldBlocks = gLiveBlocks.load() - blocksBefore;
    const double entries = static_cast<double>(held->Count());

    // The command bar's rows for what's typed: the whole computation (tabs, search, history), as
    // each keystroke runs it, over the default session's tabs.
    const BrowserState state = BrowserState::MakeDefault();
    json::Object searches;
    for (const char* query : {"r", "re", "rec", "recipe", "github", "site12", "café", "zzzz", "kite windows"}) {
        Timings timings;
        size_t rows = 0;
        for (int run = 0; run < 30; ++run) {
            timings.Add(MicrosOf([&] { rows = CommandBarSuggestions(query, state, CommandBarMode::NewTab, &*held, now).size(); }));
        }
        json::Value summary = timings.Summary();
        if (auto* o = summary.AsObject()) o->emplace("rows", static_cast<double>(rows));
        searches.emplace(query, std::move(summary));
    }

    // The prune at the cap. With the writer holding a snapshot, erasing the oldest tenth copies
    // every shard on the UI thread: measured here as that erase with a copy alive, though a visit
    // no longer does it (it waits for the writer to let go). Then the visit that pushes the
    // history over the cap with a snapshot held, and the next one, once it's let go.
    json::Object prune;
    {
        // Its own shards: a copy of `held` would share them, and a shared shard is a held snapshot.
        History atCap;
        atCap.Merge(held->Entries());
        std::vector<HistoryEntry> byAge = atCap.Entries();
        std::sort(byAge.begin(), byAge.end(), [](const HistoryEntry& a, const HistoryEntry& b) { return a.lastVisit < b.lastVisit; });
        std::vector<std::string> oldest;
        for (size_t i = 0; i < byAge.size() / 10; ++i) oldest.push_back(byAge[i].url);
        {
            // Each built on shards of its own (a copy of atCap would share atCap's).
            History alone, shared;
            alone.Merge(byAge);
            shared.Merge(byAge);
            const History snapshot = shared;
            prune.emplace("eraseWithSnapshotMicros", std::round(MicrosOf([&] { shared.Remove(oldest); })));
            prune.emplace("eraseUnsharedMicros", std::round(MicrosOf([&] { alone.Remove(oldest); })));
        }
        while (atCap.Count() < History::kMaxEntries) atCap.RecordVisit("https://fill.example/" + std::to_string(atCap.Count()), "", now);
        {
            const History snapshot = atCap;
            prune.emplace("overCapVisitWithSnapshotMicros",
                          std::round(MicrosOf([&] { atCap.RecordVisit("https://over.example/1", "", now); }) * 100) / 100);
            prune.emplace("countWhileHeld", static_cast<double>(atCap.Count()));
        }
        prune.emplace("nextVisitPrunesMicros", std::round(MicrosOf([&] { atCap.RecordVisit("https://over.example/2", "", now); })));
        prune.emplace("countAfter", static_cast<double>(atCap.Count()));
    }
    held.reset();

    // The app's store over that file: visits on the UI thread, the snapshot a save hands over,
    // and the worker's encode and write.
    double steady = 0;
    HistoryStores stores(folder, [&] { return steady; });
    stores.Start();
    HistoryStore& store = stores.ForProfile(BrowserState::kDefaultProfile);
    if (std::string error = stores.Flush(); !error.empty()) {
        std::fprintf(stderr, "history-bench: %s\n", error.c_str());
        return 3;
    }
    const double storeEntries = static_cast<double>(store.Get().Count());
    // Browsing: visits and titles with no save under way (the app saves 3 s after the last one,
    // and the writer has let its snapshot go long before the next).
    Timings repeatVisits, newVisits, titles, afterSave, snapshots;
    for (int i = 0; i < 2000; ++i) {
        steady += 0.5;
        const std::string& url = urls[pages.Next() % urls.size()];
        repeatVisits.Add(MicrosOf([&] { store.RecordVisit(url, "", now + i); }));
        const std::string title = "A page title, number " + std::to_string(i);
        titles.Add(MicrosOf([&] { store.UpdateTitle(url, title); }));
        const std::string fresh = "https://new" + std::to_string(i % 97) + ".example/page/" + std::to_string(i);
        newVisits.Add(MicrosOf([&] { store.RecordVisit(fresh, "", now + i); }));
    }
    // Saves: the snapshot handed over, then the first visit after it while the writer still holds
    // the snapshot, which unshares that visit's shard (about 80 pages).
    for (int i = 0; i < 50; ++i) {
        if (std::string error = stores.Flush(); !error.empty()) {
            std::fprintf(stderr, "history-bench: %s\n", error.c_str());
            return 4;
        }
        steady += 5;
        store.RecordVisit(urls[pages.Next() % urls.size()], "", now + i);
        snapshots.Add(MicrosOf([&] { stores.SaveNow(); }));
        const std::string& again = urls[pages.Next() % urls.size()];
        afterSave.Add(MicrosOf([&] { store.RecordVisit(again, "", now + i); }));
    }
    if (std::string error = stores.Flush(); !error.empty()) {
        std::fprintf(stderr, "history-bench: %s\n", error.c_str());
        return 4;
    }
    const HistoryStores::Statistics stats = stores.Stats();
    json::Object memory{{"requestedBytes", static_cast<double>(heldBytes)},
                        {"heapBytes", static_cast<double>(heapBytes)},
                        {"blocks", static_cast<double>(heldBlocks)},
                        {"heapBytesPerEntry", std::round(static_cast<double>(heapBytes) / std::max(1.0, entries))}};
    if (privateAfter > 0) memory.emplace("privateBytesDelta", privateAfter - privateBefore);
    std::puts(json::Write(json::Value(json::Object{
                              {"entries", entries},
                              {"storeEntries", storeEntries},
                              {"fileBytes", static_cast<double>(fileBytes)},
                              {"memory", json::Value(std::move(memory))},
                              {"loadMicros", std::round(loadMicros)},
                              {"commandBarMicros", json::Value(std::move(searches))},
                              {"prune", json::Value(std::move(prune))},
                              {"uiThread", json::Object{{"repeatVisitMicros", repeatVisits.Summary()},
                                                        {"newVisitMicros", newVisits.Summary()},
                                                        {"titleMicros", titles.Summary()},
                                                        {"snapshotMicros", snapshots.Summary()},
                                                        {"firstVisitAfterSaveMicros", afterSave.Summary()}}},
                              {"worker", json::Object{{"loadMicros", std::round(stats.lastLoadMicros)},
                                                      {"encodeMicros", std::round(stats.lastEncodeMicros)},
                                                      {"writeMicros", std::round(stats.lastWriteMicros)},
                                                      {"bytes", static_cast<double>(stats.lastBytes)},
                                                      {"writes", static_cast<double>(stats.writes)}}}}))
                  .c_str());
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    size_t entries = History::kMaxEntries;
    if (argc > 2) {
        std::fputs("usage: history-bench [ENTRIES]\n", stderr);
        return 1;
    }
    if (argc == 2) {
        const std::string_view text(argv[1]);
        auto [end, error] = std::from_chars(text.data(), text.data() + text.size(), entries);
        if (error != std::errc() || end != text.data() + text.size() || entries == 0 || entries > 1'000'000) {
            std::fputs("usage: history-bench [ENTRIES]\n", stderr);
            return 1;
        }
    }
    return Bench(entries);
}
