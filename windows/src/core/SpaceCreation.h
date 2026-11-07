#pragma once
// The space bar's + menu and Arc's Create a Space page, platform-free: the Mac's NewItemMenu
// (NewItemMenu.swift), BrowserStore's beginNewSpace, finishNewSpace, cancelNewSpace and
// spaceThemeChosen (BrowserStore.swift), Space.cleanAbout (Models.swift), the page's layout
// (SpaceCreationView.swift, ArcMetrics.SpaceCreation) and the theme editor's preset swatches
// that Choose a Theme opens (ThemeEditor.swift's presets, ArcMetrics.ThemeEditor). The edits go
// through W9d's BrowserState::InsertSpace (core/SpaceEditing). The shell draws the page
// (shell/SpaceCreationView) and the swatches (shell/ThemeSwatchesView) and shows the menu.

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "core/KeyBindings.h"
#include "core/Models.h"
#include "core/SpaceBar.h"
#include "core/SpaceEditing.h"

namespace kite {

// MARK: The + menu

// One entry of the + menu, in the Mac's order and words: New Space and New Folder, a line, then
// New Split and New Tab with their shortcuts (Arc's New Easel and New Boost left out, as the Mac
// leaves them out).
struct NewItemMenuItem {
    enum class Command { Separator, NewSpace, NewFolder, NewSplit, NewTab };
    Command command = Command::Separator;
    std::string title;     // empty for a separator
    std::string shortcut;  // as Windows shows it ("Ctrl+T"), empty for none
    bool enabled = true;
    bool operator==(const NewItemMenuItem&) const = default;
};
// The menu, its shortcuts as `shortcuts` runs them (MenuShortcut), or the Mac's own default
// made Windows' (⌘L, ⌘T) where nothing runs the command. Every item is enabled on the Mac; New
// Split stays disabled until Windows has split views (W36).
std::vector<NewItemMenuItem> NewItemMenu(const ShortcutMap& shortcuts);
// Its line for kitecore and the smoke test, as SpaceMenuLine: "---" for the separator, a disabled
// item's title in brackets, a shortcut after a tab ("New Tab\tCtrl+T").
std::string NewItemMenuLine(const std::vector<NewItemMenuItem>& items);

// MARK: Creating a space

// Arc's Create a Space page while it's open (BrowserStore.SpaceCreation): the space being made,
// already in the strip (so its theme shows live), the one Cancel goes back to, and whether a
// colour has been picked. The Mac's `before` (New Space's undo step) comes with undo (W16).
struct SpaceCreation {
    std::string spaceID;
    std::string returnTo;
    bool themeChosen = false;
    bool operator==(const SpaceCreation&) const = default;
};

// + › New Space (beginNewSpace): a nameless space with no icon right after the selected one,
// selected, with its theme and profile; or, with a creation already open, its space selected
// again. The space's id.
std::string BeginNewSpace(BrowserState& state, std::optional<SpaceCreation>& creation);
// Create Space's enabled state: a name with something besides whitespace and newlines.
bool CanCreateSpace(std::string_view name);
// Create Space (finishNewSpace): the space named (trimmed) and described (CleanAbout), and the
// page closed. False, changing nothing, with no creation open or a blank name.
bool FinishNewSpace(BrowserState& state, std::optional<SpaceCreation>& creation, std::string_view name, std::string_view about = {});
// Cancel and Escape (cancelNewSpace): the space deleted and the one it was opened from selected.
// False, changing nothing, with no creation open, or when its space is the only one left (Delete
// Space refuses the last space: the Mac would end the page and leave the nameless space for
// DropUnnamedEmptySpaces; Windows keeps the page open instead, so nothing nameless is left).
bool CancelNewSpace(BrowserState& state, std::optional<SpaceCreation>& creation);
// The theme editor's preset swatch `preset` (Theme::Presets()) picked for space `spaceID`: its
// colours and grain, the space's intensity kept (ThemeEditor.presets' set), and a creation of that
// space has its colour chosen (spaceThemeChosen). False for no such space or preset.
bool ChooseSpaceTheme(BrowserState& state, std::optional<SpaceCreation>& creation, const std::string& spaceID, size_t preset);
// The creation as the session has it now: forgotten once its space is gone (deleted by another
// path, an import). One whose space to go back to is gone stays: Cancel then leaves the space
// before it selected, as the Mac's deleteSpace does (its selectSpace finds nothing).
void CreationFollowsState(const BrowserState& state, std::optional<SpaceCreation>& creation);
// Whether the page shows: a creation open for the selected space (SidebarColumn's check).
bool ShowsCreation(const BrowserState& state, const std::optional<SpaceCreation>& creation);

// A Create a Space page left open at quit (or a crash) leaves a nameless space behind: each space
// with no name and no tabs goes, as Delete Space takes it (the one before a selected one selected,
// never the last space), as the Mac's dropUnnamedEmptySpaces does after loading the session. True
// when one went.
bool DropUnnamedEmptySpaces(BrowserState& state);

// The space's menu while Create a Space is open (SpaceEditing.h's SpaceMenu): on the space being
// made, Change Space Icon… is disabled, its header (where the picker hangs) being under the page;
// the Mac's opens the picker on a header no one sees. Its Rename Space… goes to the page's name
// field (the window's).
std::vector<SpaceMenuItem> SpaceMenu(const BrowserState& state, const std::string& spaceID, const std::optional<SpaceCreation>& creation);

// What a space is for, in the user's words (Space.about, Kite's own: Claude reads it): kept in
// the space's `extra` as the Mac writes it. Space.cleanAbout: lines joined with spaces, spaces
// and tabs trimmed, at most 500 characters; none when nothing is left.
inline constexpr size_t kMaxAboutLength = 500;
std::optional<std::string> CleanAbout(std::string_view text);
std::optional<std::string> SpaceAbout(const Space& space);
void SetSpaceAbout(Space& space, const std::optional<std::string>& about);

// + › New Space for a script (kitecore's `space new`): the page opened, a theme picked when
// `preset` is given, then Create Space with `name` and `about`. None for a blank name (nothing
// made) or no such preset.
std::optional<std::string> NewSpace(BrowserState& state, std::string_view name, std::string_view about, std::optional<size_t> preset);

// MARK: The page's layout

// ArcMetrics.SpaceCreation, in points, and the page's words.
namespace space_creation_metrics {
constexpr float kIllustrationTop = 46.5f;
constexpr float kIllustrationHeight = 33;
constexpr float kTitleTop = 21;
constexpr float kTitleFontSize = 17;
constexpr float kSubtitleTop = 11;
constexpr float kSubtitleFontSize = 14;
constexpr float kSubtitleOpacity = 0.85f;
constexpr float kFieldsTop = 32;  // the name field's top, under the subtitle (y 237)
constexpr float kProfileGap = 6;  // between the rows
constexpr float kThemeGap = 8;    // before Choose a Theme
constexpr float kInset = 14;      // the rows' sides, from the sidebar's
constexpr float kRowHeight = 36;
constexpr float kRowIconX = 22;   // a row's icon frame, from the sidebar's leading edge
constexpr float kRowTextX = 48;   // its text
constexpr float kIconSize = 18;   // the icon's frame
constexpr float kRowTrailing = 10;  // a row's trailing padding
constexpr float kRowFontSize = 15;
constexpr float kRowFill = 0.095f;  // white over the tint
constexpr float kCornerRadius = 8;
// Create Space: #2C4AFC, at half strength over the tint until there's a name; its title white,
// at 45% then.
constexpr uint32_t kCreateColor = 0x2C4AFC;
constexpr float kCreateDisabledOpacity = 0.5f;
constexpr float kCreateDisabledTextOpacity = 0.45f;
constexpr float kCancelTop = 14.5f;
constexpr float kCancelFontSize = 13;
constexpr float kCancelOpacity = 0.68f;
constexpr float kCancelBottom = 16.5f;  // to the space bar
// SwiftUI's line boxes for SF Pro (its ascender and descender, 0.952 + 0.241 of the size) at
// 2x, where the Mac lays the page out: the title's 17pt line, the subtitle's two 14pt lines and
// Cancel's 13pt line. With them the name field's top lands on Arc's y 237.
constexpr float kTitleLineHeight = 20.5f;
constexpr float kSubtitleLineHeight = 16.75f;
constexpr float kCancelLineHeight = 15.5f;
// The illustration: three 28 × 32 cards with 4pt corners, the outer two turned 12° and 18pt
// out, 2pt down.
constexpr float kCardWidth = 28, kCardHeight = 32, kCardRadius = 4;
constexpr float kCardTurn = 12, kCardSpread = 18, kCardDrop = 2;
constexpr float kCardSymbolSize = 13;
// The profile row's pill: its name and a chevron 4pt apart, 10pt in from its sides, 24pt tall.
constexpr float kPillHeight = 24, kPillPadding = 10, kPillGap = 4, kPillFontSize = 13, kPillChevronSize = 9;
constexpr float kPillFill = 0.1f;
// The rows' gap between icon and text (the HStack's spacing).
constexpr float kRowSpacing = kRowTextX - kRowIconX - kIconSize;

inline constexpr std::string_view kTitle = "Create a Space";
inline constexpr std::string_view kSubtitle = "Separate your tabs for life,\nwork, projects, and more.";
inline constexpr std::string_view kNamePlaceholder = "Space name\xE2\x80\xA6";
inline constexpr std::string_view kAboutPlaceholder = "What's it for? (for Claude)";
inline constexpr std::string_view kProfileTitle = "Profile";
inline constexpr std::string_view kThemeTitle = "Choose a Theme";
inline constexpr std::string_view kCreateTitle = "Create Space";
inline constexpr std::string_view kCancelTitle = "Cancel";
}  // namespace space_creation_metrics

// Where everything on the page sits, in points from the sidebar's top-left, for a sidebar
// `width` wide and `height` tall (the page fills the room between the top row and the space bar;
// Create Space and Cancel sit at its bottom, under a Spacer that can shrink to nothing). The
// profile's row always shows: the Mac hides it only in an incognito window, which Windows hasn't.
struct SpaceCreationLayout {
    BarRect page;          // between the top row and the space bar, the sidebar's padding in
    BarRect illustration;  // the cards' frame, centred
    BarRect title, subtitle;  // their line boxes, the text centred in them
    BarRect name, about, profile, theme;  // the rows
    BarRect nameField, aboutField;  // the text fields: from the text's x to the row's trailing padding
    BarRect create;
    BarRect cancel;  // Cancel's line box, the page's width (its text is centred in it)
    bool operator==(const SpaceCreationLayout&) const = default;
};
SpaceCreationLayout LayOutSpaceCreation(float width, float height);

// What a press at (x, y) lands on. Cancel's own button is its text's width (`cancelWidth`), the
// profile's pill its own frame (`pill`, which the shell measures); a row's field is the field.
// kitecore, which measures no text, uses these for both.
inline constexpr float kEstimatedCancelWidth = 44;
BarRect EstimatedPill(const SpaceCreationLayout& layout);
enum class SpaceCreationPart { None, NameField, AboutField, ProfilePill, ChooseTheme, Create, Cancel };
SpaceCreationPart SpaceCreationPartAt(const SpaceCreationLayout& layout, float x, float y, float cancelWidth,
                                      const std::optional<BarRect>& pill = std::nullopt);
const char* SpaceCreationPartName(SpaceCreationPart part);

// MARK: Choose a Theme's swatches

// The theme editor's preset row (ThemeEditor.presets), which Choose a Theme opens in a popover off
// the row's trailing edge (preferredEdge .maxX, with its arrow): two 32pt chevrons at the ends
// (both off, Kite's presets fitting on one page) and 24pt swatches 29.5 apart from 40pt in,
// inside the editor's 8pt inset. The editor's colour grid, intensity and grain come with the
// theme editor; until then the popover holds the presets alone.
namespace theme_swatches_metrics {
constexpr float kInset = 8;
constexpr float kContentWidth = 356;  // ThemeEditor.contentSize.width
constexpr float kSwatchButton = 32;
constexpr float kSwatchesX = 40;
constexpr float kSwatchSize = 24;
constexpr float kSwatchPitch = 29.5f;
constexpr float kSwatchRing = 1.5f;      // white at 25%, inside the edge
constexpr float kSwatchRingOpacity = 0.25f;
constexpr float kChevronSize = 15, kChevronOpacity = 0.3f;
// NSPopover's arrow, pointing at the row: 13pt deep, as the UI gate measured the picker's and the
// theme editor's (the window is the content plus 13pt a side, its leading edge at the row's).
constexpr float kArrowWidth = 18, kArrowDepth = 13;
constexpr float kCornerRadius = 10;
constexpr float kHeight = kInset + kSwatchButton + kInset;
}  // namespace theme_swatches_metrics

struct ThemeSwatchesLayout {
    float width = 0, height = 0;  // the popover's body, points
    BarRect previous, next;       // the chevrons
    std::vector<BarRect> swatches;  // one per preset, in order
    bool operator==(const ThemeSwatchesLayout&) const = default;
};
ThemeSwatchesLayout LayOutThemeSwatches(size_t presets);
// The swatch under (x, y), body points.
std::optional<size_t> ThemeSwatchAt(const ThemeSwatchesLayout& layout, float x, float y);
// Where the popover's body goes for the Choose a Theme row `row` (window points): its arrow's tip
// on the row's trailing edge, its middle level with the row's.
struct SwatchesPlacement {
    float left = 0, top = 0;  // the body's top-left
    float arrowY = 0;         // the arrow's middle, from the body's top
    bool operator==(const SwatchesPlacement&) const = default;
};
SwatchesPlacement PlaceThemeSwatches(const BarRect& row, const ThemeSwatchesLayout& layout);
// The preset a space's theme matches (its colours and grain, whatever its intensity), if any.
std::optional<size_t> PresetOf(const Theme& theme);

}  // namespace kite
