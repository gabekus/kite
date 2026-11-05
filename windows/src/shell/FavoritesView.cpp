// See FavoritesView.h.

#include "shell/FavoritesView.h"

#include <commctrl.h>

#include <algorithm>
#include <cmath>
#include <set>

#include "shell/Errors.h"
#include "shell/Text.h"

using Microsoft::WRL::ComPtr;

namespace kite {

namespace {

namespace F = favorites_metrics;

D2D1_ROUNDED_RECT Rounded(D2D1_RECT_F r, float radius) { return D2D1::RoundedRect(r, radius, radius); }

}  // namespace

std::unique_ptr<FavoritesView> FavoritesView::Create(HWND window, Favicons* favicons, bool tooltips) {
    return std::unique_ptr<FavoritesView>(new FavoritesView(window, favicons, tooltips));
}

FavoritesView::~FavoritesView() {
    ReleaseGpu();
    if (container_ && parent_) parent_->RemoveVisual(container_.Get());
    if (tooltip_) DestroyWindow(tooltip_);
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
    for (auto& [id, gpu] : gpu_) {
        if (gpu.visual && container_) container_->RemoveVisual(gpu.visual.Get());
    }
    gpu_.clear();
    brush_.Reset();
    placed_ = false;
}

std::vector<FavoritesView::PaneRef> FavoritesView::Panes() const {
    std::vector<PaneRef> panes;
    size_t index = 0;
    for (const FavoriteTile& tile : tray_.tiles) {
        for (const FavoritePane& pane : tile.panes) panes.push_back(PaneRef{&pane, index++});
    }
    return panes;
}

bool FavoritesView::Update(FavoritesTray tray, bool dark) {
    if (tray == tray_ && dark == dark_) return false;
    const bool appearance = dark != dark_;
    dark_ = dark;
    // What each pane's layers were drawn for, by tab: a new frame draws them all again, a new
    // favicon its icon (and its colour), a new appearance its icon (the globe is labelColor); a
    // selection moving draws nothing.
    std::map<std::string, FavoritePane> before;
    for (const PaneRef& ref : Panes()) before.emplace(ref.pane->tabID, *ref.pane);
    tray_ = std::move(tray);
    std::set<std::string> shown, urls;
    for (const PaneRef& ref : Panes()) {
        const FavoritePane& pane = *ref.pane;
        shown.insert(pane.tabID);
        if (pane.favicon.url) urls.insert(*pane.favicon.url);
        auto found = gpu_.find(pane.tabID);
        if (found == gpu_.end()) continue;
        PaneGpu& gpu = found->second;
        const auto old = before.find(pane.tabID);
        if (old == before.end() || old->second.frame != pane.frame) gpu.shapeDirty = gpu.colorDirty = gpu.iconDirty = true;
        if (old == before.end() || old->second.favicon != pane.favicon || appearance) gpu.iconDirty = true;
    }
    // Panes no longer in the grid go, GPU side and all.
    for (auto it = gpu_.begin(); it != gpu_.end();) {
        if (shown.contains(it->first)) {
            ++it;
            continue;
        }
        if (it->second.visual && container_) container_->RemoveVisual(it->second.visual.Get());
        it = gpu_.erase(it);
    }
    std::erase_if(colors_, [&](const auto& entry) { return !urls.contains(entry.first); });
    if (hover_ && !shown.contains(*hover_)) hover_.reset();
    UpdateTooltips();
    return Place();
}

void FavoritesView::Layout(UINT dpi) {
    if (dpi == dpi_) return;
    dpi_ = dpi;
    for (auto& [id, gpu] : gpu_) gpu.shapeDirty = gpu.colorDirty = gpu.iconDirty = true;
    placed_ = false;
    UpdateTooltips();
}

bool FavoritesView::SetHover(const std::optional<std::string>& tabID) {
    if (tabID == hover_) return false;
    hover_ = tabID;
    return Place();
}

UINT FavoritesView::IconPixels() const { return static_cast<UINT>(std::lround(F::kIconSize * Scale())); }

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

FavoriteLook FavoritesView::LookOf(const FavoritePane& pane) const {
    const auto gpu = gpu_.find(pane.tabID);
    const bool hasColor = gpu != gpu_.end() && gpu->second.drawnColor.has_value();
    return FavoriteLookOf(pane.selected, hover_ == pane.tabID, dark_, hasColor);
}

std::vector<FavoriteLook> FavoritesView::Looks() const {
    std::vector<FavoriteLook> looks;
    for (const PaneRef& ref : Panes()) looks.push_back(LookOf(*ref.pane));
    return looks;
}

bool FavoritesView::IconsArrived() {
    if (!favicons_) return false;
    bool any = false;
    const UINT px = IconPixels();
    for (const PaneRef& ref : Panes()) {
        const FavoritePane& pane = *ref.pane;
        auto found = gpu_.find(pane.tabID);
        if (found == gpu_.end() || !pane.favicon.url || pane.favicon.symbol) continue;
        PaneGpu& gpu = found->second;
        // Its icon, where the globe was; and its colour, once its 16px icon is there.
        if (!gpu.drewIcon && favicons_->Get(*pane.favicon.url, px)) {
            gpu.iconDirty = true;
            any = true;
        }
        if (ColorOf(pane) != gpu.drawnColor) {
            gpu.colorDirty = true;
            any = true;
        }
    }
    return any;
}

bool FavoritesView::ShowsIcon(const std::string& url) const {
    for (const PaneRef& ref : Panes()) {
        if (ref.pane->favicon.url == url) return true;
    }
    return false;
}

bool FavoritesView::NeedsDraw() const {
    for (const PaneRef& ref : Panes()) {
        const auto found = gpu_.find(ref.pane->tabID);
        if (found == gpu_.end()) return true;
        const PaneGpu& gpu = found->second;
        if (gpu.shapeDirty || gpu.colorDirty || gpu.iconDirty || !gpu.icon.surface) return true;
    }
    return !placed_ && !gpu_.empty();
}

bool FavoritesView::Place() {
    if (!compositor_) return false;
    const float scale = Scale();
    bool changed = false;
    for (const PaneRef& ref : Panes()) {
        const FavoritePane& pane = *ref.pane;
        auto found = gpu_.find(pane.tabID);
        if (found == gpu_.end() || !found->second.visual) continue;
        PaneGpu& gpu = found->second;
        // On whole pixels, so what's drawn into its layers stays sharp.
        gpu.at = POINT{static_cast<LONG>(std::floor(pane.frame.left * scale)), static_cast<LONG>(std::floor(pane.frame.top * scale))};
        gpu.visual->SetOffsetX(static_cast<float>(gpu.at.x));
        gpu.visual->SetOffsetY(static_cast<float>(gpu.at.y));
        const FavoriteLook look = LookOf(pane);
        if (gpu.placed != look) {
            if (gpu.fill.effect) gpu.fill.effect->SetOpacity(look.fill);
            if (gpu.tint.effect) gpu.tint.effect->SetOpacity(look.tint);
            if (gpu.ring.effect) gpu.ring.effect->SetOpacity(look.ring ? 1.0f : 0.0f);
            gpu.placed = look;
            changed = true;
        }
    }
    placed_ = true;
    return changed;
}

std::wstring FavoritesView::DrawPane(const FavoritePane& pane, PaneGpu& gpu, const DrawIcon& drawIcon, bool readBack) {
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
        gpu.placed.reset();
        placed_ = false;
    }
    // Its frame from its whole-pixel corner, a pixel to spare for the rounding.
    gpu.at = POINT{static_cast<LONG>(std::floor(pane.frame.left * scale)), static_cast<LONG>(std::floor(pane.frame.top * scale))};
    const UINT width = static_cast<UINT>(std::ceil(pane.frame.right * scale)) - static_cast<UINT>(gpu.at.x) + 1;
    const UINT height = static_cast<UINT>(std::ceil(pane.frame.bottom * scale)) - static_cast<UINT>(gpu.at.y) + 1;
    // The pane in the layers' points.
    const float left = pane.frame.left - static_cast<float>(gpu.at.x) / scale, top = pane.frame.top - static_cast<float>(gpu.at.y) / scale;
    const D2D1_RECT_F box{left, top, left + pane.frame.Width(), top + pane.frame.Height()};
    const std::optional<ThemeColor> color = ColorOf(pane);
    const D2D1_COLOR_F tint = color ? D2D1_COLOR_F{color->r, color->g, color->b, 1} : D2D1_COLOR_F{0, 0, 0, 0};

    // The layers in z order: each one made the first time goes on top of the pane's others.
    struct Layer {
        FadedLayer& layer;
        bool draw;
        Compositor::Content content;
    };
    const bool shape = gpu.shapeDirty || readBack || !gpu.fill.surface;
    const bool colour = gpu.colorDirty || readBack || !gpu.tint.surface || !gpu.ring.surface;
    const bool icon = gpu.iconDirty || readBack || !gpu.icon.surface;
    bool drewIcon = gpu.drewIcon;
    Layer layers[] = {
        // FillView: white, continuous corners of 12, faded to the look's wash.
        {gpu.fill, shape,
         [&](ID2D1DeviceContext* context) {
             brush_->SetColor(D2D1_COLOR_F{1, 1, 1, 1});
             context->FillRoundedRectangle(Rounded(box, F::kCornerRadius), brush_.Get());
         }},
        // The tint: the colour, faded to the look's tint.
        {gpu.tint, colour,
         [&](ID2D1DeviceContext* context) {
             if (!color) return;
             brush_->SetColor(tint);
             context->FillRoundedRectangle(Rounded(box, F::kCornerRadius), brush_.Get());
         }},
        // SidebarRingView: a 2pt border on the pane's edge, the band a 2pt stroke on it inset by 1 covers.
        {gpu.ring, colour,
         [&](ID2D1DeviceContext* context) {
             if (!color) return;
             brush_->SetColor(tint);
             const float inset = F::kRingInset;
             const D2D1_RECT_F ring{box.left + inset, box.top + inset, box.right - inset, box.bottom - inset};
             context->DrawRoundedRectangle(Rounded(ring, F::kCornerRadius - inset), brush_.Get(), F::kRingWidth);
         }},
        // The favicon, 18pt in the pane's middle, on whole pixels.
        {gpu.icon, icon,
         [&](ID2D1DeviceContext* context) {
             const float side = std::round(F::kIconSize * scale) / scale;
             const float x = std::round((box.left + (pane.frame.Width() - F::kIconSize) / 2) * scale) / scale;
             const float y = std::round((box.top + (pane.frame.Height() - F::kIconSize) / 2) * scale) / scale;
             drewIcon = drawIcon(context, pane.favicon, D2D1_RECT_F{x, y, x + side, y + side});
         }},
    };
    for (Layer& l : layers) {
        if (!l.draw) continue;
        bool fresh = false;
        std::wstring error = DrawFadedLayer(*compositor_, l.layer, width, height, dpi_, l.content, readBack, hr, fresh);
        if (fresh && l.layer.visual) {
            // A new layer: on top of the pane's others, its opacity set by Place.
            gpu.placed.reset();
            placed_ = false;
            if (!error.empty()) {
                l.layer = FadedLayer{};
            } else if (FAILED(hr = gpu.visual->AddVisual(l.layer.visual.Get(), FALSE, nullptr))) {
                l.layer = FadedLayer{};
                error = HResultMessage(L"adding a favorite's layer", hr);
            }
        }
        if (!error.empty()) return fail(error);
        ++surfaceDraws_;
    }
    gpu.frame = pane.frame;
    if (shape) gpu.shapeDirty = false;
    if (colour) {
        gpu.colorDirty = false;
        if (gpu.drawnColor != color) {
            gpu.drawnColor = color;
            gpu.placed.reset();  // its tint and ring show now (or go)
            placed_ = false;
        }
    }
    if (icon) {
        gpu.iconDirty = false;
        gpu.drewIcon = drewIcon;
    }
    return {};
}

std::wstring FavoritesView::Draw(const DrawIcon& drawIcon, bool readBack) {
    if (!compositor_ || !parent_) return L"no compositor";
    if (deviceLost_) return L"the GPU device was lost";
    HRESULT hr = S_OK;
    if (!container_) {
        // Over everything in the sidebar's root: it overlaps nothing else there.
        if (FAILED(hr = compositor_->Device()->CreateVisual(container_.GetAddressOf())) ||
            FAILED(hr = parent_->AddVisual(container_.Get(), FALSE, nullptr))) {
            container_.Reset();
            deviceLost_ = IsDeviceLost(hr);
            return HResultMessage(L"creating the favorites' visual", hr);
        }
    }
    if (!brush_ && FAILED(hr = compositor_->D2D()->CreateSolidColorBrush(D2D1_COLOR_F{1, 1, 1, 1}, brush_.GetAddressOf()))) {
        deviceLost_ = IsDeviceLost(hr);
        return HResultMessage(L"creating the favorites' brush", hr);
    }
    for (const PaneRef& ref : Panes()) {
        if (std::wstring error = DrawPane(*ref.pane, gpu_[ref.pane->tabID], drawIcon, readBack); !error.empty()) return error;
    }
    Place();
    return {};
}

void FavoritesView::ComposeInto(Pixels& sidebar) const {
    for (const PaneRef& ref : Panes()) {
        const auto found = gpu_.find(ref.pane->tabID);
        if (found == gpu_.end()) continue;
        const PaneGpu& gpu = found->second;
        const FavoriteLook look = LookOf(*ref.pane);
        const std::pair<const FadedLayer*, float> layers[] = {
            {&gpu.fill, look.fill}, {&gpu.tint, look.tint}, {&gpu.ring, look.ring ? 1.0f : 0.0f}, {&gpu.icon, 1.0f}};
        for (const auto& [layer, opacity] : layers) {
            if (!layer->pixels.bgra.empty() && opacity > 0) ComposeOver(sidebar, layer->pixels, gpu.at, opacity);
        }
    }
}

std::optional<POINT> FavoritesView::PaneCentre(size_t index, float left) const {
    for (const PaneRef& ref : Panes()) {
        if (ref.index != index) continue;
        const BarRect& f = ref.pane->frame;
        const float scale = Scale();
        return POINT{std::lround(((f.left + f.right) / 2 + left) * scale), std::lround((f.top + f.bottom) / 2 * scale)};
    }
    return std::nullopt;
}

// Tooltips ------------------------------------------------------------------------------------

void FavoritesView::SetTooltipsActive(bool active) {
    if (active == tooltipsActive_) return;
    tooltipsActive_ = active;
    if (tooltip_ && !active) SendMessageW(tooltip_, TTM_POP, 0, 0);
    UpdateTooltips();
}

void FavoritesView::MakeTooltips() {
    // Windows' own tooltips, as the Mac's toolTip is AppKit's: comctl32 loads with the first.
    INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_BAR_CLASSES};
    InitCommonControlsEx(&controls);
    tooltip_ = CreateWindowExW(WS_EX_TOPMOST, TOOLTIPS_CLASSW, nullptr, WS_POPUP | TTS_NOPREFIX, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT,
                               CW_USEDEFAULT, window_, nullptr, GetModuleHandleW(nullptr), nullptr);
    // No tooltip isn't a failure (the panes still work), and it isn't tried again.
    if (!tooltip_) {
        OutputDebugStringW(L"Kite: the favorites have no tooltips\n");
        tooltipsAllowed_ = false;
        return;
    }
    UpdateTooltips();
}

void FavoritesView::RelayMouse(UINT message, WPARAM wParam, LPARAM lParam) {
    if (!tooltipsActive_ || !tooltipsAllowed_ || tray_.tiles.empty()) return;
    if (!tooltip_) {
        // The first move over a pane makes them.
        if (message != WM_MOUSEMOVE) return;
        const float scale = Scale();
        const float x = static_cast<float>(static_cast<short>(LOWORD(lParam))) / scale;
        const float y = static_cast<float>(static_cast<short>(HIWORD(lParam))) / scale;
        if (!FavoritePaneAt(tray_, x, y)) return;
        MakeTooltips();
        if (!tooltip_) return;
    }
    if (message == WM_MOUSELEAVE) {
        SendMessageW(tooltip_, TTM_POP, 0, 0);
        return;
    }
    MSG msg{window_, message, wParam, lParam, static_cast<DWORD>(GetMessageTime()), {}};
    const DWORD pos = GetMessagePos();
    msg.pt = POINT{static_cast<short>(LOWORD(pos)), static_cast<short>(HIWORD(pos))};
    SendMessageW(tooltip_, TTM_RELAYEVENT, 0, reinterpret_cast<LPARAM>(&msg));
}

void FavoritesView::UpdateTooltips() {
    if (!tooltip_) return;
    // The tools again, one a pane (a rare change: the grid, the scale, the sidebar hiding).
    for (size_t id = 1; id <= tools_; ++id) {
        TOOLINFOW tool{};
        tool.cbSize = sizeof(tool);
        tool.hwnd = window_;
        tool.uId = id;
        SendMessageW(tooltip_, TTM_DELTOOLW, 0, reinterpret_cast<LPARAM>(&tool));
    }
    tools_ = 0;
    if (!tooltipsActive_) return;
    const float scale = Scale();
    for (const PaneRef& ref : Panes()) {
        const std::wstring text = Widen(ref.pane->title);
        const BarRect& f = ref.pane->frame;
        TOOLINFOW tool{};
        tool.cbSize = sizeof(tool);
        tool.hwnd = window_;  // relayed messages (TTM_RELAYEVENT), not a subclass of the window
        tool.uId = ref.index + 1;
        tool.rect = RECT{std::lround(f.left * scale), std::lround(f.top * scale), std::lround(f.right * scale), std::lround(f.bottom * scale)};
        tool.lpszText = const_cast<wchar_t*>(text.c_str());  // copied by the control
        if (SendMessageW(tooltip_, TTM_ADDTOOLW, 0, reinterpret_cast<LPARAM>(&tool))) tools_ = ref.index + 1;
    }
}

}  // namespace kite
