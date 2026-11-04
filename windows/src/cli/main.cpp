// kitecore: Kite for Windows' model, headless. It reads and changes a profile's session.json
// with the same code the app uses, so behaviour can be checked in milliseconds without a
// window (the behaviour gate in docs/helix.md). Output is JSON or a single line.
//
//   kitecore [--profile DIR] state
//   kitecore [--profile DIR] resolve TEXT...
//   kitecore [--profile DIR] suggest TEXT... [--current]
//   kitecore [--profile DIR] sidebar [SPACE_ID]
//   kitecore [--profile DIR] collapse SPACE_ID
//   kitecore [--profile DIR] open TEXT... [--space ID] [--background]
//   kitecore [--profile DIR] select TAB_ID
//   kitecore [--profile DIR] space next|prev|NUMBER|select ID|add NAME [ICON]
//   kitecore [--profile DIR] theme SPACE_ID [WIDTH HEIGHT]
//   kitecore [--profile DIR] backups
//   kitecore save-schedule KIND@SECONDS... [--at SECONDS]
//   kitecore save-bench [TABS]
//   kitecore [--profile DIR] history list|search TEXT... [--limit N]|add URL [TITLE...] [--at SECONDS]|clear [--chromium PROFILE]
//   kitecore history-bench [ENTRIES]
//   kitecore [--profile DIR] import-arc [PATH|--auto] [--include-unnamed|--leave-out-unnamed]
//   kitecore [--profile DIR] profile list|add NAME|rename DIRECTORY NAME|delete DIRECTORY
//
// --profile may come anywhere. DIR defaults to KITE_SUPPORT_PATH, then %LOCALAPPDATA%\Kite;
// an empty or missing DIR is an error, never the real profile. Use it on a profile Kite.exe
// isn't running on: both write session.json. `theme` prints the space's theme maths
// (lightness, foreground, glow, accent) and its window backdrop (material, and the corner and
// centre pixels at WIDTH×HEIGHT px, default 1280×820) as sRGB hex. `suggest` prints the command
// bar's rows for TEXT, top first (--current: editing the current tab's address, Ctrl+L).
// `sidebar` prints what the sidebar shows for a space (default the selected one): the address
// field's text and the space page's rows, top to bottom, with their place in points, then the
// space bar's cells (in the bar's points, for a 240pt sidebar, exact: the window snaps them to
// its pixels, under 1px from these at a fractional scale). `click` in the bar's 50pt along the
// bottom selects the space whose cell it hits.
// `collapse` is View → Collapse / Expand Pinned Tabs for a space.
// `backups` lists the profile's session backups (Backups/session.<stamp>[.kind].json), newest
// first as Restore Data orders them, with what each holds; it works when session.json doesn't
// read. `save-schedule` replays changes (soon@0 pageEvent@0.5 ...: a sidebar change or a page's
// title or favicon, at a time in seconds) through Kite's save timer and prints the saves it
// makes, and with --at what's still waiting then (the pending save's kind and when it's due).
// `save-bench` writes a session of TABS tabs (default 200) the way the app does, in a temp
// folder of its own (never a profile), and prints what it cost: the copy on the UI thread (μs),
// the encoding and the atomic write on the writer's thread, medians of 25 runs.
// `history` reads and changes a profile's browsing history (history.json, or with --chromium a
// Chromium profile folder's Kite History.json, as the Mac's HistoryStore keeps them): `list` is
// every page, last visited first; `search` the command bar's ranking (--limit, default 4); `add`
// records a visit (now, or --at Foundation seconds since 2001); `clear` forgets every page. Each
// prints JSON. `suggest` includes history's rows, from the selected space's profile, as the bar.
// `history-bench` measures history on the app's own path with ENTRIES pages (default 20000, the
// Mac's cap) in a temp folder of its own: a visit's cost on the UI thread, the snapshot a save
// hands over, the command bar's search, reading and writing the file, and the memory it takes.
// `import-arc` is Import from Arc (core/ArcImportController.h): from Arc for Windows' folder
// (--auto, the default), or PATH (Arc's folder, the folder holding it, or a sidebar file). It
// prints what came over, per kind, and what was skipped and why: counts only, never Arc's
// titles or addresses. Arc's unnamed spaces stay out, as the Mac's dialog starts, unless Arc
// has no named space (then they're all there is) or --include-unnamed; --leave-out-unnamed
// leaves them out either way. The session is saved first, then keybindings.json and
// LinkRouting.json; the summary prints once all of it is written. With --profile or
// KITE_SUPPORT_PATH, KITE_ARC_DATA_PATH stands in for Arc's folder, as in the Mac's test runs.
// `profile` lists, makes, renames and deletes Kite profiles (core/Profiles.h). A deleted one's
// folder name is free again once its Chromium folder is gone, which kitecore never deletes.

#include <algorithm>
#include <atomic>
#include <charconv>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <new>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "core/ArcImportController.h"
#include "core/CommandBar.h"
#include "core/History.h"
#include "core/HistoryStore.h"
#include "core/KeyBindings.h"
#include "core/LiveTabPolicy.h"
#include "core/OKLab.h"
#include "core/SessionSaveDelay.h"
#include "core/Profiles.h"
#include "core/SessionStore.h"
#include "core/SessionWriter.h"
#include "core/Sidebar.h"
#include "core/SpaceBar.h"
#include "core/SupportDirectory.h"
#include "core/TextMatch.h"
#include "core/ThemeBackdrop.h"
#include "core/URLInput.h"
#include "core/Unicode.h"
#include "core/Uuid.h"

#ifdef _WIN32
#include <windows.h>
#include <shellapi.h>
#endif

using namespace kite;

// Every allocation counted, so history-bench can say what history holds in memory. Each block
// carries its size in front; alignment stays malloc's (16 bytes).
namespace {
std::atomic<long long> gLiveBytes{0};
constexpr size_t kAllocationHeader = 16;
}  // namespace

void* operator new(std::size_t size) {
    void* block = std::malloc(size + kAllocationHeader);
    if (!block) throw std::bad_alloc();
    *static_cast<std::size_t*>(block) = size;
    gLiveBytes += static_cast<long long>(size);
    return static_cast<char*>(block) + kAllocationHeader;
}

void operator delete(void* pointer) noexcept {
    if (!pointer) return;
    char* block = static_cast<char*>(pointer) - kAllocationHeader;
    gLiveBytes -= static_cast<long long>(*reinterpret_cast<std::size_t*>(block));
    std::free(block);
}

void operator delete(void* pointer, std::size_t) noexcept { operator delete(pointer); }

namespace {

enum ExitCode : int { kOk = 0, kUsage = 1, kBadProfile = 2, kLoadFailed = 3, kSaveFailed = 4, kNotFound = 5 };

int Usage() {
    std::fputs(
        "usage: kitecore [--profile DIR] state\n"
        "       kitecore [--profile DIR] resolve TEXT...\n"
        "       kitecore [--profile DIR] suggest TEXT... [--current]\n"
        "       kitecore [--profile DIR] sidebar [SPACE_ID]\n"
        "       kitecore [--profile DIR] collapse SPACE_ID\n"
        "       kitecore [--profile DIR] click X Y [HEIGHT [SCROLL]]\n"
        "       kitecore [--profile DIR] open TEXT... [--space ID] [--background]\n"
        "       kitecore [--profile DIR] select TAB_ID\n"
        "       kitecore [--profile DIR] tab next|prev|NUMBER\n"
        "       kitecore [--profile DIR] shortcuts\n"
        "       kitecore [--profile DIR] close TAB_ID\n"
        "       kitecore [--profile DIR] reopen [TAB_ID]\n"
        "       kitecore [--profile DIR] archive-stale [NOW]\n"
        "       kitecore [--profile DIR] evict MAX [--shown TAB_ID] [--popup POPUP_ID=OPENER_ID]... TAB_ID=LAST_SHOWN...\n"
        "       kitecore [--profile DIR] space next|prev|NUMBER|select ID|add NAME [ICON]\n"
        "       kitecore [--profile DIR] theme SPACE_ID [WIDTH HEIGHT]\n"
        "       kitecore [--profile DIR] backups\n"
        "       kitecore save-schedule KIND@SECONDS... [--at SECONDS]\n"
        "       kitecore save-bench [TABS]\n"
        "       kitecore [--profile DIR] history list|search TEXT... [--limit N]|add URL [TITLE...] [--at SECONDS]|clear\n"
        "                [--chromium PROFILE]\n"
        "       kitecore history-bench [ENTRIES]\n"
        "       kitecore [--profile DIR] import-arc [PATH|--auto] [--include-unnamed|--leave-out-unnamed]\n"
        "       kitecore [--profile DIR] profile list|add NAME|rename DIRECTORY NAME|delete DIRECTORY\n",
        stderr);
    return kUsage;
}

std::string Join(const std::vector<std::string>& words, size_t from) {
    std::string out;
    for (size_t i = from; i < words.size(); ++i) {
        if (i > from) out += ' ';
        out += words[i];
    }
    return out;
}

json::Value TabSummary(const Tab& tab) {
    json::Object o{{"id", tab.id}, {"title", tab.DisplayTitle()}};
    if (tab.url) o.emplace("url", *tab.url);
    return json::Value(std::move(o));
}

json::Value Summary(const BrowserState& state) {
    json::Array spaces;
    for (const auto& space : state.spaces) {
        json::Array pinned, tabs;
        for (const Tab* tab : space.Pinned()) pinned.push_back(TabSummary(*tab));
        for (const auto& tab : space.tabs) tabs.push_back(TabSummary(tab));
        json::Object o{{"id", space.id}, {"name", space.name}, {"icon", space.icon},
                       {"pinned", json::Value(std::move(pinned))}, {"tabs", json::Value(std::move(tabs))}};
        if (space.selectedTabID) o.emplace("selectedTabID", *space.selectedTabID);
        spaces.push_back(json::Value(std::move(o)));
    }
    json::Array favorites;
    for (const auto& tab : state.Favorites()) favorites.push_back(TabSummary(tab));
    json::Object root{{"selectedSpaceID", state.selectedSpaceID}, {"searchEngine", state.searchEngine},
                      {"favorites", json::Value(std::move(favorites))}, {"spaces", json::Value(std::move(spaces))}};
    if (const Tab* tab = state.SelectedTab()) root.emplace("selectedTab", TabSummary(*tab));
    // Newest first, as Ctrl+Shift+T and the archive page list them.
    json::Array recent, archived;
    for (auto it = state.recentlyClosed.rbegin(); it != state.recentlyClosed.rend(); ++it) recent.push_back(TabSummary(it->tab));
    for (auto it = state.archived.rbegin(); it != state.archived.rend(); ++it) archived.push_back(TabSummary(it->tab));
    root.emplace("recentlyClosed", json::Value(std::move(recent)));
    root.emplace("archived", json::Value(std::move(archived)));
    root.emplace("archiveAfter", state.archiveAfter);
    return json::Value(std::move(root));
}

// The arguments as UTF-8. On Windows they come from the UTF-16 command line, so a name like
// "Café" survives whatever the code page is.
std::vector<std::string> Arguments(int argc, char** argv) {
#ifdef _WIN32
    (void)argc;
    (void)argv;
    std::vector<std::string> out;
    int count = 0;
    LPWSTR* wide = CommandLineToArgvW(GetCommandLineW(), &count);
    for (int i = 1; wide && i < count; ++i) {
        int size = WideCharToMultiByte(CP_UTF8, 0, wide[i], -1, nullptr, 0, nullptr, nullptr);
        std::string arg(static_cast<size_t>(size > 0 ? size - 1 : 0), '\0');
        if (size > 1) WideCharToMultiByte(CP_UTF8, 0, wide[i], -1, arg.data(), size, nullptr, nullptr);
        out.push_back(std::move(arg));
    }
    if (wide) LocalFree(wide);
    return out;
#else
    return std::vector<std::string>(argv + 1, argv + argc);
#endif
}

std::string Hex(const ThemeColor& c) {
    auto byte = [](float v) { return static_cast<unsigned>(std::lround(std::clamp(v, 0.f, 1.f) * 255.f)); };
    char buffer[8];
    std::snprintf(buffer, sizeof(buffer), "#%02X%02X%02X", byte(c.r), byte(c.g), byte(c.b));
    return buffer;
}

std::string Hex(const Rgba& c) { return Hex(ThemeColor{c.r, c.g, c.b}); }

json::Value ThemeSummary(const Theme& theme, int width, int height) {
    // The window's backdrop at width × height px: the theme, stored at 8 bits a channel as the
    // swap chain does, over the solid material colour, as Kite.exe --capture draws it (CI
    // compares the two).
    const Rgba material = MaterialFallback(!PrefersDarkForeground(theme));
    const float w = static_cast<float>(width), h = static_cast<float>(height);
    const ThemeUniforms uniforms = MakeThemeUniforms(theme, w, h);
    auto at = [&](float x, float y) { return json::Value(Hex(Over(Quantize8(ShadeThemePixel(uniforms, x + 0.5f, y + 0.5f)), material))); };
    json::Object backdrop{{"size", json::Value(json::Array{json::Value(w), json::Value(h)})},
                          {"material", json::Value(Hex(material))},
                          {"topLeft", at(0, 0)},
                          {"topRight", at(w - 1, 0)},
                          {"bottomLeft", at(0, h - 1)},
                          {"bottomRight", at(w - 1, h - 1)},
                          {"centre", at(static_cast<float>(width / 2), static_cast<float>(height / 2))}};
    json::Array colors;
    for (const auto& c : theme.colors) colors.push_back(json::Value(Hex(c)));
    auto [glowA, glowB] = GlowColors(theme);
    return json::Value(json::Object{{"colors", json::Value(std::move(colors))},
                                    {"lightness", json::Value(static_cast<double>(Lightness(theme)))},
                                    {"prefersDarkForeground", json::Value(PrefersDarkForeground(theme))},
                                    {"glow", json::Value(json::Array{json::Value(Hex(glowA)), json::Value(Hex(glowB))})},
                                    {"accent", json::Value(Hex(Accent(theme)))},
                                    {"backdrop", json::Value(std::move(backdrop))}});
}

// What an icon shows: "dot", "emoji", "symbol" (with its Segoe Fluent and MDL2 glyphs as hex,
// or "drawn" for one Kite draws as its own shape) or "picture". A header draws no dot: it has no
// icon slot for an icon-less space ("none"), and a blank one for a symbol with no stand-in
// ("blank").
enum class LookIn { Bar, Header };
void AddLook(json::Object& o, const SpaceIconLook& look, LookIn in = LookIn::Bar, bool headerSlot = false) {
    static constexpr const char* kShows[] = {"dot", "emoji", "symbol", "picture"};
    const char* shows = kShows[static_cast<int>(look.kind)];
    if (in == LookIn::Header && look.kind == SpaceIconLook::Kind::Dot) shows = headerSlot ? "blank" : "none";
    o.emplace("shows", std::string(shows));
    if (look.glyph && look.glyph->drawn) {
        o.emplace("glyph", json::Object{{"drawn", true}});
    } else if (look.glyph) {
        char fluent[8], mdl2[8];
        std::snprintf(fluent, sizeof fluent, "%04X", static_cast<unsigned>(look.glyph->fluent));
        std::snprintf(mdl2, sizeof mdl2, "%04X", static_cast<unsigned>(look.glyph->mdl2));
        o.emplace("glyph", json::Object{{"fluent", std::string(fluent)}, {"mdl2", std::string(mdl2)}});
    }
    if (look.kind == SpaceIconLook::Kind::Symbol) o.emplace("accent", Hex(look.accent));
}

// Ids typed in either case, like UUID(uuidString:).
std::string Id(const std::string& text) { return NormalizeUuid(text).value_or(text); }

std::optional<double> ParseSeconds(const std::string& text) {
    double value = 0;
    auto [end, error] = std::from_chars(text.data(), text.data() + text.size(), value);
    if (error != std::errc() || end != text.data() + text.size() || !std::isfinite(value)) return std::nullopt;
    return value;
}

std::string PathUtf8(const std::filesystem::path& path) {
    auto u8 = path.u8string();
    return std::string(u8.begin(), u8.end());
}

json::Value BackupsSummary(const SessionBackups& backups) {
    json::Array rows;
    for (const auto& backup : backups.Ordered(SessionBackups::Now())) {
        const auto summary = SessionBackups::SummaryOf(backup);
        json::Object o{{"file", PathUtf8(backup.file.filename())},
                       {"kind", std::string(SessionBackups::RawValue(backup.kind))},
                       {"stamp", SessionBackups::Stamp(backup.date)},
                       {"date", backup.date},
                       {"restorable", summary.IsRestorable()}};
        if (summary.spaceCount) o.emplace("spaces", static_cast<double>(*summary.spaceCount));
        if (summary.tabCount) o.emplace("tabs", static_cast<double>(*summary.tabCount));
        rows.push_back(json::Value(std::move(o)));
    }
    return json::Value(json::Object{{"directory", PathUtf8(backups.Directory())}, {"backups", json::Value(std::move(rows))}});
}

// The changes `save-schedule` replays: KIND@SECONDS, in time order.
int SaveScheduleCommand(const std::vector<std::string>& args) {
    std::vector<SaveChange> changes;
    std::optional<double> until;
    for (size_t i = 1; i < args.size(); ++i) {
        if (args[i] == "--at" && i + 1 < args.size()) {
            if (!(until = ParseSeconds(args[++i]))) return Usage();
            continue;
        }
        const size_t at = args[i].find('@');
        if (at == std::string::npos) return Usage();
        auto delay = SessionSaveDelayFromRaw(args[i].substr(0, at));
        auto seconds = ParseSeconds(args[i].substr(at + 1));
        if (!delay || !seconds || (!changes.empty() && *seconds < changes.back().at)) return Usage();
        changes.push_back({*seconds, *delay});
    }
    const SaveReplay replay = ReplaySaves(changes, until);
    json::Array saves;
    for (const ReplayedSave& save : replay.saves) {
        saves.push_back(json::Object{{"at", save.at}, {"kind", std::string(RawValue(save.kind))}});
    }
    json::Object out{{"saves", json::Value(std::move(saves))}};
    if (until) {
        out.emplace("pending", replay.pending ? json::Value(std::string(RawValue(*replay.pending))) : json::Value(nullptr));
        out.emplace("dueAt", replay.dueAt ? json::Value(*replay.dueAt) : json::Value(nullptr));
    }
    std::puts(json::Write(json::Value(std::move(out))).c_str());
    return kOk;
}

// What saving a session of `tabs` tabs costs, measured on the app's own path, in a temp folder.
int SaveBenchCommand(int tabs) {
    std::error_code ignored;
    const std::filesystem::path folder = std::filesystem::temp_directory_path(ignored) / ("kite-save-bench-" + NewUuid());
    struct Cleanup {
        std::filesystem::path folder;
        ~Cleanup() {
            std::error_code ignored;
            std::filesystem::remove_all(folder, ignored);
        }
    } cleanup{folder};
    const SessionStore store(folder / "session.json");
    BrowserState state = BrowserState::MakeDefault(std::nullopt);
    for (int i = 0; i < tabs; ++i) {
        const std::string n = std::to_string(i);
        const std::string id = state.OpenTab("https://example.com/articles/" + n + "?ref=kite-bench", std::nullopt, true, Now());
        if (auto at = state.Location(id)) {
            Tab* tab = state.TabAt(*at);
            tab->title = "A page with a usual title, number " + n + " — Example";
            tab->faviconURL = "https://example.com/favicon.ico";
        }
    }
    constexpr int kRuns = 25;
    auto median = [](std::vector<double> values) {
        std::sort(values.begin(), values.end());
        return values[values.size() / 2];
    };
    std::vector<double> copies, encodes, writes;
    size_t bytes = 0;
    // Backups dated in 1970, so each run's hourly check is one in-memory comparison, as in the app.
    SessionWriter writer(store, true, [] { return 0.0; });
    for (int run = 0; run < kRuns; ++run) {
        // A change between runs, so each one is written (an unchanged one is skipped).
        state.spaces[0].tabs[0].title = "run " + std::to_string(run);
        const auto start = std::chrono::steady_clock::now();
        writer.Save(state);  // the UI thread's whole part: the copy handed over
        copies.push_back(std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - start).count());
        if (std::string error = writer.Flush(); !error.empty()) {
            std::fprintf(stderr, "kitecore: %s\n", error.c_str());
            return kSaveFailed;
        }
        const auto stats = writer.Stats();
        encodes.push_back(stats.lastEncodeMicros);
        writes.push_back(stats.lastWriteMicros);
        bytes = stats.lastBytes;
    }
    std::puts(json::Write(json::Value(json::Object{{"tabs", static_cast<double>(tabs)},
                                                   {"bytes", static_cast<double>(bytes)},
                                                   {"runs", static_cast<double>(kRuns)},
                                                   {"uiThreadCopyMicros", median(copies)},
                                                   {"uiThreadCopyMaxMicros", *std::max_element(copies.begin(), copies.end())},
                                                   {"encodeMicros", median(encodes)},
                                                   {"writeMicros", median(writes)}}))
                  .c_str());
    return kOk;
}

// MARK: History

json::Value EntrySummary(const HistoryEntry& entry) {
    return json::Value(json::Object{{"url", entry.url},
                                    {"title", entry.title},
                                    {"displayTitle", entry.DisplayTitle()},
                                    {"lastVisit", entry.lastVisit},
                                    {"visitCount", entry.visitCount}});
}

json::Value EntriesSummary(const std::vector<HistoryEntry>& entries) {
    json::Array rows;
    for (const HistoryEntry& entry : entries) rows.push_back(EntrySummary(entry));
    return json::Value(std::move(rows));
}

std::optional<size_t> ParseCount(const std::string& text) {
    size_t value = 0;
    auto [end, error] = std::from_chars(text.data(), text.data() + text.size(), value);
    if (error != std::errc() || end != text.data() + text.size()) return std::nullopt;
    return value;
}

// kitecore history ...: on the file itself, read and written at once (the app's are on its
// writer thread). An unreadable file is reported and left as it is, never written over.
int HistoryCommand(std::vector<std::string> args, const std::filesystem::path& support) {
    std::string chromium = BrowserState::kDefaultProfile;
    std::optional<size_t> limit;
    std::optional<double> at;
    for (size_t i = 1; i < args.size(); ++i) {
        const bool hasValue = i + 1 < args.size();
        if (args[i] == "--chromium" && hasValue) {
            chromium = args[i + 1];
        } else if (args[i] == "--limit" && hasValue) {
            if (!(limit = ParseCount(args[i + 1]))) return Usage();
        } else if (args[i] == "--at" && hasValue) {
            if (!(at = ParseSeconds(args[i + 1]))) return Usage();
        } else {
            continue;
        }
        args.erase(args.begin() + static_cast<std::ptrdiff_t>(i), args.begin() + static_cast<std::ptrdiff_t>(i) + 2);
        --i;
    }
    // A profile folder's name, never a path out of the support folder.
    if (args.size() < 2 || chromium.empty() || chromium.find_first_of("/\\:") != std::string::npos || chromium == "." || chromium == "..") {
        return Usage();
    }
    const std::string& action = args[1];
    const HistoryFile file(HistoryStores::FileFor(support, chromium));
    auto loaded = file.Load(HistoryFile::Unreadable::Leave);
    if (auto* error = std::get_if<HistoryFile::Error>(&loaded)) {
        std::fprintf(stderr, "kitecore: unreadable history: %s\n", error->message.c_str());
        return kLoadFailed;
    }
    History history;
    if (auto* found = std::get_if<History>(&loaded)) history = std::move(*found);
    const auto save = [&] {
        if (std::string error = file.Save(history); !error.empty()) {
            std::fprintf(stderr, "kitecore: %s\n", error.c_str());
            return static_cast<int>(kSaveFailed);
        }
        return static_cast<int>(kOk);
    };
    if (action == "list" && args.size() == 2) {
        std::vector<HistoryEntry> entries = history.Entries();
        std::stable_sort(entries.begin(), entries.end(), [](const HistoryEntry& a, const HistoryEntry& b) { return a.lastVisit > b.lastVisit; });
        if (limit && entries.size() > *limit) entries.resize(*limit);
        std::puts(json::Write(EntriesSummary(entries)).c_str());
        return kOk;
    }
    if (action == "search" && args.size() >= 3) {
        std::puts(json::Write(EntriesSummary(history.Search(Join(args, 2), limit.value_or(4)))).c_str());
        return kOk;
    }
    if (action == "add" && args.size() >= 3) {
        const std::string& url = args[2];
        if (!History::Records(url)) {
            std::fprintf(stderr, "kitecore: history keeps web pages only (http and https): %s\n", url.c_str());
            return kNotFound;
        }
        history.RecordVisit(url, Join(args, 3), at.value_or(Now()));
        if (int code = save(); code != kOk) return code;
        std::puts(json::Write(EntrySummary(*history.Find(url))).c_str());
        return kOk;
    }
    if (action == "clear" && args.size() == 2) {
        history.RemoveAll();
        return save();
    }
    return Usage();
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
            "recipe", "kite",     "windows", "github",  "issue", "pull",  "review", "music",   "piano",  "chord", "weather",
            "news",   "market",   "board",   "design",  "swift", "chromium", "build", "release", "notes", "travel", "train",
            "map",    "rice",     "pasta",   "seafood", "beef",  "garden", "photo",  "video",   "docs",   "guide", "how",
            "to",     "best",     "2026",    "index",   "home",  "about",  "account", "orders", "cart",   "search"};
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

int HistoryBenchCommand(size_t count) {
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

    // The file, written as the Mac's JSONEncoder would. Reading has no cap: a file can hold more
    // than kMaxEntries, which only recording and importing prune.
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
        std::fprintf(stderr, "kitecore: %s\n", error.c_str());
        return kSaveFailed;
    }
    const size_t fileBytes = text.size();
    text.clear();
    text.shrink_to_fit();

    // Memory: what one History of these pages holds, once the file's text and parse are gone.
    const long long before = gLiveBytes.load();
    std::optional<History> held;
    const double loadMicros = MicrosOf([&] {
        auto loaded = file.Load(HistoryFile::Unreadable::Leave);
        if (auto* history = std::get_if<History>(&loaded)) held = std::move(*history);
    });
    if (!held) {
        std::fputs("kitecore: the bench's file didn't read\n", stderr);
        return kLoadFailed;
    }
    const long long heldBytes = gLiveBytes.load() - before;

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
    held.reset();

    // The app's store over that file: visits on the UI thread, the snapshot a save hands over,
    // and the worker's encode and write.
    double steady = 0;
    HistoryStores stores(folder, [&] { return steady; });
    HistoryStore& store = stores.ForProfile(BrowserState::kDefaultProfile);
    if (std::string error = stores.Flush(); !error.empty()) {
        std::fprintf(stderr, "kitecore: %s\n", error.c_str());
        return kLoadFailed;
    }
    const double entries = static_cast<double>(store.Get().Count());
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
            std::fprintf(stderr, "kitecore: %s\n", error.c_str());
            return kSaveFailed;
        }
        steady += 5;
        store.RecordVisit(urls[pages.Next() % urls.size()], "", now + i);
        snapshots.Add(MicrosOf([&] { stores.SaveNow(); }));
        const std::string& again = urls[pages.Next() % urls.size()];
        afterSave.Add(MicrosOf([&] { store.RecordVisit(again, "", now + i); }));
    }
    if (std::string error = stores.Flush(); !error.empty()) {
        std::fprintf(stderr, "kitecore: %s\n", error.c_str());
        return kSaveFailed;
    }
    const HistoryStores::Statistics stats = stores.Stats();
    std::puts(json::Write(json::Value(json::Object{
                              {"entries", entries},
                              {"fileBytes", static_cast<double>(fileBytes)},
                              {"memoryBytes", static_cast<double>(heldBytes)},
                              {"memoryBytesPerEntry", std::round(static_cast<double>(heldBytes) / std::max(1.0, entries))},
                              {"loadMicros", std::round(loadMicros)},
                              {"commandBarMicros", json::Value(std::move(searches))},
                              {"uiThread", json::Object{{"repeatVisitMicros", repeatVisits.Summary()},
                                                        {"newVisitMicros", newVisits.Summary()},
                                                        {"titleMicros", titles.Summary()},
                                                        {"snapshotMicros", snapshots.Summary()},
                                                        {"firstVisitAfterSaveMicros", afterSave.Summary()}}},
                              {"worker", json::Object{{"encodeMicros", std::round(stats.lastEncodeMicros)},
                                                      {"writeMicros", std::round(stats.lastWriteMicros)},
                                                      {"bytes", static_cast<double>(stats.lastBytes)},
                                                      {"writes", static_cast<double>(stats.writes)}}}}))
                  .c_str());
    return kOk;
}

}  // namespace

int main(int argc, char** argv) {
#ifdef _WIN32
    // Arguments come in as UTF-16 (CommandLineToArgvW) and are converted to UTF-8; output is
    // UTF-8 too, which the console shows only once its output code page says so.
    // The console's code page is shared with the shell that started us, so put it back.
    struct ConsoleCodePage {
        UINT previous = GetConsoleOutputCP();
        ConsoleCodePage() { if (previous) SetConsoleOutputCP(CP_UTF8); }
        ~ConsoleCodePage() { if (previous) SetConsoleOutputCP(previous); }
    } consoleCodePage;
#endif
    std::vector<std::string> args = Arguments(argc, argv);
    // --profile DIR anywhere on the line, so "open x --profile DIR" never writes to the real
    // profile with "--profile DIR" as part of a search.
    std::optional<std::filesystem::path> profile;
    for (size_t i = 0; i < args.size(); ++i) {
        if (args[i] != "--profile") continue;
        if (i + 1 >= args.size() || profile) return Usage();
        profile = std::filesystem::path(std::u8string(args[i + 1].begin(), args[i + 1].end()));
        args.erase(args.begin() + static_cast<std::ptrdiff_t>(i), args.begin() + static_cast<std::ptrdiff_t>(i) + 2);
        --i;
    }
    if (args.empty()) return Usage();
    // The save timer's rules alone: no profile involved.
    if (args[0] == "save-schedule") return SaveScheduleCommand(args);
    if (args[0] == "save-bench" && args.size() <= 2) {
        if (profile) return Usage();  // it never touches a profile
        int tabs = 200;
        if (args.size() == 2) {
            auto [end, error] = std::from_chars(args[1].data(), args[1].data() + args[1].size(), tabs);
            if (error != std::errc() || end != args[1].data() + args[1].size() || tabs < 0 || tabs > 100000) return Usage();
        }
        return SaveBenchCommand(tabs);
    }

    if (args[0] == "history-bench" && args.size() <= 2) {
        if (profile) return Usage();  // it never touches a profile
        size_t entries = History::kMaxEntries;
        if (args.size() == 2) {
            auto parsed = ParseCount(args[1]);
            if (!parsed || *parsed == 0 || *parsed > 1'000'000) return Usage();
            entries = *parsed;
        }
        return HistoryBenchCommand(entries);
    }

    auto resolved = ResolveSupportDirectory(profile ? profile : EnvironmentPath("KITE_SUPPORT_PATH"), EnvironmentPath("LOCALAPPDATA"));
    if (auto* error = std::get_if<SupportDirectoryError>(&resolved)) {
        std::fprintf(stderr, "kitecore: %s\n", error->message.c_str());
        return kBadProfile;
    }
    SessionStore store(std::get<std::filesystem::path>(resolved) / "session.json");

    // History is its own file: the session isn't read.
    if (args[0] == "history") return HistoryCommand(args, std::get<std::filesystem::path>(resolved));

    // These don't read the session: backups are there for when it can't be read.
    if (args[0] == "backups" && args.size() == 1) {
        std::puts(json::Write(BackupsSummary(store.Backups())).c_str());
        return kOk;
    }

    BrowserState state;
    // kitecore never moves the user's session aside: an unreadable one is reported and left.
    auto loaded = store.Load(SessionStore::Unreadable::Leave);
    if (auto* error = std::get_if<SessionStore::Error>(&loaded)) {
        std::fprintf(stderr, "kitecore: unreadable session: %s\n", error->message.c_str());
        return kLoadFailed;
    }
    const bool existed = std::holds_alternative<BrowserState>(loaded);
    state = existed ? std::move(std::get<BrowserState>(loaded)) : BrowserState::MakeDefault();

    const std::string& command = args[0];
    const SearchEngine engine = SearchEngineFromRaw(state.searchEngine).value_or(SearchEngine::Google);
    bool changed = false;

    if (command == "state") {
        std::puts(json::Write(Summary(state)).c_str());
        return kOk;
    } else if (command == "shortcuts" && args.size() == 1) {
        // What each key runs in Kite for Windows, after the profile's keybindings.json: the
        // shortcut as Windows shows it, its command and who gets it first in a page.
        KeyBindings bindings;
        std::ifstream in(std::get<std::filesystem::path>(resolved) / "keybindings.json", std::ios::binary);
        if (in) {
            const std::string text{std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
            auto read = KeyBindings::FromText(text);
            if (!read) {
                std::fputs("kitecore: unreadable keybindings.json (Kite uses the defaults)\n", stderr);
                return kLoadFailed;
            }
            bindings = *read;
        }
        json::Array rows;
        for (const auto& [shortcut, target] : ShortcutTable(bindings)) {
            rows.push_back(json::Object{{"shortcut", shortcut.DisplayString()},
                                        {"command", target.command->id},
                                        {"priority", std::string(RawValue(target.priority))}});
        }
        std::puts(json::Write(json::Value(std::move(rows))).c_str());
        return kOk;
    } else if (command == "theme" && (args.size() == 2 || args.size() == 4)) {
        auto space = state.SpaceIndex(Id(args[1]));
        if (!space) return kNotFound;
        int width = 1280, height = 820;
        if (args.size() == 4) {
            auto parse = [](const std::string& text, int& out) {
                auto [end, error] = std::from_chars(text.data(), text.data() + text.size(), out);
                return error == std::errc() && end == text.data() + text.size() && out > 0 && out <= 16384;
            };
            if (!parse(args[2], width) || !parse(args[3], height)) return Usage();
        }
        std::puts(json::Write(ThemeSummary(state.spaces[*space].theme, width, height)).c_str());
        return kOk;
    } else if (command == "resolve") {
        auto url = url_input::Resolve(Join(args, 1), engine);
        if (!url) return kNotFound;
        std::puts(url->c_str());
        return kOk;
    } else if (command == "suggest") {
        CommandBarMode mode = CommandBarMode::NewTab;
        std::vector<std::string> words;
        for (size_t i = 1; i < args.size(); ++i) {
            if (args[i] == "--current") mode = CommandBarMode::EditCurrent;
            else words.push_back(args[i]);
        }
        // The current space's profile's history, as the bar searches it. One that doesn't read
        // shows no rows, as in the app.
        const HistoryFile historyFile(HistoryStores::FileFor(std::get<std::filesystem::path>(resolved), state.SelectedProfileDirectory()));
        auto history = historyFile.Load(HistoryFile::Unreadable::Leave);
        if (auto* error = std::get_if<HistoryFile::Error>(&history)) {
            std::fprintf(stderr, "kitecore: unreadable history, left out: %s\n", error->message.c_str());
        }
        const History* visited = std::get_if<History>(&history);
        json::Array rows;
        for (const CommandSuggestion& row : CommandBarSuggestions(Join(words, 0), state, mode, visited)) {
            const char* kind = row.kind == CommandSuggestion::Kind::Open        ? "open"
                               : row.kind == CommandSuggestion::Kind::Search    ? "search"
                               : row.kind == CommandSuggestion::Kind::SwitchTab ? "switchTab"
                                                                                : "history";
            json::Object o{{"kind", std::string(kind)}, {"url", row.url}, {"title", row.title}, {"detail", row.detail}};
            if (!row.tabID.empty()) o.emplace("tabID", row.tabID);
            if (row.faviconURL) o.emplace("faviconURL", *row.faviconURL);
            if (!row.subtitle.empty()) o.emplace("subtitle", row.subtitle);
            rows.emplace_back(std::move(o));
        }
        std::puts(json::Write(json::Value(std::move(rows))).c_str());
        return kOk;
    } else if (command == "sidebar" && args.size() <= 2) {
        const auto space = args.size() == 2 ? state.SpaceIndex(Id(args[1])) : std::optional<size_t>(state.SelectedSpaceIndex());
        if (!space) return kNotFound;
        json::Array rows;
        for (const SidebarRow& row : SidebarRows(state, *space)) {
            static constexpr const char* kKinds[] = {"header", "tab", "folder", "divider", "newTab"};
            json::Object o{{"kind", std::string(kKinds[static_cast<int>(row.kind)])}, {"id", row.id}, {"top", static_cast<double>(row.top)},
                           {"height", static_cast<double>(row.height)}};
            switch (row.kind) {
            case SidebarRow::Kind::Header:
                o.emplace("title", row.title);
                o.emplace("icon", row.icon);
                AddLook(o, row.look, LookIn::Header, !row.icon.empty());
                o.emplace("pinnedCollapsed", row.pinnedCollapsed);
                break;
            case SidebarRow::Kind::Tab:
                o.emplace("title", row.title);
                o.emplace("depth", row.depth);
                o.emplace("pinned", row.pinned);
                o.emplace("selected", row.selected);
                if (row.favicon.url) o.emplace("favicon", *row.favicon.url);
                break;
            case SidebarRow::Kind::Folder:
                o.emplace("title", row.title);
                o.emplace("depth", row.depth);
                o.emplace("expanded", row.expanded);
                break;
            case SidebarRow::Kind::Divider: o.emplace("line", row.showsLine); break;
            case SidebarRow::Kind::NewTab: o.emplace("title", row.title); break;
            }
            rows.emplace_back(std::move(o));
        }
        // The space bar under it, laid out for Kite's 240pt sidebar: each space's cell in bar
        // points (from the bar's top-left), lit 1 for the space you're in.
        const std::vector<SpaceCell> cells = SpaceCells(state);
        const SpaceBarLayout layout = LayOutSpaceBar(240, cells.size());
        json::Array bar;
        for (size_t i = 0; i < cells.size(); ++i) {
            const BarRect& r = layout.cells[i];
            json::Object cell{{"id", cells[i].spaceID},
                              {"icon", cells[i].icon},
                              {"lit", cells[i].lit},
                              {"selected", cells[i].selected},
                              {"left", static_cast<double>(r.left)},
                              {"top", static_cast<double>(r.top)},
                              {"width", static_cast<double>(r.Width())},
                              {"height", static_cast<double>(r.Height())}};
            AddLook(cell, cells[i].look);
            // Its tip on hover: the name, the profile's chip, the keycaps, and its colours.
            const SpaceTip tip = SpaceTipOf(state, i);
            json::Array keys;
            for (const std::string& key : tip.keys) keys.emplace_back(key);
            // Its top and height in bar points (2pt above the cell); its width and x depend on
            // the fonts, so the app measures those.
            const TipOrigin at = SpaceTipOrigin(r, 0, space_tip_metrics::kHeight, 0);
            json::Object t{{"name", tip.name},
                           {"keys", json::Value(std::move(keys))},
                           {"fill", Hex(tip.fill)},
                           {"accent", Hex(tip.accent)},
                           {"top", static_cast<double>(at.y)},
                           {"height", static_cast<double>(space_tip_metrics::kHeight)}};
            if (tip.profile) t.emplace("profile", *tip.profile);
            cell.emplace("tip", std::move(t));
            bar.emplace_back(std::move(cell));
        }
        json::Object out{{"address", AddressFieldText(state)},
                         {"rows", json::Value(std::move(rows))},
                         {"spaceBar", json::Object{{"fits", layout.fits}, {"cells", json::Value(std::move(bar))}}}};
        std::puts(json::Write(json::Value(std::move(out))).c_str());
        return kOk;
    } else if (command == "click" && args.size() >= 3 && args.size() <= 5) {
        // A click (press and release) in the selected space's sidebar, 240pt wide, HEIGHT tall,
        // scrolled SCROLL: prints what it pressed and what the window does, and does it.
        float values[4] = {0, 0, 820, 0};
        for (size_t i = 1; i < args.size(); ++i) {
            auto [end, error] = std::from_chars(args[i].data(), args[i].data() + args[i].size(), values[i - 1]);
            if (error != std::errc() || end != args[i].data() + args[i].size()) return Usage();
        }
        const auto rows = SidebarRows(state, state.SelectedSpaceIndex());
        // The space bar along the bottom: a click on a space's cell selects it (pressed and let
        // go at the point, as the window's).
        if (values[1] >= SpaceBarTop(values[2]) && values[1] < values[2]) {
            const std::vector<SpaceCell> cells = SpaceCells(state);
            const SpaceBarLayout layout = LayOutSpaceBar(240, cells.size());
            const float x = values[0], y = values[1] - SpaceBarTop(values[2]);
            const auto press = SpaceBarPressAt(layout, cells, x, y);
            json::Object out{{"target", std::string(press ? "spaceCell" : "none")}};
            if (press) {
                out.emplace("id", press->spaceID);
                if (const auto space = SpaceBarRelease(*press, layout, cells, x, y)) {
                    out.emplace("action", std::string("selectSpace"));
                    state.SelectSpace(*space);
                    changed = true;
                }
            }
            std::puts(json::Write(json::Value(std::move(out))).c_str());
        } else {
            const auto press = SidebarPressAt(rows, 240, values[2], values[3], values[0], values[1], 1);
            static constexpr const char* kTargets[] = {"none", "addressField", "row", "pinnedChevron", "closeButton"};
            static constexpr const char* kActions[] = {"none",      "editAddress", "togglePinnedSection", "selectTab", "setFolderExpanded",
                                                       "newTab",    "closeTab"};
            json::Object out{{"target", std::string(kTargets[static_cast<int>(press ? press->target : SidebarHit::Target::None)])}};
            if (press) {
                if (!press->id.empty()) out.emplace("id", press->id);
                const SidebarTap tap = SidebarRelease(*press, rows, 240, values[2], values[3], values[0], values[1]);
                out.emplace("action", std::string(kActions[static_cast<int>(tap.action)]));
                switch (tap.action) {
                case SidebarTap::Action::SelectTab: state.Select(tap.id); changed = true; break;
                case SidebarTap::Action::SetFolderExpanded: state.SetFolderExpanded(tap.id, tap.expanded); changed = true; break;
                case SidebarTap::Action::TogglePinnedSection: TogglePinnedSection(state, tap.id); changed = true; break;
                case SidebarTap::Action::CloseTab: state.Close(tap.id); changed = true; break;
                default: break;  // the command bar's, in the window
                }
            }
            std::puts(json::Write(json::Value(std::move(out))).c_str());
        }
    } else if (command == "collapse" && args.size() == 2) {
        const std::string id = Id(args[1]);
        if (!state.SpaceIndex(id)) return kNotFound;
        TogglePinnedSection(state, id);
        changed = true;
    } else if (command == "open") {
        std::optional<std::string> space;
        bool background = false;
        std::vector<std::string> words;
        for (size_t i = 1; i < args.size(); ++i) {
            if (args[i] == "--space" && i + 1 < args.size()) space = Id(args[++i]);
            else if (args[i] == "--background") background = true;
            else words.push_back(args[i]);
        }
        auto url = url_input::Resolve(Join(words, 0), engine);
        if (!url) return Usage();
        if (space && !state.SpaceIndex(*space)) return kNotFound;
        std::puts(state.OpenTab(*url, space, !background).c_str());
        changed = true;
    } else if (command == "select" && args.size() == 2) {
        const std::string id = Id(args[1]);
        if (!state.Location(id)) return kNotFound;
        state.Select(id);
        changed = true;
    } else if (command == "tab" && args.size() == 2) {
        // Ctrl+Alt+Down/Up and Ctrl+1–9 in the selected space: prints the tab now selected.
        if (args[1] == "next" || args[1] == "prev") {
            state.SelectAdjacentTab(args[1] == "next" ? 1 : -1);
        } else {
            int number = 0;
            auto [end, error] = std::from_chars(args[1].data(), args[1].data() + args[1].size(), number);
            if (error != std::errc() || end != args[1].data() + args[1].size() || number < 1 || number > 9) return Usage();
            state.SelectTabNumber(number);
        }
        const Tab* tab = state.SelectedTab();
        if (!tab) return kNotFound;
        std::puts(tab->id.c_str());
        changed = true;
    } else if (command == "close" && args.size() == 2) {
        // Ctrl+W on a tab: prints whether it was removed (and archived) or only unloaded.
        const CloseOutcome outcome = state.Close(Id(args[1]));
        if (outcome == CloseOutcome::NotFound) return kNotFound;
        std::puts(outcome == CloseOutcome::Removed ? "removed" : "unloaded");
        changed = true;
    } else if (command == "reopen" && args.size() <= 2) {
        // Ctrl+Shift+T, or Undo Archive Tab for one tab: prints the tab that came back.
        auto reopened = args.size() == 2 ? state.ReopenClosed(Id(args[1])) : state.ReopenLastClosed();
        if (!reopened) return kNotFound;
        std::puts(reopened->c_str());
        changed = true;
    } else if (command == "archive-stale" && args.size() <= 2) {
        // The auto-archive's pass, as of NOW (Unix seconds; the clock by default): prints the
        // tabs it archived.
        Timestamp now = Now();
        if (args.size() == 2) {
            double seconds = 0;
            auto [end, error] = std::from_chars(args[1].data(), args[1].data() + args[1].size(), seconds);
            if (error != std::errc() || end != args[1].data() + args[1].size()) return Usage();
            now = FromUnixTime(seconds);
        }
        if (auto interval = state.ArchiveAfterSeconds()) {
            for (const Tab& tab : state.ArchiveStaleTabs(*interval, now)) std::puts(tab.id.c_str());
            changed = true;
        }
    } else if (command == "evict" && args.size() >= 2) {
        // The live-page cap (LiveTabPolicy): of the pages given with when each was last shown,
        // the ones past MAX that the shell would ask to close, least recently shown first. The
        // shown tab stays, and so does a popup or its opener while both tabs exist.
        LiveTabPolicy policy;
        auto [end, error] = std::from_chars(args[1].data(), args[1].data() + args[1].size(), policy.maxLiveTabs);
        if (error != std::errc() || end != args[1].data() + args[1].size()) return Usage();
        std::map<std::string, Timestamp> live;
        std::set<std::string> keep;
        std::map<std::string, std::string> popupOpeners;
        for (size_t i = 2; i < args.size(); ++i) {
            if (args[i] == "--shown" && i + 1 < args.size()) {
                keep.insert(Id(args[++i]));
                continue;
            }
            const bool popup = args[i] == "--popup" && i + 1 < args.size();
            const std::string& pair = popup ? args[++i] : args[i];
            const size_t equals = pair.find('=');
            if (equals == std::string::npos) return Usage();
            const std::string value = pair.substr(equals + 1);
            if (popup) {
                popupOpeners[Id(pair.substr(0, equals))] = Id(value);
                continue;
            }
            double shown = 0;
            auto [at, failed] = std::from_chars(value.data(), value.data() + value.size(), shown);
            if (failed != std::errc() || at != value.data() + value.size() || !std::isfinite(shown)) return Usage();
            live[Id(pair.substr(0, equals))] = shown;
        }
        for (const std::string& id : policy.TabsToEvict(live, keep)) {
            if (!IsLinkedToPopup(popupOpeners, state, id)) std::puts(id.c_str());
        }
    } else if (command == "space" && args.size() >= 2) {
        const std::string& action = args[1];
        if (action == "next") state.SelectAdjacentSpace(1);
        else if (action == "prev") state.SelectAdjacentSpace(-1);
        else if (args.size() == 2 && action.size() == 1 && action[0] >= '1' && action[0] <= '9') {
            // Space 1–9 (the Mac's selectSpaceNumber): nothing past the last space.
            state.SelectSpaceAt(static_cast<size_t>(action[0] - '1'));
        }
        else if (action == "select" && args.size() == 3) {
            const std::string id = Id(args[2]);
            if (!state.SpaceIndex(id)) return kNotFound;
            state.SelectSpace(id);
        } else if (action == "add" && (args.size() == 3 || args.size() == 4) && !unicode::Trim(args[2]).empty()) {
            // Like the Mac's New Space sheet: a name of only spaces isn't one.
            const auto& presets = Theme::Presets();
            std::puts(state.AddSpace(std::string(unicode::Trim(args[2])), args.size() == 4 ? args[3] : "",
                                     presets[state.spaces.size() % presets.size()]).c_str());
        } else {
            return Usage();
        }
        changed = true;
    } else if (command == "import-arc") {
        arc_import::ImportOptions options;
        std::optional<std::filesystem::path> picked;
        bool automatic = false;
        for (size_t i = 1; i < args.size(); ++i) {
            if (args[i] == "--include-unnamed" && !options.includeUntitled) options.includeUntitled = true;
            else if (args[i] == "--leave-out-unnamed" && !options.includeUntitled) options.includeUntitled = false;
            else if (args[i] == "--auto" && !picked) automatic = true;
            else if (!automatic && !picked && !args[i].starts_with("--")) picked = std::filesystem::path(std::u8string(args[i].begin(), args[i].end()));
            else return Usage();
        }
        const auto arcDirectory = arc_import::ArcDirectory(profile ? profile : EnvironmentPath("KITE_SUPPORT_PATH"),
                                                           EnvironmentPath("KITE_ARC_DATA_PATH"), EnvironmentPath("LOCALAPPDATA"));
        auto plan = picked ? arc_import::ReadPicked(*picked, arcDirectory) : arc_import::ReadAuto(arcDirectory);
        if (auto* error = std::get_if<arc_import::LoadError>(&plan)) {
            std::fprintf(stderr, "kitecore: %s %s\n", error->message.c_str(), error->detail.c_str());
            return kNotFound;
        }
        arc_import::Imported imported = arc_import::Import(state, std::get<arc_import::Plan>(plan), options);
        // The session first: shortcut changes and routes to spaces it doesn't have would be no use.
        if (std::string error = store.Save(state); !error.empty()) {
            std::fprintf(stderr, "kitecore: %s\n", error.c_str());
            return kSaveFailed;
        }
        arc_import::WriteProfileFiles(imported, std::get<std::filesystem::path>(resolved));
        std::puts(json::Write(arc_import::Summary(imported)).c_str());
        return kOk;
    } else if (command == "profile" && args.size() >= 2) {
        const std::string& action = args[1];
        if (action == "list" && args.size() == 2) {
            json::Array rows;
            for (const Profile& p : AllProfiles(state)) {
                json::Object o{{"directory", p.directory}, {"name", p.name}, {"dataStoreID", p.dataStoreID}};
                o.emplace("deletable", CanDeleteProfile(state, p.directory));
                rows.push_back(json::Value(std::move(o)));
            }
            std::puts(json::Write(json::Value(std::move(rows))).c_str());
            return kOk;
        } else if (action == "add" && args.size() == 3) {
            auto made = CreateProfile(state, args[2]);
            if (auto* error = std::get_if<ProfileNameError>(&made)) {
                std::fprintf(stderr, "kitecore: %s\n", Message(*error));
                return kUsage;
            }
            std::puts(std::get<Profile>(made).directory.c_str());
        } else if (action == "rename" && args.size() == 4) {
            if (ProfileFor(state, args[2]).directory != args[2] || args[2] == Profile::kDefaultDirectory) return kNotFound;
            if (auto error = RenameProfile(state, args[2], args[3])) {
                std::fprintf(stderr, "kitecore: %s\n", Message(*error));
                return kUsage;
            }
        } else if (action == "delete" && args.size() == 3) {
            // Arc's rule: only a profile no space uses, never the default one.
            if (!DeleteProfile(state, args[2])) return kNotFound;
            // The shell deletes a profile's Chromium folder; with none, its name is free at once.
            std::error_code error;
            if (!std::filesystem::exists(std::get<std::filesystem::path>(resolved) / "Chromium" /
                                             std::filesystem::path(std::u8string(args[2].begin(), args[2].end())),
                                         error)) {
                ForgetRetiredProfiles(state, {args[2]});
            }
        } else {
            return Usage();
        }
        changed = true;
    } else {
        return Usage();
    }

    if (changed) {
        if (std::string error = store.Save(state); !error.empty()) {
            std::fprintf(stderr, "kitecore: %s\n", error.c_str());
            return kSaveFailed;
        }
    }
    return kOk;
}
