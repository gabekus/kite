// See Favorites.h.

#include "core/Favorites.h"

#include <algorithm>
#include <cmath>
#include <map>

#include "core/ColorSpaces.h"

namespace kite {

namespace {

namespace M = favorites_metrics;
namespace E = favorites_empty;

}  // namespace

namespace favorites_empty {

float LineHeight(float size) { return std::ceil(size * (kAscender + kDescender)); }
float LinePitch(float size) { return std::ceil(size * kAscender) + std::ceil(size * kDescender); }
float LabelHeight(float size, int lines) { return lines <= 1 ? LineHeight(size) : static_cast<float>(lines) * LinePitch(size); }
const SymbolShape& CloseShape() {
    static const SymbolShape shape = [] {
        constexpr float half = kCloseStroke / 2, reach = kCloseInk / 2 - half;
        ShapeBuilder b;
        AddStroke(b, ShapePoint{-reach, -reach}, ShapePoint{reach, reach}, half);
        AddStroke(b, ShapePoint{-reach, reach}, ShapePoint{reach, -reach}, half);
        return b.Build();
    }();
    return shape;
}

float Height(int titleLines, int subtitleLines) {
    return std::max(M::kHeight, LabelHeight(kTitleSize, titleLines) + kTextGap + LabelHeight(kSubtitleSize, subtitleLines)) + 2 * kPadding;
}

}  // namespace favorites_empty

int FavoritesColumns(size_t count, float width) {
    if (count == 0) return 1;
    const int n = static_cast<int>(count);
    const int fit = std::max(static_cast<int>(std::floor((width + M::kSpacing) / (M::kHeight + M::kSpacing))), 1);
    const int c = std::min({n, M::kColumns, fit});
    const int rows = (n + c - 1) / c;
    return (n + rows - 1) / rows;
}

std::vector<SidebarGroup> GroupBySplit(const std::vector<std::string>& ids, const std::vector<SplitView>& splits) {
    std::vector<SidebarGroup> groups;
    std::map<std::string, size_t> splitRow;
    for (size_t index = 0; index < ids.size(); ++index) {
        const auto split = std::find_if(splits.begin(), splits.end(), [&](const SplitView& s) {
            return std::find(s.tabIDs.begin(), s.tabIDs.end(), ids[index]) != s.tabIDs.end();
        });
        if (split == splits.end()) {
            groups.push_back(SidebarGroup{ids[index], nullptr, {index}});
        } else if (auto row = splitRow.find(split->id); row != splitRow.end()) {
            groups[row->second].indices.push_back(index);
        } else {
            splitRow.emplace(split->id, groups.size());
            groups.push_back(SidebarGroup{split->id, &*split, {index}});
        }
    }
    return groups;
}

const std::vector<Tab>& FavoritesOf(const BrowserState& state, size_t space) {
    static const std::vector<Tab> kNone;
    if (space >= state.spaces.size()) return kNone;
    const auto it = state.favoritesByProfile.find(state.ProfileDirectory(space));
    return it == state.favoritesByProfile.end() ? kNone : it->second;
}

const std::vector<SplitView>& FavoriteSplitsOf(const BrowserState& state, size_t space) {
    static const std::vector<SplitView> kNone;
    if (space >= state.spaces.size()) return kNone;
    const auto it = state.favoriteSplitsByProfile.find(state.ProfileDirectory(space));
    return it == state.favoriteSplitsByProfile.end() ? kNone : it->second;
}

std::vector<FavoriteTile> FavoriteTilesOf(const BrowserState& state, size_t space) {
    const std::vector<Tab>& favorites = FavoritesOf(state, space);
    std::vector<std::string> ids;
    ids.reserve(favorites.size());
    for (const Tab& tab : favorites) ids.push_back(tab.id);
    // rebuild's selectedID: the space's selected tab, which a favorite is when it's shown.
    const std::optional<std::string>& selected = space < state.spaces.size() ? state.spaces[space].selectedTabID : std::nullopt;
    std::vector<FavoriteTile> tiles;
    for (const SidebarGroup& group : GroupBySplit(ids, FavoriteSplitsOf(state, space))) {
        FavoriteTile tile;
        tile.id = group.id;
        tile.split = group.split != nullptr;
        tile.vertical = group.split && group.split->orientation == "vertical";
        for (size_t index : group.indices) {
            const Tab& tab = favorites[index];
            tile.panes.push_back(FavoritePane{tab.id, tab.DisplayTitle(), FaviconSourceOf(tab.url, tab.faviconURL),
                                              selected && *selected == tab.id, {}});
        }
        tiles.push_back(std::move(tile));
    }
    return tiles;
}

FavoritesTray LayOutFavorites(std::vector<FavoriteTile> tiles, float sidebarWidth, bool emptyStateDismissed, float emptyHeight) {
    FavoritesTray tray;
    tray.tiles = std::move(tiles);
    const float width = sidebarWidth - 2 * sidebar_metrics::kPadding;
    const float top = FavoritesTop() + M::kTopGap;
    if (tray.tiles.empty()) {
        // rebuild: with no favorites, the empty state until it's dismissed (and, with W18b, while a
        // drag needs somewhere to drop).
        if (emptyStateDismissed) return tray;
        tray.emptyState = true;
        tray.height = M::kTopGap + emptyHeight + M::kBottomGap;
        tray.emptyFrame = BarRect{sidebar_metrics::kPadding, top, sidebar_metrics::kPadding + width, top + emptyHeight};
        const float closeRight = tray.emptyFrame.right - E::kCloseInset, closeTop = top + E::kPadding + E::kCloseInset;
        tray.closeFrame = BarRect{closeRight - E::kCloseSize, closeTop, closeRight, closeTop + E::kCloseSize};
        return tray;
    }
    const size_t count = tray.tiles.size();
    tray.columns = FavoritesColumns(count, width);
    const size_t cols = static_cast<size_t>(tray.columns);
    const size_t rows = (count + cols - 1) / cols;
    const float content = static_cast<float>(rows) * M::kHeight + static_cast<float>(rows - 1) * M::kSpacing;
    tray.height = M::kTopGap + content + M::kBottomGap;
    const float tileWidth = (width - M::kSpacing * static_cast<float>(cols - 1)) / static_cast<float>(cols);
    for (size_t i = 0; i < count; ++i) {
        FavoriteTile& tile = tray.tiles[i];
        const float x = sidebar_metrics::kPadding + static_cast<float>(i % cols) * (tileWidth + M::kSpacing);
        const float y = top + static_cast<float>(i / cols) * (M::kHeight + M::kSpacing);
        tile.frame = BarRect{x, y, x + tileWidth, y + M::kHeight};
        // FavoriteTileView.layout: its panes share it, 2pt apart.
        const float n = static_cast<float>(std::max<size_t>(tile.panes.size(), 1));
        for (size_t p = 0; p < tile.panes.size(); ++p) {
            const float at = static_cast<float>(p);
            if (tile.vertical) {
                const float h = (M::kHeight - M::kSplitSpacing * (n - 1)) / n;
                tile.panes[p].frame = BarRect{x, y + at * (h + M::kSplitSpacing), x + tileWidth, y + at * (h + M::kSplitSpacing) + h};
            } else {
                const float w = (tileWidth - M::kSplitSpacing * (n - 1)) / n;
                tile.panes[p].frame = BarRect{x + at * (w + M::kSplitSpacing), y, x + at * (w + M::kSplitSpacing) + w, y + M::kHeight};
            }
        }
    }
    return tray;
}

FavoritesTray LayOutFavorites(const BrowserState& state, size_t space, float width, bool emptyStateDismissed) {
    return LayOutFavorites(FavoriteTilesOf(state, space), width, emptyStateDismissed);
}

bool InFavorites(const FavoritesTray& tray, float width, float x, float y) {
    return tray.height > 0 && x >= 0 && x < width && y >= FavoritesTop() && y < FavoritesTop() + tray.height;
}

std::optional<FavoriteHit> FavoritePaneAt(const FavoritesTray& tray, float x, float y) {
    size_t index = 0;
    for (size_t t = 0; t < tray.tiles.size(); ++t) {
        const FavoriteTile& tile = tray.tiles[t];
        if (!tile.frame.Contains(x, y)) {
            index += tile.panes.size();
            continue;
        }
        for (size_t p = 0; p < tile.panes.size(); ++p) {
            if (tile.panes[p].frame.Contains(x, y)) return FavoriteHit{t, p, index + p};
        }
        return std::nullopt;  // the gap between a split's panes
    }
    return std::nullopt;
}

const FavoritePane* FavoritePaneWithTab(const FavoritesTray& tray, const std::string& tabID) {
    for (const FavoriteTile& tile : tray.tiles) {
        for (const FavoritePane& pane : tile.panes) {
            if (pane.tabID == tabID) return &pane;
        }
    }
    return nullptr;
}

bool OverEmptyState(const FavoritesTray& tray, float x, float y) { return tray.emptyState && tray.emptyFrame.Contains(x, y); }

bool OverEmptyStateClose(const FavoritesTray& tray, float x, float y) { return tray.emptyState && tray.closeFrame.Contains(x, y); }

std::optional<FavoritePress> FavoritePressAt(const FavoritesTray& tray, float x, float y, bool activating) {
    // The close button shows while the pointer is over the empty state, so a press on it is its.
    if (OverEmptyStateClose(tray, x, y)) return FavoritePress{FavoritePress::Target::CloseEmptyState, {}, x, y, false};
    if (activating) return std::nullopt;  // a pane's acceptsFirstMouse: false
    const std::optional<FavoriteHit> hit = FavoritePaneAt(tray, x, y);
    if (!hit) return std::nullopt;
    return FavoritePress{FavoritePress::Target::Pane, tray.tiles[hit->tile].panes[hit->pane].tabID, x, y, false};
}

void FavoriteMove(FavoritePress& press, float x, float y) {
    if (press.target == FavoritePress::Target::Pane && !press.dragged && std::hypot(x - press.x, y - press.y) >= M::kDragDistance) {
        press.dragged = true;
    }
}

FavoriteTap FavoriteRelease(const FavoritePress& press, const FavoritesTray& tray, float x, float y) {
    if (press.target == FavoritePress::Target::CloseEmptyState) {
        // SymbolButton: let go over itself.
        if (OverEmptyStateClose(tray, x, y)) return FavoriteTap{FavoriteTap::Action::DismissEmptyState, {}};
        return {};
    }
    if (press.dragged) return {};
    const FavoritePane* pane = FavoritePaneWithTab(tray, press.tabID);
    if (!pane || !pane->frame.Contains(x, y)) return {};
    return FavoriteTap{FavoriteTap::Action::SelectTab, press.tabID};
}

FavoriteLook FavoriteLookOf(bool selected, bool hovered, bool dark, bool hasColor) {
    FavoriteLook look;
    if (selected) {
        look.fill = dark ? M::kSelectedFill : M::kSelectedFillLight;
        if (hasColor) look.tint = dark ? (hovered ? M::kTintHovered : M::kTint) : (hovered ? M::kTintHoveredLight : 0);
        look.ring = hasColor;
    } else {
        // chromeFill: the strength on a dark theme, 3.5 times it (at most 0.7) on a light one.
        const float strength = hovered ? M::kFieldFill + M::kHoverFill : M::kFieldFill;
        look.fill = dark ? strength : std::min(strength * 3.5f, 0.7f);
    }
    return look;
}

std::optional<ThemeColor> DominantColor(const uint8_t* bgra, uint32_t width, uint32_t height, size_t stride) {
    if (!bgra) return std::nullopt;
    struct Bin {
        int count = 0;
        double r = 0, g = 0, b = 0;
    };
    Bin bins[12];
    for (uint32_t y = 0; y < height; ++y) {
        const uint8_t* row = bgra + y * stride;
        for (uint32_t x = 0; x < width; ++x) {
            const uint8_t* p = row + x * 4;
            const double a = p[3] / 255.0;
            if (a <= 0.5) continue;
            // NSColor's components are the colour itself, not premultiplied.
            const double r = std::min(1.0, p[2] / 255.0 / a), g = std::min(1.0, p[1] / 255.0 / a), b = std::min(1.0, p[0] / 255.0 / a);
            // HSB, as NSColor's hue, saturation and brightness components.
            const double max = std::max({r, g, b}), min = std::min({r, g, b});
            const double brightness = max;
            const double saturation = max > 0 ? (max - min) / max : 0;
            if (saturation <= 0.25 || brightness <= 0.15) continue;
            double hue = 0;
            const double delta = max - min;
            if (max == r) hue = std::fmod((g - b) / delta, 6.0);
            else if (max == g) hue = (b - r) / delta + 2;
            else hue = (r - g) / delta + 4;
            hue /= 6;
            if (hue < 0) hue += 1;
            const int bin = static_cast<int>(hue * 12) % 12;
            bins[bin].count += 1;
            bins[bin].r += r;
            bins[bin].g += g;
            bins[bin].b += b;
        }
    }
    const Bin* top = nullptr;
    for (const Bin& bin : bins) {
        if (bin.count > 0 && (!top || bin.count > top->count)) top = &bin;
    }
    if (!top) return std::nullopt;
    const double n = top->count;
    return ThemeColor{static_cast<float>(top->r / n), static_cast<float>(top->g / n), static_cast<float>(top->b / n)};
}

FavoriteRedraw FavoriteRedrawFor(const std::optional<std::pair<BarRect, FaviconSource>>& drawn, const FavoritePane& now,
                                 bool appearanceChanged) {
    if (!drawn || drawn->first != now.frame) return FavoriteRedraw{true, true, true};
    FavoriteRedraw redraw;
    if (drawn->second != now.favicon) redraw.icon = redraw.tint = true;
    if (appearanceChanged) redraw.icon = true;
    return redraw;
}

ThemeColor FavoriteHighlight(ThemeColor dominant) {
    // FavoritePaneView.color: highlight.blended(withFraction: 0.5, of: .white), in calibrated RGB as
    // NSColor mixes (YouTube's red rings (255, 149, 150) on the Mac; an sRGB mix gives 129s).
    const color::Color mixed = color::BlendCalibrated(color::Color{dominant.r, dominant.g, dominant.b, 1}, color::Color{1, 1, 1, 1},
                                                      favorites_metrics::kHighlightWhiten);
    return ThemeColor{mixed.r, mixed.g, mixed.b};
}

}  // namespace kite
