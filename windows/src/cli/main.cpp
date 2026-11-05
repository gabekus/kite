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
//   kitecore [--profile DIR] downloads [list]
//   kitecore [--profile DIR] downloads apply REPORT...
//   kitecore [--profile DIR] downloads clear|remove ID
//   kitecore [--profile DIR] downloads location [PROFILE [FOLDER|ask|folder|downloads]]
//   kitecore save-schedule KIND@SECONDS... [--at SECONDS]
//   kitecore save-bench [TABS]
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
// `downloads` lists downloads.json as Kite would show it after a launch (nothing live), newest
// first, with each item's file name and subtitle; it never moves an unreadable file aside.
// `downloads apply` replays the engine's reports (each a JSON object with the Mac bridge's keys:
// id, context, incognito, profileDirectory, url, path, state, receivedBytes, totalBytes, speed)
// through the app's rules (core/DownloadsModel.h) onto that list, writes it, and prints what each
// report did and when the app would save. `clear` drops the finished ones, `remove` one item.
// `downloads location` prints a profile's download settings (default: every profile's) and the
// folder its downloads go to (`usesDownloadsFolder` for the user's Downloads, which Kite.exe looks
// up); with a FOLDER (stored absolute) it saves there, `ask` asks every time, `folder` stops
// asking, `downloads` goes back to the Downloads folder (Settings › Profiles › Download location).

#include <algorithm>
#include <charconv>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "core/CommandBar.h"
#include "core/Downloads.h"
#include "core/DownloadsModel.h"
#include "core/KeyBindings.h"
#include "core/ProfileSettings.h"
#include "core/StoreFile.h"
#include "core/LiveTabPolicy.h"
#include "core/OKLab.h"
#include "core/SessionSaveDelay.h"
#include "core/SessionStore.h"
#include "core/SessionWriter.h"
#include "core/Sidebar.h"
#include "core/SpaceBar.h"
#include "core/SupportDirectory.h"
#include "core/ThemeBackdrop.h"
#include "core/URLInput.h"
#include "core/Unicode.h"
#include "core/Uuid.h"

#ifdef _WIN32
#include <windows.h>
#include <shellapi.h>
#endif

using namespace kite;

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
        "       kitecore [--profile DIR] downloads [list]\n"
        "       kitecore [--profile DIR] downloads apply REPORT...\n"
        "       kitecore [--profile DIR] downloads clear|remove ID\n"
        "       kitecore [--profile DIR] downloads location [PROFILE [FOLDER|ask|folder|downloads]]\n"
        "       kitecore save-schedule KIND@SECONDS... [--at SECONDS]\n"
        "       kitecore save-bench [TABS]\n",
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

json::Value DownloadsSummary(const DownloadList& list) {
    json::Array items;
    for (const DownloadItem& item : list.Items()) {
        json::Value encoded = Encode(item);
        json::Object o = *encoded.AsObject();
        o.emplace("fileName", item.FileName());
        o.emplace("subtitle", download_text::Subtitle(item));
        if (auto fraction = item.Fraction()) o.emplace("fraction", *fraction);
        items.push_back(json::Value(std::move(o)));
    }
    json::Object root{{"items", json::Value(std::move(items))}, {"active", list.Active().size()}};
    if (auto fraction = list.ActiveFraction()) root.emplace("activeFraction", *fraction);
    return json::Value(std::move(root));
}

// downloads.json's commands that touch only it (`location` reads the session too, below).
int DownloadsCommand(const std::vector<std::string>& args, const std::filesystem::path& support) {
    const std::filesystem::path file = support / "downloads.json";
    auto read = downloads_file::ReadOnly(file);
    if (!read) {
        std::fprintf(stderr, "kitecore: downloads.json doesn't read; left as it is\n");
        return kLoadFailed;
    }
    const std::string action = args.size() > 1 ? args[1] : "list";
    // Writing the list back would lose the items it couldn't read (a newer Kite's, say): only
    // looking is allowed then. Kite.exe copies such a file aside before it saves.
    if (read->dropped > 0 && action != "list") {
        std::fprintf(stderr, "kitecore: %zu of downloads.json's items don't read; not writing over them\n", read->dropped);
        return kLoadFailed;
    }
    DownloadsModel model;
    model.Restore(read->list, true, 0);
    json::Array reports;
    if (action == "list" && args.size() <= 2) {
        std::puts(json::Write(DownloadsSummary(model.List())).c_str());
        return kOk;
    } else if (action == "apply" && args.size() > 2) {
        for (size_t i = 2; i < args.size(); ++i) {
            auto parsed = json::Parse(args[i]);
            auto* value = std::get_if<json::Value>(&parsed);
            auto update = value ? DownloadUpdate::FromInfo(*value) : std::nullopt;
            if (!update) {
                std::fprintf(stderr, "kitecore: not a download report: %s\n", args[i].c_str());
                return kUsage;
            }
            // A second apart, so the save delays read as the app's timer would arm them: a save
            // due by then has fired.
            const double now = static_cast<double>(i - 2);
            if (auto due = model.Schedule().DueAt(); due && *due <= now) model.Schedule().Saved();
            const auto outcome = model.Apply(*update, now);
            json::Object o{{"applied", outcome.applied}, {"isNew", outcome.isNew}};
            if (outcome.applied) o.emplace("id", outcome.item.id);
            if (outcome.save) o.emplace("saveAfter", *outcome.save);
            reports.push_back(json::Value(std::move(o)));
        }
    } else if (action == "clear" && args.size() == 2) {
        model.ClearFinished(0);
    } else if (action == "remove" && args.size() == 3) {
        if (!model.List().Find(Id(args[2]))) return kNotFound;
        model.Remove(Id(args[2]), 0);
    } else {
        return Usage();
    }
    if (std::string error = store_file::WriteAtomically(file, downloads_file::Encode(model.List())); !error.empty()) {
        std::fprintf(stderr, "kitecore: %s\n", error.c_str());
        return kSaveFailed;
    }
    json::Value summary = DownloadsSummary(model.List());
    if (!reports.empty()) summary.AsObject()->emplace("reports", json::Value(std::move(reports)));
    std::puts(json::Write(summary).c_str());
    return kOk;
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

    auto resolved = ResolveSupportDirectory(profile ? profile : EnvironmentPath("KITE_SUPPORT_PATH"), EnvironmentPath("LOCALAPPDATA"));
    if (auto* error = std::get_if<SupportDirectoryError>(&resolved)) {
        std::fprintf(stderr, "kitecore: %s\n", error->message.c_str());
        return kBadProfile;
    }
    SessionStore store(std::get<std::filesystem::path>(resolved) / "session.json");

    // These don't read the session: backups are there for when it can't be read.
    if (args[0] == "backups" && args.size() == 1) {
        std::puts(json::Write(BackupsSummary(store.Backups())).c_str());
        return kOk;
    }
    const std::filesystem::path support = std::get<std::filesystem::path>(resolved);
    if (args[0] == "downloads" && (args.size() == 1 || args[1] != "location")) return DownloadsCommand(args, support);

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

    if (command == "downloads" && args.size() >= 2 && args.size() <= 4) {
        // Where a profile's downloads go, as a normal launch of Kite.exe on it resolves them (the
        // same test-profile rule). The user's Downloads folder itself is Kite.exe's to look up
        // (the shell's known folders, outside kitecore's layer): it's named, not resolved, here.
        const std::filesystem::path defaultFolder = DefaultDownloadFolder(
            EnvironmentPath("KITE_TEST_DOWNLOADS_PATH"), IsTestProfile(support, EnvironmentPath("LOCALAPPDATA")), false, support, {});
        std::vector<std::string> profiles{BrowserState::kDefaultProfile};
        if (auto list = state.extra.find("profiles"); list != state.extra.end() && list->second.AsArray()) {
            for (const auto& entry : *list->second.AsArray()) {
                if (const json::Value* directory = entry.Find("directory"); directory && directory->AsString()) profiles.push_back(*directory->AsString());
            }
        }
        if (args.size() >= 3 && std::find(profiles.begin(), profiles.end(), args[2]) == profiles.end()) {
            std::fprintf(stderr, "kitecore: no profile in the folder \"%s\"\n", args[2].c_str());
            return kNotFound;
        }
        if (args.size() == 4) {
            const std::string& choice = args[3];
            state.UpdateSettings(args[2], [&](ProfileSettings& settings) {
                if (choice == "ask") {
                    settings.promptsForDownload = true;
                } else if (choice == "folder") {
                    settings.promptsForDownload = false;
                } else if (choice == "downloads") {
                    settings.downloadDirectory.reset();
                    settings.promptsForDownload = false;
                } else {
                    // DownloadLocation.setFolder: the folder Kite saves into anyway is stored as
                    // none; any other is kept absolute (a relative one would follow the caller).
                    std::error_code error;
                    const std::filesystem::path chosen =
                        std::filesystem::absolute(std::filesystem::path(std::u8string(choice.begin(), choice.end())), error).lexically_normal();
                    std::error_code same;
                    if (!defaultFolder.empty() && std::filesystem::equivalent(chosen, defaultFolder, same) && !same) settings.downloadDirectory.reset();
                    else settings.downloadDirectory = PathUtf8(chosen);
                    settings.promptsForDownload = false;
                }
            });
            changed = true;
        }
        json::Array rows;
        for (const std::string& directory : profiles) {
            if (args.size() >= 3 && directory != args[2]) continue;
            const ProfileSettings settings = state.Settings(directory);
            const std::filesystem::path folder = settings.DownloadFolder(defaultFolder, [](const std::string& path) {
                std::error_code error;
                return std::filesystem::is_directory(std::filesystem::path(std::u8string(path.begin(), path.end())), error);
            });
            json::Object row{{"profile", directory},
                             {"name", state.ProfileName(directory)},
                             {"promptsForDownload", settings.promptsForDownload},
                             {"includesSearchSuggestions", settings.includesSearchSuggestions}};
            // A folder chosen or a test's own; else the user's Downloads folder, by name.
            if (folder.empty()) row.emplace("usesDownloadsFolder", true);
            else row.emplace("folder", PathUtf8(folder));
            if (settings.downloadDirectory) row.emplace("downloadDirectory", *settings.downloadDirectory);
            rows.push_back(json::Value(std::move(row)));
        }
        std::puts(json::Write(json::Value(std::move(rows))).c_str());
        if (!changed) return kOk;
    } else if (command == "state") {
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
        json::Array rows;
        for (const CommandSuggestion& row : CommandBarSuggestions(Join(words, 0), state, mode)) {
            const char* kind = row.kind == CommandSuggestion::Kind::Open ? "open"
                               : row.kind == CommandSuggestion::Kind::Search ? "search" : "switchTab";
            json::Object o{{"kind", std::string(kind)}, {"url", row.url}, {"title", row.title}, {"detail", row.detail}};
            if (!row.tabID.empty()) o.emplace("tabID", row.tabID);
            if (row.faviconURL) o.emplace("faviconURL", *row.faviconURL);
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
