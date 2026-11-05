// The + menu, Create a Space and Choose a Theme's swatches (SpaceCreation.h). Ports
// NewItemMenu.swift, BrowserStore's beginNewSpace / finishNewSpace / cancelNewSpace /
// spaceThemeChosen, Space.cleanAbout, SpaceCreationView.swift's layout and ThemeEditor's presets.

#include "core/SpaceCreation.h"

#include <algorithm>

#include "core/Profiles.h"
#include "core/SpaceEditing.h"
#include "core/Unicode.h"

namespace kite {

namespace {

// Swift's Character.isNewline, as Profiles.cpp's: what Space.cleanAbout splits lines on.
bool IsNewline(char32_t c) { return (c >= 0x0A && c <= 0x0D) || c == 0x85 || c == 0x2028 || c == 0x2029; }

std::string ShortcutText(const ShortcutMap& shortcuts, std::string_view command, const KeyShortcut& mac) {
    if (const std::optional<KeyShortcut> bound = MenuShortcut(shortcuts, command)) return bound->DisplayString();
    const std::optional<KeyShortcut> windows = WindowsShortcut(mac);
    return windows ? windows->DisplayString() : std::string();
}

}  // namespace

// MARK: The + menu

std::vector<NewItemMenuItem> NewItemMenu(const ShortcutMap& shortcuts) {
    using C = NewItemMenuItem::Command;
    using M = KeyShortcut::Modifier;
    return {
        {C::NewSpace, "New Space", "", true},
        {C::NewFolder, "New Folder", "", true},
        {},
        // The Mac's ⌘L (addSplitView); Windows has no split views until W36.
        {C::NewSplit, "New Split", ShortcutText(shortcuts, "addSplitView", KeyShortcut("l", {M::Command})), false},
        {C::NewTab, "New Tab", ShortcutText(shortcuts, "newTab", KeyShortcut("t", {M::Command})), true},
    };
}

std::string NewItemMenuLine(const std::vector<NewItemMenuItem>& items) {
    std::string line;
    for (const NewItemMenuItem& item : items) {
        if (!line.empty()) line += " | ";
        if (item.command == NewItemMenuItem::Command::Separator) {
            line += "---";
            continue;
        }
        const std::string title = item.shortcut.empty() ? item.title : item.title + "\t" + item.shortcut;
        line += item.enabled ? title : "(" + title + ")";
    }
    return line;
}

// MARK: Creating a space

std::string BeginNewSpace(BrowserState& state, std::optional<SpaceCreation>& creation) {
    if (creation && state.SpaceIndex(creation->spaceID)) {
        state.SelectSpace(creation->spaceID);
        return creation->spaceID;
    }
    const Space& current = state.SelectedSpace();
    const std::string returnTo = current.id;
    // The space is only a draft until it's named: no icon, no name, this space's look and profile.
    const Theme theme = current.theme;
    const std::optional<std::string> profile = SpaceProfile(current);
    const std::string id = state.InsertSpace("", "", theme, profile);
    creation = SpaceCreation{id, returnTo, false};
    return id;
}

bool CanCreateSpace(std::string_view name) { return !unicode::Trim(name).empty(); }

bool FinishNewSpace(BrowserState& state, std::optional<SpaceCreation>& creation, std::string_view name, std::string_view about) {
    if (!creation) return false;
    const std::string_view trimmed = unicode::Trim(name);
    if (trimmed.empty()) return false;
    const auto index = state.SpaceIndex(creation->spaceID);
    if (!index) {
        creation.reset();
        return false;
    }
    state.RenameSpace(creation->spaceID, trimmed);
    SetSpaceAbout(state.spaces[*index], CleanAbout(about));
    creation.reset();
    return true;
}

bool CancelNewSpace(BrowserState& state, std::optional<SpaceCreation>& creation) {
    if (!creation) return false;
    const SpaceCreation closing = *creation;
    creation.reset();
    state.DeleteSpace(closing.spaceID);
    state.SelectSpace(closing.returnTo);
    return true;
}

bool ChooseSpaceTheme(BrowserState& state, std::optional<SpaceCreation>& creation, const std::string& spaceID, size_t preset) {
    const auto index = state.SpaceIndex(spaceID);
    const std::vector<Theme>& presets = Theme::Presets();
    if (!index || preset >= presets.size()) return false;
    Theme& theme = state.spaces[*index].theme;
    const float tint = theme.tint;
    theme = presets[preset];
    theme.tint = tint;
    if (creation && creation->spaceID == spaceID) creation->themeChosen = true;
    return true;
}

void CreationFollowsState(const BrowserState& state, std::optional<SpaceCreation>& creation) {
    if (creation && !state.SpaceIndex(creation->spaceID)) creation.reset();
}

bool ShowsCreation(const BrowserState& state, const std::optional<SpaceCreation>& creation) {
    return creation && !state.spaces.empty() && state.selectedSpaceID == creation->spaceID;
}

std::optional<std::string> CleanAbout(std::string_view text) {
    // text.split(whereSeparator: \.isNewline).joined(separator: " "): empty lines go.
    const std::vector<std::u32string> characters = unicode::Characters(text);
    std::u32string joined;
    bool pendingSpace = false;
    for (const std::u32string& character : characters) {
        // A Character is a newline when its first scalar is (CR LF is one Character).
        if (!character.empty() && IsNewline(character.front())) {
            if (!joined.empty()) pendingSpace = true;
            continue;
        }
        if (pendingSpace) {
            joined += U' ';
            pendingSpace = false;
        }
        joined += character;
    }
    // .trimmingCharacters(in: .whitespaces): with the newlines gone, Unicode's White_Space is
    // the spaces (Zs) and the tab.
    std::string trimmed(unicode::Trim(unicode::Encode(joined)));
    if (trimmed.empty()) return std::nullopt;
    // String(prefix(500)): characters, not bytes.
    const std::vector<std::u32string> kept = unicode::Characters(trimmed);
    if (kept.size() <= kMaxAboutLength) return trimmed;
    std::u32string cut;
    for (size_t i = 0; i < kMaxAboutLength; ++i) cut += kept[i];
    return unicode::Encode(cut);
}

std::optional<std::string> SpaceAbout(const Space& space) {
    const auto it = space.extra.find("about");
    if (it == space.extra.end() || !it->second.AsString()) return std::nullopt;
    return *it->second.AsString();
}

void SetSpaceAbout(Space& space, const std::optional<std::string>& about) {
    if (about) space.extra.insert_or_assign("about", *about);
    else space.extra.erase("about");
}

std::optional<std::string> NewSpace(BrowserState& state, std::string_view name, std::string_view about, std::optional<size_t> preset) {
    if (!CanCreateSpace(name) || (preset && *preset >= Theme::Presets().size())) return std::nullopt;
    std::optional<SpaceCreation> creation;
    const std::string id = BeginNewSpace(state, creation);
    if (preset) ChooseSpaceTheme(state, creation, id, *preset);
    FinishNewSpace(state, creation, name, about);
    return id;
}

// MARK: The page's layout

SpaceCreationLayout LayOutSpaceCreation(float width, float height, bool showsProfile) {
    namespace M = space_creation_metrics;
    namespace S = sidebar_metrics;
    SpaceCreationLayout l;
    l.showsProfile = showsProfile;
    // SidebarColumnView: the column inside the sidebar's padding, from under the top row to the bar.
    const float top = S::kTopRowY + S::kTopRowHeight;
    const float barTop = SpaceBarTop(height);
    l.page = BarRect{S::kPadding, top, width - S::kPadding, std::max(barTop, top)};
    const float left = M::kInset, right = std::max(width - M::kInset, left);
    const auto band = [&](float y, float h) { return BarRect{left, y, right, y + h}; };
    l.illustration = band(top + M::kIllustrationTop, M::kIllustrationHeight);
    l.title = band(l.illustration.bottom + M::kTitleTop, M::kTitleLineHeight);
    l.subtitle = band(l.title.bottom + M::kSubtitleTop, 2 * M::kSubtitleLineHeight);
    l.name = band(l.subtitle.bottom + M::kFieldsTop, M::kRowHeight);
    l.about = band(l.name.bottom + M::kProfileGap, M::kRowHeight);
    float last = l.about.bottom;
    if (showsProfile) {
        l.profile = band(l.about.bottom + M::kProfileGap, M::kRowHeight);
        last = l.profile.bottom;
    }
    l.theme = band(last + M::kThemeGap, M::kRowHeight);
    const auto field = [&](const BarRect& row) {
        return BarRect{M::kRowTextX, row.top, std::max(row.right - M::kRowTrailing, M::kRowTextX), row.bottom};
    };
    l.nameField = field(l.name);
    l.aboutField = field(l.about);
    // Create Space and Cancel at the bottom, under the Spacer; when the room runs out, the Spacer
    // is gone and they follow Choose a Theme.
    const float cancelBottom = l.page.bottom - M::kCancelBottom;
    const float createTop = std::max(cancelBottom - M::kCancelLineHeight - M::kCancelTop - M::kRowHeight, l.theme.bottom);
    l.create = band(createTop, M::kRowHeight);
    l.cancel = band(l.create.bottom + M::kCancelTop, M::kCancelLineHeight);
    return l;
}

SpaceCreationPart SpaceCreationPartAt(const SpaceCreationLayout& layout, float x, float y, float cancelWidth, const std::optional<BarRect>& pill) {
    using P = SpaceCreationPart;
    if (layout.nameField.Contains(x, y)) return P::NameField;
    if (layout.aboutField.Contains(x, y)) return P::AboutField;
    if (layout.showsProfile && pill && pill->Contains(x, y)) return P::ProfilePill;
    if (layout.theme.Contains(x, y)) return P::ChooseTheme;
    if (layout.create.Contains(x, y)) return P::Create;
    const float middle = (layout.cancel.left + layout.cancel.right) / 2;
    const BarRect cancel{middle - cancelWidth / 2, layout.cancel.top, middle + cancelWidth / 2, layout.cancel.bottom};
    if (cancel.Contains(x, y)) return P::Cancel;
    return P::None;
}

const char* SpaceCreationPartName(SpaceCreationPart part) {
    switch (part) {
    case SpaceCreationPart::NameField: return "name";
    case SpaceCreationPart::AboutField: return "about";
    case SpaceCreationPart::ProfilePill: return "profile";
    case SpaceCreationPart::ChooseTheme: return "theme";
    case SpaceCreationPart::Create: return "create";
    case SpaceCreationPart::Cancel: return "cancel";
    case SpaceCreationPart::None: break;
    }
    return "none";
}

// MARK: Choose a Theme's swatches

ThemeSwatchesLayout LayOutThemeSwatches(size_t presets) {
    namespace T = theme_swatches_metrics;
    ThemeSwatchesLayout l;
    l.width = T::kContentWidth;
    l.height = T::kHeight;
    const float rowTop = T::kInset;
    l.previous = BarRect{T::kInset, rowTop, T::kInset + T::kSwatchButton, rowTop + T::kSwatchButton};
    l.next = BarRect{l.width - T::kInset - T::kSwatchButton, rowTop, l.width - T::kInset, rowTop + T::kSwatchButton};
    const float swatchTop = rowTop + (T::kSwatchButton - T::kSwatchSize) / 2;
    for (size_t i = 0; i < presets; ++i) {
        const float x = T::kInset + T::kSwatchesX + static_cast<float>(i) * T::kSwatchPitch;
        l.swatches.push_back(BarRect{x, swatchTop, x + T::kSwatchSize, swatchTop + T::kSwatchSize});
    }
    return l;
}

std::optional<size_t> ThemeSwatchAt(const ThemeSwatchesLayout& layout, float x, float y) {
    for (size_t i = 0; i < layout.swatches.size(); ++i) {
        // A Circle's button: its circle takes the press (SwiftUI's shape is its content).
        const BarRect& s = layout.swatches[i];
        const float r = s.Width() / 2, dx = x - (s.left + r), dy = y - (s.top + r);
        if (dx * dx + dy * dy <= r * r) return i;
    }
    return std::nullopt;
}

SwatchesPlacement PlaceThemeSwatches(const BarRect& row, const ThemeSwatchesLayout& layout) {
    namespace T = theme_swatches_metrics;
    const float middle = (row.top + row.bottom) / 2;
    return SwatchesPlacement{row.right + T::kArrowDepth, middle - layout.height / 2, layout.height / 2};
}

std::optional<size_t> PresetOf(const Theme& theme) {
    const std::vector<Theme>& presets = Theme::Presets();
    for (size_t i = 0; i < presets.size(); ++i) {
        if (presets[i].colors == theme.colors && presets[i].grain == theme.grain) return i;
    }
    return std::nullopt;
}

}  // namespace kite
