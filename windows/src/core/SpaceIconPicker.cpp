// See SpaceIconPicker.h.

#include "core/SpaceIconPicker.h"

#include <algorithm>
#include <cmath>
#include <iterator>
#include <utility>

#include "core/Unicode.h"

namespace kite {
namespace {

namespace M = icon_picker_metrics;

struct EmojiCategorySource {
    std::string_view name, symbol, emoji;
};
struct CodePointName {
    char32_t codePoint;
    std::string_view name;
};

#include "core/EmojiCatalog.inc"

// The category bar's SF Symbols (EmojiCatalog.categories' `symbol`) and the bin's, each as a
// glyph in Segoe Fluent Icons then Segoe MDL2 Assets, both checked against the fonts' cmaps
// (Fluent 1.54, MDL2 1.86) and picked by eye from every glyph they have. Neither font has a
// rosette: Activity's is the certificate's ribbon medal.
struct BarSymbol {
    std::string_view symbol;
    SymbolGlyph glyph;
};
constexpr BarSymbol kBarSymbols[] = {
    {"face.smiling", {u'', u''}},    // Emoji
    {"sun.max", {u'', u''}},         // Brightness
    {"cup.and.saucer", {u'', u''}},  // a cup
    {"rosette", {u'', u''}},         // Certificate
    {"car", {u'', u''}},             // Car
    {"lightbulb", {u'', u''}},       // Lightbulb
    {"heart", {u'', u''}},           // Heart
    {"flag", {u'', u''}},            // Flag
};
constexpr SymbolGlyph kTrash{u'', u''};  // Delete

SymbolGlyph BarGlyph(std::string_view symbol) {
    for (const BarSymbol& s : kBarSymbols) {
        if (s.symbol == symbol) return s.glyph;
    }
    return {};
}

bool IsNewline(char32_t c) { return c == 0x0A || c == 0x0B || c == 0x0C || c == 0x0D || c == 0x85 || c == 0x2028 || c == 0x2029; }

// Swift's trimmingCharacters(in: .whitespaces): spaces and tabs (Unicode's White_Space less its
// line and paragraph breaks, which is Zs and U+0009), not newlines.
std::string TrimSpaces(std::string_view text) {
    const std::vector<char32_t> points = unicode::Decode(text);
    size_t begin = 0, end = points.size();
    auto space = [](char32_t c) { return unicode::IsWhitespace(c) && !IsNewline(c); };
    while (begin < end && space(points[begin])) ++begin;
    while (end > begin && space(points[end - 1])) --end;
    return unicode::Encode(std::u32string(points.begin() + static_cast<std::ptrdiff_t>(begin), points.begin() + static_cast<std::ptrdiff_t>(end)));
}

std::string AsciiLower(std::string_view text) {
    std::string out(text);
    for (char& c : out) {
        if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    }
    return out;
}

}  // namespace

std::string_view IconPickerTabTitle(IconPickerTab tab) {
    switch (tab) {
    case IconPickerTab::Emoji: return "Emoji";
    case IconPickerTab::Icon: return "Icon";
    case IconPickerTab::Image: return "Image";
    }
    return {};
}

bool IconPickerTabAvailable(IconPickerTab tab) { return tab != IconPickerTab::Image; }

IconPickerTab IconPickerOpeningTab(std::string_view icon) {
    if (icon.starts_with(kSymbolIconPrefix)) return IconPickerTab::Icon;
    // A picture's is Image on the Mac, which Windows doesn't have yet.
    return IconPickerTab::Emoji;
}

const std::vector<EmojiCategory>& EmojiCategories() {
    static const std::vector<EmojiCategory> categories = [] {
        std::vector<EmojiCategory> out;
        for (const EmojiCategorySource& source : kEmojiCategorySources) {
            EmojiCategory category{std::string(source.name), std::string(source.symbol), BarGlyph(source.symbol), {}};
            // chars(): the string's Characters, as Swift's map(String.init) splits it.
            for (const std::u32string& character : unicode::Characters(source.emoji)) category.emoji.push_back(unicode::Encode(character));
            out.push_back(std::move(category));
        }
        return out;
    }();
    return categories;
}

const std::vector<std::string>& AllEmoji() {
    static const std::vector<std::string> all = [] {
        std::vector<std::string> out;
        for (const EmojiCategory& category : EmojiCategories()) out.insert(out.end(), category.emoji.begin(), category.emoji.end());
        return out;
    }();
    return all;
}

std::string EmojiName(std::string_view emoji) {
    std::string name;
    for (const char32_t c : unicode::Decode(emoji)) {
        const auto it = std::lower_bound(std::begin(kEmojiCodePointNames), std::end(kEmojiCodePointNames), c,
                                         [](const CodePointName& entry, char32_t point) { return entry.codePoint < point; });
        if (it == std::end(kEmojiCodePointNames) || it->codePoint != c) return {};
        // ICU's names are ASCII capitals, so lowercased() is ASCII's.
        name += "\\n{" + AsciiLower(it->name) + "}";
    }
    return name;
}

std::vector<std::string> EmojiMatching(std::string_view query) {
    const std::string q = unicode::Lowercased(TrimSpaces(query));
    if (q.empty()) return AllEmoji();
    // Each emoji's name, worked out once (the Mac caches them too).
    static const std::vector<std::string> names = [] {
        std::vector<std::string> out;
        for (const std::string& emoji : AllEmoji()) out.push_back(EmojiName(emoji));
        return out;
    }();
    // Every name is ASCII, so Swift's contains compares what can match byte for byte.
    std::vector<std::string> out;
    for (size_t i = 0; i < names.size(); ++i) {
        if (names[i].find(q) != std::string::npos) out.push_back(AllEmoji()[i]);
    }
    return out;
}

SymbolGlyph RemoveIconGlyph() { return kTrash; }

std::optional<IconPickerState> OpenIconPicker(const BrowserState& state, const std::string& spaceID) {
    const auto index = state.SpaceIndex(spaceID);
    if (!index) return std::nullopt;
    IconPickerState picker;
    picker.spaceID = spaceID;
    picker.tab = IconPickerOpeningTab(state.spaces[*index].icon);
    return picker;
}

IconPickerLayout LayOutIconPicker(IconPickerTab tab, bool removable) {
    IconPickerLayout layout;
    layout.width = M::kWidth;
    // HStack(spacing: 8) { Picker.segmented; the bin }, inset 12 on three sides.
    float tabsRight = M::kWidth - M::kInset;
    if (removable) {
        const float binLeft = tabsRight - M::kRemoveWidth;
        layout.remove = PickerRect{binLeft, M::kInset, tabsRight, M::kInset + M::kTabsHeight};
        tabsRight = binLeft - M::kSpacing;
    }
    layout.tabs = PickerRect{M::kInset, M::kInset, tabsRight, M::kInset + M::kTabsHeight};
    const float segment = layout.tabs.Width() / static_cast<float>(std::size(kIconPickerTabs));
    for (size_t i = 0; i < std::size(kIconPickerTabs); ++i) {
        const float left = layout.tabs.left + segment * static_cast<float>(i);
        layout.segments.push_back(PickerRect{left, layout.tabs.top, left + segment, layout.tabs.bottom});
    }
    float y = layout.tabs.bottom;
    if (tab == IconPickerTab::Emoji) {
        y += M::kSearchTop;
        layout.search = PickerRect{M::kInset, y, M::kWidth - M::kInset, y + M::kSearchHeight};
        y += M::kSearchHeight;
        layout.grid = PickerRect{0, y, M::kWidth, y + M::kEmojiGridHeight};
        layout.columns = M::kEmojiColumns;
        layout.pitch = M::kEmojiPitch;
        y = layout.grid.bottom;
        layout.divider = PickerRect{M::kInset, y, M::kWidth - M::kInset, y + M::kDividerThickness};
        y += M::kDividerThickness;
        // HStack(spacing: 0) of buttons with maxWidth .infinity: equal shares of the row.
        const float share = (M::kWidth - 2 * M::kInset) / static_cast<float>(EmojiCategories().size());
        for (size_t i = 0; i < EmojiCategories().size(); ++i) {
            const float left = M::kInset + share * static_cast<float>(i);
            layout.categories.push_back(PickerRect{left, y, left + share, y + M::kCategoryHeight});
        }
        y += M::kCategoryHeight + M::kCategoryBottom;
    } else if (tab == IconPickerTab::Icon) {
        y += M::kIconGridTop;
        layout.columns = M::kIconColumns;
        layout.pitch = M::kIconPitch;
        const float height = static_cast<float>(IconPickerRows(IconTabSymbols().size(), M::kIconColumns)) * M::kRowPitch;
        layout.grid = PickerRect{0, y, M::kWidth, y + height};
        y = layout.grid.bottom + M::kInset;
    } else {
        // The Image tab: not on Windows yet (it never shows; its segment is disabled).
        y += M::kInset;
    }
    if (layout.columns) layout.gridLeft = (M::kWidth - layout.pitch * static_cast<float>(layout.columns)) / 2;
    layout.height = y;
    return layout;
}

std::vector<std::string> IconPickerCells(const IconPickerState& state) {
    switch (state.tab) {
    case IconPickerTab::Emoji: return EmojiMatching(state.query);
    case IconPickerTab::Icon: {
        std::vector<std::string> out;
        for (const std::string_view name : IconTabSymbols()) out.push_back(std::string(kSymbolIconPrefix) + std::string(name));
        return out;
    }
    case IconPickerTab::Image: return {};
    }
    return {};
}

size_t IconPickerRows(size_t cells, size_t columns) { return columns ? (cells + columns - 1) / columns : 0; }

float IconPickerMaxScroll(size_t cells) {
    const float content = static_cast<float>(IconPickerRows(cells, M::kEmojiColumns)) * M::kRowPitch;
    return std::max(0.0f, content - M::kEmojiGridHeight);
}

PickerRect IconPickerCellFrame(const IconPickerLayout& layout, size_t index, float scroll) {
    if (!layout.columns) return {};
    const float column = static_cast<float>(index % layout.columns), row = static_cast<float>(index / layout.columns);
    const float centre = layout.grid.left + layout.gridLeft + layout.pitch * (column + 0.5f);
    const float top = layout.grid.top + row * M::kRowPitch - scroll;
    return PickerRect{centre - M::kEmojiPitch / 2, top, centre + M::kEmojiPitch / 2, top + M::kRowPitch};
}

std::pair<size_t, size_t> IconPickerVisibleRows(const IconPickerLayout& layout, size_t cells, float scroll) {
    const size_t rows = IconPickerRows(cells, layout.columns);
    if (!rows) return {0, 0};
    const auto first = static_cast<size_t>(std::max(0.0f, std::floor(scroll / M::kRowPitch)));
    const auto end = static_cast<size_t>(std::max(0.0f, std::ceil((scroll + layout.grid.Height()) / M::kRowPitch)));
    return {std::min(first, rows), std::min(end, rows)};
}

IconPickerHit IconPickerHitTest(const IconPickerLayout& layout, const IconPickerState& state, size_t cells, float x, float y) {
    using Target = IconPickerHit::Target;
    for (size_t i = 0; i < layout.segments.size(); ++i) {
        if (layout.segments[i].Contains(x, y)) {
            return IconPickerTabAvailable(kIconPickerTabs[i]) ? IconPickerHit{Target::Tab, i} : IconPickerHit{};
        }
    }
    if (layout.remove && layout.remove->Contains(x, y)) return {Target::Remove, 0};
    if (layout.search && layout.search->Contains(x, y)) return {Target::Search, 0};
    for (size_t i = 0; i < layout.categories.size(); ++i) {
        if (layout.categories[i].Contains(x, y)) return {Target::Category, i};
    }
    if (!layout.columns || !layout.grid.Contains(x, y)) return {};
    const float scroll = state.tab == IconPickerTab::Emoji ? state.scroll : 0;
    const float inGrid = y - layout.grid.top + scroll;
    const auto row = static_cast<size_t>(std::floor(inGrid / M::kRowPitch));
    // The later of two overlapping frames: the column whose frame starts at or before x, last.
    const float fromLeft = x - layout.grid.left - layout.gridLeft + (M::kEmojiPitch - layout.pitch) / 2;
    if (fromLeft < 0) return {};
    const size_t column = std::min(static_cast<size_t>(std::floor(fromLeft / layout.pitch)), layout.columns - 1);
    const size_t index = row * layout.columns + column;
    if (index >= cells) return {};
    const PickerRect frame = IconPickerCellFrame(layout, index, scroll);
    if (!frame.Contains(x, y)) return {};
    return {Target::Cell, index};
}

void SelectIconPickerTab(IconPickerState& state, IconPickerTab tab) {
    if (!IconPickerTabAvailable(tab) || tab == state.tab) return;
    state.tab = tab;
    state.scroll = 0;
}

std::vector<std::string> SetIconPickerQuery(IconPickerState& state, std::string query) {
    state.query = std::move(query);
    std::vector<std::string> cells = EmojiMatching(state.query);
    state.scroll = std::clamp(state.scroll, 0.0f, IconPickerMaxScroll(cells.size()));
    return cells;
}

void SelectIconPickerCategory(IconPickerState& state, size_t category) {
    const auto& categories = EmojiCategories();
    if (category >= categories.size()) return;
    const bool changed = category != state.category;
    state.query.clear();
    state.category = category;
    const std::vector<std::string>& all = AllEmoji();
    if (changed && !categories[category].emoji.empty()) {
        // proxy.scrollTo(first, anchor: .top): the first cell with that id, its row at the top.
        const auto first = std::find(all.begin(), all.end(), categories[category].emoji.front());
        const auto index = static_cast<size_t>(first - all.begin());
        state.scroll = static_cast<float>(index / M::kEmojiColumns) * M::kRowPitch;
    }
    state.scroll = std::clamp(state.scroll, 0.0f, IconPickerMaxScroll(all.size()));
}

void ScrollIconPicker(IconPickerState& state, float distance, size_t cells) {
    if (state.tab != IconPickerTab::Emoji) return;
    state.scroll = std::clamp(state.scroll + distance, 0.0f, IconPickerMaxScroll(cells));
}

std::optional<std::string> PictureToDiscard(const std::string& oldIcon, const std::vector<Space>& spaces) {
    const std::string_view old = oldIcon;
    if (!old.starts_with(kImageIconPrefix)) return std::nullopt;
    if (std::any_of(spaces.begin(), spaces.end(), [&](const Space& space) { return space.icon == oldIcon; })) return std::nullopt;
    const std::string_view name = old.substr(kImageIconPrefix.size());
    if (!IsValidIconImageName(name)) return std::nullopt;
    return std::string(name);
}

std::optional<IconPick> PickSpaceIcon(BrowserState& state, const std::string& spaceID, std::string_view icon) {
    const auto index = state.SpaceIndex(spaceID);
    if (!index) return std::nullopt;
    const std::string old = state.spaces[*index].icon;
    state.SetSpaceIcon(spaceID, icon);
    return IconPick{state.spaces[*index].icon, PictureToDiscard(old, state.spaces)};
}

IconPickerPlacement PlaceIconPicker(const PickerRect& anchor, float contentWidth, float contentHeight, const PickerRect& screen) {
    IconPickerPlacement placement;
    placement.width = contentWidth;
    placement.height = contentHeight + M::kArrowHeight;
    const float tip = (anchor.left + anchor.right) / 2;
    placement.top = anchor.bottom;
    // Centred on the anchor, then inside the screen's margins (the left edge wins a screen too narrow).
    float left = tip - contentWidth / 2;
    left = std::min(left, screen.right - M::kScreenMargin - contentWidth);
    left = std::max(left, screen.left + M::kScreenMargin);
    placement.left = left;
    // The arrow stays on the anchor, but never over the rounded corners.
    const float inset = M::kCornerRadius + M::kArrowWidth / 2;
    placement.arrowX = std::clamp(tip - left, inset, std::max(inset, contentWidth - inset));
    return placement;
}

}  // namespace kite
