// See SpaceBarView.h.

#include "shell/SpaceBarView.h"

#include <d2d1effects.h>

#include <algorithm>
#include <cmath>

#include "shell/Errors.h"
#include "shell/Text.h"

using Microsoft::WRL::ComPtr;

namespace kite {

namespace {

namespace M = space_bar_metrics;

// Segoe Fluent Icons (Windows 11) and Segoe MDL2 Assets (Windows 10) for the Mac's archivebox
// and plus, set at 15pt as SidebarView sets its symbols (the glyphs fill about 90% of their em).
constexpr wchar_t kArchive = 0xE7B8;
constexpr wchar_t kPlus = 0xE710;
constexpr float kGlyphInk = 0.9f;
// The saturation effect's D2D1_SATURATION_PROP_SATURATION (MinGW's headers don't name it).
constexpr UINT32 kSaturationProperty = 0;

D2D1_RECT_F Rect(float left, float top, float right, float bottom) { return D2D1_RECT_F{left, top, right, bottom}; }

}  // namespace

std::unique_ptr<SpaceBarView> SpaceBarView::Create(IDWriteFactory* dwrite, std::wstring& error) {
    std::unique_ptr<SpaceBarView> view(new SpaceBarView());
    view->dwrite_ = dwrite;
    ComPtr<IDWriteFontCollection> fonts;
    dwrite->GetSystemFontCollection(fonts.GetAddressOf());
    auto installed = [&](const wchar_t* family) {
        UINT32 index = 0;
        BOOL exists = FALSE;
        return fonts && SUCCEEDED(fonts->FindFamilyName(family, &index, &exists)) && exists;
    };
    auto format = [&](const wchar_t* family, float size, ComPtr<IDWriteTextFormat>& out) {
        HRESULT made = dwrite->CreateTextFormat(family, nullptr, DWRITE_FONT_WEIGHT_REGULAR, DWRITE_FONT_STYLE_NORMAL,
                                                DWRITE_FONT_STRETCH_NORMAL, size, L"", out.GetAddressOf());
        if (SUCCEEDED(made)) made = out->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        if (SUCCEEDED(made)) made = out->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
        if (SUCCEEDED(made)) made = out->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
        return made;
    };
    HRESULT hr = S_OK;
    if (FAILED(hr = format(L"Segoe UI Emoji", M::kIconFontSize, view->emojiFormat_)) ||
        FAILED(hr = format(installed(L"Segoe Fluent Icons") ? L"Segoe Fluent Icons" : L"Segoe MDL2 Assets",
                           M::kButtonSymbolSize / kGlyphInk, view->iconFormat_))) {
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
    return true;
}

void SpaceBarView::ReleaseGpu() {
    for (CellGpu& cell : cellGpu_) {
        if (cell.visual && cellsClip_) cellsClip_->RemoveVisual(cell.visual.Get());
    }
    cellGpu_.clear();
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
}

bool SpaceBarView::ShowsDot(const SpaceCell& cell) {
    // SF Symbols and pictures have no Windows counterpart yet: they show as an icon-less space.
    return cell.icon.empty() || cell.icon.starts_with("symbol:") || cell.icon.starts_with("image:");
}

void SpaceBarView::Update(std::vector<SpaceCell> cells, bool dark) {
    if (cells == cells_ && dark == dark_) return;
    const bool reshaped = cells.size() != cells_.size();
    // A cell that shows something else draws again; one whose light alone changed only fades.
    for (size_t i = 0; i < cells.size() && i < cellGpu_.size(); ++i) {
        if (i >= cells_.size() || cells[i].icon != cells_[i].icon || dark != dark_) cellGpu_[i].dirty = true;
    }
    if (dark != dark_ || reshaped) dirty_ = true;
    if (hover_ && std::none_of(cells.begin(), cells.end(), [&](const SpaceCell& c) { return c.spaceID == *hover_; })) hover_.reset();
    // The backing isn't drawn for the space you're in, so a new selection can move it.
    if (hover_) dirty_ = true;
    cells_ = std::move(cells);
    dark_ = dark;
    if (reshaped) {
        layout_ = LayOutSpaceBar(width_, cells_.size(), layout_.scroll);
        placed_ = false;
    }
    // A slide that's under way keeps its animation unless the spaces changed under it.
    if (reshaped) slide_.reset();
    opacitiesApplied_ = false;
}

void SpaceBarView::Layout(float width, UINT dpi) {
    if (width == width_ && dpi == dpi_) return;
    width_ = width;
    dpi_ = dpi;
    layout_ = LayOutSpaceBar(width_, cells_.size(), layout_.scroll);
    dirty_ = true;
    placed_ = false;
    for (CellGpu& cell : cellGpu_) cell.dirty = true;
    // An animation in the old scale's pixels lands (opacities have no scale, but its cells move).
    slide_.reset();
    opacitiesApplied_ = false;
}

void SpaceBarView::Slide(const std::vector<CubicSegment>& segments, double duration, double from, double pageWidth,
                         const std::vector<size_t>& built, size_t selected) {
    slide_ = Relight{segments, duration, from, pageWidth, built, selected};
    if (segments.empty() || duration <= 0) slide_.reset();
    opacitiesApplied_ = false;
    // The cells' new light comes with the strip's commit.
    ApplyOpacities();
}

void SpaceBarView::Land() {
    if (!slide_) return;
    slide_.reset();
    opacitiesApplied_ = false;
    ApplyOpacities();
}

bool SpaceBarView::Scroll(float by) {
    if (layout_.fits || by == 0) return false;
    // In whole pixels, as the sidebar's list scrolls, so the icons keep their edges.
    const float scale = Scale();
    const float wanted = std::round((layout_.scroll + by) * scale) / scale;
    const SpaceBarLayout next = LayOutSpaceBar(width_, cells_.size(), wanted);
    if (next.scroll == layout_.scroll) return false;
    layout_ = next;
    placed_ = false;
    if (hover_) dirty_ = true;  // the backing moves with its cell
    // A whole-pixel scroll keeps each icon's place inside its surface: only the cells move.
    return true;
}

void SpaceBarView::SetHover(const std::optional<std::string>& spaceID) {
    if (spaceID == hover_) return;
    hover_ = spaceID;
    dirty_ = true;
}

std::optional<std::string> SpaceBarView::SpaceAt(float x, float y) const {
    const std::optional<size_t> index = SpaceCellAt(layout_, x, y);
    if (!index || *index >= cells_.size()) return std::nullopt;
    return cells_[*index].spaceID;
}

bool SpaceBarView::InCell(const std::string& id, float x, float y) const {
    for (size_t i = 0; i < cells_.size() && i < layout_.cells.size(); ++i) {
        if (cells_[i].spaceID == id) return layout_.cells[i].Contains(x, y) && layout_.viewport.Contains(x, y);
    }
    return false;
}

bool SpaceBarView::NeedsDraw() const {
    return dirty_ || !placed_ || !opacitiesApplied_ || cellGpu_.size() != cells_.size() ||
           std::any_of(cellGpu_.begin(), cellGpu_.end(), [](const CellGpu& cell) { return cell.dirty; });
}

D2D1_COLOR_F SpaceBarView::Primary(float alpha) const {
    const float c = dark_ ? 1.0f : 0.0f;
    return D2D1_COLOR_F{c, c, c, alpha};
}

void SpaceBarView::DrawBar(ID2D1DeviceContext* context) {
    // Arc's Library button and + menu: their symbols at 15pt, 70% (SymbolButton's opacity).
    auto glyph = [&](wchar_t g, const BarRect& box) {
        ComPtr<IDWriteTextLayout> layout;
        if (FAILED(dwrite_->CreateTextLayout(&g, 1, iconFormat_.Get(), box.Width(), box.Height(), layout.GetAddressOf()))) return;
        brush_->SetColor(Primary(M::kButtonOpacity));
        context->DrawTextLayout(D2D1::Point2F(box.left, box.top), layout.Get(), brush_.Get());
    };
    glyph(kArchive, layout_.library);
    glyph(kPlus, layout_.plus);
    // Under the pointer a cell has a rounded backing, but not the space you're in.
    if (hover_) {
        for (size_t i = 0; i < cells_.size() && i < layout_.cells.size(); ++i) {
            if (cells_[i].spaceID != *hover_ || cells_[i].selected) continue;
            const BarRect& cell = layout_.cells[i];
            const float x = cell.left + (cell.Width() - M::kButtonSize) / 2, y = cell.top + (cell.Height() - M::kButtonSize) / 2;
            const BarRect& view = layout_.viewport;
            context->PushAxisAlignedClip(Rect(view.left, view.top, view.right, view.bottom), D2D1_ANTIALIAS_MODE_ALIASED);
            brush_->SetColor(Primary(M::kBackingOpacity));
            context->FillRoundedRectangle(D2D1::RoundedRect(Rect(x, y, x + M::kButtonSize, y + M::kButtonSize), M::kBackingRadius,
                                                            M::kBackingRadius),
                                          brush_.Get());
            context->PopAxisAlignedClip();
        }
    }
}

void SpaceBarView::DrawIcon(ID2D1DeviceContext* context, const SpaceCell& cell, float dx, bool greyed) {
    const D2D1_RECT_F box = Rect(dx, 0, dx + M::kCellWidth, M::kCellHeight);
    if (ShowsDot(cell)) {
        // The dot at full strength: its layer's opacity is the light (0.23 greyed ... 1).
        const float cx = dx + M::kCellWidth / 2, cy = M::kCellHeight / 2, r = M::kDotSize / 2;
        brush_->SetColor(Primary(1));
        context->FillEllipse(D2D1::Ellipse(D2D1::Point2F(cx, cy), r, r), brush_.Get());
        return;
    }
    const std::wstring icon = Widen(cell.icon);
    ComPtr<IDWriteTextLayout> layout;
    if (FAILED(dwrite_->CreateTextLayout(icon.c_str(), static_cast<UINT32>(icon.size()), emojiFormat_.Get(), box.right - box.left,
                                         box.bottom - box.top, layout.GetAddressOf()))) {
        return;
    }
    brush_->SetColor(Primary(1));
    if (!greyed) {
        context->DrawTextLayout(D2D1::Point2F(box.left, box.top), layout.Get(), brush_.Get(), D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
        return;
    }
    // Greyed, as the Mac's CIColorControls (saturation 0) at 45%: the emoji drawn into a command
    // list in the context's own space, then through Direct2D's saturation effect.
    D2D1_MATRIX_3X2_F transform{};
    context->GetTransform(&transform);
    ComPtr<ID2D1Image> target;
    context->GetTarget(target.GetAddressOf());
    ComPtr<ID2D1CommandList> list;
    ComPtr<ID2D1Effect> saturation;
    if (FAILED(context->CreateCommandList(list.GetAddressOf())) || FAILED(context->CreateEffect(CLSID_D2D1Saturation, saturation.GetAddressOf()))) {
        return;
    }
    context->SetTarget(list.Get());
    context->SetTransform(D2D1::Matrix3x2F::Identity());
    context->DrawTextLayout(D2D1::Point2F(box.left, box.top), layout.Get(), brush_.Get(), D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
    context->SetTarget(target.Get());
    context->SetTransform(transform);
    if (FAILED(list->Close())) return;
    saturation->SetInput(0, list.Get());
    saturation->SetValue(kSaturationProperty, 0.0f);
    context->PushLayer(D2D1::LayerParameters1(D2D1::InfiniteRect(), nullptr, D2D1_ANTIALIAS_MODE_PER_PRIMITIVE, D2D1::IdentityMatrix(),
                                              M::kGreyOpacity),
                       nullptr);
    context->DrawImage(saturation.Get());
    context->PopLayer();
}

std::wstring SpaceBarView::DrawLayer(Layer& layer, UINT width, UINT height, const Compositor::Content& content, bool readBack,
                                     HRESULT& hr) {
    if (!layer.visual) {
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

std::wstring SpaceBarView::DrawCell(size_t index, CellGpu& gpu, bool readBack) {
    const SpaceCell& cell = cells_[index];
    const float scale = Scale();
    const UINT width = static_cast<UINT>(std::ceil(M::kCellWidth * scale)) + 1;
    const UINT height = static_cast<UINT>(std::ceil(M::kCellHeight * scale)) + 1;
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
    // The icon sits at the cell's exact place, its surface at the whole pixel left of it.
    const float exact = layout_.cells[index].left * scale;
    const float dx = (exact - std::floor(exact)) / scale;
    const bool dot = ShowsDot(cell);
    std::wstring error =
        DrawLayer(gpu.lit, width, height, [&](ID2D1DeviceContext* context) { DrawIcon(context, cell, dx, false); }, readBack, hr);
    if (error.empty()) {
        if (dot) {
            if (gpu.grey.visual) gpu.visual->RemoveVisual(gpu.grey.visual.Get());
            gpu.grey = Layer{};
        } else {
            error = DrawLayer(gpu.grey, width, height, [&](ID2D1DeviceContext* context) { DrawIcon(context, cell, dx, true); }, readBack, hr);
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
    gpu.width = width;
    gpu.height = height;
    gpu.dirty = false;
    opacitiesApplied_ = false;
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
        cellGpu_[i].visual->SetOffsetX(std::floor(layout_.cells[i].left * scale));
        cellGpu_[i].visual->SetOffsetY(std::round(layout_.cells[i].top * scale));
    }
    placed_ = true;
}

void SpaceBarView::ApplyOpacities() {
    if (!compositor_ || !cellsClip_) return;
    for (size_t i = 0; i < cellGpu_.size() && i < cells_.size(); ++i) {
        CellGpu& gpu = cellGpu_[i];
        if (!gpu.lit.effect) continue;
        const bool dot = ShowsDot(cells_[i]);
        // lit → the coloured layer's opacity; the greyed one's is the rest; a dot's runs from
        // its faint 23% to full.
        const auto litOpacity = [&](double lit) { return dot ? M::kDotOpacity + (1 - M::kDotOpacity) * lit : lit; };
        const double rest = cells_[i].lit;
        bool animated = false;
        if (slide_) {
            const LinearLit along = HighlightAlongSettle(i, slide_->selected, slide_->built, slide_->from, slide_->pageWidth);
            ComPtr<IDCompositionAnimation> lit, grey;
            const double litScale = dot ? (1 - M::kDotOpacity) : 1, litBase = dot ? M::kDotOpacity : 0;
            auto make = [&](double scale, double offset, double end, ComPtr<IDCompositionAnimation>& out) {
                HRESULT hr = compositor_->Device()->CreateAnimation(out.GetAddressOf());
                for (const CubicSegment& s : MapSegments(slide_->segments, scale, offset)) {
                    if (FAILED(hr)) break;
                    hr = out->AddCubic(s.begin, static_cast<float>(s.constant), static_cast<float>(s.linear), static_cast<float>(s.quadratic),
                                       static_cast<float>(s.cubic));
                }
                if (SUCCEEDED(hr)) hr = out->End(slide_->duration, static_cast<float>(end));
                return SUCCEEDED(hr);
            };
            if (along.slope != 0 &&
                make(along.slope * litScale, along.rest * litScale + litBase, litOpacity(along.rest), lit) &&
                (!gpu.grey.effect || make(-along.slope, 1 - along.rest, 1 - along.rest, grey))) {
                gpu.lit.effect->SetOpacity(lit.Get());
                if (gpu.grey.effect) gpu.grey.effect->SetOpacity(grey.Get());
                animated = true;
            }
        }
        if (!animated) {
            gpu.lit.effect->SetOpacity(static_cast<float>(litOpacity(rest)));
            if (gpu.grey.effect) gpu.grey.effect->SetOpacity(static_cast<float>(1 - rest));
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
    const UINT largest = compositor_->GetRenderer().MaxTextureSize();
    const UINT width = std::clamp(static_cast<UINT>(std::ceil(width_ * scale)), 1u, largest);
    const UINT height = std::clamp(static_cast<UINT>(std::round(M::kHeight * scale)), 1u, largest);
    // At the window's bottom, in whole pixels.
    const LONG top = static_cast<LONG>(clientHeight) - static_cast<LONG>(height);
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
        if (error = DrawCell(i, cellGpu_[i], readBack != nullptr); !error.empty()) return error;
    }
    if (!placed_) PlaceCells();
    if (!opacitiesApplied_) ApplyOpacities();

    if (readBack) {
        // At rest, as the screen shows it: the bar, then each cell's layers at their opacity
        // inside the strip's viewport.
        *readBack = barPixels_;
        const BarRect& view = layout_.viewport;
        const RECT clip{static_cast<LONG>(std::round(view.left * scale)), static_cast<LONG>(std::round(view.top * scale)),
                        static_cast<LONG>(std::round(view.right * scale)), static_cast<LONG>(std::round(view.bottom * scale))};
        for (size_t i = 0; i < cellGpu_.size() && i < cells_.size(); ++i) {
            const POINT at{static_cast<LONG>(std::floor(layout_.cells[i].left * scale)), static_cast<LONG>(std::round(layout_.cells[i].top * scale))};
            const double lit = cells_[i].lit;
            if (ShowsDot(cells_[i])) {
                ComposeOver(*readBack, cellGpu_[i].lit.pixels, at, static_cast<float>(M::kDotOpacity + (1 - M::kDotOpacity) * lit), &clip);
            } else {
                ComposeOver(*readBack, cellGpu_[i].grey.pixels, at, static_cast<float>(1 - lit), &clip);
                ComposeOver(*readBack, cellGpu_[i].lit.pixels, at, static_cast<float>(lit), &clip);
            }
        }
    }
    return {};
}

}  // namespace kite
