// See KeyBindings.h.

#include "core/KeyBindings.h"

#include <algorithm>
#include <set>

namespace kite {

namespace {

using Modifier = KeyShortcut::Modifier;

constexpr std::string_view RawValue(Modifier modifier) {
    switch (modifier) {
    case Modifier::Control: return "control";
    case Modifier::Option: return "option";
    case Modifier::Shift: return "shift";
    case Modifier::Command: return "command";
    }
    return "";
}

std::optional<Modifier> ModifierFromRaw(std::string_view raw) {
    for (Modifier m : {Modifier::Control, Modifier::Option, Modifier::Shift, Modifier::Command}) {
        if (RawValue(m) == raw) return m;
    }
    return std::nullopt;
}

// The Mac's KeyShortcut.namedKeys symbols, and Windows' names for the same keys.
struct NamedKey {
    std::string_view name, mac, windows;
};
constexpr NamedKey kNamedKeys[] = {
    {"left", "←", "Left"},     {"right", "→", "Right"},    {"up", "↑", "Up"},       {"down", "↓", "Down"},
    {"tab", "⇥", "Tab"},       {"return", "↩", "Enter"},   {"delete", "⌫", "Backspace"},
    {"escape", "⎋", "Esc"},    {"space", "Space", "Space"},
};

const NamedKey* FindNamed(std::string_view key) {
    for (const NamedKey& named : kNamedKeys) {
        if (named.name == key) return &named;
    }
    return nullptr;
}

bool IsFunctionKey(std::string_view key) {
    if (key.size() < 2 || key.size() > 3 || key[0] != 'f') return false;
    return std::all_of(key.begin() + 1, key.end(), [](char c) { return c >= '0' && c <= '9'; });
}

std::string Upper(std::string text) {
    for (char& c : text) {
        if (c >= 'a' && c <= 'z') c = static_cast<char>(c - 'a' + 'A');
    }
    return text;
}

KeyShortcut Ctrl(std::string key) { return KeyShortcut(std::move(key), {Modifier::Control}); }
KeyShortcut CtrlShift(std::string key) { return KeyShortcut(std::move(key), {Modifier::Control, Modifier::Shift}); }
KeyShortcut CtrlAlt(std::string key) { return KeyShortcut(std::move(key), {Modifier::Control, Modifier::Option}); }
KeyShortcut Alt(std::string key) { return KeyShortcut(std::move(key), {Modifier::Option}); }
KeyShortcut Bare(std::string key) { return KeyShortcut(std::move(key), {}); }

}  // namespace

// MARK: KeyShortcut

KeyShortcut::KeyShortcut(std::string k, std::vector<Modifier> m) : key(std::move(k)), modifiers(std::move(m)) {
    if (key.size() == 1 && key[0] >= 'A' && key[0] <= 'Z') key[0] = static_cast<char>(key[0] - 'A' + 'a');
    std::sort(modifiers.begin(), modifiers.end());
    modifiers.erase(std::unique(modifiers.begin(), modifiers.end()), modifiers.end());
}

bool KeyShortcut::Has(Modifier modifier) const {
    return std::find(modifiers.begin(), modifiers.end(), modifier) != modifiers.end();
}

bool KeyShortcut::IsSafeKeyEquivalent() const {
    return IsFunctionKey(key) || std::any_of(modifiers.begin(), modifiers.end(), [](Modifier m) { return m != Modifier::Shift; });
}

std::string KeyShortcut::MacDisplayString() const {
    std::string out;
    for (Modifier m : modifiers) {
        switch (m) {
        case Modifier::Control: out += "⌃"; break;
        case Modifier::Option: out += "⌥"; break;
        case Modifier::Shift: out += "⇧"; break;
        case Modifier::Command: out += "⌘"; break;
        }
    }
    const NamedKey* named = FindNamed(key);
    return out + (named ? std::string(named->mac) : Upper(key));
}

std::string KeyShortcut::DisplayString() const {
    std::string out;
    if (Has(Modifier::Control)) out += "Ctrl+";
    if (Has(Modifier::Option)) out += "Alt+";
    if (Has(Modifier::Shift)) out += "Shift+";
    if (Has(Modifier::Command)) out += "Win+";
    const NamedKey* named = FindNamed(key);
    return out + (named ? std::string(named->windows) : Upper(key));
}

json::Value KeyShortcut::ToJson() const {
    json::Array raw;
    for (Modifier m : modifiers) raw.emplace_back(std::string(RawValue(m)));
    return json::Object{{"key", key}, {"modifiers", std::move(raw)}};
}

std::optional<KeyShortcut> KeyShortcut::FromJson(const json::Value& value) {
    const json::Value* key = value.Find("key");
    const json::Value* modifiers = value.Find("modifiers");
    if (!key || !key->AsString() || key->AsString()->empty() || !modifiers || !modifiers->AsArray()) return std::nullopt;
    std::vector<Modifier> out;
    for (const json::Value& raw : *modifiers->AsArray()) {
        const std::string* name = raw.AsString();
        auto modifier = name ? ModifierFromRaw(*name) : std::nullopt;
        if (!modifier) return std::nullopt;
        out.push_back(*modifier);
    }
    return KeyShortcut(*key->AsString(), std::move(out));
}

// MARK: Priority

std::string_view RawValue(KeyShortcutPriority priority) {
    switch (priority) {
    case KeyShortcutPriority::OverrideWebView: return "overrideWebView";
    case KeyShortcutPriority::PromptAfterConsumedByWebView: return "promptAfterConsumedByWebView";
    case KeyShortcutPriority::Low: return "low";
    }
    return "low";
}

std::optional<KeyShortcutPriority> PriorityFromRaw(std::string_view raw) {
    for (auto p : {KeyShortcutPriority::OverrideWebView, KeyShortcutPriority::PromptAfterConsumedByWebView, KeyShortcutPriority::Low}) {
        if (RawValue(p) == raw) return p;
    }
    return std::nullopt;
}

KeyShortcutPriority DefaultPriority(std::string_view action) {
    // KeyShortcutPriority.defaults (Arc's MainMenu.nib arcKeyBindingPriority).
    static const std::set<std::string, std::less<>> kiteWins{
        "addressBar", "archiveTab", "closeWindow", "copyCurrentURL", "copyCurrentURLAsQuote", "copyCurrentURLAsMarkdown",
        "cycleNextTab", "cyclePreviousTab", "goBack", "goForward", "hideKite", "minimize", "newIncognitoWindow", "newTab",
        "newWindow", "quitKite", "reopenClosedTab", "nextTab", "previousTab", "newLittleBrowserWindow",
    };
    static const std::set<std::string, std::less<>> both{
        "addSplitView", "developerTools", "fullscreen", "inspectElements", "pinTab", "printPage",
        "removeSplitView", "toggleSidebar", "toggleDeveloperMode", "toggleToolbar", "viewSource",
    };
    if (kiteWins.contains(action)) return KeyShortcutPriority::OverrideWebView;
    if (both.contains(action)) return KeyShortcutPriority::PromptAfterConsumedByWebView;
    return KeyShortcutPriority::Low;
}

// MARK: KeyBindings

KeyBindings::KeyBindings(std::vector<KeyBindingOverride> overrides) {
    for (auto& o : overrides) Set(std::move(o));
}

const KeyBindingOverride* KeyBindings::Override(std::string_view action) const {
    for (const auto& o : overrides_) {
        if (o.action == action) return &o;
    }
    return nullptr;
}

void KeyBindings::Set(KeyBindingOverride override) {
    std::erase_if(overrides_, [&](const KeyBindingOverride& o) { return o.action == override.action; });
    overrides_.push_back(std::move(override));
}

void KeyBindings::SetShortcut(std::optional<KeyShortcut> shortcut, const std::string& action, KeyBindingOverride::Source source) {
    const KeyBindingOverride* existing = Override(action);
    Set(KeyBindingOverride{action, std::move(shortcut), source, existing ? existing->priority : std::nullopt});
}

void KeyBindings::SetPriority(KeyShortcutPriority priority, const std::string& action, std::optional<KeyShortcut> shortcut) {
    const KeyBindingOverride* existing = Override(action);
    const std::optional<KeyShortcutPriority> keep =
        priority == DefaultPriority(action) ? std::nullopt : std::optional<KeyShortcutPriority>(priority);
    KeyBindingOverride next{action, existing && existing->shortcut ? existing->shortcut : std::move(shortcut),
                            existing ? existing->source : KeyBindingOverride::Source::User, keep};
    Set(std::move(next));
}

KeyShortcutPriority KeyBindings::Priority(std::string_view action) const {
    const KeyBindingOverride* o = Override(action);
    return o && o->priority ? *o->priority : DefaultPriority(action);
}

void KeyBindings::Reset(std::string_view action) {
    std::erase_if(overrides_, [&](const KeyBindingOverride& o) { return o.action == action; });
}

std::map<std::string, std::optional<KeyShortcut>> KeyBindings::Resolve(
    const std::map<std::string, std::optional<KeyShortcut>>& defaults) const {
    auto result = defaults;
    for (const KeyBindingOverride& o : overrides_) {
        if (!defaults.contains(o.action)) continue;
        if (o.shortcut) {
            for (auto& [action, current] : result) {
                if (current == o.shortcut && action != o.action) current.reset();
            }
        }
        result[o.action] = o.shortcut;
    }
    return result;
}

json::Value KeyBindings::ToJson() const {
    json::Array overrides;
    for (const KeyBindingOverride& o : overrides_) {
        json::Object entry{{"action", o.action}, {"source", o.source == KeyBindingOverride::Source::Arc ? "arc" : "user"}};
        if (o.shortcut) entry["shortcut"] = o.shortcut->ToJson();
        if (o.priority) entry["priority"] = std::string(RawValue(*o.priority));
        overrides.emplace_back(std::move(entry));
    }
    return json::Object{{"version", kCurrentVersion}, {"userOverrides", std::move(overrides)}};
}

std::optional<KeyBindings> KeyBindings::FromJson(const json::Value& value) {
    const json::Value* overrides = value.Find("userOverrides");
    if (!value.AsObject() || !overrides || !overrides->AsArray()) return std::nullopt;
    KeyBindings out;
    for (const json::Value& entry : *overrides->AsArray()) {
        const json::Value* action = entry.Find("action");
        const json::Value* source = entry.Find("source");
        if (!action || !action->AsString() || !source || !source->AsString()) continue;
        KeyBindingOverride o;
        o.action = *action->AsString();
        if (*source->AsString() == "arc") {
            o.source = KeyBindingOverride::Source::Arc;
        } else if (*source->AsString() != "user") {
            continue;
        }
        if (const json::Value* shortcut = entry.Find("shortcut"); shortcut && !shortcut->IsNull()) {
            o.shortcut = KeyShortcut::FromJson(*shortcut);
            if (!o.shortcut) continue;
        }
        // A priority this build doesn't know keeps the default.
        if (const json::Value* priority = entry.Find("priority"); priority && priority->AsString()) {
            o.priority = PriorityFromRaw(*priority->AsString());
        }
        out.Set(std::move(o));
    }
    return out;
}

std::optional<KeyBindings> KeyBindings::FromText(std::string_view text) {
    auto parsed = json::Parse(text);
    auto* value = std::get_if<json::Value>(&parsed);
    return value ? FromJson(*value) : std::nullopt;
}

// MARK: ShortcutPriorityGate

bool ShortcutPriorityGate::Press(const std::string& action, int window, double time, bool isRepeat) {
    if (last_ && last_->action == action && last_->window == window && time - last_->time <= kSecondPressWindow) {
        // A held key repeating isn't a second press; it keeps the first one's place.
        if (isRepeat) return false;
        last_.reset();
        return true;
    }
    if (isRepeat) {
        last_.reset();
    } else {
        last_ = Pressed{action, window, time, false};
    }
    return false;
}

void ShortcutPriorityGate::CommandRan(std::string_view action) {
    if (last_ && last_->action == action) last_.reset();
}

bool ShortcutPriorityGate::PageConsumed(std::string_view action, int window, double pressedAt) {
    if (!last_ || last_->action != action || last_->window != window || last_->time != pressedAt || last_->consumed) return false;
    last_->consumed = true;
    return true;
}

std::string ShortcutPriorityGate::Prompt(const KeyShortcut& shortcut, std::string_view title) {
    std::string action(title);
    constexpr std::string_view kEllipsis = "…";
    if (action.ends_with(kEllipsis)) action.resize(action.size() - kEllipsis.size());
    return "Press " + shortcut.DisplayString() + " again to " + action;
}

// MARK: Windows' commands

const std::vector<ShortcutCommand>& ShortcutCommands() {
    // The Mac's MainMenu items Kite for Windows has, grouped by menu (not always in the Mac's current order), ⌘ made Ctrl.
    static const std::vector<ShortcutCommand> commands = [] {
        std::vector<ShortcutCommand> c{
            {"newTab", "New Tab…", Ctrl("t")},
            {"reopenClosedTab", "Restore Last Closed Tab", CtrlShift("t"), {}},
            {"openLocation", "Open Location…", std::nullopt},
            {"archiveTab", "Archive Tab", Ctrl("w"), {Ctrl("f4")}},  // closes the bar first
            {"closeWindow", "Close Window", CtrlShift("w"), {}},
            {"quitKite", "Quit Kite", Ctrl("q"), {}},
            // Print (⌘P) waits for printing that survives a cancelled dialog: after Windows 11's
            // print dialog is dismissed, CEF 156 never prints again and Chromium's shutdown hangs.
            {"copyCurrentURL", "Copy URL", CtrlShift("c")},
            // Edit › Find. F3 and Shift+F3 are Windows' own Find Next and Previous.
            {"find", "Find…", Ctrl("f")},
            {"findNext", "Find Next", Ctrl("g"), {Bare("f3")}},
            {"findPrevious", "Find Previous", CtrlShift("g"), {KeyShortcut("f3", {Modifier::Shift})}},
            {"collapsePinnedSection", "Collapse Pinned Tabs", std::nullopt},
            {"stopLoading", "Stop Loading", Ctrl(".")},
            {"reloadPage", "Refresh the Page", Ctrl("r"), {Bare("f5")}},
            {"forceReloadPage", "Force Refresh the Page", CtrlShift("r"), {Ctrl("f5"), KeyShortcut("f5", {Modifier::Shift})}},
            {"viewSource", "View Source", CtrlAlt("u"), {Ctrl("u")}},
            {"developerTools", "Developer Tools", CtrlAlt("i"), {Bare("f12"), CtrlShift("i")}},
            {"nextTab", "Next Tab", CtrlAlt("down"), {}},
            {"previousTab", "Previous Tab", CtrlAlt("up"), {}},
        };
        for (int n = 1; n <= 9; ++n) {
            const std::string digit(1, static_cast<char>('0' + n));
            c.emplace_back(n == 9 ? "lastTab" : "tab" + digit, n == 9 ? "Last Tab" : "Tab " + digit, Ctrl(digit));
        }
        // The Spaces menu. The Mac's Space n is ⌃n, which is Ctrl+n here (Tab n), so it's Alt+n.
        c.emplace_back("nextSpace", "Next Space", CtrlShift("s"), std::vector<KeyShortcut>{CtrlAlt("right")});
        c.emplace_back("previousSpace", "Previous Space", CtrlAlt("left"), std::vector<KeyShortcut>{});
        for (int n = 1; n <= 9; ++n) {
            const std::string digit(1, static_cast<char>('0' + n));
            c.emplace_back("space" + digit, "Space " + digit, Alt(digit));
        }
        c.emplace_back("goBack", "Go Back", Ctrl("["), std::vector<KeyShortcut>{Alt("left")});
        c.emplace_back("goForward", "Go Forward", Ctrl("]"), std::vector<KeyShortcut>{Alt("right")});
        c.emplace_back("minimize", "Minimize Window", Ctrl("m"));
        return c;
    }();
    return commands;
}

std::optional<KeyShortcut> WindowsShortcut(const KeyShortcut& shortcut) {
    if (!shortcut.Has(Modifier::Command)) return shortcut;
    if (shortcut.Has(Modifier::Control)) return std::nullopt;
    std::vector<Modifier> modifiers;
    for (Modifier m : shortcut.modifiers) modifiers.push_back(m == Modifier::Command ? Modifier::Control : m);
    return KeyShortcut(shortcut.key, std::move(modifiers));
}

ShortcutMap ShortcutTable(const KeyBindings& bindings) {
    // The user's overrides as Windows presses them, so a Mac file's ⌘⇧W takes Ctrl+Shift+W
    // from Close Window as it took ⌘⇧W on the Mac.
    // One Windows can't press (⌃⌘) or that would take typing keys is ignored, and the command
    // keeps its default, as the Mac's KeyBindingsStore.apply ignores an unsafe one.
    std::map<std::string, std::optional<KeyShortcut>> defaults;
    std::map<std::string_view, const ShortcutCommand*> byID;
    for (const ShortcutCommand& command : ShortcutCommands()) {
        defaults[command.id] = command.shortcut;
        byID[command.id] = &command;
    }
    std::vector<KeyBindingOverride> overrides;
    for (KeyBindingOverride o : bindings.UserOverrides()) {
        if (o.shortcut) {
            o.shortcut = WindowsShortcut(*o.shortcut);
            if (!o.shortcut || !o.shortcut->IsSafeKeyEquivalent()) {
                auto fallback = defaults.find(o.action);
                o.shortcut = fallback == defaults.end() ? std::nullopt : fallback->second;
            }
        }
        overrides.push_back(std::move(o));
    }
    const KeyBindings windows(std::move(overrides));
    ShortcutMap table;
    for (const auto& [action, shortcut] : windows.Resolve(defaults)) {
        if (shortcut) table[*shortcut] = ShortcutTarget{byID.at(action), windows.Priority(action)};
    }
    for (const ShortcutCommand& command : ShortcutCommands()) {
        for (const KeyShortcut& extra : command.more) table.try_emplace(extra, ShortcutTarget{&command, windows.Priority(command.id)});
    }
    return table;
}

bool EditsText(const KeyShortcut& shortcut) {
    static const std::set<std::string, std::less<>> kEditingKeys{"left", "right", "up", "down", "delete"};
    return kEditingKeys.contains(shortcut.key) && !(shortcut.Has(Modifier::Control) && shortcut.Has(Modifier::Option));
}

const ShortcutTarget* FindShortcut(const ShortcutMap& table, const KeyShortcut& pressed) {
    if (!pressed.IsSafeKeyEquivalent()) return nullptr;
    auto it = table.find(pressed);
    return it == table.end() ? nullptr : &it->second;
}

}  // namespace kite
