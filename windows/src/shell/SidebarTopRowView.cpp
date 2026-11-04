// See SidebarTopRowView.h.

#include "shell/SidebarTopRowView.h"

#include <commctrl.h>

#include <algorithm>
#include <cmath>

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
    if (symbol == "arrow.clockwise") return 0xE72C;  // Refresh
    if (symbol == "xmark") return 0xE711;            // Cancel
    if (symbol == "ellipsis") return 0xE712;         // More
    return 0;
}

}  // namespace

std::unique_ptr<SidebarTopRowView> SidebarTopRowView::Create(HWND window, IDWriteFactory* dwrite, bool tooltips, std::wstring& error) {
    std::unique_ptr<SidebarTopRowView> view(new SidebarTopRowView(window));
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
    if (tooltips) {
        // Windows' own tooltips, as the Mac's toolTip is AppKit's. The window's mouse messages
        // reach them through comctl32's subclass of it (TTF_SUBCLASS).
        INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_WIN95_CLASSES};
        InitCommonControlsEx(&controls);
        view->tooltip_ = CreateWindowExW(WS_EX_TOPMOST, TOOLTIPS_CLASSW, nullptr, WS_POPUP | TTS_NOPREFIX, CW_USEDEFAULT, CW_USEDEFAULT,
                                         CW_USEDEFAULT, CW_USEDEFAULT, window, nullptr, GetModuleHandleW(nullptr), nullptr);
        // No tooltip isn't a failure: the buttons still work.
        if (!view->tooltip_) OutputDebugStringW(L"Kite: the top row has no tooltips\n");
    }
    view->items_ = LayOutTopRow(view->width_, view->model_);
    view->UpdateTooltips();
    return view;
}

SidebarTopRowView::~SidebarTopRowView() {
    ReleaseGpu();
    if (tooltip_) DestroyWindow(tooltip_);
}

void SidebarTopRowView::UseCompositor(Compositor* compositor, IDCompositionVisual* parent) {
    ReleaseGpu();
    compositor_ = compositor;
    parent_ = parent;
    deviceLost_ = false;
}

void SidebarTopRowView::ReleaseGpu() {
    for (auto& [button, gpu] : gpu_) {
        if (gpu.visual && parent_) {
            gpu.visual->SetContent(nullptr);
            parent_->RemoveVisual(gpu.visual.Get());
        }
    }
    gpu_.clear();
    brush_.Reset();
    toggleShape_.Reset();
    placed_ = false;
}

void SidebarTopRowView::Update(const TopRowModel& model, bool dark) {
    if (model == model_ && dark == dark_) return;
    const std::vector<TopRowItem> old = items_;
    model_ = model;
    if (dark != dark_) {
        dark_ = dark;
        for (auto& [button, gpu] : gpu_) gpu.dirty = true;
    }
    items_ = LayOutTopRow(width_, model_);
    // Enabled or not is the visual's opacity: no drawing (Place). A new symbol draws (NeedsDraw).
    placed_ = false;
    Place();
    const auto frames = [](const std::vector<TopRowItem>& items) {
        std::vector<std::pair<TopRowButton, BarRect>> out;
        for (const TopRowItem& item : items) out.emplace_back(item.button, item.frame);
        return out;
    };
    if (frames(old) != frames(items_)) UpdateTooltips();
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

void SidebarTopRowView::SetTooltipsActive(bool active) {
    if (active == tooltipsActive_) return;
    tooltipsActive_ = active;
    UpdateTooltips();
}

void SidebarTopRowView::UpdateTooltips() {
    if (!tooltip_) return;
    // The tools again, from the buttons as they are now (a rare change: the width, the scale, or
    // the sidebar hiding or showing).
    for (UINT_PTR id : tools_) {
        TOOLINFOW tool{};
        tool.cbSize = sizeof(tool);
        tool.hwnd = window_;
        tool.uId = id;
        SendMessageW(tooltip_, TTM_DELTOOLW, 0, reinterpret_cast<LPARAM>(&tool));
    }
    tools_.clear();
    if (!tooltipsActive_) return;
    const float scale = Scale();
    for (const TopRowItem& item : items_) {
        const std::wstring text = Widen(item.tooltip);
        TOOLINFOW tool{};
        tool.cbSize = sizeof(tool);
        tool.uFlags = TTF_SUBCLASS;
        tool.hwnd = window_;
        tool.uId = static_cast<UINT_PTR>(item.button) + 1;
        tool.rect = RECT{std::lround(item.frame.left * scale), std::lround(item.frame.top * scale), std::lround(item.frame.right * scale),
                         std::lround(item.frame.bottom * scale)};
        tool.lpszText = const_cast<wchar_t*>(text.c_str());  // copied by the control
        if (SendMessageW(tooltip_, TTM_ADDTOOLW, 0, reinterpret_cast<LPARAM>(&tool))) tools_.push_back(tool.uId);
    }
}

bool SidebarTopRowView::NeedsDraw() const {
    for (const TopRowItem& item : items_) {
        const auto found = gpu_.find(item.button);
        if (found == gpu_.end() || found->second.dirty || !found->second.surface || found->second.symbol != item.symbol) return true;
    }
    return !placed_;
}

void SidebarTopRowView::Place() {
    if (!compositor_) return;
    const float scale = Scale();
    for (const TopRowItem& item : items_) {
        auto found = gpu_.find(item.button);
        if (found == gpu_.end() || !found->second.visual) continue;
        ButtonGpu& gpu = found->second;
        // On whole pixels, so the symbol drawn into the surface stays sharp.
        gpu.at = POINT{std::lround(item.frame.left * scale), std::lround(item.frame.top * scale)};
        gpu.visual->SetOffsetX(static_cast<float>(gpu.at.x));
        gpu.visual->SetOffsetY(static_cast<float>(gpu.at.y));
        gpu.effect->SetOpacity(item.Opacity());
    }
    placed_ = true;
}

void SidebarTopRowView::DrawSymbol(ID2D1DeviceContext* context, const std::string& symbol, D2D1_POINT_2F centre) {
    brush_->SetColor(D2D1_COLOR_F{dark_ ? 1.0f : 0.0f, dark_ ? 1.0f : 0.0f, dark_ ? 1.0f : 0.0f, kLabelAlpha});
    if (symbol == "sidebar.left") {
        if (!toggleShape_) return;
        D2D1_MATRIX_3X2_F transform{};
        context->GetTransform(&transform);
        context->SetTransform(D2D1::Matrix3x2F::Translation(centre.x, centre.y) * transform);
        context->FillGeometry(toggleShape_.Get(), brush_.Get());
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
    HRESULT hr = S_OK;
    const auto fail = [&](const wchar_t* what) {
        deviceLost_ = IsDeviceLost(hr);
        return HResultMessage(what, hr);
    };
    if (!gpu.visual) {
        if (FAILED(hr = compositor_->Device()->CreateVisual(gpu.visual.GetAddressOf())) ||
            FAILED(hr = compositor_->Device()->CreateEffectGroup(gpu.effect.GetAddressOf())) ||
            FAILED(hr = gpu.visual->SetEffect(gpu.effect.Get())) || FAILED(hr = parent_->AddVisual(gpu.visual.Get(), TRUE, nullptr))) {
            gpu = ButtonGpu{};
            return fail(L"creating a top-row button's visual");
        }
        placed_ = false;
    }
    // The button's frame from its whole-pixel corner, a pixel to spare for the rounding.
    gpu.at = POINT{std::lround(item.frame.left * scale), std::lround(item.frame.top * scale)};
    const UINT width = static_cast<UINT>(std::ceil(item.frame.Width() * scale)) + 1;
    const UINT height = static_cast<UINT>(std::ceil(item.frame.Height() * scale)) + 1;
    if (!gpu.surface) {
        if (FAILED(hr = compositor_->Device()->CreateVirtualSurface(width, height, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED,
                                                                     gpu.surface.GetAddressOf())) ||
            FAILED(hr = gpu.visual->SetContent(gpu.surface.Get()))) {
            gpu.surface.Reset();
            return fail(L"creating a top-row button's surface");
        }
    } else if ((width != gpu.width || height != gpu.height) && FAILED(hr = gpu.surface->Resize(width, height))) {
        return fail(L"resizing a top-row button's surface");
    }
    gpu.width = width;
    gpu.height = height;
    const D2D1_POINT_2F centre{((item.frame.left + item.frame.right) / 2 * scale - static_cast<float>(gpu.at.x)) / scale,
                               ((item.frame.top + item.frame.bottom) / 2 * scale - static_cast<float>(gpu.at.y)) / scale};
    gpu.pixels = Pixels{};
    std::wstring error = compositor_->DrawSurface(
        gpu.surface.Get(), width, height, dpi_, [&](ID2D1DeviceContext* context) { DrawSymbol(context, item.symbol, centre); },
        readBack ? &gpu.pixels : nullptr, hr);
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
    if (!toggleShape_) {
        ComPtr<ID2D1Factory> factory;
        compositor_->D2D()->GetFactory(factory.GetAddressOf());
        toggleShape_ = MakeShapeGeometry(factory.Get(), SidebarToggleShape());
    }
    // Buttons no longer shown (a compact width) go.
    for (auto it = gpu_.begin(); it != gpu_.end();) {
        const bool shown = std::any_of(items_.begin(), items_.end(), [&](const TopRowItem& item) { return item.button == it->first; });
        if (shown) {
            ++it;
            continue;
        }
        if (it->second.visual) parent_->RemoveVisual(it->second.visual.Get());
        it = gpu_.erase(it);
    }
    for (const TopRowItem& item : items_) {
        ButtonGpu& gpu = gpu_[item.button];
        if (!readBack && !gpu.dirty && gpu.surface && gpu.symbol == item.symbol) continue;
        if (std::wstring error = DrawButton(item, gpu, readBack); !error.empty()) return error;
    }
    Place();
    return {};
}

void SidebarTopRowView::ComposeInto(Pixels& sidebar) const {
    for (const TopRowItem& item : items_) {
        const auto found = gpu_.find(item.button);
        if (found != gpu_.end() && !found->second.pixels.bgra.empty()) ComposeOver(sidebar, found->second.pixels, found->second.at, item.Opacity());
    }
}

}  // namespace kite
