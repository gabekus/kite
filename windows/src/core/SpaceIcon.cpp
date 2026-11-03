#include "core/SpaceIcon.h"

#include <cmath>
#include <utility>

#include "core/OKLab.h"
#include "core/Unicode.h"

namespace kite {
namespace {

struct SymbolEntry {
    std::string_view name;
    SymbolGlyph glyph;
};

// Each SF Symbol's stand-in, in Segoe Fluent Icons then Segoe MDL2 Assets: the Icon tab's 56 in
// its order, then "briefcase" (the test sessions' Work space) and the picture placeholder's "photo".
// Each code point was checked against both fonts' cmaps (Fluent 1.54, MDL2 1.86) and picked by
// eye from every glyph they have. Where neither font has the object (`true`), Kite draws its own
// shape instead (core/SymbolShape.h), so there's no glyph.
constexpr SymbolEntry kSymbols[] = {
    {"star.fill", {u'\uE735', u'\uE735'}},
    {"bookmark.fill", {0, 0, true}},
    {"heart.fill", {u'\uEB52', u'\uEB52'}},
    {"flag.fill", {u'\uEB4B', u'\uEB4B'}},
    {"bolt.fill", {u'\uE945', u'\uE945'}},
    {"triangle.fill", {u'\uF139', u'\uF139'}},
    {"asterisk", {u'\uEA38', u'\uEA38'}},
    {"bell.fill", {u'\uF2A5', u'\uEA8F'}},
    {"lightbulb.fill", {u'\uEB4F', u'\uEB4F'}},
    {"square.on.circle.fill", {u'\uE74C', u'\uE74C'}},
    {"square.grid.2x2.fill", {u'\uF0E2', u'\uF0E2'}},
    {"circle.grid.3x3.fill", {u'\uE75F', u'\uE75F'}},
    {"square.3.layers.3d", {u'\uE81E', u'\uE81E'}},
    {"cylinder.split.1x2.fill", {u'\uEE94', u'\uEE94'}},
    {"tray.fill", {u'\uEC59', u'\uEC59'}},
    {"square.on.square.fill", {u'\uE8C8', u'\uE8C8'}},
    {"folder.fill", {u'\uE8D5', u'\uF12B'}},
    {"archivebox.fill", {u'\uE7B8', u'\uE7B8'}},
    {"calendar", {u'\uE787', u'\uE787'}},
    {"envelope.fill", {u'\uE715', u'\uE715'}},
    {"checkmark.square.fill", {u'\uE73D', u'\uE73D'}},
    {"doc.fill", {u'\uE729', u'\uE729'}},
    {"book.fill", {u'\uE82D', u'\uE82D'}},
    {"ellipsis.bubble.fill", {u'\uED0C', u'\uED0C'}},
    {"person.2.fill", {u'\uE716', u'\uE716'}},
    {"terminal.fill", {u'\uE756', u'\uE756'}},
    {"wrench.and.screwdriver.fill", {u'\uEC7A', u'\uEC7A'}},
    {"square.fill", {u'\uE73B', u'\uE73B'}},
    {"drop.fill", {u'\uEB42', u'\uEB42'}},
    {"circle.fill", {u'\uF63C', u'\uF63C'}},
    {"moon.fill", {u'\uF1DB', u'\uE708'}},
    {"sun.max.fill", {u'\uE706', u'\uE706'}},
    {"globe.americas.fill", {u'\uE909', u'\uE909'}},
    {"leaf.fill", {u'\uE8BE', u'\uE8BE'}},
    {"cloud.fill", {u'\uE753', u'\uE753'}},
    {"pawprint.fill", {0, 0, true}},
    {"basket.fill", {u'\uE7BF', u'\uE7BF'}},
    {"gift.fill", {u'\uF133', u'\uF133'}},
    {"bed.double.fill", {0, 0, true}},
    {"fork.knife", {0, 0, true}},
    {"dumbbell.fill", {0, 0, true}},
    {"airplane", {u'\uE709', u'\uE709'}},
    {"music.note", {u'\uEC4F', u'\uEC4F'}},
    {"paintpalette.fill", {u'\uF354', u'\uF354'}},
    {"video.fill", {u'\uEA0C', u'\uEA0C'}},
    {"bandage.fill", {0, 0, true}},
    {"chevron.left.forwardslash.chevron.right", {u'\uF54C', u'\uE943'}},
    {"baseball.fill", {0, 0, true}},
    {"cloud", {u'\uE753', u'\uE753'}},
    {"map.fill", {u'\uE800', u'\uE826'}},
    {"flame.fill", {u'\uECAD', u'\uECAD'}},
    {"takeoutbag.and.cup.and.straw.fill", {0, 0, true}},
    {"theatermasks.fill", {0, 0, true}},
    {"scroll.fill", {u'\uF000', u'\uF000'}},
    {"hand.thumbsup.fill", {u'\uF3BF', u'\uE8E1'}},
    {"tram.fill", {u'\uEB4D', u'\uEB4D'}},
    {"briefcase", {u'\uE821', u'\uE821'}},
    {"photo", {u'\uE91B', u'\uEB9F'}},
};
constexpr size_t kIconTabCount = 56;

}  // namespace

std::optional<SymbolGlyph> SymbolGlyphFor(std::string_view name) {
    for (const SymbolEntry& entry : kSymbols) {
        if (entry.name == name) return entry.glyph;
    }
    return std::nullopt;
}

const std::vector<std::string_view>& IconTabSymbols() {
    static const std::vector<std::string_view> names = [] {
        std::vector<std::string_view> out;
        for (size_t i = 0; i < kIconTabCount; ++i) out.push_back(kSymbols[i].name);
        return out;
    }();
    return names;
}

bool IsValidIconImageName(std::string_view name) {
    // By bytes where Swift compares characters (the leading dot, the separators and the colon):
    // a name starting with a dot and a combining mark passes on the Mac and not here, which
    // Kite's own (UUID) names never are.
    if (name.empty() || name.starts_with('.')) return false;
    if (name.find_first_of("/\\:") != std::string_view::npos) return false;
    // Swift's String.count: characters (grapheme clusters), not bytes.
    return unicode::Characters(name).size() <= 128;
}

PictureFrame PictureFrameAt(float x, float y, float size, float scale) {
    PictureFrame frame;
    const float side = std::round(size * 1.2f);
    frame.radius = side * 0.22f;
    frame.pixels = static_cast<unsigned>(std::lround(side * scale));
    frame.side = frame.pixels / scale;
    frame.left = std::round((x - frame.side / 2) * scale) / scale;
    frame.top = std::round((y - frame.side / 2) * scale) / scale;
    return frame;
}

bool GreysByTint(SpaceIconLook::Kind kind) { return kind == SpaceIconLook::Kind::Symbol; }

SpaceIconLook SpaceIconLookOf(const std::string& icon, const Theme& theme) {
    SpaceIconLook look;
    if (icon.empty()) return look;
    const std::string_view view = icon;
    if (view.starts_with(kImageIconPrefix)) {
        look.kind = SpaceIconLook::Kind::Picture;
        const std::string_view name = view.substr(kImageIconPrefix.size());
        if (IsValidIconImageName(name)) look.text = name;
        return look;
    }
    if (view.starts_with(kSymbolIconPrefix)) {
        look.text = view.substr(kSymbolIconPrefix.size());
        look.glyph = SymbolGlyphFor(look.text);
        if (!look.glyph) return look;  // the dot
        look.kind = SpaceIconLook::Kind::Symbol;
        look.accent = Accent(theme);
        return look;
    }
    look.kind = SpaceIconLook::Kind::Emoji;
    look.text = icon;
    return look;
}

}  // namespace kite
