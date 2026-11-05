// kitecore: Kite for Windows' model, headless. It reads and changes a profile's session.json
// with the same code the app uses, so behaviour can be checked in milliseconds without a
// window (the behaviour gate in docs/helix.md). Output is JSON or a single line.
//
//   kitecore [--profile DIR] state
//   kitecore [--profile DIR] resolve TEXT...
//   kitecore [--profile DIR] suggest TEXT... [--current]
//   kitecore [--profile DIR] find TEXT... [--result ACTIVE/TOTAL] [--width W] [--ask [--conversation]]
//                                       the find bar with TEXT typed: what it asks the page, its
//                                       counter for that report, Ask on Page's mode, and its
//                                       frame (core/FindBar.h)
//   kitecore [--profile DIR] undo STEP...
//                                       a field's undo grouping (core/TextUndo.h): type:TEXT,
//                                       back, paste:TEXT, move, undo, redo
//   kitecore [--profile DIR] sidebar [SPACE_ID]
//   kitecore [--profile DIR] collapse SPACE_ID
//   kitecore [--profile DIR] open TEXT... [--space ID] [--background]
//   kitecore [--profile DIR] select TAB_ID
//   kitecore [--profile DIR] tab pin|favorite|duplicate|reset|separate|reveal|replace-pin TAB_ID
//   kitecore [--profile DIR] tab rename TAB_ID [NAME...]|pinned-url TAB_ID URL|reset-all
//   kitecore [--profile DIR] folder new [SPACE_ID]|rename FOLDER NAME...|delete FOLDER|move TAB_ID FOLDER
//   kitecore [--profile DIR] shown header|tab|folder|divider|newTab ID [SPACE_ID]
//   kitecore [--profile DIR] menu tab|favorite TAB_ID|folder FOLDER [--pick TITLE...]
//   kitecore [--profile DIR] space next|prev|NUMBER|select ID|add NAME [ICON]
//   kitecore [--profile DIR] space swipe DX [SECONDS]
//   kitecore [--profile DIR] space menu ID|rename ID NAME...|icon ID ICON|delete ID|folder ID|new NAME...
//   kitecore [--profile DIR] space move ID PLACE|drag ID X [Y]
//   kitecore [--profile DIR] theme SPACE_ID [WIDTH HEIGHT]
//   kitecore [--profile DIR] backups
//   kitecore [--profile DIR] downloads [list]
//   kitecore [--profile DIR] downloads apply REPORT...
//   kitecore [--profile DIR] downloads clear|remove ID
//   kitecore [--profile DIR] downloads location [PROFILE [FOLDER|ask|folder|downloads]]
//   kitecore save-schedule KIND@SECONDS... [--at SECONDS]
//   kitecore save-bench [TABS]
//   kitecore [--profile DIR] history list|search TEXT... [--limit N]|add URL [TITLE...] [--at SECONDS]
//            |merge FILE|remove URL...|remove-since SECONDS|all|clear [--chromium PROFILE]
//   kitecore history chromium-date MICROSECONDS
//   kitecore [--profile DIR] import-arc [PATH|--auto] [--include-unnamed|--leave-out-unnamed]
//   kitecore [--profile DIR] profile list|add NAME|rename DIRECTORY NAME|delete DIRECTORY
//   kitecore occlusion WINDOW [--monitor RECT]... [OCCLUDER...]
//
// --profile may come anywhere. DIR defaults to KITE_SUPPORT_PATH, then %LOCALAPPDATA%\Kite;
// an empty or missing DIR is an error, never the real profile. Use it on a profile Kite.exe
// isn't running on: both write session.json and history.json. `theme` prints the space's theme maths
// (lightness, foreground, glow, accent) and its window backdrop (material, and the corner and
// centre pixels at WIDTH×HEIGHT px, default 1280×820) as sRGB hex. `suggest` prints the command
// bar's rows for TEXT, top first (--current: editing the current tab's address, Ctrl+L).
// `sidebar` prints what the sidebar shows for a space (default the selected one): the address
// field's text and the space page's rows, top to bottom, with their place in points, then the
// space bar's cells (in the bar's points, for a 240pt sidebar, exact: the window snaps them to
// its pixels, under 1px from these at a fractional scale). Its `favorites` are the grid over the
// page: its columns, its height with its gaps, where the page's rows start (`listTop`: their `top`s
// are from there), and each tile with its panes and their frames, in sidebar points; with none,
// the empty state (until the profile's One-Shot Flags.plist says it was dismissed).
// `click` in the bar's 50pt along the bottom selects the space whose cell it hits; on a favorite's
// pane, it selects that favorite (in the space you're in); on the empty state's close button, it
// dismisses it (the one-shot flag, written to the profile).
// `collapse` is View → Collapse / Expand Pinned Tabs for a space. `click … --double` is the
// second press of a double-click there (a tab's row renames, in the window). `click … --button middle`
// is a middle click (pressed and let go at the point): on a tab's row it closes the tab as its close
// button does (a Windows addition, not the Mac's), printing whether it went ("removed") or, pinned,
// only unloaded; anywhere else, nothing. A close button's click prints the same `outcome`.
// `click … --button right` is a right-click (or a Ctrl+click, the Mac's ⌃-click) there: it prints the
// menu the window opens (`kind` space, tab, folder or favorite, its `id` and `line`, and `button`
// on one of a row's own buttons, which a Ctrl+click presses instead), or `none`.
// `menu` prints a tab's, folder's or favorite's menu as `space menu` prints the space's (each
// item's title, enabled and submenu, a submenu's items too) and its `line`, as the Mac's
// KITE_TEST_CONTEXT_MENU logs one; with --pick it runs the item of that title ("Submenu ▸ Item" for
// one in a submenu) as the window does and prints what it did (exit 6 for a disabled or missing
// one): Delete prints the question the window asks first and goes on as if Delete Folder was
// pressed; Rename… and New Nested Folder… print that the window opens a rename; the Copy items
// print what they'd copy.
// The tab edits (Tabs and the command bar's commands, and the sidebar's buttons): `tab pin` is Pin
// Tab / Unpin Tab (Ctrl+D) and prints where the tab is now (pinned or unpinned, or favorite);
// `favorite` is Add to / Remove from Favorites, likewise; `rename` renames it (no NAME, or a blank
// one, goes back to the page's title) and prints what its row shows; `duplicate` prints the copy's
// id; `reset` is Back to Pinned URL and prints the URL it goes to (exit 6 when it hasn't left its
// pinned page); `reset-all` is Reset all tabs in this Space, a line "ID URL" for each (exit 6 for
// none); `separate` is Separate From Pinned Tab and prints the new tab's id; `reveal` is Reveal Tab
// in Sidebar and prints its row's id; `pinned-url` is Edit Pinned Page › Edit… and `replace-pin` is
// Replace Pin with Current Page, each printing the pinned URL (exit 6 when refused). `folder new`
// is New Folder (in the selected space, or SPACE_ID's) and prints its id; FOLDER is a folder's id or
// name (any case, the selected space's first); `rename` prints its name (a blank one keeps it);
// `delete` archives what's in it and prints those tabs' ids; `move` puts a tab at the end of a
// folder (pinning it; exit 6 for a favorite). `shown` says whether a space's page (the selected
// one's by default) lists that row now: "yes" or "no".
// `space swipe` is two fingers sideways over the sidebar: the content dragged DX points (positive
// towards the previous space) at a steady pace over SECONDS (default 0.25), an event every
// 1/60 s, then let go. It prints where the pages were at the release (offset, the theme's
// progress and direction) and where it lands, and selects that space.
// The space menu and its edits (the bar's cells and the header's): `space menu` prints the menu
// as the window shows it (each item's title, whether it's enabled, whether it's a submenu) and
// its `line`, as the Mac's KITE_TEST_CONTEXT_MENU logs one; `rename`, `icon` (an emoji,
// symbol:NAME, image:FILE, or "" for the dot), `folder` (New Folder) and `delete` are its items.
// `delete` prints whether the window deletes at once or asks first (and what), then deletes; the
// last space stays (exit 6; 5 is a space that isn't there). `new` is + › New Space, named
// NAME. `move` puts a space at PLACE (from 1) among the others, as a drop in the bar; `drag`
// presses its cell in the 240pt bar, drags to X (and Y, default the bar's middle) in bar points
// and prints the strip there (the open slot, each cell's left, the ghost's), then lets go,
// prints the slot it lands in and moves it there.
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
// up); with a FOLDER (stored absolute; the Downloads folder's own path, given as FOLDER, is
// stored as that path, since kitecore doesn't look the folder up: `downloads` stores none) it
// saves there, `ask` asks every time, `folder` stops asking, `downloads` goes back to the
// Downloads folder (Settings › Profiles › Download location).
// `history` reads and changes a profile's browsing history (history.json, or with --chromium a
// Chromium profile folder's Kite History.json, as the Mac's HistoryStore keeps them): `list` is
// every page, last visited first; `search` the command bar's ranking (--limit, default 4); `add`
// records a visit (now, or --at Foundation seconds since 2001); `merge` adds a history.json's
// pages as Import from Arc does (a later visit and the higher count win); `remove` is Remove from
// History, `remove-since` Delete browsing data's (pages last visited at or after SECONDS, or all);
// `clear` forgets every page. Each prints JSON. `history chromium-date` turns Chromium's
// microseconds since 1601 into Foundation seconds, as the Arc import reads them. `suggest`
// includes history's rows, from the selected space's profile, as the bar. The history-bench
// executable (windows/tests/HistoryBench.cpp) measures history on the app's own path.
// `import-arc` is Import from Arc (core/ArcImportController.h): from Arc for Windows' folder
// (--auto, the default), or PATH (Arc's folder, the folder holding it, or a sidebar file). It
// prints what came over, per kind, and what was skipped and why: counts only, never Arc's
// titles or addresses. Arc's unnamed spaces stay out, as the Mac's dialog starts, unless Arc
// has no named space (then they're all there is) or --include-unnamed; --leave-out-unnamed
// leaves them out either way. The session is saved first, then keybindings.json and
// LinkRouting.json, then each Arc profile's history into its Kite profile's history (found:
// historyRows, historyPages; imported: historyPages, historyPagesNew; skipped: history* by
// reason); the summary prints once all of it is written. With --profile or
// KITE_SUPPORT_PATH, KITE_ARC_DATA_PATH stands in for Arc's folder, as in the Mac's test runs.
// `profile` lists, makes, renames and deletes Kite profiles (core/Profiles.h). A deleted one's
// folder name is free again once its Chromium folder is gone, which kitecore never deletes.
// `occlusion` is shell/Occlusion's sum: how many of the window's pixels show on the monitors
// (default one 1920×1080 at 0,0) past the occluders, and whether that's covered. Rects are
// screen pixels LEFT,TOP,RIGHT,BOTTOM.

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

#include "core/ArcImportController.h"
#include "core/CommandBar.h"
#include "core/Downloads.h"
#include "core/DownloadsModel.h"
#include "core/Favorites.h"
#include "core/History.h"
#include "core/HistoryStore.h"
#include "core/FindBar.h"
#include "core/TextUndo.h"
#include "core/KeyBindings.h"
#include "core/ProfileSettings.h"
#include "core/StoreFile.h"
#include "core/LiveTabPolicy.h"
#include "core/OKLab.h"
#include "core/Occlusion.h"
#include "core/OneShotFlags.h"
#include "core/Profiles.h"
#include "core/SessionSaveDelay.h"
#include "core/SessionStore.h"
#include "core/SessionWriter.h"
#include "core/Sidebar.h"
#include "core/SidebarContextMenu.h"
#include "core/SidebarTopRow.h"
#include "core/SpaceBar.h"
#include "core/SpaceEditing.h"
#include "core/SpaceSwipeGesture.h"
#include "core/StoreFile.h"
#include "core/SupportDirectory.h"
#include "core/ThemeBackdrop.h"
#include "core/TitleBar.h"
#include "core/URLInput.h"
#include "core/Unicode.h"
#include "core/Uuid.h"

#ifdef _WIN32
#include <windows.h>
#include <shellapi.h>
#endif

using namespace kite;

namespace {

enum ExitCode : int { kOk = 0, kUsage = 1, kBadProfile = 2, kLoadFailed = 3, kSaveFailed = 4, kNotFound = 5, kRefused = 6 };

int Usage() {
    std::fputs(
        "usage: kitecore [--profile DIR] state\n"
        "       kitecore [--profile DIR] resolve TEXT...\n"
        "       kitecore [--profile DIR] suggest TEXT... [--current]\n"
        "       kitecore [--profile DIR] find TEXT... [--result ACTIVE/TOTAL] [--width W] [--ask [--conversation]]\n"
        "       kitecore [--profile DIR] undo type:TEXT|back|paste:TEXT|move|undo|redo...\n"
        "       kitecore [--profile DIR] sidebar [SPACE_ID] [--page back,forward,loading] [--hidden]\n"
        "       kitecore [--profile DIR] collapse SPACE_ID\n"
        "       kitecore [--profile DIR] click X Y [HEIGHT [SCROLL]] [--page back,forward,loading] [--double] [--button left|middle|right]\n"
        "       kitecore [--profile DIR] open TEXT... [--space ID] [--background]\n"
        "       kitecore [--profile DIR] select TAB_ID\n"
        "       kitecore [--profile DIR] tab next|prev|NUMBER\n"
        "       kitecore [--profile DIR] tab pin|favorite|duplicate|reset|separate|reveal|replace-pin TAB_ID\n"
        "       kitecore [--profile DIR] tab rename TAB_ID [NAME...]|pinned-url TAB_ID URL|reset-all\n"
        "       kitecore [--profile DIR] folder new [SPACE_ID]|rename FOLDER NAME...|delete FOLDER|move TAB_ID FOLDER\n"
        "       kitecore [--profile DIR] menu tab|favorite TAB_ID|folder FOLDER [--pick TITLE...]\n"
        "       kitecore [--profile DIR] shown header|tab|folder|divider|newTab ID [SPACE_ID]\n"
        "       kitecore [--profile DIR] shortcuts\n"
        "       kitecore [--profile DIR] close TAB_ID\n"
        "       kitecore [--profile DIR] reopen [TAB_ID]\n"
        "       kitecore [--profile DIR] archive-stale [NOW]\n"
        "       kitecore [--profile DIR] evict MAX [--shown TAB_ID] [--popup POPUP_ID=OPENER_ID]... TAB_ID=LAST_SHOWN...\n"
        "       kitecore [--profile DIR] space next|prev|NUMBER|select ID|add NAME [ICON]\n"
        "       kitecore [--profile DIR] space swipe DX [SECONDS]\n"
        "       kitecore [--profile DIR] space menu ID|rename ID NAME...|icon ID ICON|delete ID|folder ID|new NAME...\n"
        "       kitecore [--profile DIR] space move ID PLACE|drag ID X [Y]\n"
        "       kitecore [--profile DIR] theme SPACE_ID [WIDTH HEIGHT]\n"
        "       kitecore [--profile DIR] backups\n"
        "       kitecore [--profile DIR] downloads [list]\n"
        "       kitecore [--profile DIR] downloads apply REPORT...\n"
        "       kitecore [--profile DIR] downloads clear|remove ID\n"
        "       kitecore [--profile DIR] downloads location [PROFILE [FOLDER|ask|folder|downloads]]\n"
        "       kitecore save-schedule KIND@SECONDS... [--at SECONDS]\n"
        "       kitecore save-bench [TABS]\n"
        "       kitecore [--profile DIR] history list|search TEXT... [--limit N]|add URL [TITLE...] [--at SECONDS]\n"
        "                |merge FILE|remove URL...|remove-since SECONDS|all|clear [--chromium PROFILE]\n"
        "       kitecore history chromium-date MICROSECONDS\n"
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

// "LEFT,TOP,RIGHT,BOTTOM" in screen pixels; nullopt unless it's four whole numbers.
std::optional<occlusion::Rect> ParseRect(const std::string& text) {
    int32_t v[4] = {};
    const char* at = text.data();
    const char* end = text.data() + text.size();
    for (int i = 0; i < 4; ++i) {
        auto [next, error] = std::from_chars(at, end, v[i]);
        if (error != std::errc() || (i < 3 ? next == end || *next != ',' : next != end)) return std::nullopt;
        at = next + (i < 3 ? 1 : 0);
    }
    return occlusion::Rect{v[0], v[1], v[2], v[3]};
}

// Ids typed in either case, like UUID(uuidString:).
std::string Id(const std::string& text) { return NormalizeUuid(text).value_or(text); }

// A menu's items for `menu` and `click --button right`: each title, whether it's enabled,
// whether it's a submenu (with its items), separators as {"separator": true}.
json::Value MenuItemsJson(const std::vector<SidebarMenuItem>& menu) {
    json::Array items;
    for (const SidebarMenuItem& item : menu) {
        if (item.command == SidebarMenuItem::Command::Separator) {
            items.emplace_back(json::Object{{"separator", true}});
            continue;
        }
        json::Object entry{{"title", item.title}, {"enabled", item.enabled}, {"submenu", item.submenu}};
        if (item.submenu) entry.emplace("items", MenuItemsJson(item.items));
        items.emplace_back(std::move(entry));
    }
    return json::Value(std::move(items));
}

const char* OutcomeName(CloseOutcome outcome);

// What the window does for a row menu's item (BrowserWindowController::RunRowMenuItem), on the
// session: what it did goes in `out`. The items that need the window (a rename field, the
// clipboard) say so and what they'd do. Empty on success.
std::string RunMenuItem(BrowserState& state, const std::string& id, const SidebarMenuItem& item, json::Object& out) {
    using C = SidebarMenuItem::Command;
    using R = BrowserState::ArchiveTabsRelative;
    const auto where = [&] {
        const TabSection section = state.Location(id)->section;
        return std::string(section == TabSection::Pinned ? "pinned" : section == TabSection::Unpinned ? "unpinned" : "favorite");
    };
    const auto ids = [](const std::vector<Tab>& tabs) {
        json::Array list;
        for (const Tab& tab : tabs) list.emplace_back(tab.id);
        return json::Value(std::move(list));
    };
    switch (item.command) {
    case C::AddToFavorites:
    case C::RemoveFromFavorites:
    case C::TogglePin:
        if (item.command == C::TogglePin) state.TogglePin(id);
        else state.ToggleFavorite(id);
        out.emplace("now", where());
        return {};
    case C::BackToPinnedURL: {
        const auto url = state.ResetTab(id);
        if (!url) return "nothing to reset";
        out.emplace("url", *url);
        return {};
    }
    case C::SeparateFromPinnedTab: {
        const auto made = state.SeparateFromPinnedTab(id);
        if (!made) return "nothing to separate";
        out.emplace("id", *made);
        return {};
    }
    case C::ReplacePinnedURL:
        if (!state.ReplacePinnedURLWithCurrent(id)) return "nothing to replace";
        out.emplace("pinnedURL", *state.FindTabByID(id)->pinnedURL);
        return {};
    case C::CopyLink:
        if (const Tab* tab = state.FindTabByID(id); tab->url) out.emplace("copy", *tab->url);
        return {};
    case C::CopyLinkAsMarkdown:
        out.emplace("copy", MarkdownLink(*state.FindTabByID(id)).value_or(""));
        return {};
    case C::RenameTab:
    case C::RenameFolder: out.emplace("window", std::string("rename")); return {};
    case C::DuplicateTab: out.emplace("id", *state.Duplicate(id)); return {};
    case C::CloseTab: out.emplace("outcome", std::string(OutcomeName(state.Close(id)))); return {};
    case C::ArchiveOthers: out.emplace("archived", ids(state.ArchiveTabs(R::Others, id))); return {};
    case C::ArchiveBelow: out.emplace("archived", ids(state.ArchiveTabs(R::Below, id))); return {};
    case C::ArchiveAbove: out.emplace("archived", ids(state.ArchiveTabs(R::Above, id))); return {};
    case C::DuplicateFolder: {
        const auto copy = state.DuplicateFolder(id);
        if (!copy) return "it can't be duplicated";
        out.emplace("id", *copy);
        return {};
    }
    case C::DeleteFolder:
    case C::DeleteLiveFolder: {
        // The window asks first; here it's as if its Delete Folder (or a live folder's Delete) was
        // pressed. A folder's tabs are archived; a live folder's go unarchived.
        const FolderDeletion deletion = FolderDeletionOf(state, id);
        out.emplace("asks", json::Object{{"title", deletion.title}, {"message", deletion.message}, {"confirm", deletion.confirm}});
        if (deletion.live) {
            json::Array removed;
            for (const std::string& tab : state.DeleteLiveFolder(id)) removed.emplace_back(tab);
            out.emplace("removed", json::Value(std::move(removed)));
        } else {
            out.emplace("archived", ids(state.DeleteFolder(id)));
        }
        return {};
    }
    case C::NewNestedFolder: {
        const auto nested = state.CreateNestedFolder(id);
        if (!nested) return "no such folder";
        out.emplace("id", *nested);
        out.emplace("window", std::string("rename"));
        return {};
    }
    case C::TurnFolderIntoSpace: {
        const auto space = state.TurnFolderIntoSpace(id);
        if (!space) return "it can't become a space";
        out.emplace("space", *space);
        return {};
    }
    case C::CopyAllLinks: out.emplace("copy", LinkList(TabsIn(state.FolderByID(id)->items))); return {};
    case C::CopyAllLinksAsMarkdown: out.emplace("copy", MarkdownLinkList(TabsIn(state.FolderByID(id)->items))); return {};
    default: return "it isn't ported yet";  // disabled, so never picked
    }
}

// What closing a tab did, as `close` and a click's `outcome` print it.
const char* OutcomeName(CloseOutcome outcome) {
    switch (outcome) {
    case CloseOutcome::Removed: return "removed";
    case CloseOutcome::Unloaded: return "unloaded";
    case CloseOutcome::NotFound: return "notFound";
    }
    return "notFound";
}

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
    if (action == "chromium-date") {
        if (args.size() != 3) return Usage();
        int64_t micros = 0;
        auto [end, error] = std::from_chars(args[2].data(), args[2].data() + args[2].size(), micros);
        if (error != std::errc() || end != args[2].data() + args[2].size()) return Usage();
        std::puts(json::Write(json::Value(History::ChromiumDate(micros))).c_str());
        return kOk;
    }
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
    if (action == "merge" && args.size() == 3) {
        const auto text = store_file::Read(std::filesystem::path(std::u8string(args[2].begin(), args[2].end())),
                                           store_file::kMaxHistoryReadBytes);
        if (!text) {
            std::fprintf(stderr, "kitecore: couldn't read %s\n", args[2].c_str());
            return kLoadFailed;
        }
        auto imported = History::DecodeFile(*text);
        if (auto* error = std::get_if<std::string>(&imported)) {
            std::fprintf(stderr, "kitecore: not a history file: %s\n", error->c_str());
            return kLoadFailed;
        }
        const size_t added = history.Merge(std::get<History>(imported).Entries());
        if (int code = save(); code != kOk) return code;
        std::puts(json::Write(json::Value(json::Object{{"added", added}, {"entries", history.Count()}})).c_str());
        return kOk;
    }
    if (action == "remove" && args.size() >= 3) {
        const size_t before = history.Count();
        history.Remove(std::vector<std::string>(args.begin() + 2, args.end()));
        if (int code = save(); code != kOk) return code;
        std::puts(json::Write(json::Value(json::Object{{"removed", before - history.Count()}})).c_str());
        return kOk;
    }
    if (action == "remove-since" && args.size() == 3) {
        std::optional<Timestamp> since;
        if (args[2] != "all" && !(since = ParseSeconds(args[2]))) return Usage();
        const size_t before = history.Count();
        history.RemoveVisits(since);
        if (int code = save(); code != kOk) return code;
        std::puts(json::Write(json::Value(json::Object{{"removed", before - history.Count()}})).c_str());
        return kOk;
    }
    if (action == "clear" && args.size() == 2) {
        history.RemoveAll();
        return save();
    }
    return Usage();
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

    if (args[0] == "occlusion") {
        // Needs no profile: the sum shell/Occlusion runs over the screen's windows.
        if (args.size() < 2) return Usage();
        const auto window = ParseRect(args[1]);
        if (!window) return Usage();
        std::vector<occlusion::Rect> monitors, occluders;
        for (size_t i = 2; i < args.size(); ++i) {
            const bool monitor = args[i] == "--monitor";
            if (monitor && ++i >= args.size()) return Usage();
            const auto rect = ParseRect(args[i]);
            if (!rect) return Usage();
            (monitor ? monitors : occluders).push_back(*rect);
        }
        if (monitors.empty()) monitors.push_back({0, 0, 1920, 1080});
        const int64_t visible = occlusion::VisiblePixels(*window, monitors, occluders);
        std::puts(json::Write(json::Object{{"visiblePixels", visible}, {"covered", occlusion::Covered(visible)}}).c_str());
        return kOk;
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
    // The profile's one-shot flags (the favorites' empty state, dismissed or not).
    OneShotFlags flags = OneShotFlags::Load(std::get<std::filesystem::path>(resolved));
    state = existed ? std::move(std::get<BrowserState>(loaded)) : BrowserState::MakeDefault();

    // The page the selected tab shows, as Chromium would report it (kitecore has no pages): what the
    // top row shows (sidebar, click). And the sidebar hidden (View › Hide Sidebar, which the session
    // doesn't keep): where the card's edge is.
    PageStatus page;
    bool hidden = false;
    int clicks = 1;
    bool middle = false, right = false;
    if (args[0] == "sidebar" || args[0] == "click") {
        for (size_t i = 1; i < args.size(); ++i) {
            if (args[i] == "--hidden" && args[0] == "sidebar") {
                hidden = true;
            } else if (args[i] == "--double" && args[0] == "click") {
                clicks = 2;
            } else if (args[i] == "--button" && args[0] == "click" && i + 1 < args.size()) {
                if (args[i + 1] == "middle") middle = true;
                else if (args[i + 1] == "right") right = true;
                else if (args[i + 1] != "left") return Usage();
                args.erase(args.begin() + static_cast<std::ptrdiff_t>(i));
            } else if (args[i] == "--page" && i + 1 < args.size()) {
                std::string_view rest = args[i + 1];
                while (!rest.empty()) {
                    const std::string_view word = rest.substr(0, rest.find(','));
                    if (word == "back") page.canGoBack = true;
                    else if (word == "forward") page.canGoForward = true;
                    else if (word == "loading") page.isLoading = true;
                    else if (word != "none") return Usage();
                    rest = rest.size() > word.size() ? rest.substr(word.size() + 1) : std::string_view{};
                }
                args.erase(args.begin() + static_cast<std::ptrdiff_t>(i));
            } else {
                continue;
            }
            args.erase(args.begin() + static_cast<std::ptrdiff_t>(i));
            --i;
        }
    }

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
    } else if (command == "find") {
        // The find bar (Ctrl+F) with TEXT typed: its placeholder, the search it asks the page for,
        // the counter for a page report ACTIVE/TOTAL (0/0 for none, as Kite.exe's --find-result),
        // whether Return would ask instead (Ask on Page, --ask, in a conversation with
        // --conversation; Windows has no Ask on Page yet), and its frame in a window WIDTH points wide.
        std::vector<std::string> words;
        std::optional<FindResult> result;
        double width = 1280;
        bool ask = false, conversation = false;
        const auto whole = [](std::string_view text, auto& value) {
            const auto [end, error] = std::from_chars(text.data(), text.data() + text.size(), value);
            return !text.empty() && error == std::errc() && end == text.data() + text.size();
        };
        for (size_t i = 1; i < args.size(); ++i) {
            if (args[i] == "--result" && i + 1 < args.size()) {
                const std::string_view report = args[++i];
                const size_t slash = report.find('/');
                int active = -1, total = -1;
                if (slash == std::string_view::npos || !whole(report.substr(0, slash), active) || !whole(report.substr(slash + 1), total) ||
                    active < 0 || total < active || (total > 0 && active < 1)) {
                    return Usage();
                }
                result = FindResult{total > 0, total, active};
            } else if (args[i] == "--width" && i + 1 < args.size()) {
                if (!whole(args[++i], width) || !(width >= 1 && width <= 8192)) return Usage();
            } else if (args[i] == "--ask") {
                ask = true;
            } else if (args[i] == "--conversation") {
                conversation = true;
            } else {
                words.push_back(args[i]);
            }
        }
        FindQuery query;
        query.askEnabled = ask;
        const FindQuery::Search search = query.TextChanged(Join(words, 0));
        if (result) query.Show(*result);
        const FindBarFrame frame = FindBarFrameIn(title_bar::kSidebarWidth, title_bar::kContentTop, width - sidebar_toggle::kContentInset,
                                                  find_bar_style::ForAskEnabled(ask));
        json::Object o{{"placeholder", ask_on_page::Placeholder(ask, conversation)},
                       {"search", json::Object{{"text", search.text}, {"forward", search.forward}, {"findNext", search.findNext}}},
                       {"label", query.Label()},
                       {"notFound", query.LabelIsNotFound()},
                       {"askMode", ask_on_page::IsAskMode(ask, query.Query(), query.Matches(), conversation)},
                       {"frame", json::Object{{"left", frame.left}, {"top", frame.top}, {"width", frame.width}, {"height", frame.height}}}};
        std::puts(json::Write(json::Value(std::move(o))).c_str());
        return kOk;
    } else if (command == "undo") {
        // A text field's undo (core/TextUndo, as Kite's fields group it): STEP is type:TEXT (a
        // keystroke a character), back (Backspace), paste:TEXT, move (the caret moved), undo or
        // redo; prints the text after each step.
        TextUndo<std::string> history;
        std::string text;
        json::Array texts;
        for (size_t i = 1; i < args.size(); ++i) {
            const std::string_view step = args[i];
            if (step.starts_with("type:")) {
                for (const std::u32string& character : unicode::Characters(step.substr(5))) {
                    history.Record(text, TextUndo<std::string>::Kind::Typing);
                    text += unicode::Encode(character);
                }
            } else if (step == "back") {
                if (text.empty()) continue;
                history.Record(text, TextUndo<std::string>::Kind::Typing);
                text.resize(text.size() - unicode::Encode(unicode::Characters(text).back()).size());
            } else if (step.starts_with("paste:")) {
                history.Record(text, TextUndo<std::string>::Kind::Other);
                text += step.substr(6);
            } else if (step == "move") {
                history.BreakTyping();
            } else if (step == "undo" || step == "redo") {
                if (auto to = step == "undo" ? history.Undo(text) : history.Redo(text)) text = *to;
            } else {
                return Usage();
            }
            texts.emplace_back(text);
        }
        std::puts(json::Write(json::Value(std::move(texts))).c_str());
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
                // Back to Pinned URL on hover: a pinned tab off its pinned page.
                o.emplace("canReset", row.canReset);
                if (row.renamed) o.emplace("renamed", true);
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
        // The top row over the address field (sidebar points), for the page given with --page, and
        // where the sidebar and the card's leading edge sit, shown or hidden (window points).
        json::Array topRow;
        for (const TopRowItem& item : LayOutTopRow(240, TopRowModelOf(state, page))) {
            json::Object button{{"button", std::string(TopRowButtonName(item.button))},
                                {"symbol", item.symbol},
                                {"tooltip", item.tooltip},
                                {"enabled", item.enabled},
                                {"opacity", static_cast<double>(item.Opacity())},
                                {"left", static_cast<double>(item.frame.left)},
                                {"top", static_cast<double>(item.frame.top)},
                                {"width", static_cast<double>(item.frame.Width())},
                                {"height", static_cast<double>(item.frame.Height())}};
            button.emplace("command", TopRowCommand(item.button));
            topRow.emplace_back(std::move(button));
        }
        // The favorites over the page (FavoritesTrayView), for a 240pt sidebar.
        const FavoritesTray tray =
            LayOutFavorites(state, *space, 240, flags.Get(OneShotFlags::kFavoritesEmptyStateDismissed));
        const auto frameOf = [](json::Object& o, const BarRect& r) {
            o.emplace("left", static_cast<double>(r.left));
            o.emplace("top", static_cast<double>(r.top));
            o.emplace("width", static_cast<double>(r.Width()));
            o.emplace("height", static_cast<double>(r.Height()));
        };
        json::Array tiles;
        for (const FavoriteTile& tile : tray.tiles) {
            json::Array panes;
            for (const FavoritePane& pane : tile.panes) {
                json::Object p{{"id", pane.tabID}, {"title", pane.title}, {"selected", pane.selected}};
                if (pane.favicon.url) p.emplace("favicon", *pane.favicon.url);
                // Its fill at rest, with no favicon colour known (kitecore decodes no icons).
                const FavoriteLook look = FavoriteLookOf(pane.selected, false, !PrefersDarkForeground(state.spaces[*space].theme), false);
                p.emplace("fill", static_cast<double>(look.fill));
                frameOf(p, pane.frame);
                panes.emplace_back(std::move(p));
            }
            json::Object t{{"id", tile.id}, {"split", tile.split}, {"panes", json::Value(std::move(panes))}};
            if (tile.split) t.emplace("vertical", tile.vertical);
            frameOf(t, tile.frame);
            tiles.emplace_back(std::move(t));
        }
        json::Object favorites{{"columns", tray.columns},
                               {"height", static_cast<double>(tray.height)},
                               {"listTop", static_cast<double>(SidebarListTop(tray))},
                               {"tiles", json::Value(std::move(tiles))}};
        if (tray.emptyState) {
            json::Object empty{{"title", std::string(favorites_empty::kTitle)}, {"subtitle", std::string(favorites_empty::kSubtitle)}};
            frameOf(empty, tray.emptyFrame);
            json::Object close{{"tooltip", std::string(favorites_empty::kCloseTooltip)}};
            frameOf(close, tray.closeFrame);
            empty.emplace("close", json::Value(std::move(close)));
            favorites.emplace("emptyState", json::Value(std::move(empty)));
        }
        json::Object out{{"address", AddressFieldText(state)},
                         {"topRow", json::Value(std::move(topRow))},
                         {"favorites", json::Value(std::move(favorites))},
                         {"shown", !hidden},
                         {"sidebarLeft", static_cast<double>(SidebarLeft(!hidden, 240))},
                         {"cardLeft", static_cast<double>(CardLeft(!hidden, 240))},
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
        const std::vector<TopRowItem> topRow = LayOutTopRow(240, TopRowModelOf(state, page));
        const FavoritesTray tray =
            LayOutFavorites(state, state.SelectedSpaceIndex(), 240, flags.Get(OneShotFlags::kFavoritesEmptyStateDismissed));
        const float listTop = SidebarListTop(tray);
        // The space bar along the bottom: a click on a space's cell selects it (pressed and let
        // go at the point, as the window's).
        if (right) {
            // A right-click (or a Ctrl+click, the Mac's ⌃-click): the menu the window opens there,
            // as the window asks (SidebarView::MenuTargetAt): a space's cell, a favorite's pane, then
            // the page's header (the space's menu), a tab's row or a folder's. Nothing changes.
            json::Object out{{"target", std::string("none")}};
            const auto put = [&](const char* kind, const std::string& id, const std::string& line) {
                out["target"] = json::Value(std::string("menu"));
                out.emplace("kind", std::string(kind));
                out.emplace("id", id);
                out.emplace("line", line);
            };
            const float x = values[0], y = values[1];
            if (x >= 0 && x < 240 && y >= SpaceBarTop(values[2]) && y < values[2]) {
                const std::vector<SpaceCell> cells = SpaceCells(state);
                const SpaceBarLayout layout = LayOutSpaceBar(240, cells.size());
                if (const auto press = SpaceBarPressAt(layout, cells, x, y - SpaceBarTop(values[2]))) {
                    put("space", press->spaceID, SpaceMenuLine(SpaceMenu(state, press->spaceID)));
                }
            } else if (x >= 0 && x < 240 && InFavorites(tray, 240, x, y)) {
                if (const auto pane = FavoritePressAt(tray, x, y); pane && pane->target == FavoritePress::Target::Pane) {
                    put("favorite", pane->tabID, SidebarMenuLine(FavoriteMenu(state, pane->tabID)));
                }
            } else if (x >= 0 && x < 240 && !TopRowItemAt(topRow, x, y)) {
                if (const auto target = SidebarMenuTargetAt(rows, 240, values[2], values[3], x, y, listTop)) {
                    switch (target->kind) {
                    case SidebarMenuTarget::Kind::Space: put("space", target->id, SpaceMenuLine(SpaceMenu(state, target->id))); break;
                    case SidebarMenuTarget::Kind::Tab: put("tab", target->id, SidebarMenuLine(TabMenu(state, target->id))); break;
                    case SidebarMenuTarget::Kind::Folder: put("folder", target->id, SidebarMenuLine(FolderMenu(state, target->id))); break;
                    case SidebarMenuTarget::Kind::Favorite:
                    case SidebarMenuTarget::Kind::None: break;  // New Tab: no menu
                    }
                    // On one of the row's buttons, which a Ctrl+click presses instead.
                    if (target->button) out.emplace("button", true);
                }
            }
            std::puts(json::Write(json::Value(std::move(out))).c_str());
        } else if (middle) {
            // A middle click (Windows' close-a-tab click): a tab's row closes as its close button
            // does; anything else (the top row, the bar, a favorite, a folder, the header) takes nothing.
            const auto press = values[0] >= 0 && values[0] < 240 && !TopRowItemAt(topRow, values[0], values[1]) &&
                                       !(values[1] >= SpaceBarTop(values[2]) && values[1] < values[2]) &&
                                       !InFavorites(tray, 240, values[0], values[1])
                                   ? SidebarMiddlePressAt(rows, 240, values[2], values[3], values[0], values[1], listTop)
                                   : std::nullopt;
            json::Object out{{"target", std::string(press ? "row" : "none")}};
            if (press) {
                out.emplace("id", press->id);
                const SidebarTap tap = SidebarMiddleRelease(*press, rows, 240, values[2], values[3], values[0], values[1], listTop);
                out.emplace("action", std::string(tap.action == SidebarTap::Action::CloseTab ? "closeTab" : "none"));
                if (tap.action == SidebarTap::Action::CloseTab) {
                    out.emplace("outcome", std::string(OutcomeName(state.Close(tap.id))));
                    changed = true;
                }
            }
            std::puts(json::Write(json::Value(std::move(out))).c_str());
        } else if (const auto button = values[0] >= 0 && values[0] < 240 ? TopRowItemAt(topRow, values[0], values[1]) : std::nullopt) {
            // A top-row button: the command the window runs (nothing for a disabled one). Toggle
            // Sidebar and the page's commands are the window's, so nothing here changes.
            const TopRowItem& item = topRow[*button];
            json::Object out{{"target", std::string("topRow")}, {"button", std::string(TopRowButtonName(item.button))}, {"enabled", item.enabled}};
            out.emplace("action", item.enabled ? TopRowCommand(item.button) : std::string("none"));
            std::puts(json::Write(json::Value(std::move(out))).c_str());
        } else if (values[1] >= SpaceBarTop(values[2]) && values[1] < values[2]) {
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
        } else if (InFavorites(tray, 240, values[0], values[1])) {
            // The tray's band: a pane's press selects its favorite on release (FavoritePaneView's
            // mouseUp), the empty state's close button dismisses it; the rest takes the press and
            // does nothing.
            const auto press = FavoritePressAt(tray, values[0], values[1]);
            const bool close = press && press->target == FavoritePress::Target::CloseEmptyState;
            json::Object out{{"target", std::string(close ? "favoritesClose" : press ? "favorite" : "favorites")}};
            if (press) {
                if (!close) out.emplace("id", press->tabID);
                const FavoriteTap tap = FavoriteRelease(*press, tray, values[0], values[1]);
                out.emplace("action", std::string(tap.action == FavoriteTap::Action::SelectTab           ? "selectTab"
                                                  : tap.action == FavoriteTap::Action::DismissEmptyState ? "dismissEmptyState"
                                                                                                         : "none"));
                if (tap.action == FavoriteTap::Action::SelectTab) {
                    state.Select(tap.tabID);
                    changed = true;
                } else if (tap.action == FavoriteTap::Action::DismissEmptyState) {
                    if (const std::string problem = flags.Set(OneShotFlags::kFavoritesEmptyStateDismissed, true); !problem.empty()) {
                        std::fprintf(stderr, "kitecore: %s\n", problem.c_str());
                        return kLoadFailed;
                    }
                }
            }
            std::puts(json::Write(json::Value(std::move(out))).c_str());
        } else {
            const auto press = SidebarPressAt(rows, 240, values[2], values[3], values[0], values[1], clicks, false, listTop);
            static constexpr const char* kTargets[] = {"none", "addressField", "row", "pinnedChevron", "closeButton", "resetButton"};
            static constexpr const char* kActions[] = {"none",   "editAddress", "togglePinnedSection", "selectTab", "setFolderExpanded",
                                                       "newTab", "closeTab",    "resetTab"};
            json::Object out{{"target", std::string(kTargets[static_cast<int>(press ? press->target : SidebarHit::Target::None)])}};
            if (press) {
                if (!press->id.empty()) out.emplace("id", press->id);
                // The second press of a double-click on a tab's row opens its rename field as it goes
                // down (the window's); its release taps nothing.
                if (SidebarRenameOnPress(*press)) out.emplace("pressed", std::string("renameTab"));
                const SidebarTap tap = SidebarRelease(*press, rows, 240, values[2], values[3], values[0], values[1], listTop);
                out.emplace("action", std::string(kActions[static_cast<int>(tap.action)]));
                switch (tap.action) {
                case SidebarTap::Action::SelectTab: state.Select(tap.id); changed = true; break;
                case SidebarTap::Action::SetFolderExpanded: state.SetFolderExpanded(tap.id, tap.expanded); changed = true; break;
                case SidebarTap::Action::TogglePinnedSection: TogglePinnedSection(state, tap.id); changed = true; break;
                case SidebarTap::Action::CloseTab:
                    out.emplace("outcome", std::string(OutcomeName(state.Close(tap.id))));
                    changed = true;
                    break;
                case SidebarTap::Action::ResetTab:
                    if (const auto url = state.ResetTab(tap.id)) out.emplace("url", *url);
                    changed = true;
                    break;
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
    } else if (command == "tab" && args.size() >= 2 && !(args.size() == 2 && (args[1] == "next" || args[1] == "prev" ||
                                                                          (args[1].size() == 1 && args[1][0] >= '1' && args[1][0] <= '9')))) {
        // The tab edits (see the top of this file).
        const std::string& action = args[1];
        if (action == "reset-all" && args.size() == 2) {
            const auto reset = state.ResetPinnedTabs();
            if (reset.empty()) return kRefused;
            for (const auto& [id, url] : reset) std::printf("%s %s\n", id.c_str(), url.c_str());
        } else {
            if (args.size() < 3) return Usage();
            const std::string id = Id(args[2]);
            if (!state.Location(id)) return kNotFound;
            const auto where = [&] {
                const TabSection section = state.Location(id)->section;
                return section == TabSection::Pinned ? "pinned" : section == TabSection::Unpinned ? "unpinned" : "favorite";
            };
            if (action == "pin" && args.size() == 3) {
                state.TogglePin(id);
                std::puts(where());
            } else if (action == "favorite" && args.size() == 3) {
                state.ToggleFavorite(id);
                std::puts(where());
            } else if (action == "rename") {
                state.RenameTab(id, Join(args, 3));
                std::puts(state.FindTabByID(id)->DisplayTitle().c_str());
            } else if (action == "duplicate" && args.size() == 3) {
                std::puts(state.Duplicate(id)->c_str());
            } else if (action == "reset" && args.size() == 3) {
                const auto url = state.ResetTab(id);
                if (!url) return kRefused;
                std::puts(url->c_str());
            } else if (action == "separate" && args.size() == 3) {
                const auto made = state.SeparateFromPinnedTab(id);
                if (!made) return kRefused;
                std::puts(made->c_str());
            } else if (action == "reveal" && args.size() == 3) {
                const auto row = state.RevealTab(id);
                if (!row) return kRefused;
                std::puts(row->c_str());
            } else if (action == "pinned-url" && args.size() >= 4) {
                if (!state.EditPinnedURL(id, Join(args, 3))) return kRefused;
                std::puts(state.FindTabByID(id)->pinnedURL->c_str());
            } else if (action == "replace-pin" && args.size() == 3) {
                if (!state.ReplacePinnedURLWithCurrent(id)) return kRefused;
                std::puts(state.FindTabByID(id)->pinnedURL->c_str());
            } else {
                return Usage();
            }
        }
        changed = true;
    } else if (command == "folder" && args.size() >= 2) {
        const std::string& action = args[1];
        if (action == "new" && args.size() <= 3) {
            const auto space = args.size() == 3 ? state.SpaceIndex(Id(args[2])) : std::optional<size_t>(state.SelectedSpaceIndex());
            if (!space) return kNotFound;
            std::puts(state.CreateNewFolder(*space).c_str());
        } else if (action == "rename" && args.size() >= 4) {
            const auto found = state.FolderMatching(args[2]);
            if (!found) return kNotFound;
            const std::string id = found->folder->id;
            state.RenameFolder(id, Join(args, 3));
            std::puts(state.FolderByID(id)->name.c_str());
        } else if (action == "delete" && args.size() == 3) {
            const auto found = state.FolderMatching(args[2]);
            if (!found) return kNotFound;
            const std::string id = found->folder->id;
            for (const Tab& tab : state.DeleteFolder(id)) std::puts(tab.id.c_str());
        } else if (action == "move" && args.size() == 4) {
            const std::string tab = Id(args[2]);
            const auto location = state.Location(tab);
            const auto found = state.FolderMatching(args[3]);
            if (!location || !found) return kNotFound;
            // Favorites stay where they are (moveTab(_:toFolder:)).
            if (location->section == TabSection::Favorite) return kRefused;
            if (!state.MoveTabToFolder(tab, std::string(found->folder->id))) return kNotFound;
        } else {
            return Usage();
        }
        changed = true;
    } else if (command == "menu" && args.size() >= 3) {
        // A row's menu as the window shows it (core/SidebarContextMenu.h), and with --pick an item
        // of it run as the window runs it (the Mac's KITE_TEST_CONTEXT_MENU pick).
        std::optional<std::string> pick;
        if (args.size() >= 5 && args[3] == "--pick") pick = Join(args, 4);
        else if (args.size() != 3) return Usage();
        static const std::map<std::string, SidebarMenuKind> kinds{
            {"tab", SidebarMenuKind::Tab}, {"folder", SidebarMenuKind::Folder}, {"favorite", SidebarMenuKind::Favorite}};
        const auto kind = kinds.find(args[1]);
        if (kind == kinds.end()) return Usage();
        std::string id = Id(args[2]);
        if (kind->second == SidebarMenuKind::Folder) {
            const auto found = state.FolderMatching(args[2]);
            if (!found) return kNotFound;
            id = found->folder->id;
        }
        const std::vector<SidebarMenuItem> menu = SidebarMenu(state, kind->second, id);
        if (menu.empty()) return kNotFound;
        if (!pick) {
            std::puts(json::Write(json::Object{{"items", MenuItemsJson(menu)}, {"line", SidebarMenuLine(menu)}}).c_str());
            return kOk;
        }
        const SidebarMenuItem* item = PickSidebarMenuItem(menu, *pick);
        if (!item) return kRefused;
        json::Object out{{"picked", item->title}};
        if (const std::string problem = RunMenuItem(state, id, *item, out); !problem.empty()) {
            std::fprintf(stderr, "kitecore: %s\n", problem.c_str());
            return kRefused;
        }
        std::puts(json::Write(json::Value(std::move(out))).c_str());
        changed = true;
    } else if (command == "shown" && (args.size() == 3 || args.size() == 4)) {
        static const std::map<std::string, SidebarRow::Kind> kinds{{"header", SidebarRow::Kind::Header},   {"tab", SidebarRow::Kind::Tab},
                                                                   {"folder", SidebarRow::Kind::Folder},   {"divider", SidebarRow::Kind::Divider},
                                                                   {"newTab", SidebarRow::Kind::NewTab}};
        const auto kind = kinds.find(args[1]);
        if (kind == kinds.end()) return Usage();
        const auto space = args.size() == 4 ? state.SpaceIndex(Id(args[3])) : std::optional<size_t>(state.SelectedSpaceIndex());
        if (!space) return kNotFound;
        std::puts(SidebarShowsRow(state, *space, kind->second, Id(args[2])) ? "yes" : "no");
        return kOk;
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
        std::puts(OutcomeName(outcome));
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
        if (action == "swipe" && (args.size() == 3 || args.size() == 4)) {
            double values[2] = {0, 0.25};
            for (size_t i = 2; i < args.size(); ++i) {
                auto [end, error] = std::from_chars(args[i].data(), args[i].data() + args[i].size(), values[i - 2]);
                if (error != std::errc() || end != args[i].data() + args[i].size()) return Usage();
            }
            if (!std::isfinite(values[0]) || !std::isfinite(values[1]) || values[1] < 0) return Usage();
            // The window's sidebar, the pages at rest.
            const size_t index = state.SelectedSpaceIndex();
            const SwipeStart start{240, index > 0, index + 1 < state.spaces.size(), 0};
            SpaceSwipeGesture gesture;
            const auto begin = [&] { return start; };
            const int events = std::max(1, static_cast<int>(std::lround(values[1] * 60)));
            gesture.Handle(SwipeInput{SwipeInput::Phase::Began, 0, 0, 0}, true, begin);
            for (int i = 1; i <= events; ++i) {
                gesture.Handle(SwipeInput{SwipeInput::Phase::Changed, values[0] / events, 0, i / 60.0}, true, begin);
            }
            json::Object out;
            if (const auto& swipe = gesture.Swipe()) {
                out.emplace("offset", swipe->Offset());
                out.emplace("progress", swipe->Progress());
                out.emplace("direction", static_cast<double>(swipe->Direction()));
            }
            gesture.Handle(SwipeInput{SwipeInput::Phase::Ended, 0, 0, (events + 1) / 60.0}, true, begin);
            out.emplace("landing", static_cast<double>(gesture.Landing()));
            state.SelectSpaceAt(index + static_cast<size_t>(gesture.Landing()));
            out.emplace("space", state.SelectedSpace().id);
            std::puts(json::Write(json::Value(std::move(out))).c_str());
        } else if (action == "next") state.SelectAdjacentSpace(1);
        else if (action == "prev") state.SelectAdjacentSpace(-1);
        else if (args.size() == 2 && action.size() == 1 && action[0] >= '1' && action[0] <= '9') {
            // Space 1–9 (the Mac's selectSpaceNumber): nothing past the last space.
            state.SelectSpaceAt(static_cast<size_t>(action[0] - '1'));
        }
        else if (action == "select" && args.size() == 3) {
            const std::string id = Id(args[2]);
            if (!state.SpaceIndex(id)) return kNotFound;
            state.SelectSpace(id);
        } else if (action == "menu" && args.size() == 3) {
            const std::vector<SpaceMenuItem> menu = SpaceMenu(state, Id(args[2]));
            if (menu.empty()) return kNotFound;
            json::Array items;
            for (const SpaceMenuItem& item : menu) {
                if (item.command == SpaceMenuItem::Command::Separator) {
                    items.emplace_back(json::Object{{"separator", true}});
                    continue;
                }
                items.emplace_back(json::Object{{"title", item.title}, {"enabled", item.enabled}, {"submenu", item.submenu}});
            }
            std::puts(json::Write(json::Object{{"items", json::Value(std::move(items))}, {"line", SpaceMenuLine(menu)}}).c_str());
            return kOk;
        } else if (action == "rename" && args.size() >= 4) {
            const std::string id = Id(args[2]);
            if (!state.SpaceIndex(id)) return kNotFound;
            state.RenameSpace(id, Join(args, 3));
            std::puts(state.spaces[*state.SpaceIndex(id)].name.c_str());
        } else if (action == "icon" && args.size() == 4) {
            const std::string id = Id(args[2]);
            if (!state.SpaceIndex(id)) return kNotFound;
            state.SetSpaceIcon(id, args[3]);
            std::puts(state.spaces[*state.SpaceIndex(id)].icon.c_str());
        } else if (action == "folder" && args.size() == 3) {
            const auto space = state.SpaceIndex(Id(args[2]));
            if (!space) return kNotFound;
            std::puts(state.CreateNewFolder(*space).c_str());
        } else if (action == "delete" && args.size() == 3) {
            const std::string id = Id(args[2]);
            if (!state.SpaceIndex(id)) return kNotFound;
            const SpaceDeletion deletion = DeletionOf(state, id);
            if (deletion.kind == SpaceDeletion::Kind::Refused) return kRefused;
            json::Object out{{"kind", std::string(deletion.kind == SpaceDeletion::Kind::Now ? "now" : "ask")}};
            if (deletion.kind == SpaceDeletion::Kind::Ask) {
                out.emplace("title", deletion.title);
                out.emplace("message", deletion.message);
            }
            state.DeleteSpace(id);
            out.emplace("selected", state.selectedSpaceID);
            std::puts(json::Write(json::Value(std::move(out))).c_str());
        } else if (action == "new" && args.size() >= 3) {
            const auto id = NewSpace(state, Join(args, 2));
            if (!id) return Usage();
            std::puts(id->c_str());
        } else if (action == "move" && args.size() == 4) {
            const std::string id = Id(args[2]);
            size_t place = 0;
            auto [end, error] = std::from_chars(args[3].data(), args[3].data() + args[3].size(), place);
            if (error != std::errc() || end != args[3].data() + args[3].size() || place == 0) return Usage();
            if (!state.SpaceIndex(id)) return kNotFound;
            state.MoveSpace(id, place - 1);
            std::puts(std::to_string(*state.SpaceIndex(id) + 1).c_str());
        } else if (action == "drag" && (args.size() == 4 || args.size() == 5)) {
            const std::string id = Id(args[2]);
            float point[2] = {0, space_bar_metrics::kHeight / 2};
            for (size_t i = 3; i < args.size(); ++i) {
                auto [end, error] = std::from_chars(args[i].data(), args[i].data() + args[i].size(), point[i - 3]);
                if (error != std::errc() || end != args[i].data() + args[i].size() || !std::isfinite(point[i - 3])) return Usage();
            }
            const auto index = state.SpaceIndex(id);
            if (!index) return kNotFound;
            const std::vector<SpaceCell> cells = SpaceCells(state);
            const SpaceBarLayout layout = LayOutSpaceBar(240, cells.size());
            const BarRect& cell = layout.cells[*index];
            const float x0 = (cell.left + cell.right) / 2, y0 = (cell.top + cell.bottom) / 2;
            auto press = SpaceBarPressAt(layout, cells, x0, y0);
            if (!press) return kNotFound;
            SpaceBarMove(*press, point[0], point[1]);
            auto drag = BeginSpaceDrag(layout, cells, *press);
            // One space, or a drag shorter than 4pt: a click, not a drag.
            if (!drag) return Usage();
            MoveSpaceDrag(*drag, layout, cells.size(), point[0], point[1]);
            std::vector<std::string> ids;
            for (const SpaceCell& c : cells) ids.push_back(c.spaceID);
            const std::vector<BarRect> placed = SpaceDragCells(layout, ids, *drag);
            json::Array strip;
            for (size_t i = 0; i < ids.size(); ++i) {
                strip.emplace_back(json::Object{{"id", ids[i]}, {"left", static_cast<double>(placed[i].left)}, {"hidden", ids[i] == id}});
            }
            const BarRect ghost = SpaceDragGhost(layout, *drag);
            json::Object out{{"target", drag->target ? json::Value(static_cast<double>(*drag->target)) : json::Value()},
                             {"cells", json::Value(std::move(strip))},
                             {"ghost", json::Object{{"left", static_cast<double>(ghost.left)}, {"top", static_cast<double>(ghost.top)}}}};
            const size_t slot = DropSpaceDrag(*drag, layout, cells.size(), point[0], point[1]);
            out.emplace("landing", static_cast<double>(slot));
            state.MoveSpace(id, slot);
            std::puts(json::Write(json::Value(std::move(out))).c_str());
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
        std::variant<arc_import::Plan, arc_import::LoadError> plan = arc_import::LoadError{};
        try {
            plan = picked ? arc_import::ReadPicked(*picked, arcDirectory) : arc_import::ReadAuto(arcDirectory);
        } catch (const std::exception& e) {
            plan = arc_import::ReadFailed(e.what());
        } catch (...) {
            plan = arc_import::ReadFailed(nullptr);
        }
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
        // Then each Arc profile's history, into the stores the app keeps (history.json, and
        // Chromium/<dir>/Kite History.json for another profile), written before the summary.
        HistoryStores stores(std::get<std::filesystem::path>(resolved));
        stores.Start();
        if (!arc_import::MergeHistories(imported, stores, std::chrono::seconds(60))) {
            std::fputs("kitecore: history: the profiles' history files weren't read within 60 s, so Arc's history wasn't merged\n", stderr);
            return kSaveFailed;
        }
        stores.SaveNow();
        if (std::string error = stores.Flush(DeadlineAfter(std::chrono::seconds(60))); !error.empty()) {
            std::fprintf(stderr, "kitecore: history: %s\n", error.c_str());
            return kSaveFailed;
        }
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
        // A tab pinned by any path (a move into a folder too) remembers its page, as the Mac's
        // BrowserStore.mutate syncs after every change.
        state.SyncPinnedURLs();
        if (std::string error = store.Save(state); !error.empty()) {
            std::fprintf(stderr, "kitecore: %s\n", error.c_str());
            return kSaveFailed;
        }
    }
    return kOk;
}
