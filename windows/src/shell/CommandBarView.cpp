// See CommandBarView.h.

#include "shell/CommandBarView.h"

#include <imm.h>
#include <windowsx.h>

#include <algorithm>
#include <cmath>

#include "core/Unicode.h"
#include "shell/Errors.h"
#include "shell/SystemFont.h"
#include "shell/Text.h"

using Microsoft::WRL::ComPtr;

namespace kite {

namespace {

// ArcMetrics.CommandBar, in points.
namespace C {
constexpr float kWidth = 765;
constexpr float kMinimumWindowMargin = 20;
constexpr float kTopFraction = 0.369f;
constexpr float kCornerRadius = 12;
constexpr float kBorderOpacity = 0.22f;
constexpr float kOutlineWidth = 0.5f;
constexpr float kPlaceholderOpacity = 0.25f;
constexpr float kFieldHeight = 63.5f;
constexpr float kIconX = 22.5f;
constexpr float kIconSize = 18;
constexpr D2D1_POINT_2F kMagnifierCenter{8.35f, 8};
constexpr float kMagnifierRadius = 4.65f;
constexpr float kMagnifierStroke = 1.4f;
constexpr float kMagnifierHandleEnd = 8.1f;
constexpr float kTextX = 51.5f;
constexpr float kFieldFontSize = 18;
constexpr float kFieldBaseline = 38.5f;  // fieldTextLift: the baseline sits at 38.5
constexpr float kDividerInset = 11.5f;
constexpr float kDividerOpacity = 0.10f;
constexpr float kListTopGap = 4.5f;
constexpr float kListBottomGap = 9.5f;
constexpr float kRowInset = 7.5f;
constexpr float kRowPitch = 50;
constexpr float kRowFillInset = 2;
constexpr float kRowFillHeight = 44.5f;
constexpr float kRowCornerRadius = 8;
constexpr float kRowIconTileSize = 24;
constexpr float kRowIconSize = 16;
constexpr float kRowIconX = 10;
constexpr float kRowTitleX = 41;
constexpr float kRowFontSize = 13;
constexpr float kRowTextOpacity = 0.8f;
constexpr float kRowDetailOpacity = 0.33f;
constexpr float kActionBoxSize = 24;
constexpr float kActionBoxTrailing = 13;
constexpr float kActionGap = 7;
}  // namespace C

// Kite for Windows' own. DirectComposition can't blur the page's child window under the
// panel, so the panel is the colour Arc's blurred one comes out as: ArcMetrics measured
// 21 + 0.106 × page per channel (48 over white), which is #181818 at 89.4% over the page.
constexpr float kDarkPanelGrey = 21.0f / 0.894f / 255.0f;
constexpr float kPanelAlpha = 0.894f;
// Light spaces: the Mac's 0.98 white tint over its light material, not measured against Arc.
constexpr float kLightPanelGrey = 0.97f;
// ArcMetrics' shadow (opacity 0.9, radius 45, y 16) is a SwiftUI shadow; the darkening it
// measured on Arc (35% under the bottom edge, 25% at the sides, 16% at the top, gone about
// 100pt away) is a Gaussian of 30pt at 50% black, 16pt down. Kite draws it for the panel's
// rectangle (the 12pt corners make little difference under a 30pt blur).
constexpr float kShadowBlur = 30;
constexpr float kShadowOpacity = 0.5f;
constexpr float kShadowY = 16;
constexpr float kShadowMargin = 112;  // room for it around the panel: 3σ and the offset
// Open, five tabs, three pages from history, search: the most rows CommandBarSuggestions makes.
constexpr size_t kMaxRows = 10;
// The Mac's default text selection colours (NSColor.selectedTextBackgroundColor), not
// checked against Arc's bar.
constexpr D2D1_COLOR_F kDarkSelection{63 / 255.0f, 99 / 255.0f, 139 / 255.0f, 1};
constexpr D2D1_COLOR_F kLightSelection{179 / 255.0f, 215 / 255.0f, 1, 1};
// docs/windows.md, Refresh rate: flip-discard with a frame-latency waitable object, latency 1.
constexpr UINT kSwapChainFlags = DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;

// Segoe Fluent Icons (Windows 11) and Segoe MDL2 Assets (Windows 10) share these code points:
// the counterparts of the Mac's SF Symbols globe, magnifyingglass and arrow.right.
constexpr wchar_t kGlobeGlyph = 0xE774;
constexpr wchar_t kSearchGlyph = 0xE721;
constexpr wchar_t kArrowGlyph = 0xE72A;
// The Mac's FaviconView with no favicon yet: the globe at 60% (of labelColor, SidebarKit.swift:269, 313).
constexpr float kNoFaviconOpacity = 0.6f;
// NSColor.labelColor's alpha, in both appearances.
constexpr float kLabelAlpha = 0.85f;

// How much of a Gaussian of standard deviation `sigma` falls between `from` and `to`: the
// shadow's falloff along one axis at `x`.
float GaussianCoverage(float x, float from, float to, float sigma) {
    const float s = sigma * std::sqrt(2.0f);
    return 0.5f * (std::erf((x - from) / s) - std::erf((x - to) / s));
}

// One row (or column) of premultiplied black at these opacities, as a bitmap at `dpi`.
HRESULT MakeAlphaStrip(ID2D1DeviceContext* context, const std::vector<float>& alphas, bool row, float dpi,
                       ComPtr<ID2D1Bitmap1>& out) {
    std::vector<uint8_t> pixels(alphas.size() * 4, 0);
    for (size_t i = 0; i < alphas.size(); ++i) {
        pixels[i * 4 + 3] = static_cast<uint8_t>(std::lround(std::clamp(alphas[i], 0.0f, 1.0f) * 255));
    }
    const auto count = static_cast<UINT32>(alphas.size());
    const D2D1_SIZE_U size = row ? D2D1_SIZE_U{count, 1} : D2D1_SIZE_U{1, count};
    D2D1_BITMAP_PROPERTIES1 props{};
    props.pixelFormat = D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED);
    props.dpiX = props.dpiY = dpi;
    props.bitmapOptions = D2D1_BITMAP_OPTIONS_NONE;
    return context->CreateBitmap(size, pixels.data(), row ? count * 4 : 4, &props, out.ReleaseAndGetAddressOf());
}

D2D1_COLOR_F Color(float r, float g, float b, float a) { return D2D1_COLOR_F{r, g, b, a}; }
D2D1_COLOR_F WithAlpha(D2D1_COLOR_F color, float alpha) {
    color.a *= alpha;
    return color;
}

}  // namespace

std::unique_ptr<CommandBarView> CommandBarView::Create(HWND window, Callbacks callbacks, std::wstring& error) {
    std::unique_ptr<CommandBarView> view(new CommandBarView(window, std::move(callbacks)));
    D2D1_FACTORY_OPTIONS options{};
    HRESULT hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory1), &options,
                                   reinterpret_cast<void**>(view->d2dFactory_.GetAddressOf()));
    if (FAILED(hr)) {
        error = HResultMessage(L"D2D1CreateFactory", hr);
        return nullptr;
    }
    if (FAILED(hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                                        reinterpret_cast<IUnknown**>(view->dwrite_.GetAddressOf())))) {
        error = HResultMessage(L"DWriteCreateFactory", hr);
        return nullptr;
    }
    // The Mac's bar sets its field and rows in SF Pro medium (shell/SystemFont).
    auto format = [&](float size, ComPtr<IDWriteTextFormat>& out) {
        HRESULT made = system_font::CreateTextFormat(view->dwrite_.Get(), MacWeight::Medium, size, out);
        if (SUCCEEDED(made)) made = out->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        return made;
    };
    auto icon = [&](float size, ComPtr<IDWriteTextFormat>& out) {
        HRESULT made = system_font::CreateIconFormat(view->dwrite_.Get(), system_font::IconFont::Symbols, DWRITE_FONT_WEIGHT_MEDIUM, size, out);
        if (SUCCEEDED(made)) made = out->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        return made;
    };
    if (FAILED(hr = format(C::kFieldFontSize, view->fieldFormat_)) || FAILED(hr = format(C::kRowFontSize, view->rowFormat_)) ||
        FAILED(hr = format(C::kRowFontSize, view->rowEllipsisFormat_)) || FAILED(hr = icon(C::kRowIconSize, view->iconFormat_)) ||
        FAILED(hr = icon(13, view->arrowFormat_))) {
        error = HResultMessage(L"CreateTextFormat", hr);
        return nullptr;
    }
    // Icons sit in the middle of their tile or box.
    for (IDWriteTextFormat* icons : {view->iconFormat_.Get(), view->arrowFormat_.Get()}) {
        icons->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
        icons->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    }
    // Rows: one line, centred in the row's fill; a title too long for its row ends in "…".
    view->rowFormat_->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    view->rowEllipsisFormat_->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    if (SUCCEEDED(view->dwrite_->CreateEllipsisTrimmingSign(view->rowEllipsisFormat_.Get(), view->ellipsis_.GetAddressOf()))) {
        const DWRITE_TRIMMING trimming{DWRITE_TRIMMING_GRANULARITY_CHARACTER, 0, 0};
        view->rowEllipsisFormat_->SetTrimming(&trimming, view->ellipsis_.Get());
    }
    D2D1_STROKE_STYLE_PROPERTIES1 round{};
    round.startCap = round.endCap = round.dashCap = D2D1_CAP_STYLE_ROUND;
    round.lineJoin = D2D1_LINE_JOIN_ROUND;
    round.miterLimit = 10;
    round.dashStyle = D2D1_DASH_STYLE_SOLID;
    round.transformType = D2D1_STROKE_TRANSFORM_TYPE_NORMAL;
    if (FAILED(hr = view->d2dFactory_->CreateStrokeStyle(round, nullptr, 0, view->roundStroke_.GetAddressOf()))) {
        error = HResultMessage(L"CreateStrokeStyle", hr);
        return nullptr;
    }
    static constexpr wchar_t kPlaceholder[] = L"Search or Enter URL...";
    view->dwrite_->CreateTextLayout(kPlaceholder, static_cast<UINT32>(std::size(kPlaceholder) - 1), view->fieldFormat_.Get(), 100000,
                                    C::kFieldHeight, view->placeholderLayout_.GetAddressOf());
    view->line_.SetFormat(view->dwrite_.Get(), view->fieldFormat_.Get(), C::kFieldHeight);
    return view;
}

CommandBarView::~CommandBarView() {
    if (open_) line_.StopBlink();
    ReleaseGpu();
}

void CommandBarView::UseCompositor(Compositor* compositor) {
    ReleaseGpu();
    compositor_ = compositor;
    renderer_ = compositor ? &compositor->GetRenderer() : nullptr;
    deviceLost_ = false;
    if (open_ && renderer_) Draw();
}

bool CommandBarView::CreateGpu(std::wstring& error) {
    ComPtr<IDXGIDevice> dxgi;
    HRESULT hr = renderer_->Device()->QueryInterface(IID_PPV_ARGS(dxgi.GetAddressOf()));
    if (SUCCEEDED(hr)) hr = d2dFactory_->CreateDevice(dxgi.Get(), d2dDevice_.ReleaseAndGetAddressOf());
    if (SUCCEEDED(hr)) hr = d2dDevice_->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, context_.ReleaseAndGetAddressOf());
    if (SUCCEEDED(hr)) hr = context_->CreateSolidColorBrush(Color(0, 0, 0, 1), brush_.ReleaseAndGetAddressOf());
    if (FAILED(hr)) {
        error = HResultMessage(L"creating the command bar's Direct2D device", hr);
        ReleaseGpu();
        return false;
    }
    // Grayscale: ClearType needs an opaque background, and the panel isn't.
    context_->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
    // In the overlay: over the page's child window (the backdrop is behind it).
    composition_ = compositor_->Device();
    if (FAILED(hr = composition_->CreateVisual(visual_.ReleaseAndGetAddressOf())) ||
        FAILED(hr = compositor_->Overlay()->AddVisual(visual_.Get(), FALSE, nullptr)) || FAILED(hr = compositor_->Commit())) {
        error = HResultMessage(L"building the command bar's composition tree", hr);
        ReleaseGpu();
        return false;
    }
    return true;
}

void CommandBarView::ReleaseGpu() {
    ReleaseBuffers();
    shadowRow_.Reset();
    shadowColumn_.Reset();
    shadowColumnBrush_.Reset();
    outsidePanel_.Reset();
    shadowWidth_ = shadowHeight_ = -1;
    shadowDpi_ = 0;
    caret_.Release();
    if (visual_ && compositor_) {
        compositor_->Overlay()->RemoveVisual(visual_.Get());
        compositor_->Commit();
    }
    visual_.Reset();
    composition_.Reset();
    brush_.Reset();
    context_.Reset();
    d2dDevice_.Reset();
}

void CommandBarView::ReleaseBuffers() {
    if (context_) context_->SetTarget(nullptr);
    backBuffer_.Reset();
    if (visual_) visual_->SetContent(nullptr);
    swapChain_.Reset();
    if (frameLatency_) CloseHandle(frameLatency_);
    frameLatency_ = nullptr;
}

void CommandBarView::ComputeGeometry() {
    Geometry g;
    g.dpi = callbacks_.dpi ? callbacks_.dpi() : GetDpiForWindow(window_);
    g.scale = static_cast<float>(g.dpi) / USER_DEFAULT_SCREEN_DPI;
    RECT client{};
    GetClientRect(window_, &client);
    const float windowWidth = static_cast<float>(client.right) / g.scale;
    const float windowHeight = static_cast<float>(client.bottom) / g.scale;
    // Arc's 765pt, but never past the window's edges: the window can be 640 wide.
    g.width = std::max(100.0f, std::min(C::kWidth, windowWidth - 2 * C::kMinimumWindowMargin));
    // Centred, its top at 36.9% of the window's height, rounded to a point (the Mac's overlay).
    const float left = (windowWidth - g.width) / 2;
    const float top = std::round(windowHeight * C::kTopFraction);
    g.leftPx = std::lround(left * g.scale);
    g.topPx = std::lround(top * g.scale);
    g.marginPx = static_cast<LONG>(std::ceil(kShadowMargin * g.scale));
    const float tallest = C::kFieldHeight + 0.5f + C::kListTopGap + kMaxRows * C::kRowPitch + C::kListBottomGap;
    g.bufferWidth = static_cast<UINT>(std::ceil(g.width * g.scale)) + 2 * static_cast<UINT>(g.marginPx);
    g.bufferHeight = static_cast<UINT>(std::ceil(tallest * g.scale)) + 2 * static_cast<UINT>(g.marginPx);
    const bool widthChanged = g.width != geometry_.width;
    geometry_ = g;
    // The field's visible width before any text is laid out in it (Show sets the text next).
    line_.SetVisibleWidth(g.width - C::kIconX - C::kTextX);
    if (widthChanged) BuildRowText();
}

float CommandBarView::PanelHeight() const {
    if (rows_.empty()) return C::kFieldHeight;
    return C::kFieldHeight + 0.5f + C::kListTopGap + static_cast<float>(rows_.size()) * C::kRowPitch + C::kListBottomGap;
}

bool CommandBarView::EnsureBuffer(std::wstring& error) {
    const Geometry& g = geometry_;
    HRESULT hr = S_OK;
    DXGI_SWAP_CHAIN_DESC1 desc{};
    if (swapChain_) swapChain_->GetDesc1(&desc);
    if (!swapChain_) {
        ComPtr<IDXGIDevice> dxgi;
        ComPtr<IDXGIAdapter> adapter;
        ComPtr<IDXGIFactory2> factory;
        ComPtr<IDXGISwapChain1> swapChain;
        hr = renderer_->Device()->QueryInterface(IID_PPV_ARGS(dxgi.GetAddressOf()));
        if (SUCCEEDED(hr)) hr = dxgi->GetAdapter(adapter.GetAddressOf());
        if (SUCCEEDED(hr)) hr = adapter->GetParent(IID_PPV_ARGS(factory.GetAddressOf()));
        desc = {};
        desc.Width = g.bufferWidth;
        desc.Height = g.bufferHeight;
        desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        desc.BufferCount = 2;
        desc.Scaling = DXGI_SCALING_STRETCH;
        desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
        desc.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;
        desc.Flags = kSwapChainFlags;
        if (SUCCEEDED(hr)) hr = factory->CreateSwapChainForComposition(renderer_->Device(), &desc, nullptr, swapChain.GetAddressOf());
        if (SUCCEEDED(hr)) hr = swapChain.As(&swapChain_);
        if (SUCCEEDED(hr)) hr = swapChain_->SetMaximumFrameLatency(1);
        if (SUCCEEDED(hr)) hr = visual_->SetContent(swapChain_.Get());
        if (FAILED(hr)) {
            deviceLost_ = IsDeviceLost(hr);
            swapChain_.Reset();
            error = HResultMessage(L"creating the command bar's swap chain", hr);
            return false;
        }
        frameLatency_ = swapChain_->GetFrameLatencyWaitableObject();
    } else if (desc.Width != g.bufferWidth || desc.Height != g.bufferHeight) {
        context_->SetTarget(nullptr);
        backBuffer_.Reset();
        renderer_->Flush();
        if (FAILED(hr = swapChain_->ResizeBuffers(0, g.bufferWidth, g.bufferHeight, DXGI_FORMAT_UNKNOWN, kSwapChainFlags))) {
            deviceLost_ = IsDeviceLost(hr);
            error = HResultMessage(L"resizing the command bar's swap chain", hr);
            return false;
        }
    }
    if (!backBuffer_) {
        // Buffer 0 is always the one to draw into: DXGI rotates flip-model buffers behind it.
        ComPtr<IDXGISurface> surface;
        hr = swapChain_->GetBuffer(0, IID_PPV_ARGS(surface.GetAddressOf()));
        const D2D1_BITMAP_PROPERTIES1 props =
            D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
                                    D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
                                    static_cast<float>(g.dpi), static_cast<float>(g.dpi));
        if (SUCCEEDED(hr)) hr = context_->CreateBitmapFromDxgiSurface(surface.Get(), &props, backBuffer_.GetAddressOf());
        if (FAILED(hr)) {
            deviceLost_ = IsDeviceLost(hr);
            error = HResultMessage(L"getting the command bar's buffer", hr);
            return false;
        }
    }
    visual_->SetOffsetX(static_cast<float>(g.leftPx - g.marginPx));
    visual_->SetOffsetY(static_cast<float>(g.topPx - g.marginPx));
    return true;
}

bool CommandBarView::EnsureShadow(float height, std::wstring& error) {
    const Geometry& g = geometry_;
    const float dpi = static_cast<float>(g.dpi);
    const float margin = static_cast<float>(g.marginPx) / g.scale;
    HRESULT hr = S_OK;
    // Its horizontal falloff: per width and DPI. At 50% black, with the vertical one at 100%.
    if (!shadowRow_ || shadowWidth_ != g.width || shadowDpi_ != g.dpi) {
        std::vector<float> alphas(g.bufferWidth);
        for (UINT i = 0; i < g.bufferWidth; ++i) {
            const float x = (static_cast<float>(i) + 0.5f) / g.scale - margin;
            alphas[i] = kShadowOpacity * GaussianCoverage(x, 0, g.width, kShadowBlur);
        }
        hr = MakeAlphaStrip(context_.Get(), alphas, true, dpi, shadowRow_);
        shadowHeight_ = -1;  // the mask follows the width too
    }
    // Its vertical falloff, 16pt down, and the panel's outline to keep it out of: per height.
    if (SUCCEEDED(hr) && (!shadowColumn_ || shadowHeight_ != height || shadowDpi_ != g.dpi)) {
        std::vector<float> alphas(g.bufferHeight);
        for (UINT i = 0; i < g.bufferHeight; ++i) {
            const float y = (static_cast<float>(i) + 0.5f) / g.scale - margin - kShadowY;
            alphas[i] = GaussianCoverage(y, 0, height, kShadowBlur);
        }
        hr = MakeAlphaStrip(context_.Get(), alphas, false, dpi, shadowColumn_);
        D2D1_BITMAP_BRUSH_PROPERTIES1 brush{};
        brush.extendModeX = D2D1_EXTEND_MODE_CLAMP;  // the column, repeated across
        brush.extendModeY = D2D1_EXTEND_MODE_CLAMP;
        brush.interpolationMode = D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR;
        if (SUCCEEDED(hr)) hr = context_->CreateBitmapBrush(shadowColumn_.Get(), &brush, nullptr, shadowColumnBrush_.ReleaseAndGetAddressOf());
        ComPtr<ID2D1RectangleGeometry> everything;
        ComPtr<ID2D1RoundedRectangleGeometry> inside;
        ComPtr<ID2D1GeometrySink> sink;
        const D2D1_ROUNDED_RECT panel{{margin, margin, margin + g.width, margin + height}, C::kCornerRadius, C::kCornerRadius};
        if (SUCCEEDED(hr)) {
            hr = d2dFactory_->CreateRectangleGeometry(
                D2D1::RectF(0, 0, static_cast<float>(g.bufferWidth) / g.scale, static_cast<float>(g.bufferHeight) / g.scale),
                everything.GetAddressOf());
        }
        if (SUCCEEDED(hr)) hr = d2dFactory_->CreateRoundedRectangleGeometry(panel, inside.GetAddressOf());
        if (SUCCEEDED(hr)) hr = d2dFactory_->CreatePathGeometry(outsidePanel_.ReleaseAndGetAddressOf());
        if (SUCCEEDED(hr)) hr = outsidePanel_->Open(sink.GetAddressOf());
        if (SUCCEEDED(hr)) hr = everything->CombineWithGeometry(inside.Get(), D2D1_COMBINE_MODE_EXCLUDE, nullptr, sink.Get());
        if (SUCCEEDED(hr)) hr = sink->Close();
    }
    if (FAILED(hr)) {
        deviceLost_ = IsDeviceLost(hr);
        shadowRow_.Reset();
        shadowColumn_.Reset();
        error = HResultMessage(L"making the command bar's shadow", hr);
        return false;
    }
    shadowWidth_ = g.width;
    shadowHeight_ = height;
    shadowDpi_ = g.dpi;
    return true;
}

void CommandBarView::Show(CommandBarMode mode, const std::string& text, const Look& look) {
    look_ = look;
    mode_ = mode;
    if (open_) {
        // Ctrl+T on an open bar: the mode changes; what's typed and the highlight stay (the
        // Mac keeps the view's state), and the field keeps the keyboard.
        if (GetForegroundWindow() == window_) SetFocus(window_);
        Refresh();
        return;
    }
    open_ = true;
    highlighted_ = 0;
    selecting_ = false;
    composing_ = false;
    pressed_ = kPressedNothing;
    hoveredRow_ = -1;
    // Laid out and filled before anything can draw (taking the focus below draws).
    ComputeGeometry();
    std::wstring wide = Widen(text);
    const size_t end = wide.size();
    // All selected, as an NSTextField's text when it takes focus.
    SetText(std::move(wide), end, 0);
    if (callbacks_.opened) callbacks_.opened();
    // The keyboard, when Kite is the window in front (a quiet test run never activates).
    if (GetForegroundWindow() == window_) SetFocus(window_);
    focused_ = GetFocus() == window_;
    if (focused_) CreateCaret(window_, nullptr, 1, 1);  // hidden: where magnifiers and IMEs look
    RestartCaretBlink();
}

void CommandBarView::Type(std::string_view text) {
    if (open_) Apply(line_.Edit().Insert(Widen(text)));
}

void CommandBarView::Hide() {
    if (!open_) return;
    open_ = false;
    line_.StopBlink();
    if (GetCapture() == window_) ReleaseCapture();
    if (focused_) DestroyCaret();
    selecting_ = false;
    composing_ = false;
    hoveredRow_ = -1;
    redrawPosted_ = false;
    drawOnRestore_ = false;
    // Its buffers go until it opens again; the device, target and shadow strips stay.
    ReleaseBuffers();
    caret_.Update(composition_.Get(), context_.Get(), visual_.Get(), false, {}, 0, 0, {});
    if (composition_ && compositor_) compositor_->Commit();
    line_.Edit().SetText(std::wstring(), 0, 0);
    line_.Relayout();
    rows_.clear();
    rowText_.clear();
    if (callbacks_.closed) callbacks_.closed();
}

void CommandBarView::Layout() {
    if (!open_) return;
    const Geometry before = geometry_;
    ComputeGeometry();
    const Geometry& g = geometry_;
    if (visual_ && swapChain_ && before.width == g.width && before.dpi == g.dpi && before.bufferWidth == g.bufferWidth &&
        before.bufferHeight == g.bufferHeight) {
        // Only moved (a resize of a window wider than the bar): no redraw.
        visual_->SetOffsetX(static_cast<float>(g.leftPx - g.marginPx));
        visual_->SetOffsetY(static_cast<float>(g.topPx - g.marginPx));
        UpdateCaret();  // the hidden system caret follows; commits
    } else {
        KeepCaretVisible();
        Invalidate();
    }
    if (composing_) PlaceImeWindow();
    if (drawOnRestore_) {
        drawOnRestore_ = false;
        Invalidate();
    }
}

void CommandBarView::Refresh() {
    if (!open_) return;
    std::vector<CommandSuggestion> rows = callbacks_.suggestions ? callbacks_.suggestions(Narrow(line_.Edit().Text()), mode_) : std::vector<CommandSuggestion>{};
    if (rows.size() > kMaxRows) rows.resize(kMaxRows);
    if (rows == rows_) return;
    const bool hadHighlight = highlighted_ >= 0 && static_cast<size_t>(highlighted_) < rows_.size();
    const CommandSuggestion was = hadHighlight ? rows_[static_cast<size_t>(highlighted_)] : CommandSuggestion{};
    SetRows(std::move(rows));
    int keep = std::clamp(highlighted_, 0, std::max(static_cast<int>(rows_.size()) - 1, 0));
    if (hadHighlight) {
        for (size_t i = 0; i < rows_.size(); ++i) {
            const CommandSuggestion& row = rows_[i];
            const bool same = row.kind == was.kind &&
                              (row.kind == CommandSuggestion::Kind::SwitchTab ? row.tabID == was.tabID : row.url == was.url);
            if (same) {
                keep = static_cast<int>(i);
                break;
            }
        }
    }
    highlighted_ = keep;
    Invalidate();
}

void CommandBarView::SetRows(std::vector<CommandSuggestion> rows) {
    if (rows.size() > kMaxRows) rows.resize(kMaxRows);
    rows_ = std::move(rows);
    BuildRowText();
}

void CommandBarView::BuildRowText() {
    rowText_.clear();
    const float fillWidth = geometry_.width - 2 * (C::kRowInset + C::kRowFillInset);
    const float boxLeft = fillWidth - C::kActionBoxTrailing - C::kActionBoxSize;
    for (const CommandSuggestion& row : rows_) {
        RowText text;
        float titleRight = boxLeft - C::kActionGap;
        if (!row.detail.empty()) {
            const std::wstring detail = Widen(row.detail);
            dwrite_->CreateTextLayout(detail.c_str(), static_cast<UINT32>(detail.size()), rowFormat_.Get(), 100000, C::kRowFillHeight,
                                      text.detail.GetAddressOf());
            DWRITE_TEXT_METRICS metrics{};
            if (text.detail && SUCCEEDED(text.detail->GetMetrics(&metrics))) text.detailWidth = metrics.widthIncludingTrailingWhitespace;
            // The detail keeps its padding before the arrow; the title stops 7pt short of it.
            titleRight = boxLeft - C::kActionGap - text.detailWidth - C::kActionGap;
        }
        const std::wstring title = Widen(row.title);
        const float room = std::max(titleRight - C::kRowTitleX, 1.0f);
        dwrite_->CreateTextLayout(title.c_str(), static_cast<UINT32>(title.size()), rowEllipsisFormat_.Get(), room, C::kRowFillHeight,
                                  text.title.GetAddressOf());
        if (text.title && !row.subtitle.empty()) {
            DWRITE_TEXT_METRICS metrics{};
            if (SUCCEEDED(text.title->GetMetrics(&metrics))) text.titleWidth = metrics.widthIncludingTrailingWhitespace;
            // The subtitle only where the whole title fits; the rest of the line, cut at its end.
            if (text.titleWidth < room - 1) {
                const std::wstring subtitle = L" \u2014 " + Widen(row.subtitle);
                dwrite_->CreateTextLayout(subtitle.c_str(), static_cast<UINT32>(subtitle.size()), rowEllipsisFormat_.Get(),
                                          room - text.titleWidth, C::kRowFillHeight, text.subtitle.GetAddressOf());
            }
        }
        rowText_.push_back(std::move(text));
    }
}

// Text editing ---------------------------------------------------------------------------

void CommandBarView::SetText(std::wstring text, size_t caret, size_t anchor) {
    line_.Edit().SetText(std::move(text), caret, anchor);
    TextChanged();
}

void CommandBarView::TextChanged() {
    const std::wstring& text = line_.Edit().Text();
    line_.Relayout();
    // As the Mac's onChange(of: query): the rows again, the first highlighted.
    highlighted_ = 0;
    SetRows(callbacks_.suggestions ? callbacks_.suggestions(Narrow(text), mode_) : std::vector<CommandSuggestion>{});
    KeepCaretVisible();
    Invalidate();  // first, so the caret waits for the text's draw
    RestartCaretBlink();
}

void CommandBarView::SelectionChanged() {
    KeepCaretVisible();
    Invalidate();  // first, so the caret waits for the text's draw
    RestartCaretBlink();
}

void CommandBarView::Apply(TextEditing::Change change) {
    if (change == TextEditing::Change::Text) TextChanged();
    else if (change == TextEditing::Change::Selection) SelectionChanged();
}

bool CommandBarView::KeyDown(UINT key, bool ctrl, bool shift) {
    switch (key) {
    case VK_ESCAPE:
        Hide();
        return true;
    case VK_RETURN:
        Commit();
        return true;
    case VK_UP:
        SetHighlighted(std::max(highlighted_ - 1, 0));
        return true;
    case VK_DOWN:
        SetHighlighted(std::min(highlighted_ + 1, std::max(static_cast<int>(rows_.size()) - 1, 0)));
        return true;
    case 'W':
        // The Mac's closeTab closes an open bar rather than the tab.
        if (ctrl && !shift) {
            Hide();
            return true;
        }
        break;
    default:
        break;
    }
    // Ctrl+T and the rest go on to the window's shortcuts.
    const std::optional<TextEditing::Change> change = line_.Edit().KeyDown(key, ctrl, shift);
    if (!change) return false;
    Apply(*change);
    return true;
}

void CommandBarView::Character(wchar_t c) { Apply(line_.Edit().Character(c)); }

void CommandBarView::ForwardKey(UINT key, bool ctrl, bool shift) {
    // Ctrl+T among them finds the bar open already, so it's dropped.
    if (open_) KeyDown(key, ctrl, shift);
}

void CommandBarView::ForwardCharacter(wchar_t character) {
    if (open_) Character(character);
}

void CommandBarView::SetHighlighted(int index) {
    if (index == highlighted_) return;
    highlighted_ = index;
    Invalidate();
}

void CommandBarView::Commit() {
    if (highlighted_ < 0 || static_cast<size_t>(highlighted_) >= rows_.size()) return;
    const CommandSuggestion row = rows_[static_cast<size_t>(highlighted_)];
    const CommandBarMode mode = mode_;
    // As the Mac: the bar closes first, then the row is acted on.
    Hide();
    if (callbacks_.commit) callbacks_.commit(row, mode);
}

// Geometry -------------------------------------------------------------------------------

D2D1_POINT_2F CommandBarView::PanelPoint(LPARAM clientPixels) const {
    const float x = static_cast<float>(GET_X_LPARAM(clientPixels) - geometry_.leftPx) / geometry_.scale;
    const float y = static_cast<float>(GET_Y_LPARAM(clientPixels) - geometry_.topPx) / geometry_.scale;
    return {x, y};
}

bool CommandBarView::InPanel(D2D1_POINT_2F p) const {
    return p.x >= 0 && p.x < geometry_.width && p.y >= 0 && p.y < PanelHeight();
}

bool CommandBarView::InField(D2D1_POINT_2F p) const {
    return p.x >= C::kTextX && p.x < geometry_.width - C::kIconX && p.y >= 0 && p.y < C::kFieldHeight;
}

int CommandBarView::RowAt(D2D1_POINT_2F p) const {
    const float top = C::kFieldHeight + 0.5f + C::kListTopGap;
    if (rows_.empty() || p.y < top || p.x < C::kRowInset || p.x >= geometry_.width - C::kRowInset) return -1;
    const auto index = static_cast<size_t>((p.y - top) / C::kRowPitch);
    return index < rows_.size() ? static_cast<int>(index) : -1;
}

float CommandBarView::TextTop() const {
    // Placed so the first line's baseline sits at 38.5.
    return C::kFieldBaseline - line_.Baseline();
}

size_t CommandBarView::TextIndexAt(float x) const { return line_.IndexAt(x - C::kTextX); }

void CommandBarView::KeepCaretVisible() { line_.KeepCaretVisible(); }

void CommandBarView::PlaceImeWindow() {
    if (!open_) return;
    const float scale = geometry_.scale;
    const POINT caret{geometry_.leftPx + std::lround((C::kTextX + line_.CaretX() - line_.ScrollX()) * scale),
                      geometry_.topPx + std::lround(TextTop() * scale)};
    // The composition in the field's own size.
    LOGFONTW font{};
    font.lfHeight = -std::lround(C::kFieldFontSize * scale);
    font.lfWeight = FW_MEDIUM;
    font.lfCharSet = DEFAULT_CHARSET;
    lstrcpynW(font.lfFaceName, system_font::GdiFaceName(), LF_FACESIZE);
    line_.PlaceIme(caret, std::lround(line_.LineHeight() * scale), &font);
}

void CommandBarView::RestartCaretBlink() {
    line_.RestartBlink(open_ && focused_);
    // With a draw on its way, the caret moves with the text it belongs to (Draw places it).
    if (!redrawPosted_) UpdateCaret();
}

void CommandBarView::Invalidate() {
    if (!open_ || redrawPosted_) return;
    redrawPosted_ = PostMessageW(window_, kRedrawMessage, 0, 0) != FALSE;
    if (!redrawPosted_) Draw();
}

void CommandBarView::UpdateCaret() {
    if (!visual_ || !composition_ || !context_) return;
    const Geometry& g = geometry_;
    const float x = C::kTextX - line_.ScrollX() + line_.CaretX();
    // Only in the window with the keyboard, not over a selection, and inside the field.
    const bool wanted = open_ && swapChain_ && focused_ && line_.CaretOn() && !line_.Edit().HasSelection() && x >= C::kTextX - 1 &&
                        x <= g.width - C::kIconX;
    const UINT width = static_cast<UINT>(std::max(1L, std::lround(g.scale)));  // 1pt
    const UINT height = static_cast<UINT>(std::max(1L, std::lround(line_.LineHeight() * g.scale)));
    // In the panel's buffer: centred on the caret's position, snapped to a pixel.
    const POINT at{g.marginPx + std::lround(x * g.scale) - static_cast<LONG>(width) / 2, g.marginPx + std::lround(TextTop() * g.scale)};
    if (const HRESULT hr = caret_.Update(composition_.Get(), context_.Get(), visual_.Get(), wanted, at, width, height, Primary()); FAILED(hr)) {
        deviceLost_ = deviceLost_ || IsDeviceLost(hr);
        return;
    }
    // The hidden system caret follows, in client pixels.
    if (wanted && focused_) SetCaretPos(g.leftPx + std::lround(x * g.scale), g.topPx + std::lround(TextTop() * g.scale));
    compositor_->Commit();
}

// Messages -------------------------------------------------------------------------------

bool CommandBarView::HandleMessage(UINT message, WPARAM wParam, LPARAM lParam, LRESULT& result) {
    result = 0;
    if (message == kRedrawMessage) {
        // Also after the bar closed, so a redraw that was on its way never leaves the flag set.
        redrawPosted_ = false;
        if (!open_) return true;
        // Drawn on restore instead: a minimized window's frame never comes (the latency wait).
        if (IsIconic(window_)) {
            drawOnRestore_ = true;
            return true;
        }
        if (std::wstring problem = Draw(); !problem.empty()) {
            // A bar that can't draw mustn't stay open unseen, holding the keyboard and clicks.
            OutputDebugStringW((L"Kite: the command bar couldn't draw, so it closed: " + problem + L"\n").c_str());
            Hide();
        }
        return true;
    }
    if (!open_) return false;
    switch (message) {
    case WM_KEYDOWN: {
        // AltGr is Ctrl+Alt: its characters come as WM_CHAR, never as a Ctrl shortcut.
        const bool alt = GetKeyState(VK_MENU) < 0;
        const bool ctrl = GetKeyState(VK_CONTROL) < 0 && !alt;
        const bool shift = GetKeyState(VK_SHIFT) < 0;
        return KeyDown(static_cast<UINT>(wParam), ctrl, shift);
    }
    case WM_CHAR:
        Character(static_cast<wchar_t>(wParam));
        return true;
    case WM_IME_STARTCOMPOSITION:
        composing_ = true;
        PlaceImeWindow();
        Invalidate();  // the placeholder goes, as NSTextField's does under marked text
        return false;  // Windows' composition window draws it; the result comes as WM_CHAR
    case WM_IME_ENDCOMPOSITION:
        composing_ = false;
        Invalidate();
        return false;
    case WM_SETFOCUS:
        focused_ = true;
        CreateCaret(window_, nullptr, 1, 1);
        Invalidate();  // the selection's colour
        RestartCaretBlink();
        return false;
    case WM_KILLFOCUS:
        focused_ = false;
        DestroyCaret();
        selecting_ = false;
        if (GetCapture() == window_) ReleaseCapture();
        RestartCaretBlink();
        Invalidate();
        return false;
    case WM_TIMER:
        if (!line_.HandleTimer(wParam)) return false;
        UpdateCaret();
        return true;
    case WM_SETCURSOR: {
        if (LOWORD(lParam) != HTCLIENT) return false;
        POINT cursor{};
        GetCursorPos(&cursor);
        ScreenToClient(window_, &cursor);
        const bool text = InField(PanelPoint(MAKELPARAM(cursor.x, cursor.y)));
        SetCursor(LoadCursorW(nullptr, text ? IDC_IBEAM : IDC_ARROW));
        result = TRUE;
        return true;
    }
    case WM_LBUTTONDOWN: {
        const D2D1_POINT_2F p = PanelPoint(lParam);
        pressed_ = kPressedNothing;
        if (!InPanel(p)) {
            pressed_ = kPressedOutside;
        } else if (InField(p)) {
            SetCapture(window_);
            selecting_ = true;
            Apply(line_.Edit().Select(TextIndexAt(p.x), (wParam & MK_SHIFT) != 0));
        } else if (const int row = RowAt(p); row >= 0) {
            pressed_ = row;
        }
        return true;
    }
    case WM_MOUSEMOVE: {
        const D2D1_POINT_2F p = PanelPoint(lParam);
        if (selecting_) {
            if (const size_t at = TextIndexAt(p.x); at != line_.Edit().Caret()) {
                Apply(line_.Edit().Select(at, true));
            }
            return true;
        }
        // The Mac's onHover: the highlight moves when the pointer enters a row, so the arrow
        // keys' choice stays while the pointer only moves within its row.
        const int row = RowAt(p);
        if (row != hoveredRow_) {
            hoveredRow_ = row;
            if (row >= 0) SetHighlighted(row);
        }
        return true;
    }
    case WM_LBUTTONUP: {
        if (GetCapture() == window_) ReleaseCapture();
        if (selecting_) {
            selecting_ = false;
            return true;
        }
        // As SwiftUI's tap gestures, on release over what was pressed.
        const D2D1_POINT_2F p = PanelPoint(lParam);
        const int pressed = pressed_;
        pressed_ = kPressedNothing;
        if (pressed == kPressedOutside && !InPanel(p)) {
            Hide();
        } else if (pressed >= 0 && RowAt(p) == pressed) {
            highlighted_ = pressed;
            Commit();
        }
        return true;
    }
    case WM_CAPTURECHANGED:
        selecting_ = false;
        return false;
    case WM_LBUTTONDBLCLK:
    case WM_RBUTTONDOWN:
    case WM_RBUTTONUP:
    case WM_MBUTTONDOWN:
    case WM_MBUTTONUP:
    case WM_MOUSEWHEEL:
        return true;  // nothing under the bar takes them while it's open
    default:
        return false;
    }
}

// Drawing --------------------------------------------------------------------------------

std::wstring CommandBarView::Draw(Pixels* readBack, POINT* origin) {
    redrawPosted_ = false;
    if (!open_) return {};
    if (!renderer_) return L"no renderer";
    if (deviceLost_) return L"the GPU device was lost";
    std::wstring error;
    if (!context_ && !CreateGpu(error)) return error;
    if (geometry_.width <= 0) ComputeGeometry();
    if (!EnsureBuffer(error)) return error;
    const float height = PanelHeight();
    if (!EnsureShadow(height, error)) return error;

    const Geometry& g = geometry_;
    const float margin = static_cast<float>(g.marginPx) / g.scale;
    // Wait for the frame queue to have room, so this frame is the next one shown; bounded.
    if (frameLatency_) WaitForSingleObjectEx(frameLatency_, 1000, FALSE);
    context_->SetTarget(backBuffer_.Get());
    context_->SetDpi(static_cast<float>(g.dpi), static_cast<float>(g.dpi));
    context_->BeginDraw();
    context_->Clear(Color(0, 0, 0, 0));
    context_->SetTransform(D2D1::Matrix3x2F::Identity());
    // The shadow: its horizontal falloff stretched down, times the vertical one (the layer's
    // opacity brush), outside the panel (the layer's mask).
    D2D1_LAYER_PARAMETERS1 shadowLayer{};
    shadowLayer.contentBounds = D2D1::InfiniteRect();
    shadowLayer.geometricMask = outsidePanel_.Get();
    shadowLayer.maskAntialiasMode = D2D1_ANTIALIAS_MODE_PER_PRIMITIVE;
    shadowLayer.maskTransform = D2D1::Matrix3x2F::Identity();
    shadowLayer.opacity = 1;
    shadowLayer.opacityBrush = shadowColumnBrush_.Get();
    shadowLayer.layerOptions = D2D1_LAYER_OPTIONS1_NONE;
    context_->PushLayer(shadowLayer, nullptr);
    context_->DrawBitmap(shadowRow_.Get(),
                         D2D1::RectF(0, 0, static_cast<float>(g.bufferWidth) / g.scale, static_cast<float>(g.bufferHeight) / g.scale), 1,
                         D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR, nullptr);
    context_->PopLayer();
    context_->SetTransform(D2D1::Matrix3x2F::Translation(margin, margin));
    DrawPanel(context_.Get(), height);
    DrawField(context_.Get());
    if (!rows_.empty()) {
        // The divider, inset 11.5 from each side, then the rows.
        brush_->SetColor(WithAlpha(Primary(), C::kDividerOpacity));
        context_->FillRectangle(D2D1::RectF(C::kDividerInset, C::kFieldHeight, g.width - C::kDividerInset, C::kFieldHeight + 0.5f),
                                brush_.Get());
        const float top = C::kFieldHeight + 0.5f + C::kListTopGap;
        for (size_t i = 0; i < rows_.size(); ++i) DrawRow(context_.Get(), i, top + static_cast<float>(i) * C::kRowPitch);
    }
    HRESULT hr = context_->EndDraw();
    if (FAILED(hr)) {
        deviceLost_ = IsDeviceLost(hr);
        return HResultMessage(L"drawing the command bar", hr);
    }
    if (readBack) {
        ComPtr<ID3D11Texture2D> texture;
        if (FAILED(hr = swapChain_->GetBuffer(0, IID_PPV_ARGS(texture.GetAddressOf())))) return HResultMessage(L"GetBuffer", hr);
        auto pixels = renderer_->ReadBack(texture.Get(), error);
        if (!pixels) return error;
        *readBack = std::move(*pixels);
        if (origin) *origin = {g.leftPx - g.marginPx, g.topPx - g.marginPx};
    }
    perf::CountSurfaceDraw(perf::View::CommandBar);
    perf::CountPresent();
    if (FAILED(hr = swapChain_->Present(1, 0))) {
        deviceLost_ = IsDeviceLost(hr);
        return HResultMessage(L"presenting the command bar", hr);
    }
    UpdateCaret();  // commits
    return {};
}

D2D1_COLOR_F CommandBarView::Primary() const { return look_.dark ? Color(1, 1, 1, 1) : Color(0, 0, 0, 1); }

// labelColor is white (dark) or black (light) at 0.85 alpha. Where the Mac takes it with
// withAlphaComponent (the subtitle, the placeholder, the arrow box) that alpha is replaced, not
// multiplied, so those use Primary with their own.
D2D1_COLOR_F CommandBarView::Label(float opacity) const { return WithAlpha(Primary(), kLabelAlpha * opacity); }

D2D1_COLOR_F CommandBarView::Accent() const { return Color(look_.accent.r, look_.accent.g, look_.accent.b, 1); }

void CommandBarView::DrawPanel(ID2D1DeviceContext* context, float height) {
    const float width = geometry_.width;
    const float grey = look_.dark ? kDarkPanelGrey : kLightPanelGrey;
    brush_->SetColor(Color(grey, grey, grey, kPanelAlpha));
    context->FillRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(0, 0, width, height), C::kCornerRadius, C::kCornerRadius), brush_.Get());
    // A 1pt border inside the edge: white at 22% (black at 12% on a light space).
    brush_->SetColor(look_.dark ? Color(1, 1, 1, C::kBorderOpacity) : Color(0, 0, 0, 0.12f));
    context->DrawRoundedRectangle(
        D2D1::RoundedRect(D2D1::RectF(0.5f, 0.5f, width - 0.5f, height - 0.5f), C::kCornerRadius - 0.5f, C::kCornerRadius - 0.5f),
        brush_.Get(), 1);
    // And a black hairline just outside it, which shows on light pages.
    const float o = C::kOutlineWidth / 2;
    brush_->SetColor(Color(0, 0, 0, 1));
    context->DrawRoundedRectangle(
        D2D1::RoundedRect(D2D1::RectF(-o, -o, width + o, height + o), C::kCornerRadius + o, C::kCornerRadius + o), brush_.Get(),
        C::kOutlineWidth);
}

void CommandBarView::DrawField(ID2D1DeviceContext* context) {
    const float width = geometry_.width;
    // Arc's magnifier: a ring and a short handle at 45°, in the 18pt icon frame.
    const float iconTop = (C::kFieldHeight - C::kIconSize) / 2;
    const D2D1_POINT_2F center{C::kIconX + C::kMagnifierCenter.x, iconTop + C::kMagnifierCenter.y};
    const float diagonal = std::sqrt(0.5f);
    brush_->SetColor(Primary());
    context->DrawEllipse(D2D1::Ellipse(center, C::kMagnifierRadius, C::kMagnifierRadius), brush_.Get(), C::kMagnifierStroke,
                         roundStroke_.Get());
    context->DrawLine(D2D1::Point2F(center.x + C::kMagnifierRadius * diagonal, center.y + C::kMagnifierRadius * diagonal),
                      D2D1::Point2F(center.x + C::kMagnifierHandleEnd * diagonal, center.y + C::kMagnifierHandleEnd * diagonal),
                      brush_.Get(), C::kMagnifierStroke, roundStroke_.Get());

    const float top = TextTop();
    const D2D1_POINT_2F origin{C::kTextX - line_.ScrollX(), top};
    context->PushAxisAlignedClip(D2D1::RectF(C::kTextX - 1, 0, width - C::kIconX, C::kFieldHeight), D2D1_ANTIALIAS_MODE_ALIASED);
    if (line_.Edit().Text().empty()) {
        // Not under an IME's composition, which Windows draws over the field at the caret.
        brush_->SetColor(WithAlpha(Primary(), C::kPlaceholderOpacity));
        if (placeholderLayout_ && !composing_) context->DrawTextLayout(origin, placeholderLayout_.Get(), brush_.Get());
    } else if (IDWriteTextLayout* layout = line_.Layout()) {
        // Grey when the window isn't the one in front, as on the Mac.
        const D2D1_COLOR_F selection = look_.dark ? kDarkSelection : kLightSelection;
        line_.DrawSelection(context, brush_.Get(), origin, origin.y, origin.y + line_.LineHeight(),
                            focused_ ? selection : WithAlpha(Primary(), 0.15f));
        brush_->SetColor(Label());  // CommandBar.swift:533, textColor = .labelColor
        context->DrawTextLayout(origin, layout, brush_.Get());
    }
    // The caret is its own visual (UpdateCaret).
    context->PopAxisAlignedClip();
}

void CommandBarView::Glyph(ID2D1DeviceContext* context, wchar_t glyph, float size, D2D1_RECT_F box, D2D1_COLOR_F color) {
    IDWriteTextFormat* format = size == C::kRowIconSize ? iconFormat_.Get() : arrowFormat_.Get();
    if (!format) return;
    brush_->SetColor(color);
    context->DrawText(&glyph, 1, format, box, brush_.Get(), D2D1_DRAW_TEXT_OPTIONS_NONE);
}

void CommandBarView::DrawRow(ID2D1DeviceContext* context, size_t index, float top) {
    const CommandSuggestion& row = rows_[index];
    const bool highlighted = static_cast<int>(index) == highlighted_;
    const D2D1_COLOR_F white = Color(1, 1, 1, 1);
    const D2D1_COLOR_F accent = Accent();
    const D2D1_RECT_F fill{C::kRowInset + C::kRowFillInset, top + C::kRowFillInset, geometry_.width - C::kRowInset - C::kRowFillInset,
                           top + C::kRowFillInset + C::kRowFillHeight};
    if (highlighted) {
        brush_->SetColor(accent);
        context->FillRoundedRectangle(D2D1::RoundedRect(fill, C::kRowCornerRadius, C::kRowCornerRadius), brush_.Get());
    }

    // The icon in its 24pt tile: white with the icon in the accent when highlighted.
    const float tileLeft = fill.left + C::kRowIconX;
    const float tileTop = fill.top + (C::kRowFillHeight - C::kRowIconTileSize) / 2;
    const D2D1_RECT_F tile{tileLeft, tileTop, tileLeft + C::kRowIconTileSize, tileTop + C::kRowIconTileSize};
    if (highlighted) {
        brush_->SetColor(white);
        context->FillRoundedRectangle(D2D1::RoundedRect(tile, 6, 6), brush_.Get());
    }
    wchar_t icon = kGlobeGlyph;
    float iconOpacity = 1;
    switch (row.kind) {
    case CommandSuggestion::Kind::Open: icon = kGlobeGlyph; break;
    case CommandSuggestion::Kind::Search: icon = kSearchGlyph; break;
    case CommandSuggestion::Kind::SwitchTab:
    case CommandSuggestion::Kind::History:
        // The bar's favicons come later (the sidebar's are W4's); until then the Mac's
        // no-favicon globe, for a tab and for a page from history (FaviconView.show(page:)).
        icon = kGlobeGlyph;
        iconOpacity = kNoFaviconOpacity;
        break;
    }
    // CommandBar.swift:820 (the symbol's tint) and SidebarKit.swift:269 (the favicon's globe):
    // labelColor, at the globe's 60%.
    Glyph(context, icon, C::kRowIconSize, tile, highlighted ? WithAlpha(accent, iconOpacity) : Label(iconOpacity));

    // The arrow in its 24pt box, 13pt from the fill's right.
    const float boxRight = fill.right - C::kActionBoxTrailing;
    const float boxTop = fill.top + (C::kRowFillHeight - C::kActionBoxSize) / 2;
    const D2D1_RECT_F box{boxRight - C::kActionBoxSize, boxTop, boxRight, boxTop + C::kActionBoxSize};
    const float boxOpacity = highlighted ? 1 : 0.7f;
    brush_->SetColor(highlighted ? white : WithAlpha(Primary(), 0.06f * boxOpacity));
    context->FillRoundedRectangle(D2D1::RoundedRect(box, 6, 6), brush_.Get());
    Glyph(context, kArrowGlyph, 13, box, highlighted ? accent : Label(boxOpacity));  // CommandBar.swift:821, 823

    if (index >= rowText_.size()) return;
    const RowText& text = rowText_[index];
    if (text.detail) {
        const float right = box.left - C::kActionGap;
        brush_->SetColor(highlighted ? WithAlpha(white, 0.8f) : Label(C::kRowDetailOpacity));  // CommandBar.swift:836-837
        context->DrawTextLayout(D2D1::Point2F(right - text.detailWidth, fill.top), text.detail.Get(), brush_.Get());
    }
    if (text.title) {
        brush_->SetColor(highlighted ? white : Label(C::kRowTextOpacity));  // CommandBar.swift:826, 833
        context->DrawTextLayout(D2D1::Point2F(fill.left + C::kRowTitleX, fill.top), text.title.Get(), brush_.Get(),
                                D2D1_DRAW_TEXT_OPTIONS_CLIP);
    }
    if (text.subtitle) {
        // The Mac's dim part: white at 0.7 on the accent, else the label colour at 0.5, both
        // under the title's own 0.8 when not highlighted.
        // CommandBar.swift:829, 833: labelColor.withAlphaComponent(0.5) (replacing its 0.85), under
        // the title's 0.8.
        brush_->SetColor(highlighted ? WithAlpha(white, 0.7f) : WithAlpha(Primary(), 0.5f * C::kRowTextOpacity));
        context->DrawTextLayout(D2D1::Point2F(fill.left + C::kRowTitleX + text.titleWidth, fill.top), text.subtitle.Get(), brush_.Get(),
                                D2D1_DRAW_TEXT_OPTIONS_CLIP);
    }
}

}  // namespace kite
