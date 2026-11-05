// See FavoritesView.h.

#include "shell/FavoritesView.h"

#include <algorithm>
#include <cmath>

#include "shell/Errors.h"
#include "shell/SpaceIconPainter.h"
#include "shell/Text.h"

using Microsoft::WRL::ComPtr;

namespace kite {

namespace {

namespace F = favorites_metrics;
namespace E = favorites_empty;

// NSColor.labelColor: black (light) or white (dark) at 85%.
constexpr float kLabelAlpha = 0.85f;

D2D1_ROUNDED_RECT Rounded(D2D1_RECT_F r, float radius) { return D2D1::RoundedRect(r, radius, radius); }

// A label's line box (as core's LabelHeight) for DirectWrite: each line `pitch` tall with its
// baseline where SF's is in CenteredLabel's.
void SetLines(IDWriteTextLayout* layout, float size, int lines) {
    if (lines > 1) {
        const float pitch = E::LinePitch(size);
        layout->SetLineSpacing(DWRITE_LINE_SPACING_METHOD_UNIFORM, pitch, pitch - std::ceil(size * E::kDescender));
    } else {
        layout->SetLineSpacing(DWRITE_LINE_SPACING_METHOD_UNIFORM, E::LineHeight(size), size * E::kAscender);
    }
}

}  // namespace

std::unique_ptr<FavoritesView> FavoritesView::Create(HWND window, IDWriteFactory* dwrite, Favicons* favicons, bool tooltips,
                                                     std::wstring& error) {
    std::unique_ptr<FavoritesView> view(new FavoritesView(window, favicons, tooltips));
    view->dwrite_ = dwrite;
    ComPtr<IDWriteFontCollection> fonts;
    dwrite->GetSystemFontCollection(fonts.GetAddressOf());
    auto installed = [&](const wchar_t* family) {
        UINT32 index = 0;
        BOOL exists = FALSE;
        return fonts && SUCCEEDED(fonts->FindFamilyName(family, &index, &exists)) && exists;
    };
    // The system UI font for the Mac's SF Pro, as the rest of the sidebar.
    const wchar_t* text = installed(L"Segoe UI Variable Text") ? L"Segoe UI Variable Text" : L"Segoe UI";
    HRESULT hr = dwrite->CreateTextFormat(text, nullptr, DWRITE_FONT_WEIGHT_SEMI_BOLD, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
                                          E::kTitleSize, L"", view->titleFormat_.GetAddressOf());
    if (SUCCEEDED(hr)) {
        hr = dwrite->CreateTextFormat(text, nullptr, DWRITE_FONT_WEIGHT_REGULAR, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
                                      E::kSubtitleSize, L"", view->subtitleFormat_.GetAddressOf());
    }
    if (FAILED(hr)) {
        error = HResultMessage(L"CreateTextFormat (the favorites)", hr);
        return nullptr;
    }
    // Each line centred, wrapped at word breaks (CenteredLabel with `wraps`).
    for (IDWriteTextFormat* f : {view->titleFormat_.Get(), view->subtitleFormat_.Get()}) {
        f->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
        f->SetWordWrapping(DWRITE_WORD_WRAPPING_WRAP);
    }
    return view;
}

FavoritesView::~FavoritesView() {
    ReleaseGpu();
    if (container_ && parent_) parent_->RemoveVisual(container_.Get());
}

void FavoritesView::UseCompositor(Compositor* compositor, IDCompositionVisual* parent) {
    ReleaseGpu();
    if (container_ && parent_) parent_->RemoveVisual(container_.Get());
    container_.Reset();
    compositor_ = compositor;
    parent_ = parent;
    deviceLost_ = false;
}

void FavoritesView::ReleaseGpu() {
    // The panes keep what they show; everything is drawn again on the new device.
    for (auto& [id, gpu] : gpu_) {
        if (gpu.visual && container_) container_->RemoveVisual(gpu.visual.Get());
        gpu = PaneGpu{};
    }
    for (FadedLayer* layer : {&emptyBox_, &emptyClose_}) {
        if (layer->visual && container_) container_->RemoveVisual(layer->visual.Get());
        *layer = FadedLayer{};
    }
    emptyDirty_ = true;
    closeOpacity_.reset();
    brush_.Reset();
    dashes_.Reset();
    closeShape_.Reset();
    closeShapeTried_ = false;
    placed_ = false;
}

bool FavoritesView::Update(FavoritesTray tray, bool dark, float left) {
    if (tray == tray_ && dark == dark_ && left == left_) return false;
    const bool appearance = dark != dark_;
    if (appearance || tray.emptyFrame != tray_.emptyFrame) emptyDirty_ = true;
    dark_ = dark;
    left_ = left;
    tray_ = std::move(tray);
    panes_.clear();
    urls_.clear();
    for (const FavoriteTile& tile : tray_.tiles) {
        for (const FavoritePane& pane : tile.panes) {
            panes_.push_back(&pane);
            if (pane.favicon.url) urls_.insert(*pane.favicon.url);
        }
    }
    // Each pane against what its layers were drawn for: a new frame draws them all, a new favicon
    // its icon and colour, a new appearance its icon; a selection moving draws nothing.
    std::set<std::string> shown;
    paneGpu_.clear();
    for (const FavoritePane* pane : panes_) {
        shown.insert(pane->tabID);
        PaneGpu& gpu = gpu_[pane->tabID];
        const FavoriteRedraw redraw = FavoriteRedrawFor(gpu.drawn, *pane, appearance);
        gpu.redraw.wash |= redraw.wash;
        gpu.redraw.tint |= redraw.tint;
        gpu.redraw.icon |= redraw.icon;
        paneGpu_.push_back(&gpu);
    }
    // Panes no longer in the grid go, GPU side and all; and the empty state once there's none.
    for (auto it = gpu_.begin(); it != gpu_.end();) {
        if (shown.contains(it->first)) {
            ++it;
            continue;
        }
        if (it->second.visual && container_) container_->RemoveVisual(it->second.visual.Get());
        it = gpu_.erase(it);
    }
    if (!tray_.emptyState) {
        for (FadedLayer* layer : {&emptyBox_, &emptyClose_}) {
            if (layer->visual && container_) container_->RemoveVisual(layer->visual.Get());
            *layer = FadedLayer{};
        }
        closeOpacity_.reset();
        emptyHover_ = false;
    }
    std::erase_if(colors_, [&](const auto& entry) { return !urls_.contains(entry.first); });
    if (hover_ && *hover_ >= panes_.size()) hover_.reset();
    UpdateTooltips();
    return Place();
}

float FavoritesView::EmptyStateHeight(float width) {
    if (const auto known = emptyHeights_.find(width); known != emptyHeights_.end()) return known->second;
    // Its lines at the box's width within the 16pt insets.
    const float inner = std::max(1.0f, width - 2 * sidebar_metrics::kPadding - 2 * E::kInset);
    const auto lines = [&](const char* text, IDWriteTextFormat* format, int fallback) {
        const std::wstring wide = Widen(text);
        ComPtr<IDWriteTextLayout> layout;
        DWRITE_TEXT_METRICS metrics{};
        if (FAILED(dwrite_->CreateTextLayout(wide.c_str(), static_cast<UINT32>(wide.size()), format, inner, 1000, layout.GetAddressOf())) ||
            FAILED(layout->GetMetrics(&metrics))) {
            return fallback;
        }
        return static_cast<int>(std::max<UINT32>(metrics.lineCount, 1));
    };
    const float height = E::Height(lines(E::kTitle, titleFormat_.Get(), E::kTitleLines), lines(E::kSubtitle, subtitleFormat_.Get(), E::kSubtitleLines));
    emptyHeights_.emplace(width, height);
    return height;
}

void FavoritesView::Layout(UINT dpi) {
    if (dpi == dpi_) return;
    dpi_ = dpi;
    for (auto& [id, gpu] : gpu_) gpu.redraw = FavoriteRedraw{true, true, true};
    emptyDirty_ = true;
    placed_ = false;
    UpdateTooltips();
}

bool FavoritesView::SetHover(std::optional<size_t> pane, bool overEmptyState) {
    overEmptyState = overEmptyState && tray_.emptyState;
    if (pane == hover_ && overEmptyState == emptyHover_) return false;
    hover_ = pane;
    emptyHover_ = overEmptyState;
    return Place();
}

UINT FavoritesView::IconPixels() const { return static_cast<UINT>(std::lround(F::kIconSize * Scale())); }

POINT FavoritesView::CornerOf(const BarRect& frame) const {
    const float scale = Scale();
    return POINT{static_cast<LONG>(std::floor(frame.left * scale)), static_cast<LONG>(std::floor(frame.top * scale))};
}

std::optional<ThemeColor> FavoritesView::ColorOf(const FavoritePane& pane) {
    if (!pane.favicon.url || pane.favicon.symbol || !favicons_) return std::nullopt;
    const std::string& url = *pane.favicon.url;
    if (auto known = colors_.find(url); known != colors_.end()) return known->second;
    // NSImage.dominantColor draws the icon 16px a side: the icon at that size, once it's there.
    const Pixels* sample = favicons_->Get(url, F::kColorSampleSide);
    if (!sample) return std::nullopt;
    std::optional<ThemeColor> color = DominantColor(sample->bgra.data(), sample->width, sample->height, sample->width * 4);
    if (color) color = FavoriteHighlight(*color);
    colors_.emplace(url, color);
    return color;
}

FavoriteLook FavoritesView::LookOf(size_t index) const {
    const bool hasColor = index < paneGpu_.size() && paneGpu_[index]->drawnColor.has_value();
    return FavoriteLookOf(panes_[index]->selected, hover_ == index, dark_, hasColor);
}

std::vector<FavoriteLook> FavoritesView::Looks() const {
    std::vector<FavoriteLook> looks;
    for (size_t i = 0; i < panes_.size(); ++i) looks.push_back(LookOf(i));
    return looks;
}

bool FavoritesView::IconsArrived() {
    if (!favicons_) return false;
    bool any = false;
    const UINT px = IconPixels();
    for (size_t i = 0; i < panes_.size(); ++i) {
        const FavoritePane& pane = *panes_[i];
        PaneGpu& gpu = *paneGpu_[i];
        if (!pane.favicon.url || pane.favicon.symbol) continue;
        // Its icon, where the globe was; and its colour, once its 16px icon is there.
        if (!gpu.drewIcon && favicons_->Get(*pane.favicon.url, px)) {
            gpu.redraw.icon = true;
            any = true;
        }
        if (ColorOf(pane) != gpu.drawnColor) {
            gpu.redraw.tint = true;
            any = true;
        }
    }
    return any;
}

bool FavoritesView::NeedsDraw() const {
    for (const PaneGpu* gpu : paneGpu_) {
        if (gpu->redraw.wash || gpu->redraw.tint || gpu->redraw.icon) return true;
    }
    if (tray_.emptyState && (emptyDirty_ || !emptyBox_.surface || !emptyClose_.surface)) return true;
    return !placed_ && (!panes_.empty() || tray_.emptyState);
}

bool FavoritesView::Place() {
    if (!compositor_) return false;
    bool changed = false;
    for (size_t i = 0; i < panes_.size(); ++i) {
        PaneGpu& gpu = *paneGpu_[i];
        if (!gpu.visual) continue;
        // On whole pixels, so what's drawn into its layers stays sharp; moved only when it moves.
        const POINT at = CornerOf(panes_[i]->frame);
        if (!gpu.atSet || at.x != gpu.at.x || at.y != gpu.at.y) {
            gpu.at = at;
            gpu.atSet = true;
            gpu.visual->SetOffsetX(static_cast<float>(at.x));
            gpu.visual->SetOffsetY(static_cast<float>(at.y));
        }
        const FavoriteLook look = LookOf(i);
        if (gpu.placed != look) {
            if (gpu.fill.effect) gpu.fill.effect->SetOpacity(look.fill);
            if (gpu.tint.effect) gpu.tint.effect->SetOpacity(look.tint);
            if (gpu.ring.effect) gpu.ring.effect->SetOpacity(look.ring ? 1.0f : 0.0f);
            gpu.placed = look;
            changed = true;
        }
    }
    if (tray_.emptyState && emptyClose_.effect) {
        const float opacity = CloseShown() ? E::kCloseOpacity : 0.0f;
        if (closeOpacity_ != opacity) {
            emptyClose_.effect->SetOpacity(opacity);
            closeOpacity_ = opacity;
            changed = true;
        }
    }
    placed_ = true;
    return changed;
}

std::wstring FavoritesView::DrawPane(size_t index, const DrawIcon& drawIcon, bool readBack) {
    const FavoritePane& pane = *panes_[index];
    PaneGpu& gpu = *paneGpu_[index];
    const float scale = Scale();
    HRESULT hr = S_OK;
    auto fail = [&](const std::wstring& what) {
        deviceLost_ = IsDeviceLost(hr);
        return L"a favorite: " + what;
    };
    if (!gpu.visual) {
        if (FAILED(hr = compositor_->Device()->CreateVisual(gpu.visual.GetAddressOf())) ||
            FAILED(hr = container_->AddVisual(gpu.visual.Get(), FALSE, nullptr))) {
            gpu.visual.Reset();
            return fail(HResultMessage(L"creating a favorite's visual", hr));
        }
        gpu.atSet = false;
        gpu.placed.reset();
        placed_ = false;
    }
    // Its frame from its whole-pixel corner, a pixel to spare for the rounding.
    const POINT at = CornerOf(pane.frame);
    const UINT width = static_cast<UINT>(std::ceil(pane.frame.right * scale)) - static_cast<UINT>(at.x) + 1;
    const UINT height = static_cast<UINT>(std::ceil(pane.frame.bottom * scale)) - static_cast<UINT>(at.y) + 1;
    // The pane in the layers' points.
    const float left = pane.frame.left - static_cast<float>(at.x) / scale, top = pane.frame.top - static_cast<float>(at.y) / scale;
    const D2D1_RECT_F box{left, top, left + pane.frame.Width(), top + pane.frame.Height()};
    const std::optional<ThemeColor> color = ColorOf(pane);
    const D2D1_COLOR_F tint = color ? D2D1_COLOR_F{color->r, color->g, color->b, 1} : D2D1_COLOR_F{0, 0, 0, 0};

    const bool drawWash = gpu.redraw.wash || readBack || !gpu.fill.surface;
    // The tint and the ring are made once there's a colour; with none (a grey favicon now) they
    // stay as they were, at no opacity.
    const bool drawTint = color && (gpu.redraw.tint || readBack || !gpu.tint.surface || !gpu.ring.surface);
    const bool drawIconLayer = gpu.redraw.icon || readBack || !gpu.icon.surface;
    bool drewIcon = gpu.drewIcon;
    struct Layer {
        FadedLayer& layer;
        bool draw;
        // Where a new one goes among the pane's layers: above `reference`, or (none) on top.
        IDCompositionVisual* reference;
        Compositor::Content content;
    };
    Layer layers[] = {
        // FillView: white, faded to the look's wash.
        {gpu.fill, drawWash, nullptr,
         [&](ID2D1DeviceContext* context) {
             brush_->SetColor(D2D1_COLOR_F{1, 1, 1, 1});
             context->FillRoundedRectangle(Rounded(box, F::kCornerRadius), brush_.Get());
         }},
        // The favicon, 18pt in the pane's middle, on whole pixels: made with the wash, so on top.
        {gpu.icon, drawIconLayer, nullptr,
         [&](ID2D1DeviceContext* context) {
             const float side = std::round(F::kIconSize * scale) / scale;
             const float x = std::round((box.left + (pane.frame.Width() - F::kIconSize) / 2) * scale) / scale;
             const float y = std::round((box.top + (pane.frame.Height() - F::kIconSize) / 2) * scale) / scale;
             drewIcon = drawIcon(context, pane.favicon, D2D1_RECT_F{x, y, x + side, y + side});
         }},
        // The tint: the colour, faded to the look's tint, just above the wash.
        {gpu.tint, drawTint, gpu.fill.visual.Get(),
         [&](ID2D1DeviceContext* context) {
             brush_->SetColor(tint);
             context->FillRoundedRectangle(Rounded(box, F::kCornerRadius), brush_.Get());
         }},
        // SidebarRingView: a 2pt border on the pane's edge, the band a 2pt stroke on it inset by 1
        // covers, just above the tint.
        {gpu.ring, drawTint, nullptr,
         [&](ID2D1DeviceContext* context) {
             brush_->SetColor(tint);
             const float inset = F::kRingInset;
             const D2D1_RECT_F ring{box.left + inset, box.top + inset, box.right - inset, box.bottom - inset};
             context->DrawRoundedRectangle(Rounded(ring, F::kCornerRadius - inset), brush_.Get(), F::kRingWidth);
         }},
    };
    for (Layer& l : layers) {
        if (!l.draw) continue;
        // The ring goes above the tint, which a draw before it this pass may just have made.
        IDCompositionVisual* reference = &l.layer == &gpu.ring ? gpu.tint.visual.Get() : l.reference;
        bool fresh = false;
        std::wstring error = DrawFadedLayer(*compositor_, l.layer, width, height, dpi_, l.content, readBack, hr, fresh);
        if (fresh && l.layer.visual) {
            // A new layer: its opacity set by Place.
            gpu.placed.reset();
            placed_ = false;
        }
        error = AttachFadedLayer(l.layer, fresh, std::move(error), gpu.visual.Get(), reference ? TRUE : FALSE, reference, hr);
        if (!error.empty()) return fail(error);
        ++surfaceDraws_;
    }
    gpu.drawn = std::make_pair(pane.frame, pane.favicon);
    gpu.redraw.wash = false;
    gpu.redraw.icon = gpu.redraw.icon && !drawIconLayer;
    if (drawIconLayer) gpu.drewIcon = drewIcon;
    if (drawTint || !color) {
        gpu.redraw.tint = false;
        if (gpu.drawnColor != color) {
            gpu.drawnColor = color;
            gpu.placed.reset();  // its tint and ring show now (or go)
            placed_ = false;
        }
    }
    return {};
}

void FavoritesView::DrawEmptyBox(ID2D1DeviceContext* context, D2D1_RECT_F box) {
    const float c = dark_ ? 1.0f : 0.0f;
    // strokeBorder of the dashed outline: the 1.5pt line inside the whole box.
    const float half = E::kOutlineWidth / 2;
    brush_->SetColor(D2D1_COLOR_F{c, c, c, E::kOutlineOpacity});
    context->DrawRoundedRectangle(Rounded(D2D1_RECT_F{box.left + half, box.top + half, box.right - half, box.bottom - half}, E::kCornerRadius - half),
                                  brush_.Get(), E::kOutlineWidth, dashes_.Get());
    // The title and subtitle 2pt apart, centred in the box between the 6pt insets, lines rounded down.
    const float innerLeft = box.left + E::kInset, innerWidth = box.right - box.left - 2 * E::kInset;
    const auto layoutOf = [&](const char* text, IDWriteTextFormat* format, float size, int& lines) {
        const std::wstring wide = Widen(text);
        ComPtr<IDWriteTextLayout> layout;
        DWRITE_TEXT_METRICS metrics{};
        if (FAILED(dwrite_->CreateTextLayout(wide.c_str(), static_cast<UINT32>(wide.size()), format, std::max(innerWidth, 1.0f), 1000,
                                             layout.GetAddressOf())) ||
            FAILED(layout->GetMetrics(&metrics))) {
            return ComPtr<IDWriteTextLayout>();
        }
        lines = static_cast<int>(std::max<UINT32>(metrics.lineCount, 1));
        SetLines(layout.Get(), size, lines);
        return layout;
    };
    int titleLines = 1, subtitleLines = 1;
    const ComPtr<IDWriteTextLayout> title = layoutOf(E::kTitle, titleFormat_.Get(), E::kTitleSize, titleLines);
    const ComPtr<IDWriteTextLayout> subtitle = layoutOf(E::kSubtitle, subtitleFormat_.Get(), E::kSubtitleSize, subtitleLines);
    const float th = E::LabelHeight(E::kTitleSize, titleLines), sh = E::LabelHeight(E::kSubtitleSize, subtitleLines);
    const float inner = box.bottom - box.top - 2 * E::kPadding;
    const float top = box.top + E::kPadding + std::floor((inner - th - E::kTextGap - sh) / 2);
    if (title) {
        brush_->SetColor(D2D1_COLOR_F{c, c, c, kLabelAlpha * E::kTitleOpacity});
        context->DrawTextLayout(D2D1::Point2F(innerLeft, top), title.Get(), brush_.Get());
    }
    if (subtitle) {
        brush_->SetColor(D2D1_COLOR_F{c, c, c, kLabelAlpha * E::kSubtitleOpacity});
        context->DrawTextLayout(D2D1::Point2F(innerLeft, top + th + E::kTextGap), subtitle.Get(), brush_.Get());
    }
}

std::wstring FavoritesView::DrawEmptyState(bool readBack) {
    HRESULT hr = S_OK;
    const float scale = Scale();
    const auto draw = [&](FadedLayer& layer, const BarRect& frame, POINT& at, const std::function<void(ID2D1DeviceContext*, D2D1_RECT_F)>& content) {
        at = CornerOf(frame);
        const UINT width = static_cast<UINT>(std::ceil(frame.right * scale)) - static_cast<UINT>(at.x) + 1;
        const UINT height = static_cast<UINT>(std::ceil(frame.bottom * scale)) - static_cast<UINT>(at.y) + 1;
        const float left = frame.left - static_cast<float>(at.x) / scale, top = frame.top - static_cast<float>(at.y) / scale;
        const D2D1_RECT_F box{left, top, left + frame.Width(), top + frame.Height()};
        bool fresh = false;
        std::wstring error = DrawFadedLayer(*compositor_, layer, width, height, dpi_, [&](ID2D1DeviceContext* context) { content(context, box); },
                                            readBack, hr, fresh);
        if (fresh && layer.visual) closeOpacity_.reset();
        error = AttachFadedLayer(layer, fresh, std::move(error), container_.Get(), FALSE, nullptr, hr);
        if (!error.empty()) {
            deviceLost_ = IsDeviceLost(hr);
            return L"the favorites' empty state: " + error;
        }
        if (layer.visual) {
            layer.visual->SetOffsetX(static_cast<float>(at.x));
            layer.visual->SetOffsetY(static_cast<float>(at.y));
        }
        ++surfaceDraws_;
        return std::wstring();
    };
    if (std::wstring error = draw(emptyBox_, tray_.emptyFrame, emptyAt_, [&](ID2D1DeviceContext* context, D2D1_RECT_F box) { DrawEmptyBox(context, box); });
        !error.empty()) {
        return error;
    }
    // The close button's X (Kite's own, at an 8pt bold xmark's box and weight) in labelColor, centred
    // in its 18pt box, faded to SymbolButton's 0.5 while hovered.
    if (std::wstring error = draw(emptyClose_, tray_.closeFrame, closeAt_,
                                  [&](ID2D1DeviceContext* context, D2D1_RECT_F box) {
                                      if (!closeShape_) return;
                                      const float c = dark_ ? 1.0f : 0.0f;
                                      brush_->SetColor(D2D1_COLOR_F{c, c, c, kLabelAlpha});
                                      D2D1_MATRIX_3X2_F transform{};
                                      context->GetTransform(&transform);
                                      context->SetTransform(
                                          D2D1::Matrix3x2F::Translation((box.left + box.right) / 2, (box.top + box.bottom) / 2) * transform);
                                      context->FillGeometry(closeShape_.Get(), brush_.Get());
                                      context->SetTransform(transform);
                                  });
        !error.empty()) {
        return error;
    }
    emptyDirty_ = false;
    return {};
}

std::wstring FavoritesView::Draw(const DrawIcon& drawIcon, IDCompositionVisual* above, bool readBack) {
    if (!compositor_ || !parent_) return L"no compositor";
    if (deviceLost_) return L"the GPU device was lost";
    // Nothing to show: no visuals made for it.
    if (panes_.empty() && !tray_.emptyState) return {};
    HRESULT hr = S_OK;
    if (!container_) {
        if (FAILED(hr = compositor_->Device()->CreateVisual(container_.GetAddressOf())) ||
            FAILED(hr = parent_->AddVisual(container_.Get(), above ? TRUE : FALSE, above))) {
            container_.Reset();
            deviceLost_ = IsDeviceLost(hr);
            return HResultMessage(L"creating the favorites' visual", hr);
        }
    }
    if (!brush_ && FAILED(hr = compositor_->D2D()->CreateSolidColorBrush(D2D1_COLOR_F{1, 1, 1, 1}, brush_.GetAddressOf()))) {
        deviceLost_ = IsDeviceLost(hr);
        return HResultMessage(L"creating the favorites' brush", hr);
    }
    for (size_t i = 0; i < panes_.size(); ++i) {
        const PaneGpu& gpu = *paneGpu_[i];
        if (!readBack && !gpu.redraw.wash && !gpu.redraw.tint && !gpu.redraw.icon && gpu.fill.surface && gpu.icon.surface) continue;
        if (std::wstring error = DrawPane(i, drawIcon, readBack); !error.empty()) return error;
    }
    if (tray_.emptyState && (readBack || emptyDirty_ || !emptyBox_.surface || !emptyClose_.surface)) {
        if (!dashes_) {
            // CAShapeLayer's 5 on, 4 off, which Direct2D gives in stroke widths.
            ComPtr<ID2D1Factory> factory;
            compositor_->D2D()->GetFactory(factory.GetAddressOf());
            const float dashes[] = {E::kDashOn / E::kOutlineWidth, E::kDashOff / E::kOutlineWidth};
            const D2D1_STROKE_STYLE_PROPERTIES props{D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_FLAT, D2D1_LINE_JOIN_MITER,
                                                     10, D2D1_DASH_STYLE_CUSTOM, 0};
            if (FAILED(hr = factory->CreateStrokeStyle(props, dashes, 2, dashes_.GetAddressOf()))) {
                return HResultMessage(L"creating the favorites' dashes", hr);
            }
        }
        if (!closeShapeTried_) {
            // Once per device, as the top row's shapes: a failure isn't retried every draw.
            closeShapeTried_ = true;
            ComPtr<ID2D1Factory> factory;
            compositor_->D2D()->GetFactory(factory.GetAddressOf());
            closeShape_ = MakeShapeGeometry(factory.Get(), E::CloseShape());
        }
        if (std::wstring error = DrawEmptyState(readBack); !error.empty()) return error;
    }
    Place();
    return {};
}

void FavoritesView::ComposeInto(Pixels& sidebar) const {
    for (size_t i = 0; i < panes_.size(); ++i) {
        const PaneGpu& gpu = *paneGpu_[i];
        const FavoriteLook look = LookOf(i);
        const POINT at = CornerOf(panes_[i]->frame);
        const std::pair<const FadedLayer*, float> layers[] = {
            {&gpu.fill, look.fill}, {&gpu.tint, look.tint}, {&gpu.ring, look.ring ? 1.0f : 0.0f}, {&gpu.icon, 1.0f}};
        for (const auto& [layer, opacity] : layers) {
            if (!layer->pixels.bgra.empty() && opacity > 0) ComposeOver(sidebar, layer->pixels, at, opacity);
        }
    }
    if (tray_.emptyState) {
        if (!emptyBox_.pixels.bgra.empty()) ComposeOver(sidebar, emptyBox_.pixels, emptyAt_);
        if (!emptyClose_.pixels.bgra.empty() && CloseShown()) ComposeOver(sidebar, emptyClose_.pixels, closeAt_, E::kCloseOpacity);
    }
}

std::optional<POINT> FavoritesView::PaneCentre(size_t index, float left) const {
    if (index >= panes_.size()) return std::nullopt;
    const BarRect& f = panes_[index]->frame;
    const float scale = Scale();
    return POINT{std::lround(((f.left + f.right) / 2 + left) * scale), std::lround((f.top + f.bottom) / 2 * scale)};
}

void FavoritesView::UpdateTooltips() {
    // A tool a pane, and the empty state's close button's; RelayedTooltips makes the control's tools
    // again only when their places or count change (a title alone updates its text).
    const float scale = Scale();
    const auto rect = [&](const BarRect& f) {
        return RECT{std::lround((f.left + left_) * scale), std::lround(f.top * scale), std::lround((f.right + left_) * scale),
                    std::lround(f.bottom * scale)};
    };
    std::vector<RelayedTooltips::Tool> tools;
    tools.reserve(panes_.size() + 1);
    for (const FavoritePane* pane : panes_) tools.push_back({rect(pane->frame), Widen(pane->title)});
    if (tray_.emptyState) tools.push_back({rect(tray_.closeFrame), Widen(E::kCloseTooltip)});
    tooltips_.SetTools(std::move(tools));
}

}  // namespace kite
