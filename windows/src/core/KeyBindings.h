#pragma once
// Keyboard shortcuts: the Mac's KeyBindings.swift (KeyShortcut, KeyShortcutPriority,
// KeyBindingOverride, KeyBindings) and ShortcutPriorityGate.swift, plus Windows' command table
// (the commands Kite for Windows has, with their default shortcuts, Ctrl in place of ⌘).
//
// keybindings.json has the Mac's layout (Arc's StorableKeyBindings.json). On Windows a
// shortcut's modifiers mean the keys Windows has: "control" is Ctrl, "option" is Alt, "shift"
// is Shift ("command", the Windows key, is never matched: Windows keeps it for itself).

#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "core/Json.h"

namespace kite {

struct KeyShortcut {
    // Declared in the order macOS draws them: ⌃⌥⇧⌘; `modifiers` is kept sorted and unique.
    enum class Modifier { Control, Option, Shift, Command };

    // A lowercased character ("t", "[", "1") or a named key: left, right, up, down, tab, return,
    // delete, escape, space (the Mac's namedKeys), and f1…f24 (Windows' function keys).
    std::string key;
    std::vector<Modifier> modifiers;

    KeyShortcut() = default;
    KeyShortcut(std::string key, std::vector<Modifier> modifiers);

    bool Has(Modifier modifier) const;
    // Whether it can run a command without taking keys a page or text field needs: it holds
    // Ctrl, Alt (or ⌘), or it's a function key. A bare or Shift-only key types instead.
    bool IsSafeKeyEquivalent() const;
    // "⇧⌘S", as the Mac's menus show it.
    std::string MacDisplayString() const;
    // "Ctrl+Shift+S", as Windows shows shortcuts.
    std::string DisplayString() const;

    json::Value ToJson() const;
    static std::optional<KeyShortcut> FromJson(const json::Value& value);

    bool operator==(const KeyShortcut&) const = default;
    auto operator<=>(const KeyShortcut&) const = default;
};

// Who gets a shortcut first when a web page wants the same keys: Arc's
// KeyboardShortcutPriority, with its raw values.
enum class KeyShortcutPriority {
    OverrideWebView,               // Kite runs the command before the page sees the key
    PromptAfterConsumedByWebView,  // the page first; a second press runs Kite's command
    Low,                           // Kite's command only if the page doesn't use the key
};
std::string_view RawValue(KeyShortcutPriority priority);
std::optional<KeyShortcutPriority> PriorityFromRaw(std::string_view raw);
// Each command's priority as Arc's MainMenu.nib sets it, by Kite's ids; others are Low.
KeyShortcutPriority DefaultPriority(std::string_view action);

// A user's change to one command's shortcut. No shortcut removes it.
struct KeyBindingOverride {
    enum class Source { User, Arc };
    KeyBindingOverride() = default;
    KeyBindingOverride(std::string action, std::optional<KeyShortcut> shortcut, Source source = Source::User,
                       std::optional<KeyShortcutPriority> priority = std::nullopt)
        : action(std::move(action)), shortcut(std::move(shortcut)), source(source), priority(priority) {}
    std::string action;
    std::optional<KeyShortcut> shortcut;
    Source source = Source::User;
    std::optional<KeyShortcutPriority> priority;  // none keeps the command's default
    bool operator==(const KeyBindingOverride&) const = default;
};

// Shortcut overrides on disk (keybindings.json).
class KeyBindings {
public:
    static constexpr int kCurrentVersion = 1;

    KeyBindings() = default;
    explicit KeyBindings(std::vector<KeyBindingOverride> overrides);

    const std::vector<KeyBindingOverride>& UserOverrides() const { return overrides_; }
    const KeyBindingOverride* Override(std::string_view action) const;
    // One override per action; a later one replaces an earlier one.
    void Set(KeyBindingOverride override);
    // Changes a command's shortcut, keeping any priority the user chose for it.
    void SetShortcut(std::optional<KeyShortcut> shortcut, const std::string& action,
                     KeyBindingOverride::Source source = KeyBindingOverride::Source::User);
    // Changes a command's priority, keeping (or taking) `shortcut`, as Arc's overrides hold both.
    void SetPriority(KeyShortcutPriority priority, const std::string& action, std::optional<KeyShortcut> shortcut);
    KeyShortcutPriority Priority(std::string_view action) const;
    void Reset(std::string_view action);
    // What each command's shortcut becomes, given its defaults (an action → its shortcut, or
    // none). An overridden shortcut is taken away from any other command that had it, as in
    // Arc; overrides for commands not in `defaults` are left out.
    std::map<std::string, std::optional<KeyShortcut>> Resolve(const std::map<std::string, std::optional<KeyShortcut>>& defaults) const;

    json::Value ToJson() const;
    // Reads a file the Mac or Windows wrote; overrides it can't read are skipped. nullopt when
    // it isn't a key bindings file at all.
    static std::optional<KeyBindings> FromJson(const json::Value& value);
    // The same, from the file's text; nullopt when it isn't JSON or a key bindings file.
    static std::optional<KeyBindings> FromText(std::string_view text);

    bool operator==(const KeyBindings&) const = default;

private:
    std::vector<KeyBindingOverride> overrides_;
};

// Arc's "Use Both" priority: the first press of a shortcut goes to the page; if the page uses
// it, the next press runs Kite's command instead (ShortcutPriorityGate.swift). Times in seconds.
class ShortcutPriorityGate {
public:
    static constexpr double kConsumedDelay = 0.35;
    static constexpr double kSecondPressWindow = 4.6;

    // A press of `action`'s shortcut while a page has the keys. True: it's the second press,
    // run Kite's command now, before the page sees it.
    bool Press(const std::string& action, int window, double time, bool isRepeat);
    // The command ran because the page passed the key on: nothing to ask.
    void CommandRan(std::string_view action);
    // kConsumedDelay after the press at `time`: true if the page kept the key (time to prompt).
    bool PageConsumed(std::string_view action, int window, double pressedAt);
    // "Press Ctrl+D again to Pin Tab".
    static std::string Prompt(const KeyShortcut& shortcut, std::string_view title);

private:
    struct Pressed {
        std::string action;
        int window = 0;
        double time = 0;
        bool consumed = false;
    };
    std::optional<Pressed> last_;
};

// A command Kite for Windows has, with its default shortcut on Windows: the Mac's menu item
// (MainMenu.swift) by its id, ⌘ made Ctrl. `more` are extra shortcuts Windows users expect
// (F5, Alt+Left), which work but aren't the one shown, like the Mac's hidden alternates
// (⌘← for Back): they stay when the command is rebound, unless another command takes them.
struct ShortcutCommand {
    std::string id;
    std::string title;
    std::optional<KeyShortcut> shortcut;
    std::vector<KeyShortcut> more;

    ShortcutCommand(std::string id, std::string title, std::optional<KeyShortcut> shortcut, std::vector<KeyShortcut> more = {})
        : id(std::move(id)), title(std::move(title)), shortcut(std::move(shortcut)), more(std::move(more)) {}
};
const std::vector<ShortcutCommand>& ShortcutCommands();

// A shortcut as Windows can press it. A file from the Mac holds ⌘ ("command"), which Windows
// reads as Ctrl, as its defaults do; none for a shortcut with both ⌃ and ⌘ (no Windows keys).
std::optional<KeyShortcut> WindowsShortcut(const KeyShortcut& shortcut);

// What a shortcut runs: the command (one of ShortcutCommands(), which live for the program)
// and who gets the key first when a page wants it too.
struct ShortcutTarget {
    const ShortcutCommand* command = nullptr;
    KeyShortcutPriority priority = KeyShortcutPriority::Low;
};
using ShortcutMap = std::map<KeyShortcut, ShortcutTarget>;

// Which command each shortcut runs, after the user's overrides (their ⌘ read as Ctrl): the
// shown shortcuts, then the extra ones that no command's shown shortcut took.
ShortcutMap ShortcutTable(const KeyBindings& bindings);

// Whether a text field uses these keys itself (Alt+Left, Ctrl+Backspace…), so they stay the
// command bar's while it's open, as the Mac doesn't take ⌘← and ⌘→ from a focused field.
bool EditsText(const KeyShortcut& shortcut);

// The command a pressed key runs, if any. Keys without Ctrl or Alt (other than function keys)
// type, so they're never looked up.
const ShortcutTarget* FindShortcut(const ShortcutMap& table, const KeyShortcut& pressed);

}  // namespace kite
