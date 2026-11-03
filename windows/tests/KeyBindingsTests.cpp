// Ports of KiteCore's KeyBindingsTests (KeyBindings.swift, ShortcutPriorityGate.swift), the tab
// number and cycling tests (KiteCoreTests.tabNumbersAndCycling, SplitViewTests.
// tabNumbersCountASplitOnce), and Windows' command table.

#include <algorithm>

#include "Check.h"
#include "core/KeyBindings.h"
#include "core/Models.h"

using namespace kite;
using M = KeyShortcut::Modifier;

namespace {

const KeyShortcut kShiftCmdS("s", {M::Shift, M::Command});
const KeyShortcut kCmdL("l", {M::Command});

KeyBindings RoundTrip(const KeyBindings& bindings) {
    auto parsed = json::Parse(json::Write(bindings.ToJson()));
    auto* value = std::get_if<json::Value>(&parsed);
    if (!value) return {};
    return KeyBindings::FromJson(*value).value_or(KeyBindings{});
}

KeyBindings Parse(std::string_view text) {
    auto parsed = json::Parse(text);
    return KeyBindings::FromJson(std::get<json::Value>(parsed)).value_or(KeyBindings{});
}

}  // namespace

TEST(displaysLikeMenus) {
    CHECK(kShiftCmdS.MacDisplayString() == "⇧⌘S");
    CHECK(KeyShortcut("right", {M::Option, M::Command}).MacDisplayString() == "⌥⌘→");
    CHECK(KeyShortcut("C", {M::Control, M::Command, M::Shift}).MacDisplayString() == "⌃⇧⌘C");
    // Windows' own way.
    CHECK(KeyShortcut("t", {M::Shift, M::Control}).DisplayString() == "Ctrl+Shift+T");
    CHECK(KeyShortcut("down", {M::Option, M::Control}).DisplayString() == "Ctrl+Alt+Down");
    CHECK(KeyShortcut("f5", {}).DisplayString() == "F5");
}

TEST(roundTripsThroughJSON) {
    KeyBindings bindings;
    bindings.Set({"addSplitView", kCmdL, KeyBindingOverride::Source::Arc, std::nullopt});
    bindings.Set({"toggleSidebar", std::nullopt, KeyBindingOverride::Source::User, std::nullopt});
    bindings.Set({"pinTab", std::nullopt, KeyBindingOverride::Source::User, KeyShortcutPriority::Low});
    CHECK(RoundTrip(bindings) == bindings);
}

TEST(oneOverridePerAction) {
    KeyBindings bindings;
    bindings.Set({"nextSpace", kCmdL});
    bindings.Set({"nextSpace", kShiftCmdS});
    CHECK(bindings.UserOverrides().size() == 1);
    CHECK(bindings.Override("nextSpace")->shortcut == kShiftCmdS);
    bindings.Reset("nextSpace");
    CHECK(bindings.UserOverrides().empty());
}

TEST(overrideTakesTheShortcutFromOtherCommands) {
    const std::map<std::string, std::optional<KeyShortcut>> defaults{
        {"openLocation", kCmdL},
        {"addSplitView", std::nullopt},
        {"toggleSidebar", KeyShortcut("s", {M::Command})},
    };
    const KeyBindings bindings({
        {"addSplitView", kCmdL},
        {"toggleSidebar", std::nullopt},
        {"notAKiteCommand", kShiftCmdS},
    });
    const auto resolved = bindings.Resolve(defaults);
    CHECK(resolved.at("addSplitView") == kCmdL);
    CHECK(!resolved.at("openLocation"));
    CHECK(!resolved.at("toggleSidebar"));
    CHECK(!resolved.contains("notAKiteCommand"));
}

TEST(prioritiesDefaultToArcs) {
    const KeyBindings bindings;
    CHECK(bindings.Priority("newTab") == KeyShortcutPriority::OverrideWebView);
    CHECK(bindings.Priority("addSplitView") == KeyShortcutPriority::PromptAfterConsumedByWebView);
    CHECK(bindings.Priority("find") == KeyShortcutPriority::Low);
    CHECK(bindings.Priority("askClaude") == KeyShortcutPriority::Low);
}

TEST(priorityKeepsTheShortcutAndShortcutKeepsThePriority) {
    KeyBindings bindings;
    const KeyShortcut cmdT("t", {M::Command});
    bindings.SetPriority(KeyShortcutPriority::Low, "newTab", cmdT);
    CHECK(*bindings.Override("newTab") == (KeyBindingOverride{"newTab", cmdT, KeyBindingOverride::Source::User, KeyShortcutPriority::Low}));
    bindings.SetShortcut(kCmdL, "newTab");
    CHECK(bindings.Priority("newTab") == KeyShortcutPriority::Low);
    CHECK(bindings.Override("newTab")->shortcut == kCmdL);
    // Back to the default priority: none stored.
    bindings.SetPriority(KeyShortcutPriority::OverrideWebView, "newTab", kCmdL);
    CHECK(!bindings.Override("newTab")->priority);
    CHECK(bindings.Override("newTab")->shortcut == kCmdL);
}

TEST(readsFilesFromBeforePriorities) {
    const KeyBindings old = Parse(
        R"({"version":1,"userOverrides":[{"action":"addSplitView","shortcut":{"key":"l","modifiers":["command"]},"source":"arc"}]})");
    CHECK(*old.Override("addSplitView") == (KeyBindingOverride{"addSplitView", kCmdL, KeyBindingOverride::Source::Arc, std::nullopt}));
    const KeyBindings unknown = Parse(R"({"version":1,"userOverrides":[{"action":"pinTab","source":"user","priority":"somethingNew"}]})");
    CHECK(unknown.Priority("pinTab") == KeyShortcutPriority::PromptAfterConsumedByWebView);
    // Not a key bindings file, and an override it can't read (skipped, the rest kept).
    CHECK(!KeyBindings::FromJson(json::Value(json::Array{})));
    const KeyBindings mixed = Parse(
        R"({"version":1,"userOverrides":[{"action":"a","shortcut":{"key":"l","modifiers":["hyper"]},"source":"user"},)"
        R"({"action":"b","shortcut":{"key":"l","modifiers":["control"]},"source":"user"}]})");
    CHECK(mixed.UserOverrides().size() == 1);
    CHECK(mixed.Override("b")->shortcut == KeyShortcut("l", {M::Control}));
}

TEST(secondPressRunsKitesCommand) {
    ShortcutPriorityGate gate;
    CHECK(!gate.Press("pinTab", 1, 10, false));
    CHECK(gate.PageConsumed("pinTab", 1, 10));
    CHECK(!gate.PageConsumed("pinTab", 1, 10));
    // Held down: repeats don't count.
    CHECK(!gate.Press("pinTab", 1, 10.5, true));
    CHECK(gate.Press("pinTab", 1, 12, false));
    // Then it starts over.
    CHECK(!gate.Press("pinTab", 1, 12.5, false));
}

TEST(secondPressOnlyCountsSoonInTheSameWindowAfterAKeptKey) {
    ShortcutPriorityGate gate;
    gate.Press("pinTab", 1, 10, false);
    CHECK(!gate.Press("pinTab", 2, 11, false));
    CHECK(!gate.Press("pinTab", 2, 20, false));
    // The page passed it on: the command ran, so there's nothing to ask.
    gate.CommandRan("pinTab");
    CHECK(!gate.PageConsumed("pinTab", 2, 20));
    CHECK(!gate.Press("pinTab", 2, 21, false));
    CHECK(ShortcutPriorityGate::Prompt(KeyShortcut("d", {M::Control}), "Pin Tab") == "Press Ctrl+D again to Pin Tab");
    CHECK(ShortcutPriorityGate::Prompt(KeyShortcut("l", {M::Control}), "Print…") == "Press Ctrl+L again to Print");
}

TEST(onlyModifiedShortcutsAreSafeKeyEquivalents) {
    CHECK(kCmdL.IsSafeKeyEquivalent());
    CHECK(KeyShortcut("e", {M::Option}).IsSafeKeyEquivalent());
    CHECK(!KeyShortcut("e", {}).IsSafeKeyEquivalent());
    CHECK(!KeyShortcut("e", {M::Shift}).IsSafeKeyEquivalent());
    CHECK(!KeyShortcut("escape", {}).IsSafeKeyEquivalent());
    // Windows' function keys run commands on their own (F5, F12).
    CHECK(KeyShortcut("f5", {}).IsSafeKeyEquivalent());
}

TEST(windowsCommandsUseCtrlForCommand) {
    const auto table = ShortcutTable(KeyBindings{});
    CHECK(table.at(KeyShortcut("t", {M::Control})) == "newTab");
    CHECK(table.at(KeyShortcut("t", {M::Control, M::Shift})) == "reopenClosedTab");
    CHECK(table.at(KeyShortcut("w", {M::Control})) == "archiveTab");
    CHECK(table.at(KeyShortcut("1", {M::Control})) == "tab1");
    CHECK(table.at(KeyShortcut("9", {M::Control})) == "lastTab");
    CHECK(table.at(KeyShortcut("[", {M::Control})) == "goBack");
    // Windows' own keys for the same commands.
    CHECK(table.at(KeyShortcut("f5", {})) == "reloadPage");
    CHECK(table.at(KeyShortcut("left", {M::Option})) == "goBack");
    CHECK(table.at(KeyShortcut("f12", {})) == "developerTools");
    // Every shown shortcut holds Ctrl or Alt, or is a function key, so typing never runs one.
    for (const ShortcutCommand& command : ShortcutCommands()) {
        if (command.shortcut) CHECK(command.shortcut->IsSafeKeyEquivalent());
        for (const KeyShortcut& extra : command.more) CHECK(extra.IsSafeKeyEquivalent());
    }
}

TEST(aUsersShortcutWinsOverDefaultsAndExtras) {
    KeyBindings bindings;
    // Ctrl+R to the address field, F5 to nothing new: Refresh keeps F5 but loses Ctrl+R.
    bindings.SetShortcut(KeyShortcut("r", {M::Control}), "openLocation");
    // An extra key taken by another command's shortcut goes to that command.
    bindings.SetShortcut(KeyShortcut("f12", {}), "viewSource");
    const auto table = ShortcutTable(bindings);
    CHECK(table.at(KeyShortcut("r", {M::Control})) == "openLocation");
    CHECK(table.at(KeyShortcut("f5", {})) == "reloadPage");
    CHECK(table.at(KeyShortcut("f12", {})) == "viewSource");
    CHECK(!table.contains(KeyShortcut("u", {M::Control, M::Option})));
}

TEST(tabNumbersAndCycling) {
    BrowserState state = BrowserState::MakeDefault(std::nullopt);
    std::vector<std::string> ids;
    for (int i = 0; i < 4; ++i) ids.insert(ids.begin(), state.OpenTab("https://site" + std::to_string(i) + ".com"));
    state.SelectTabNumber(2);
    CHECK(state.SelectedTab()->id == ids[1]);
    state.SelectTabNumber(9);
    CHECK(state.SelectedTab()->id == ids[3]);
    state.SelectAdjacentTab(1);
    CHECK(state.SelectedTab()->id == ids[0]);
    state.SelectAdjacentTab(-1);
    CHECK(state.SelectedTab()->id == ids[3]);
    // Past the end: nothing changes.
    state.SelectTabNumber(7);
    CHECK(state.SelectedTab()->id == ids[3]);
}

TEST(tabNumbersCountASplitOnce) {
    BrowserState state = BrowserState::MakeDefault(std::nullopt);
    std::vector<std::string> ids;
    for (int i = 0; i < 4; ++i) ids.insert(ids.begin(), state.OpenTab("https://site" + std::to_string(i) + ".com", std::nullopt, true, 100 + i));
    // Sidebar: [split(ids0, ids1)], ids2, ids3; ids1 used last in the split.
    Space& space = state.spaces[state.SelectedSpaceIndex()];
    space.splits.push_back(SplitView{"split", {ids[0], ids[1]}, {0.5, 0.5}, "horizontal", std::nullopt, {}});
    for (Tab& tab : space.tabs) {
        if (tab.id == ids[1]) tab.lastActiveAt = 500;
    }
    state.Select(ids[3], 600);
    CHECK(state.SidebarStops(state.SelectedSpaceIndex()).size() == 3);
    state.SelectTabNumber(2, 700);
    CHECK(state.SelectedTab()->id == ids[2]);
    state.SelectAdjacentTab(-1, 800);
    // Back into the split, at the pane used last.
    CHECK(state.SelectedTab()->id == ids[1]);
    state.SelectAdjacentTab(1, 900);
    CHECK(state.SelectedTab()->id == ids[2]);
}
