// kitecore: Kite for Windows' model, headless. It reads and changes a profile's session.json
// with the same code the app uses, so behaviour can be checked in milliseconds without a
// window (the behaviour gate in docs/helix.md). Output is JSON or a single line.
//
//   kitecore [--profile DIR] state
//   kitecore [--profile DIR] resolve TEXT...
//   kitecore [--profile DIR] open TEXT... [--space ID] [--background]
//   kitecore [--profile DIR] select TAB_ID
//   kitecore [--profile DIR] space next|prev|select ID|add NAME [ICON]
//   kitecore [--profile DIR] theme SPACE_ID
//
// --profile may come anywhere. DIR defaults to KITE_SUPPORT_PATH, then %LOCALAPPDATA%\Kite;
// an empty or missing DIR is an error, never the real profile. Use it on a profile Kite.exe
// isn't running on: both write session.json. `theme` prints the space's theme maths
// (lightness, foreground, glow, accent) as sRGB hex.

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <string>
#include <vector>

#include "core/OKLab.h"
#include "core/SessionStore.h"
#include "core/SupportDirectory.h"
#include "core/URLInput.h"
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
        "       kitecore [--profile DIR] open TEXT... [--space ID] [--background]\n"
        "       kitecore [--profile DIR] select TAB_ID\n"
        "       kitecore [--profile DIR] space next|prev|select ID|add NAME [ICON]\n"
        "       kitecore [--profile DIR] theme SPACE_ID\n",
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
    return json::Value(std::move(root));
}

}  // namespace

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

json::Value ThemeSummary(const Theme& theme) {
    json::Array colors;
    for (const auto& c : theme.colors) colors.push_back(json::Value(Hex(c)));
    auto [glowA, glowB] = GlowColors(theme);
    return json::Value(json::Object{{"colors", json::Value(std::move(colors))},
                                    {"lightness", json::Value(static_cast<double>(Lightness(theme)))},
                                    {"prefersDarkForeground", json::Value(PrefersDarkForeground(theme))},
                                    {"glow", json::Value(json::Array{json::Value(Hex(glowA)), json::Value(Hex(glowB))})},
                                    {"accent", json::Value(Hex(Accent(theme)))}});
}

// Ids typed in either case, like UUID(uuidString:).
std::string Id(const std::string& text) { return NormalizeUuid(text).value_or(text); }

int main(int argc, char** argv) {
#ifdef _WIN32
    // Arguments come in as UTF-16 (CommandLineToArgvW) and are converted to UTF-8; output is
    // UTF-8 too, which the console shows only once its output code page says so.
    SetConsoleOutputCP(CP_UTF8);
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
    state = existed ? std::get<BrowserState>(loaded) : BrowserState::MakeDefault();

    const std::string& command = args[0];
    const SearchEngine engine = SearchEngineFromRaw(state.searchEngine).value_or(SearchEngine::Google);
    bool changed = false;

    if (command == "state") {
        std::puts(json::Write(Summary(state)).c_str());
        return kOk;
    } else if (command == "theme" && args.size() == 2) {
        auto space = state.SpaceIndex(Id(args[1]));
        if (!space) return kNotFound;
        std::puts(json::Write(ThemeSummary(state.spaces[*space].theme)).c_str());
        return kOk;
    } else if (command == "resolve") {
        auto url = url_input::Resolve(Join(args, 1), engine);
        if (!url) return kNotFound;
        std::puts(url->c_str());
        return kOk;
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
    } else if (command == "space" && args.size() >= 2) {
        const std::string& action = args[1];
        if (action == "next") state.SelectAdjacentSpace(1);
        else if (action == "prev") state.SelectAdjacentSpace(-1);
        else if (action == "select" && args.size() == 3) {
            const std::string id = Id(args[2]);
            if (!state.SpaceIndex(id)) return kNotFound;
            state.SelectSpace(id);
        } else if (action == "add" && args.size() >= 3 && !args[2].empty()) {  // the Mac drops nameless spaces
            const auto& presets = Theme::Presets();
            std::puts(state.AddSpace(args[2], args.size() >= 4 ? args[3] : "", presets[state.spaces.size() % presets.size()]).c_str());
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
