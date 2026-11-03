// See SpaceBarView.h.

#include "shell/SpaceBarView.h"

#include <d2d1effects.h>

#include <algorithm>
#include <cmath>
#include <set>

#include "shell/Errors.h"
#include "shell/Text.h"

using Microsoft::WRL::ComPtr;

namespace kite {

namespace {

namespace M = space_bar_metrics;

// NSColor.labelColor's own alpha, under SymbolButton's opacity.
constexpr float kLabelAlpha = 0.85f;
// The Mac's archivebox and plus at 15pt, as measured in its 2x capture of the bar (Segoe Fluent's
// glyphs are other shapes and sizes, so they're drawn): both centred 0.2pt under their button's
// centre, stroked 1.25pt. The archive box: 15 x 13.5 ink, a lid 4.05 tall, a box 12.55 wide
// under it with 1.8pt outer corners at its bottom, and a 5.8pt slot 6.4 under the top. The plus:
// arms 12pt long, round ends.
constexpr float kSymbolDrop = 0.2f;
constexpr float kStroke = 1.25f;
constexpr float kBoxInkWidth = 15, kBoxInkHeight = 13.5f, kLidHeight = 4.05f, kBoxWidth = 12.55f;
constexpr float kLidRadius = 0.75f, kBoxRadius = 1.2f, kSlotLength = 5.8f, kSlotFromTop = 6.4f;
constexpr float kPlusLength = 12;
// The Mac's 12.5pt emoji (Apple Color Emoji) inks 14.5pt square (🏠, 29x29px in its 2x capture of
// the bar); Segoe UI Emoji's 🏠 inks 12.75pt at 12.5 (the PC's capture), so it's set larger to
// ink the same.
constexpr float kEmojiFontSize = space_bar_metrics::kIconFontSize * 14.5f / 12.75f;
// The saturation effect's D2D1_SATURATION_PROP_SATURATION (MinGW's headers don't name it).
constexpr UINT32 kSaturationProperty = 0;

D2D1_RECT_F Rect(float left, float top, float right, float bottom) { return D2D1_RECT_F{left, top, right, bottom}; }

}  // namespace

std::unique_ptr<SpaceBarView> SpaceBarView::Create(IDWriteFactory* dwrite, SpaceIconPainter* painter, std::wstring& error) {
    std::unique_ptr<SpaceBarView> view(new SpaceBarView());
    view->dwrite_ = dwrite;
    view->painter_ = painter;
    HRESULT hr = dwrite->CreateTextFormat(L"Segoe UI Emoji", nullptr, DWRITE_FONT_WEIGHT_REGULAR, DWRITE_FONT_STYLE_NORMAL,
                                          DWRITE_FONT_STRETCH_NORMAL, kEmojiFontSize, L"", view->emojiFormat_.GetAddressOf());
    if (SUCCEEDED(hr)) hr = view->emojiFormat_->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    if (FAILED(hr)) {
        error = HResultMessage(L"CreateTextFormat", hr);
        return nullptr;
    }
    return view;
}

SpaceBarView::~SpaceBarView() { ReleaseGpu(); }

void SpaceBarView::UseCompositor(Compositor* compositor, IDCompositionVisual* parent) {
    ReleaseGpu();
    compositor_ = compositor;
    parent_ = parent;
    deviceLost_ = false;
}

bool SpaceBarView::CreateGpu(std::wstring& error) {
    IDCompositionDevice* device = compositor_->Device();
    HRESULT hr = compositor_->D2D()->CreateSolidColorBrush(D2D1_COLOR_F{0, 0, 0, 1}, brush_.ReleaseAndGetAddressOf());
    if (SUCCEEDED(hr)) hr = device->CreateVisual(visual_.ReleaseAndGetAddressOf());
    if (SUCCEEDED(hr)) hr = parent_->AddVisual(visual_.Get(), FALSE, nullptr);
    if (SUCCEEDED(hr)) hr = device->CreateVisual(cellsClip_.ReleaseAndGetAddressOf());
    if (SUCCEEDED(hr)) hr = visual_->AddVisual(cellsClip_.Get(), FALSE, nullptr);
    if (SUCCEEDED(hr)) hr = compositor_->D2D()->CreateEffect(CLSID_D2D1Saturation, saturation_.ReleaseAndGetAddressOf());
    if (SUCCEEDED(hr)) hr = saturation_->SetValue(kSaturationProperty, 0.0f);
    // The symbols' shapes, in points about their centre.
    ComPtr<ID2D1Factory> factory;
    compositor_->D2D()->GetFactory(factory.GetAddressOf());
    if (SUCCEEDED(hr)) {
        hr = factory->CreateStrokeStyle(D2D1::StrokeStyleProperties(D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND,
                                                                   D2D1_LINE_JOIN_ROUND),
                                        nullptr, 0, roundCaps_.ReleaseAndGetAddressOf());
    }
    if (SUCCEEDED(hr)) {
        hr = factory->CreateStrokeStyle(D2D1::StrokeStyleProperties(D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_FLAT,
                                                                   D2D1_LINE_JOIN_ROUND),
                                        nullptr, 0, flatCaps_.ReleaseAndGetAddressOf());
    }
    if (SUCCEEDED(hr)) hr = factory->CreatePathGeometry(box_.ReleaseAndGetAddressOf());
    ComPtr<ID2D1GeometrySink> sink;
    if (SUCCEEDED(hr)) hr = box_->Open(sink.GetAddressOf());
    if (SUCCEEDED(hr)) {
        // The box's sides and bottom, from under the lid's stroke.
        const float x = kBoxWidth / 2 - kStroke / 2, top = -kBoxInkHeight / 2 + kLidHeight - kStroke / 2;
        const float bottom = kBoxInkHeight / 2 - kStroke / 2, r = kBoxRadius;
        sink->BeginFigure(D2D1::Point2F(-x, top), D2D1_FIGURE_BEGIN_HOLLOW);
        sink->AddLine(D2D1::Point2F(-x, bottom - r));
        sink->AddArc(D2D1::ArcSegment(D2D1::Point2F(-x + r, bottom), D2D1::SizeF(r, r), 0, D2D1_SWEEP_DIRECTION_COUNTER_CLOCKWISE,
                                      D2D1_ARC_SIZE_SMALL));
        sink->AddLine(D2D1::Point2F(x - r, bottom));
        sink->AddArc(D2D1::ArcSegment(D2D1::Point2F(x, bottom - r), D2D1::SizeF(r, r), 0, D2D1_SWEEP_DIRECTION_COUNTER_CLOCKWISE,
                                      D2D1_ARC_SIZE_SMALL));
        sink->AddLine(D2D1::Point2F(x, top));
        sink->EndFigure(D2D1_FIGURE_END_OPEN);
        hr = sink->Close();
    }
    if (FAILED(hr)) {
        deviceLost_ = IsDeviceLost(hr);
        error = HResultMessage(L"creating the space bar's visuals", hr);
        ReleaseGpu();
        return false;
    }
    top_ = -1;
    placed_ = false;
    opacitiesApplied_ = false;
    dirty_ = true;
    backingDirty_ = true;
    backingShown_ = false;
    return true;
}

void SpaceBarView::ReleaseGpu() {
    for (CellGpu& cell : cellGpu_) {
        if (cell.visual && cellsClip_) cellsClip_->RemoveVisual(cell.visual.Get());
    }
    cellGpu_.clear();
    if (backing_.visual && cellsClip_ && backingShown_) cellsClip_->RemoveVisual(backing_.visual.Get());
    backing_ = Layer{};
    backingShown_ = false;
    if (visual_) {
        if (cellsClip_) visual_->RemoveVisual(cellsClip_.Get());
        visual_->SetContent(nullptr);
        if (parent_) parent_->RemoveVisual(visual_.Get());
    }
    // An animation is the old device's: the cells land where they rest.
    slide_.reset();
    cellsClip_.Reset();
    visual_.Reset();
    surface_.Reset();
    surfaceWidth_ = surfaceHeight_ = 0;
    brush_.Reset();
    saturation_.Reset();
    box_.Reset();
    roundCaps_.Reset();
    flatCaps_.Reset();
}

void SpaceBarView::Update(std::vector<SpaceCell> cells, bool dark) {
    if (cells == cells_ && dark == dark_) return;
    const bool reshaped = cells.size() != cells_.size();
    // A cell that shows something else draws again; one whose light alone changed only fades.
    for (size_t i = 0; i < cells.size() && i < cellGpu_.size(); ++i) {
        if (i >= cells_.size() || cells[i].look != cells_[i].look || dark != dark_) cellGpu_[i].dirty = true;
    }
    if (dark != dark_) dirty_ = backingDirty_ = true;
    // Only a new light or layer needs new opacities: a slide's keep running through an icon edit.
    bool relit = reshaped;
    for (size_t i = 0; !relit && i < cells.size(); ++i) relit = cells[i].lit != cells_[i].lit || cells[i].Dot() != cells_[i].Dot();
    const auto gone = [&](const std::optional<std::string>& id) {
        return id && std::none_of(cells.begin(), cells.end(), [&](const SpaceCell& c) { return c.spaceID == *id; });
    };
    if (gone(hover_)) hover_.reset();
    if (gone(backingFor_)) {
        backingFor_.reset();
        placed_ = false;
    }
    // A new selection leaves the backing as it is, as the Mac's show() (it changes as the
    // pointer comes and goes).
    cells_ = std::move(cells);
    dark_ = dark;
    if (reshaped) {
        layout_ = LayOutSpaceBar(width_, cells_.size(), layout_.scroll, Scale());
        placed_ = false;
    }
    // A slide that's under way keeps its animation unless the spaces changed under it.
    if (reshaped) {
        slide_.reset();
        follow_.reset();
    }
    if (relit) opacitiesApplied_ = false;
}

void SpaceBarView::Layout(float width, UINT dpi) {
    if (width == width_ && dpi == dpi_) return;
    const bool rescaled = dpi != dpi_;
    width_ = width;
    dpi_ = dpi;
    layout_ = LayOutSpaceBar(width_, cells_.size(), layout_.scroll, Scale());
    dirty_ = true;
    placed_ = false;
    if (rescaled) backingDirty_ = true;
    for (CellGpu& cell : cellGpu_) cell.dirty = true;
    // An animation in the old scale's pixels lands (opacities have no scale, but its cells move).
    slide_.reset();
    opacitiesApplied_ = false;
}

void SpaceBarView::Slide(const std::vector<CubicSegment>& segments, double duration, double from, double to, double pageWidth,
                         const std::vector<size_t>& built, size_t selected) {
    slide_ = Relight{segments, duration, from, to, pageWidth, built, selected};
    follow_.reset();
    if (segments.empty() || duration <= 0) slide_.reset();
    opacitiesApplied_ = false;
    // The cells' new light comes with the strip's commit.
    ApplyOpacities();
}

void SpaceBarView::InvalidatePictures(const std::set<std::string>& names) {
    for (size_t i = 0; i < cells_.size() && i < cellGpu_.size(); ++i) {
        if (cells_[i].look.kind == SpaceIconLook::Kind::Picture && names.contains(cells_[i].look.text)) cellGpu_[i].dirty = true;
    }
}

void SpaceBarView::Follow(double offset, double pageWidth, const std::vector<size_t>& built, size_t selected) {
    if (offset == 0) return Land();
    Held held{offset, pageWidth, built, selected};
    if (!slide_ && follow_ == held) return;
    slide_.reset();
    follow_ = std::move(held);
    opacitiesApplied_ = false;
}

double SpaceBarView::LitAtRest(size_t index) const {
    if (!follow_) return cells_[index].lit;
    return SpaceSwipe::Highlight(index, follow_->selected, follow_->built, follow_->offset, follow_->pageWidth);
}

void SpaceBarView::Land() {
    if (!slide_ && !follow_) return;
    slide_.reset();
    follow_.reset();
    // Applied by the next draw, so a commit carries it.
    opacitiesApplied_ = false;
}

bool SpaceBarView::Scroll(float by) {
    if (layout_.fits || by == 0) return false;
    // In whole pixels, as the sidebar's list scrolls, so the icons keep their edges.
    const float scale = Scale();
    const float wanted = std::round((layout_.scroll + by) * scale) / scale;
    const SpaceBarLayout next = LayOutSpaceBar(width_, cells_.size(), wanted, scale);
    if (next.scroll == layout_.scroll) return false;
    // Only the visuals move: the cells and the backing (with its cell).
    layout_ = next;
    placed_ = false;
    return true;
}

void SpaceBarView::SetHover(const std::optional<std::string>& spaceID) {
    if (spaceID == hover_) return;
    hover_ = spaceID;
    // The Mac's updateBacking on mouseEntered and mouseExited.
    const auto cell = std::find_if(cells_.begin(), cells_.end(), [&](const SpaceCell& c) { return spaceID && c.spaceID == *spaceID; });
    backingFor_ = cell != cells_.end() && !cell->selected ? spaceID : std::nullopt;
    placed_ = false;
}

std::optional<std::string> SpaceBarView::SpaceAt(float x, float y) const {
    const std::optional<size_t> index = SpaceCellAt(layout_, x, y);
    if (!index || *index >= cells_.size()) return std::nullopt;
    return cells_[*index].spaceID;
}

bool SpaceBarView::NeedsDraw() const {
    return dirty_ || !placed_ || !opacitiesApplied_ || (backingFor_ && backingDirty_) || cellGpu_.size() != cells_.size() ||
           std::any_of(cellGpu_.begin(), cellGpu_.end(), [](const CellGpu& cell) { return cell.dirty; });
}

D2D1_COLOR_F SpaceBarView::Primary(float alpha) const {
    const float c = dark_ ? 1.0f : 0.0f;
    return D2D1_COLOR_F{c, c, c, alpha};
}

void SpaceBarView::DrawBar(ID2D1DeviceContext* context) {
    // Arc's Library button and + menu: labelColor at SymbolButton's 70%, each symbol faded as a
    // whole (an image's alphaValue), so where its strokes meet the ink doesn't double.
    brush_->SetColor(Primary(1));
    context->PushLayer(D2D1::LayerParameters1(D2D1::InfiniteRect(), nullptr, D2D1_ANTIALIAS_MODE_PER_PRIMITIVE, D2D1::IdentityMatrix(),
                                              kLabelAlpha * M::kButtonOpacity),
                       nullptr);
    D2D1_MATRIX_3X2_F transform{};
    context->GetTransform(&transform);
    const auto centred = [&](const BarRect& box) {
        context->SetTransform(D2D1::Matrix3x2F::Translation((box.left + box.right) / 2, (box.top + box.bottom) / 2 + kSymbolDrop) * transform);
    };
    centred(layout_.library);
    const float lidX = kBoxInkWidth / 2 - kStroke / 2, lidTop = -kBoxInkHeight / 2 + kStroke / 2;
    context->DrawRoundedRectangle(D2D1::RoundedRect(Rect(-lidX, lidTop, lidX, lidTop + kLidHeight - kStroke), kLidRadius, kLidRadius),
                                  brush_.Get(), kStroke, roundCaps_.Get());
    context->DrawGeometry(box_.Get(), brush_.Get(), kStroke, flatCaps_.Get());
    const float slotY = -kBoxInkHeight / 2 + kSlotFromTop, slotX = kSlotLength / 2 - kStroke / 2;
    context->DrawLine(D2D1::Point2F(-slotX, slotY), D2D1::Point2F(slotX, slotY), brush_.Get(), kStroke, roundCaps_.Get());
    centred(layout_.plus);
    const float arm = kPlusLength / 2 - kStroke / 2;
    context->DrawLine(D2D1::Point2F(-arm, 0), D2D1::Point2F(arm, 0), brush_.Get(), kStroke, roundCaps_.Get());
    context->DrawLine(D2D1::Point2F(0, -arm), D2D1::Point2F(0, arm), brush_.Get(), kStroke, roundCaps_.Get());
    context->SetTransform(transform);
    context->PopLayer();
}

void SpaceBarView::DrawDot(ID2D1DeviceContext* context) {
    // At full strength: its layer's opacity is the light (0.23 greyed ... 1).
    const float r = M::kDotSize / 2;
    brush_->SetColor(Primary(1));
    context->FillEllipse(D2D1::Ellipse(D2D1::Point2F(M::kCellWidth / 2, M::kCellHeight / 2), r, r), brush_.Get());
}

void SpaceBarView::DrawIcon(ID2D1DeviceContext* context, const SpaceCell& cell, bool greyed) {
    if (cell.look.kind != SpaceIconLook::Kind::Emoji) {
        // A symbol: in the theme's accent, or greyed in labelColor at 45% (no saturation filter, as
        // the Mac's tint). A picture: as it is (greyed by the caller's filter).
        const ThemeColor& a = cell.look.accent;
        painter_->Draw(context, brush_.Get(), cell.look, D2D1::Point2F(M::kCellWidth / 2, M::kCellHeight / 2), M::kIconFontSize, Scale(),
                       greyed ? Primary(M::kGreyOpacity) : D2D1_COLOR_F{a.r, a.g, a.b, 1}, dark_);
        return;
    }
    const std::wstring icon = Widen(cell.look.text);
    ComPtr<IDWriteTextLayout> layout;
    if (FAILED(dwrite_->CreateTextLayout(icon.c_str(), static_cast<UINT32>(icon.size()), emojiFormat_.Get(), M::kCellWidth, M::kCellHeight,
                                         layout.GetAddressOf()))) {
        return;
    }
    // Its ink in the middle of the cell, whatever the glyph's side bearings and the line's ascent.
    // (The Mac's CenteredTextView centres the string's typographic box instead; with Apple Color
    // Emoji's metrics that puts the ink within 0.25pt of the cell's centre in its capture, which
    // Segoe UI Emoji's ascent and descent wouldn't.)
    DWRITE_TEXT_METRICS metrics{};
    DWRITE_OVERHANG_METRICS overhang{};
    float x = 0, y = 0;
    if (SUCCEEDED(layout->GetMetrics(&metrics)) && SUCCEEDED(layout->GetOverhangMetrics(&overhang))) {
        const float left = -overhang.left, right = M::kCellWidth + overhang.right;
        const float top = -overhang.top, bottom = M::kCellHeight + overhang.bottom;
        x = M::kCellWidth / 2 - (left + right) / 2;
        y = M::kCellHeight / 2 - (top + bottom) / 2;
    }
    brush_->SetColor(Primary(1));
    context->DrawTextLayout(D2D1::Point2F(x, y), layout.Get(), brush_.Get(), D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
}

ComPtr<ID2D1CommandList> SpaceBarView::RecordIcon(const SpaceCell& cell, HRESULT& hr) {
    // Into a command list with the context to itself (no surface's draw under way), so the
    // greyed layer's draw only plays it through the saturation effect.
    ID2D1DeviceContext* context = compositor_->D2D();
    ComPtr<ID2D1CommandList> list;
    if (FAILED(hr = context->CreateCommandList(list.GetAddressOf()))) return nullptr;
    ComPtr<ID2D1Image> target;
    context->GetTarget(target.GetAddressOf());
    context->SetTarget(list.Get());
    context->BeginDraw();
    context->SetTransform(D2D1::Matrix3x2F::Identity());
    DrawIcon(context, cell, false);
    hr = context->EndDraw();
    context->SetTarget(target.Get());
    if (SUCCEEDED(hr)) hr = list->Close();
    return SUCCEEDED(hr) ? list : nullptr;
}

std::wstring SpaceBarView::DrawLayer(Layer& layer, UINT width, UINT height, const Compositor::Content& content, bool readBack,
                                     HRESULT& hr, bool& fresh) {
    if (!layer.visual) {
        fresh = true;
        if (FAILED(hr = compositor_->Device()->CreateVisual(layer.visual.GetAddressOf())) ||
            FAILED(hr = compositor_->Device()->CreateEffectGroup(layer.effect.GetAddressOf())) ||
            FAILED(hr = layer.visual->SetEffect(layer.effect.Get()))) {
            layer = Layer{};
            return HResultMessage(L"creating a space cell's visual", hr);
        }
    }
    if (!layer.surface) {
        if (FAILED(hr = compositor_->Device()->CreateVirtualSurface(width, height, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED,
                                                                     layer.surface.GetAddressOf())) ||
            FAILED(hr = layer.visual->SetContent(layer.surface.Get()))) {
            layer.surface.Reset();
            return HResultMessage(L"creating a space cell's surface", hr);
        }
    } else if (FAILED(hr = layer.surface->Resize(width, height))) {
        return HResultMessage(L"resizing a space cell's surface", hr);
    }
    layer.pixels = Pixels{};
    return compositor_->DrawSurface(layer.surface.Get(), width, height, dpi_, content, readBack ? &layer.pixels : nullptr, hr);
}

std::wstring SpaceBarView::DrawCell(size_t index, CellGpu& gpu, bool readBack, bool& fresh) {
    const SpaceCell& cell = cells_[index];
    const float scale = Scale();
    // Its surface at the cell's place, a whole pixel (core snaps the cells).
    const UINT width = static_cast<UINT>(std::ceil(M::kCellWidth * scale));
    const UINT height = static_cast<UINT>(std::ceil(M::kCellHeight * scale));
    HRESULT hr = S_OK;
    if (!gpu.visual) {
        if (FAILED(hr = compositor_->Device()->CreateVisual(gpu.visual.GetAddressOf())) ||
            FAILED(hr = cellsClip_->AddVisual(gpu.visual.Get(), FALSE, nullptr))) {
            gpu.visual.Reset();
            deviceLost_ = IsDeviceLost(hr);
            return HResultMessage(L"creating a space cell", hr);
        }
        placed_ = false;
    }
    std::wstring error;
    if (cell.Dot()) {
        error = DrawLayer(gpu.lit, width, height, [&](ID2D1DeviceContext* context) { DrawDot(context); }, readBack, hr, fresh);
        if (gpu.grey.visual) gpu.visual->RemoveVisual(gpu.grey.visual.Get());
        gpu.grey = Layer{};
    } else {
        // A picture's bitmap, made before the layers' draws begin.
        painter_->Prepare(compositor_->D2D(), cell.look, M::kIconFontSize, Scale());
        error = DrawLayer(gpu.lit, width, height, [&](ID2D1DeviceContext* context) { DrawIcon(context, cell, false); }, readBack, hr, fresh);
        if (error.empty() && GreysByTint(cell.look.kind)) {
            error = DrawLayer(gpu.grey, width, height, [&](ID2D1DeviceContext* context) { DrawIcon(context, cell, true); }, readBack, hr, fresh);
        } else if (error.empty()) {
            // An emoji or a picture greyed, as the Mac's CIColorControls (saturation 0), at 45%
            // inside its own fade.
            ComPtr<ID2D1CommandList> icon;
            if (!(icon = RecordIcon(cell, hr))) error = HResultMessage(L"recording a space's icon", hr);
            if (error.empty()) {
                error = DrawLayer(
                    gpu.grey, width, height,
                    [&](ID2D1DeviceContext* context) {
                        saturation_->SetInput(0, icon.Get());
                        context->PushLayer(D2D1::LayerParameters1(D2D1::InfiniteRect(), nullptr, D2D1_ANTIALIAS_MODE_PER_PRIMITIVE,
                                                                  D2D1::IdentityMatrix(), M::kGreyOpacity),
                                           nullptr);
                        context->DrawImage(saturation_.Get());
                        context->PopLayer();
                        saturation_->SetInput(0, nullptr);
                    },
                    readBack, hr, fresh);
            }
        }
    }
    if (!error.empty()) {
        deviceLost_ = IsDeviceLost(hr);
        return L"a space cell: " + error;
    }
    // Greyed under coloured, as the Mac's two image views.
    gpu.visual->RemoveVisual(gpu.lit.visual.Get());
    if (gpu.grey.visual) {
        gpu.visual->RemoveVisual(gpu.grey.visual.Get());
        gpu.visual->AddVisual(gpu.grey.visual.Get(), FALSE, nullptr);
    }
    gpu.visual->AddVisual(gpu.lit.visual.Get(), FALSE, nullptr);
    gpu.dirty = false;
    return {};
}

std::wstring SpaceBarView::DrawBacking(bool readBack) {
    // One rounded square, drawn for an appearance or a scale; it moves to the hovered cell.
    const UINT side = static_cast<UINT>(std::ceil(M::kButtonSize * Scale()));
    HRESULT hr = S_OK;
    bool fresh = false;
    std::wstring error = DrawLayer(
        backing_, side, side,
        [&](ID2D1DeviceContext* context) {
            brush_->SetColor(Primary(M::kBackingOpacity));
            context->FillRoundedRectangle(D2D1::RoundedRect(Rect(0, 0, M::kButtonSize, M::kButtonSize), M::kBackingRadius, M::kBackingRadius),
                                          brush_.Get());
        },
        readBack, hr, fresh);
    if (!error.empty()) {
        deviceLost_ = IsDeviceLost(hr);
        return L"a space cell's backing: " + error;
    }
    if (fresh) backing_.effect->SetOpacity(1.0f);
    backingDirty_ = false;
    return {};
}

void SpaceBarView::PlaceCells() {
    if (!cellsClip_) return;
    const float scale = Scale();
    const BarRect& view = layout_.viewport;
    cellsClip_->SetClip(D2D_RECT_F{std::round(view.left * scale), std::round(view.top * scale), std::round(view.right * scale),
                                   std::round(view.bottom * scale)});
    for (size_t i = 0; i < cellGpu_.size() && i < layout_.cells.size(); ++i) {
        if (!cellGpu_[i].visual) continue;
        cellGpu_[i].visual->SetOffsetX(std::round(layout_.cells[i].left * scale));
        cellGpu_[i].visual->SetOffsetY(std::round(layout_.cells[i].top * scale));
    }
    ShowBacking();
    placed_ = true;
}

void SpaceBarView::ShowBacking() {
    // Under the cells, centred on the hovered one (32pt in its 36x34).
    std::optional<size_t> at;
    for (size_t i = 0; backingFor_ && i < cells_.size() && i < layout_.cells.size(); ++i) {
        if (cells_[i].spaceID == *backingFor_) at = i;
    }
    const bool show = at && backing_.visual;
    if (show) {
        const float scale = Scale();
        const BarRect& cell = layout_.cells[*at];
        backing_.visual->SetOffsetX(std::round((cell.left + (M::kCellWidth - M::kButtonSize) / 2) * scale));
        backing_.visual->SetOffsetY(std::round((cell.top + (M::kCellHeight - M::kButtonSize) / 2) * scale));
    }
    if (show == backingShown_) return;
    if (show) {
        cellsClip_->AddVisual(backing_.visual.Get(), TRUE, nullptr);
    } else {
        cellsClip_->RemoveVisual(backing_.visual.Get());
    }
    backingShown_ = show;
}

void SpaceBarView::ApplyOpacities() {
    if (!compositor_ || !cellsClip_) return;
    for (size_t i = 0; i < cellGpu_.size() && i < cells_.size(); ++i) {
        CellGpu& gpu = cellGpu_[i];
        if (!gpu.lit.effect) continue;
        const SpaceCell& cell = cells_[i];
        bool animated = false;
        if (slide_) {
            const CellOpacityAlong along = CellOpacityAlongSettle(
                cell.Dot(), HighlightAlongSettle(i, slide_->selected, slide_->built, slide_->from, slide_->to, slide_->pageWidth));
            auto make = [&](const LinearLit& opacity, ComPtr<IDCompositionAnimation>& out) {
                HRESULT hr = compositor_->Device()->CreateAnimation(out.GetAddressOf());
                for (const CubicSegment& s : MapSegments(slide_->segments, opacity.slope, opacity.rest)) {
                    if (FAILED(hr)) break;
                    hr = out->AddCubic(s.begin, static_cast<float>(s.constant), static_cast<float>(s.linear), static_cast<float>(s.quadratic),
                                       static_cast<float>(s.cubic));
                }
                if (SUCCEEDED(hr)) hr = out->End(slide_->duration, static_cast<float>(opacity.rest));
                return SUCCEEDED(hr);
            };
            ComPtr<IDCompositionAnimation> lit, grey;
            if (along.lit.slope != 0 && make(along.lit, lit) && (!gpu.grey.effect || make(along.grey, grey))) {
                gpu.lit.effect->SetOpacity(lit.Get());
                if (gpu.grey.effect) gpu.grey.effect->SetOpacity(grey.Get());
                animated = true;
            }
        }
        if (!animated) {
            const CellOpacity rest = CellOpacityAt(cell.Dot(), LitAtRest(i));
            gpu.lit.effect->SetOpacity(static_cast<float>(rest.lit));
            if (gpu.grey.effect) gpu.grey.effect->SetOpacity(static_cast<float>(rest.grey));
        }
    }
    opacitiesApplied_ = true;
}

std::wstring SpaceBarView::Draw(UINT clientHeight, Pixels* readBack) {
    if (!compositor_ || !parent_) return L"no compositor";
    if (deviceLost_) return L"the GPU device was lost";
    std::wstring error;
    if (!visual_ && !CreateGpu(error)) return error;
    const float scale = Scale();
    // Where the space's page ends, to the nearest pixel, down to the window's bottom.
    const LONG top = std::lround(SpaceBarTop(static_cast<float>(clientHeight) / scale) * scale);
    const UINT largest = compositor_->GetRenderer().MaxTextureSize();
    const UINT width = std::clamp(static_cast<UINT>(std::ceil(width_ * scale)), 1u, largest);
    const UINT height = std::clamp(static_cast<UINT>(std::max(static_cast<LONG>(clientHeight) - top, 1L)), 1u, largest);
    if (top != top_) {
        top_ = top;
        visual_->SetOffsetY(static_cast<float>(top));
    }
    auto fail = [this](const wchar_t* what, HRESULT hr) {
        deviceLost_ = IsDeviceLost(hr);
        return HResultMessage(what, hr);
    };
    HRESULT hr = S_OK;
    if (width != surfaceWidth_ || height != surfaceHeight_) dirty_ = true;
    if (dirty_ || readBack) {
        if (!surface_) {
            if (FAILED(hr = compositor_->Device()->CreateVirtualSurface(width, height, DXGI_FORMAT_B8G8R8A8_UNORM,
                                                                         DXGI_ALPHA_MODE_PREMULTIPLIED, surface_.GetAddressOf())) ||
                FAILED(hr = visual_->SetContent(surface_.Get()))) {
                surface_.Reset();
                return fail(L"creating the space bar's surface", hr);
            }
        } else if (width != surfaceWidth_ || height != surfaceHeight_) {
            if (FAILED(hr = surface_->Resize(width, height))) return fail(L"resizing the space bar's surface", hr);
        }
        surfaceWidth_ = width;
        surfaceHeight_ = height;
        barPixels_ = Pixels{};
        error = compositor_->DrawSurface(
            surface_.Get(), width, height, dpi_, [&](ID2D1DeviceContext* context) { DrawBar(context); }, readBack ? &barPixels_ : nullptr, hr);
        if (!error.empty()) {
            deviceLost_ = IsDeviceLost(hr);
            return L"the space bar: " + error;
        }
        dirty_ = false;
    }
    if ((backingFor_ && backingDirty_) || (readBack && backingFor_)) {
        if (error = DrawBacking(readBack != nullptr); !error.empty()) return error;
        placed_ = false;
    }
    // One cell per space: spaces gone take theirs with them.
    while (cellGpu_.size() > cells_.size()) {
        if (cellGpu_.back().visual) cellsClip_->RemoveVisual(cellGpu_.back().visual.Get());
        cellGpu_.pop_back();
    }
    if (cellGpu_.size() < cells_.size()) {
        cellGpu_.resize(cells_.size());
        placed_ = false;
    }
    for (size_t i = 0; i < cellGpu_.size(); ++i) {
        if (!cellGpu_[i].dirty && !readBack) continue;
        bool fresh = false;
        if (error = DrawCell(i, cellGpu_[i], readBack != nullptr, fresh); !error.empty()) return error;
        // A new layer needs its opacity; a redrawn one keeps its own (and a slide's animation).
        if (fresh) opacitiesApplied_ = false;
    }
    if (!placed_) PlaceCells();
    if (!opacitiesApplied_) ApplyOpacities();

    if (readBack) {
        // At rest (or held by a swipe), as the screen shows it: the bar, then the backing and
        // each cell's layers at their opacity inside the strip's viewport.
        *readBack = barPixels_;
        const BarRect& view = layout_.viewport;
        const RECT clip{std::lround(view.left * scale), std::lround(view.top * scale), std::lround(view.right * scale),
                        std::lround(view.bottom * scale)};
        if (backingShown_) {
            for (size_t i = 0; i < cells_.size() && i < layout_.cells.size(); ++i) {
                if (cells_[i].spaceID != *backingFor_) continue;
                const BarRect& cell = layout_.cells[i];
                const POINT at{std::lround((cell.left + (M::kCellWidth - M::kButtonSize) / 2) * scale),
                               std::lround((cell.top + (M::kCellHeight - M::kButtonSize) / 2) * scale)};
                ComposeOver(*readBack, backing_.pixels, at, 1, &clip);
            }
        }
        for (size_t i = 0; i < cellGpu_.size() && i < cells_.size(); ++i) {
            const POINT at{std::lround(layout_.cells[i].left * scale), std::lround(layout_.cells[i].top * scale)};
            const CellOpacity opacity = CellOpacityAt(cells_[i].Dot(), LitAtRest(i));
            if (!cells_[i].Dot()) ComposeOver(*readBack, cellGpu_[i].grey.pixels, at, static_cast<float>(opacity.grey), &clip);
            ComposeOver(*readBack, cellGpu_[i].lit.pixels, at, static_cast<float>(opacity.lit), &clip);
        }
    }
    return {};
}

}  // namespace kite
