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

#include <algorithm>
#include <charconv>
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
#include "core/KeyBindings.h"
#include "core/LiveTabPolicy.h"
#include "core/OKLab.h"
#include "core/SessionStore.h"
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
        "       kitecore [--profile DIR] theme SPACE_ID [WIDTH HEIGHT]\n",
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

// What an icon shows: "dot", "emoji", "symbol" (with its Segoe Fluent and MDL2 glyphs as hex)
// or "picture". A header draws no dot: it has no icon slot for an icon-less space ("none"), and a
// blank one for a symbol with no stand-in ("blank").
enum class LookIn { Bar, Header };
void AddLook(json::Object& o, const SpaceIconLook& look, LookIn in = LookIn::Bar, bool headerSlot = false) {
    static constexpr const char* kShows[] = {"dot", "emoji", "symbol", "picture"};
    const char* shows = kShows[static_cast<int>(look.kind)];
    if (in == LookIn::Header && look.kind == SpaceIconLook::Kind::Dot) shows = headerSlot ? "blank" : "none";
    o.emplace("shows", std::string(shows));
    if (look.glyph) {
        char fluent[8], mdl2[8];
        std::snprintf(fluent, sizeof fluent, "%04X", static_cast<unsigned>(look.glyph->fluent));
        std::snprintf(mdl2, sizeof mdl2, "%04X", static_cast<unsigned>(look.glyph->mdl2));
        o.emplace("glyph", json::Object{{"fluent", std::string(fluent)}, {"mdl2", std::string(mdl2)}, {"standIn", look.glyph->standIn}});
    }
    if (look.kind == SpaceIconLook::Kind::Symbol) o.emplace("accent", Hex(look.accent));
}

// Ids typed in either case, like UUID(uuidString:).
std::string Id(const std::string& text) { return NormalizeUuid(text).value_or(text); }

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

    auto resolved = ResolveSupportDirectory(profile ? profile : EnvironmentPath("KITE_SUPPORT_PATH"), EnvironmentPath("LOCALAPPDATA"));
    if (auto* error = std::get_if<SupportDirectoryError>(&resolved)) {
        std::fprintf(stderr, "kitecore: %s\n", error->message.c_str());
        return kBadProfile;
    }
    SessionStore store(std::get<std::filesystem::path>(resolved) / "session.json");

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
