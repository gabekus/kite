// See SidebarTopRowView.h.

#include "shell/SidebarTopRowView.h"

#include <algorithm>
#include <cmath>
#include <optional>

#include "shell/Errors.h"
#include "shell/SpaceIconPainter.h"
#include "shell/Text.h"

using Microsoft::WRL::ComPtr;

namespace kite {

namespace {

namespace M = top_row_metrics;

// NSColor.labelColor: black (light) or white (dark) at 85%, which SymbolButton tints its symbol.
constexpr float kLabelAlpha = 0.85f;
// The icon fonts' glyphs fill about this much of their em square: a symbol whose Mac ink isn't
// measured yet is set at its point size over it (an SF Symbol is about as big as its point size).
constexpr float kGlyphInk = 0.9f;

// The Segoe Fluent Icons and Segoe MDL2 Assets stand-ins for the Mac's SF Symbols.
wchar_t GlyphOf(const std::string& symbol) {
    if (symbol == "arrow.left") return 0xE72B;       // Back
    if (symbol == "arrow.right") return 0xE72A;      // Forward
    return 0;
}

}  // namespace

std::unique_ptr<SidebarTopRowView> SidebarTopRowView::Create(HWND window, IDWriteFactory* dwrite, bool tooltips, std::wstring& error) {
    std::unique_ptr<SidebarTopRowView> view(new SidebarTopRowView(window, tooltips));
    view->dwrite_ = dwrite;
    ComPtr<IDWriteFontCollection> fonts;
    dwrite->GetSystemFontCollection(fonts.GetAddressOf());
    UINT32 index = 0;
    BOOL fluent = FALSE;
    if (fonts) fonts->FindFamilyName(L"Segoe Fluent Icons", &index, &fluent);
    HRESULT hr = dwrite->CreateTextFormat(fluent ? L"Segoe Fluent Icons" : L"Segoe MDL2 Assets", nullptr, DWRITE_FONT_WEIGHT_REGULAR,
                                          DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, M::kSymbolSize, L"",
                                          view->iconFormat_.GetAddressOf());
    if (SUCCEEDED(hr)) hr = view->iconFormat_->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    if (FAILED(hr)) {
        error = HResultMessage(L"CreateTextFormat (the top row)", hr);
        return nullptr;
    }
    view->items_ = LayOutTopRow(view->width_, view->model_);
    view->UpdateTooltips();
    return view;
}

SidebarTopRowView::~SidebarTopRowView() {
    ReleaseGpu();
}

void SidebarTopRowView::UseCompositor(Compositor* compositor, IDCompositionVisual* parent) {
    ReleaseGpu();
    compositor_ = compositor;
    parent_ = parent;
    deviceLost_ = false;
}

void SidebarTopRowView::ReleaseGpu() {
    for (auto& [button, gpu] : gpu_) {
        if (gpu.layer.visual && parent_) {
            gpu.layer.visual->SetContent(nullptr);
            parent_->RemoveVisual(gpu.layer.visual.Get());
        }
    }
    gpu_.clear();
    opacities_.clear();
    brush_.Reset();
    shapes_.clear();
    placed_ = false;
}

bool SidebarTopRowView::Update(const TopRowModel& model, bool dark) {
    if (model == model_ && dark == dark_) return false;
    model_ = model;
    if (dark != dark_) {
        dark_ = dark;
        for (auto& [button, gpu] : gpu_) gpu.dirty = true;
    }
    // The frames and tooltips depend only on the width; enabled or not is the visual's opacity,
    // which draws nothing (Place), and a new symbol draws (NeedsDraw).
    items_ = LayOutTopRow(width_, model_);
    return Place();
}

void SidebarTopRowView::Layout(float width, UINT dpi) {
    if (width == width_ && dpi == dpi_) return;
    width_ = width;
    dpi_ = dpi;
    items_ = LayOutTopRow(width_, model_);
    for (auto& [button, gpu] : gpu_) gpu.dirty = true;
    placed_ = false;
    UpdateTooltips();
}

void SidebarTopRowView::SetTooltipsActive(bool active) { tooltips_.SetActive(active); }

void SidebarTopRowView::RelayMouse(UINT message, WPARAM wParam, LPARAM lParam) { tooltips_.Relay(message, wParam, lParam); }

void SidebarTopRowView::UpdateTooltips() {
    const float scale = Scale();
    std::vector<RelayedTooltips::Tool> tools;
    for (const TopRowItem& item : items_) {
        tools.push_back({RECT{std::lround(item.frame.left * scale), std::lround(item.frame.top * scale), std::lround(item.frame.right * scale),
                              std::lround(item.frame.bottom * scale)},
                         Widen(item.tooltip)});
    }
    tooltips_.SetTools(std::move(tools));
}

bool SidebarTopRowView::NeedsDraw() const {
    for (const TopRowItem& item : items_) {
        const auto found = gpu_.find(item.button);
        if (found == gpu_.end() || found->second.dirty || !found->second.layer.surface || found->second.symbol != item.symbol) return true;
    }
    return !placed_;
}

bool SidebarTopRowView::Place() {
    if (!compositor_) return false;
    const float scale = Scale();
    bool changed = false;
    for (const TopRowItem& item : items_) {
        auto found = gpu_.find(item.button);
        if (found == gpu_.end() || !found->second.layer.visual) continue;
        ButtonGpu& gpu = found->second;
        // On whole pixels, so the symbol drawn into the surface stays sharp.
        gpu.at = POINT{std::lround(item.frame.left * scale), std::lround(item.frame.top * scale)};
        gpu.layer.visual->SetOffsetX(static_cast<float>(gpu.at.x));
        gpu.layer.visual->SetOffsetY(static_cast<float>(gpu.at.y));
        const float opacity = item.Opacity();
        if (auto set = opacities_.find(item.button); set == opacities_.end() || set->second != opacity) {
            gpu.layer.effect->SetOpacity(opacity);
            opacities_[item.button] = opacity;
            changed = true;
        }
    }
    placed_ = true;
    return changed;
}

void SidebarTopRowView::DrawSymbol(ID2D1DeviceContext* context, const std::string& symbol, D2D1_POINT_2F centre) {
    brush_->SetColor(D2D1_COLOR_F{dark_ ? 1.0f : 0.0f, dark_ ? 1.0f : 0.0f, dark_ ? 1.0f : 0.0f, kLabelAlpha});
    if (const SymbolShape* shape = TopRowShape(symbol)) {
        auto made = shapes_.find(shape);
        if (made == shapes_.end()) {
            ComPtr<ID2D1Factory> factory;
            context->GetFactory(factory.GetAddressOf());
            made = shapes_.emplace(shape, MakeShapeGeometry(factory.Get(), *shape)).first;
        }
        if (!made->second) return;  // its geometry couldn't be made on this device
        D2D1_MATRIX_3X2_F transform{};
        context->GetTransform(&transform);
        context->SetTransform(D2D1::Matrix3x2F::Translation(centre.x, centre.y) * transform);
        context->FillGeometry(made->second.Get(), brush_.Get());
        context->SetTransform(transform);
        return;
    }
    wchar_t glyph = GlyphOf(symbol);
    if (!glyph) return;
    // The glyph's ink at 100pt (DirectWrite's overhangs past a layout box at the origin), then the
    // size whose ink covers the Mac's ink box's area, centred where the Mac's is.
    constexpr float kProbe = 100, kBox = 400;
    const DWRITE_TEXT_RANGE all{0, 1};
    ComPtr<IDWriteTextLayout> layout;
    DWRITE_OVERHANG_METRICS ink{};
    if (FAILED(dwrite_->CreateTextLayout(&glyph, 1, iconFormat_.Get(), kBox, kBox, layout.GetAddressOf())) ||
        FAILED(layout->SetFontSize(kProbe, all)) || FAILED(layout->GetOverhangMetrics(&ink))) {
        return;
    }
    const float inkLeft = -ink.left, inkTop = -ink.top, inkRight = kBox + ink.right, inkBottom = kBox + ink.bottom;
    const float inkWidth = inkRight - inkLeft, inkHeight = inkBottom - inkTop;
    if (inkWidth <= 0 || inkHeight <= 0) return;
    float size = M::kSymbolSize / kGlyphInk;
    D2D1_POINT_2F target = centre;
    if (const std::optional<SymbolInk> mac = MacSymbolInk(symbol)) {
        size = kProbe * std::sqrt(mac->width * mac->height / (inkWidth * inkHeight));
        target = D2D1::Point2F(centre.x + mac->centerX, centre.y + mac->centerY);
    }
    const float factor = size / kProbe;
    if (FAILED(layout->SetFontSize(size, all))) return;
    const D2D1_POINT_2F origin{target.x - (inkLeft + inkRight) / 2 * factor, target.y - (inkTop + inkBottom) / 2 * factor};
    context->DrawTextLayout(origin, layout.Get(), brush_.Get());
}

std::wstring SidebarTopRowView::DrawButton(const TopRowItem& item, ButtonGpu& gpu, bool readBack) {
    const float scale = Scale();
    // The button's frame from its whole-pixel corner, a pixel to spare for the rounding.
    gpu.at = POINT{std::lround(item.frame.left * scale), std::lround(item.frame.top * scale)};
    const UINT width = static_cast<UINT>(std::ceil(item.frame.Width() * scale)) + 1;
    const UINT height = static_cast<UINT>(std::ceil(item.frame.Height() * scale)) + 1;
    const D2D1_POINT_2F centre{((item.frame.left + item.frame.right) / 2 * scale - static_cast<float>(gpu.at.x)) / scale,
                               ((item.frame.top + item.frame.bottom) / 2 * scale - static_cast<float>(gpu.at.y)) / scale};
    HRESULT hr = S_OK;
    bool fresh = false;
    std::wstring error = DrawFadedLayer(
        *compositor_, perf::View::Sidebar, gpu.layer, width, height, dpi_, [&](ID2D1DeviceContext* context) { DrawSymbol(context, item.symbol, centre); },
        readBack, hr, fresh);
    if (fresh && gpu.layer.visual) {
        // A new visual: into the sidebar, and its opacity set again by Place.
        opacities_.erase(item.button);
        placed_ = false;
    }
    error = AttachFadedLayer(gpu.layer, fresh, std::move(error), parent_, TRUE, nullptr, hr);
    if (!error.empty()) {
        deviceLost_ = IsDeviceLost(hr);
        return L"a top-row button: " + error;
    }
    ++surfaceDraws_;
    gpu.symbol = item.symbol;
    gpu.dirty = false;
    return {};
}

std::wstring SidebarTopRowView::Draw(bool readBack) {
    if (!compositor_ || !parent_) return L"no compositor";
    if (deviceLost_) return L"the GPU device was lost";
    HRESULT hr = S_OK;
    if (!brush_ && FAILED(hr = compositor_->D2D()->CreateSolidColorBrush(D2D1_COLOR_F{0, 0, 0, 1}, brush_.GetAddressOf()))) {
        deviceLost_ = IsDeviceLost(hr);
        return HResultMessage(L"creating the top row's brush", hr);
    }
    for (const TopRowItem& item : items_) {
        ButtonGpu& gpu = gpu_[item.button];
        if (!readBack && !gpu.dirty && gpu.layer.surface && gpu.symbol == item.symbol) continue;
        if (std::wstring error = DrawButton(item, gpu, readBack); !error.empty()) return error;
    }
    Place();
    return {};
}

void SidebarTopRowView::ComposeInto(Pixels& sidebar) const {
    for (const TopRowItem& item : items_) {
        const auto found = gpu_.find(item.button);
        if (found != gpu_.end() && !found->second.layer.pixels.bgra.empty()) {
            ComposeOver(sidebar, found->second.layer.pixels, found->second.at, item.Opacity());
        }
    }
}

}  // namespace kite
