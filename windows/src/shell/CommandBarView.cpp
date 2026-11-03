// See CommandBarView.h.

#include "shell/CommandBarView.h"

#include <imm.h>
#include <windowsx.h>

#include <algorithm>
#include <cmath>

#include "core/Unicode.h"
#include "shell/Errors.h"

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
// 100pt away) is a Gaussian of 30pt at 50% black, 16pt down.
constexpr float kShadowBlur = 30;
constexpr float kShadowOpacity = 0.5f;
constexpr float kShadowY = 16;
constexpr float kShadowMargin = 112;  // room for it around the panel: 3σ and the offset
// Open, five tabs, search: the most rows CommandBarSuggestions makes.
constexpr size_t kMaxRows = 7;
// The Mac's default text selection colours (NSColor.selectedTextBackgroundColor), not
// checked against Arc's bar.
constexpr D2D1_COLOR_F kDarkSelection{63 / 255.0f, 99 / 255.0f, 139 / 255.0f, 1};
constexpr D2D1_COLOR_F kLightSelection{179 / 255.0f, 215 / 255.0f, 1, 1};
constexpr UINT_PTR kCaretTimer = 0x4B42;  // 'KB'; Chromium's close deadline is 0x4B43

// Segoe Fluent Icons (Windows 11) and Segoe MDL2 Assets (Windows 10) share these code points:
// the counterparts of the Mac's SF Symbols globe, magnifyingglass and arrow.right.
constexpr wchar_t kGlobeGlyph = 0xE774;
constexpr wchar_t kSearchGlyph = 0xE721;
constexpr wchar_t kArrowGlyph = 0xE72A;
// The Mac's FaviconView with no favicon yet: the globe at 60%.
constexpr float kNoFaviconOpacity = 0.6f;

// Direct2D's built-in shadow effect (d2d1effects.h's CLSID_D2D1Shadow), defined here so Kite
// needn't link dxguid; its properties are the blur's standard deviation and the colour.
constexpr CLSID kShadowEffect = {0xC67EA361, 0x1863, 0x4E69, {0x89, 0xDB, 0x69, 0x5D, 0x3E, 0x9A, 0x5B, 0x6B}};
constexpr UINT32 kShadowStandardDeviation = 0;  // D2D1_SHADOW_PROP_BLUR_STANDARD_DEVIATION
constexpr UINT32 kShadowColor = 1;              // D2D1_SHADOW_PROP_COLOR

bool IsDeviceLost(HRESULT hr) {
    return hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET || hr == static_cast<HRESULT>(D2DERR_RECREATE_TARGET);
}

std::wstring Widen(std::string_view utf8) {
    if (utf8.empty()) return {};
    const int size = MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
    std::wstring out(static_cast<size_t>(std::max(size, 0)), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), out.data(), size);
    return out;
}

std::string Narrow(std::wstring_view text) {
    if (text.empty()) return {};
    const int size = WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    std::string out(static_cast<size_t>(std::max(size, 0)), '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), out.data(), size, nullptr, nullptr);
    return out;
}

bool IsHighSurrogate(wchar_t c) { return c >= 0xD800 && c < 0xDC00; }
bool IsLowSurrogate(wchar_t c) { return c >= 0xDC00 && c < 0xE000; }

char32_t CodePointAt(const std::wstring& text, size_t at) {
    const wchar_t c = text[at];
    if (IsHighSurrogate(c) && at + 1 < text.size() && IsLowSurrogate(text[at + 1])) {
        return 0x10000 + ((static_cast<char32_t>(c) - 0xD800) << 10) + (static_cast<char32_t>(text[at + 1]) - 0xDC00);
    }
    return c;
}

// Where characters (grapheme clusters, as the core's matching and Swift count them) start,
// per UTF-16 unit, plus one past the end: the caret only ever sits between characters.
std::vector<bool> Utf16CharacterStarts(const std::wstring& text) {
    std::u32string codePoints;
    std::vector<size_t> offsets;
    for (size_t i = 0; i < text.size();) {
        const char32_t c = CodePointAt(text, i);
        codePoints.push_back(c);
        offsets.push_back(i);
        i += c > 0xFFFF ? 2 : 1;
    }
    const std::vector<bool> starts = unicode::CharacterStarts(codePoints);
    std::vector<bool> out(text.size() + 1, false);
    for (size_t k = 0; k < codePoints.size(); ++k) {
        if (starts[k]) out[offsets[k]] = true;
    }
    out[text.size()] = true;
    return out;
}

// Ctrl+Left and Ctrl+Right stop between runs of these, as in Windows' own text boxes.
enum class WordClass { Space, Word, Other };
WordClass Classify(char32_t c) {
    if (c == ' ' || c == '\t' || c == 0xA0 || c == 0x3000 || (c >= 0x2000 && c <= 0x200A)) return WordClass::Space;
    if (unicode::IsLetter(c) || unicode::IsNumber(c) || c == '_') return WordClass::Word;
    return WordClass::Other;
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
    // The system UI font, as the Mac's bar uses its own (SF Pro): Segoe UI Variable on Windows
    // 11, Segoe UI before it. Medium, as the Mac's field and rows.
    ComPtr<IDWriteFontCollection> fonts;
    view->dwrite_->GetSystemFontCollection(fonts.GetAddressOf());
    auto installed = [&](const wchar_t* family) {
        UINT32 index = 0;
        BOOL exists = FALSE;
        return fonts && SUCCEEDED(fonts->FindFamilyName(family, &index, &exists)) && exists;
    };
    view->textFamily_ = installed(L"Segoe UI Variable Text") ? L"Segoe UI Variable Text" : L"Segoe UI";
    const wchar_t* iconFamily = installed(L"Segoe Fluent Icons") ? L"Segoe Fluent Icons" : L"Segoe MDL2 Assets";
    auto format = [&](const wchar_t* family, float size, ComPtr<IDWriteTextFormat>& out) {
        HRESULT made = view->dwrite_->CreateTextFormat(family, nullptr, DWRITE_FONT_WEIGHT_MEDIUM, DWRITE_FONT_STYLE_NORMAL,
                                                       DWRITE_FONT_STRETCH_NORMAL, size, L"", out.GetAddressOf());
        if (SUCCEEDED(made)) made = out->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        return made;
    };
    const wchar_t* text = view->textFamily_.c_str();
    if (FAILED(hr = format(text, C::kFieldFontSize, view->fieldFormat_)) || FAILED(hr = format(text, C::kRowFontSize, view->rowFormat_)) ||
        FAILED(hr = format(text, C::kRowFontSize, view->rowEllipsisFormat_)) ||
        FAILED(hr = format(iconFamily, C::kRowIconSize, view->iconFormat_)) || FAILED(hr = format(iconFamily, 13, view->arrowFormat_))) {
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
    return view;
}

CommandBarView::~CommandBarView() {
    if (open_) KillTimer(window_, kCaretTimer);
    ReleaseGpu();
}

void CommandBarView::UseRenderer(Renderer* renderer) {
    ReleaseGpu();
    renderer_ = renderer;
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
    // topmost TRUE: over the page's child window (the backdrop's target is behind it).
    if (FAILED(hr = DCompositionCreateDevice(dxgi.Get(), IID_PPV_ARGS(composition_.ReleaseAndGetAddressOf()))) ||
        FAILED(hr = composition_->CreateTargetForHwnd(window_, TRUE, target_.ReleaseAndGetAddressOf())) ||
        FAILED(hr = composition_->CreateVisual(visual_.ReleaseAndGetAddressOf())) || FAILED(hr = target_->SetRoot(visual_.Get())) ||
        FAILED(hr = composition_->Commit())) {
        error = HResultMessage(L"building the command bar's composition tree", hr);
        ReleaseGpu();
        return false;
    }
    return true;
}

void CommandBarView::ReleaseGpu() {
    if (context_) context_->SetTarget(nullptr);
    backBuffer_.Reset();
    shadow_.Reset();
    shadowHeight_ = shadowWidth_ = -1;
    shadowDpi_ = 0;
    swapChain_.Reset();
    if (target_) {
        target_->SetRoot(nullptr);
        composition_->Commit();
    }
    visual_.Reset();
    target_.Reset();
    composition_.Reset();
    brush_.Reset();
    context_.Reset();
    d2dDevice_.Reset();
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
        desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
        desc.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;
        if (SUCCEEDED(hr)) hr = factory->CreateSwapChainForComposition(renderer_->Device(), &desc, nullptr, swapChain_.GetAddressOf());
        if (SUCCEEDED(hr)) hr = visual_->SetContent(swapChain_.Get());
        if (FAILED(hr)) {
            deviceLost_ = IsDeviceLost(hr);
            swapChain_.Reset();
            error = HResultMessage(L"creating the command bar's swap chain", hr);
            return false;
        }
    } else if (desc.Width != g.bufferWidth || desc.Height != g.bufferHeight) {
        context_->SetTarget(nullptr);
        backBuffer_.Reset();
        renderer_->Flush();
        if (FAILED(hr = swapChain_->ResizeBuffers(0, g.bufferWidth, g.bufferHeight, DXGI_FORMAT_UNKNOWN, 0))) {
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
    if (shadow_ && shadowHeight_ == height && shadowWidth_ == g.width && shadowDpi_ == g.dpi) return true;
    shadow_.Reset();
    const D2D1_BITMAP_PROPERTIES1 props =
        D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_TARGET, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
                                static_cast<float>(g.dpi), static_cast<float>(g.dpi));
    const D2D1_SIZE_U size{g.bufferWidth, g.bufferHeight};
    const float margin = static_cast<float>(g.marginPx) / g.scale;
    const D2D1_ROUNDED_RECT panel{{margin, margin, margin + g.width, margin + height}, C::kCornerRadius, C::kCornerRadius};

    // The panel's shape in black, blurred into its shadow, kept only outside the panel: the
    // panel isn't opaque, and on the Mac the shadow never shows through it.
    ComPtr<ID2D1Bitmap1> shape, cache;
    ComPtr<ID2D1Effect> effect;
    ComPtr<ID2D1RectangleGeometry> everything;
    ComPtr<ID2D1RoundedRectangleGeometry> inside;
    ComPtr<ID2D1PathGeometry> outside;
    ComPtr<ID2D1GeometrySink> sink;
    HRESULT hr = context_->CreateBitmap(size, nullptr, 0, &props, shape.GetAddressOf());
    if (SUCCEEDED(hr)) hr = context_->CreateBitmap(size, nullptr, 0, &props, cache.GetAddressOf());
    if (SUCCEEDED(hr)) hr = context_->CreateEffect(kShadowEffect, effect.GetAddressOf());
    if (SUCCEEDED(hr)) {
        hr = d2dFactory_->CreateRectangleGeometry(
            D2D1::RectF(0, 0, static_cast<float>(g.bufferWidth) / g.scale, static_cast<float>(g.bufferHeight) / g.scale),
            everything.GetAddressOf());
    }
    if (SUCCEEDED(hr)) hr = d2dFactory_->CreateRoundedRectangleGeometry(panel, inside.GetAddressOf());
    if (SUCCEEDED(hr)) hr = d2dFactory_->CreatePathGeometry(outside.GetAddressOf());
    if (SUCCEEDED(hr)) hr = outside->Open(sink.GetAddressOf());
    if (SUCCEEDED(hr)) hr = everything->CombineWithGeometry(inside.Get(), D2D1_COMBINE_MODE_EXCLUDE, nullptr, sink.Get());
    if (SUCCEEDED(hr)) hr = sink->Close();
    if (FAILED(hr)) {
        deviceLost_ = IsDeviceLost(hr);
        error = HResultMessage(L"making the command bar's shadow", hr);
        return false;
    }
    context_->SetTarget(shape.Get());
    context_->SetDpi(static_cast<float>(g.dpi), static_cast<float>(g.dpi));
    context_->BeginDraw();
    context_->Clear(Color(0, 0, 0, 0));
    context_->SetTransform(D2D1::Matrix3x2F::Identity());
    brush_->SetColor(Color(0, 0, 0, 1));
    context_->FillRoundedRectangle(panel, brush_.Get());
    hr = context_->EndDraw();
    if (SUCCEEDED(hr)) {
        effect->SetInput(0, shape.Get());
        const float deviation = kShadowBlur;
        const D2D1_VECTOR_4F color{0, 0, 0, kShadowOpacity};
        effect->SetValue(kShadowStandardDeviation, D2D1_PROPERTY_TYPE_FLOAT, reinterpret_cast<const BYTE*>(&deviation), sizeof(deviation));
        effect->SetValue(kShadowColor, D2D1_PROPERTY_TYPE_VECTOR4, reinterpret_cast<const BYTE*>(&color), sizeof(color));
        context_->SetTarget(cache.Get());
        context_->BeginDraw();
        context_->Clear(Color(0, 0, 0, 0));
        context_->PushLayer(D2D1::LayerParameters1(D2D1::InfiniteRect(), outside.Get()), nullptr);
        context_->DrawImage(effect.Get(), D2D1::Point2F(0, kShadowY));
        context_->PopLayer();
        hr = context_->EndDraw();
    }
    context_->SetTarget(nullptr);
    if (FAILED(hr)) {
        deviceLost_ = IsDeviceLost(hr);
        error = HResultMessage(L"drawing the command bar's shadow", hr);
        return false;
    }
    shadow_ = std::move(cache);
    shadowHeight_ = height;
    shadowWidth_ = g.width;
    shadowDpi_ = g.dpi;
    return true;
}

void CommandBarView::Show(CommandBarMode mode, const std::string& text, const Look& look) {
    look_ = look;
    mode_ = mode;
    if (open_) {
        // Ctrl+T on an open bar: the mode changes, what's typed stays (the Mac keeps the
        // view's state), and the field keeps the keyboard.
        SetFocus(window_);
        rows_.clear();
        TextChanged();
        return;
    }
    open_ = true;
    highlighted_ = 0;
    scrollX_ = 0;
    selecting_ = false;
    pressed_ = kPressedNothing;
    highSurrogate_ = 0;
    if (callbacks_.opened) callbacks_.opened();
    SetFocus(window_);
    focused_ = GetFocus() == window_;
    ComputeGeometry();
    std::wstring wide = Widen(text);
    const size_t end = wide.size();
    // All selected, as an NSTextField's text when it takes focus.
    SetText(std::move(wide), end, 0);
}

void CommandBarView::Hide() {
    if (!open_) return;
    open_ = false;
    KillTimer(window_, kCaretTimer);
    if (GetCapture() == window_) ReleaseCapture();
    selecting_ = false;
    // Its buffers go until it opens again; the device and target stay.
    if (context_) context_->SetTarget(nullptr);
    backBuffer_.Reset();
    shadow_.Reset();
    shadowHeight_ = -1;
    if (visual_) {
        visual_->SetContent(nullptr);
        composition_->Commit();
    }
    swapChain_.Reset();
    text_.clear();
    characterStarts_.assign(1, true);
    caret_ = anchor_ = 0;
    textLayout_.Reset();
    rows_.clear();
    rowText_.clear();
    if (callbacks_.closed) callbacks_.closed();
}

void CommandBarView::Layout() {
    if (!open_) return;
    ComputeGeometry();
    KeepCaretVisible();
    Draw();
}

void CommandBarView::Refresh() {
    if (!open_) return;
    SetRows(callbacks_.suggestions ? callbacks_.suggestions(Narrow(text_), mode_) : std::vector<CommandSuggestion>{});
    highlighted_ = std::clamp(highlighted_, 0, std::max(static_cast<int>(rows_.size()) - 1, 0));
    Draw();
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
        dwrite_->CreateTextLayout(title.c_str(), static_cast<UINT32>(title.size()), rowEllipsisFormat_.Get(),
                                  std::max(titleRight - C::kRowTitleX, 1.0f), C::kRowFillHeight, text.title.GetAddressOf());
        rowText_.push_back(std::move(text));
    }
}

// Text editing ---------------------------------------------------------------------------

void CommandBarView::SetText(std::wstring text, size_t caret, size_t anchor) {
    text_ = std::move(text);
    caret_ = std::min(caret, text_.size());
    anchor_ = std::min(anchor, text_.size());
    TextChanged();
}

void CommandBarView::TextChanged() {
    characterStarts_ = Utf16CharacterStarts(text_);
    textLayout_.Reset();
    dwrite_->CreateTextLayout(text_.c_str(), static_cast<UINT32>(text_.size()), fieldFormat_.Get(), 100000, C::kFieldHeight,
                              textLayout_.GetAddressOf());
    // As the Mac's onChange(of: query): the rows again, the first highlighted.
    highlighted_ = 0;
    SetRows(callbacks_.suggestions ? callbacks_.suggestions(Narrow(text_), mode_) : std::vector<CommandSuggestion>{});
    KeepCaretVisible();
    RestartCaretBlink();
    PlaceImeWindow();
    Draw();
}

void CommandBarView::SelectionChanged() {
    KeepCaretVisible();
    RestartCaretBlink();
    PlaceImeWindow();
    Draw();
}

void CommandBarView::Insert(std::wstring_view text) {
    const size_t start = SelectionStart();
    text_.replace(start, SelectionEnd() - start, text);
    caret_ = anchor_ = start + text.size();
    TextChanged();
}

void CommandBarView::DeleteRange(size_t from, size_t to) {
    if (from >= to) return;
    text_.erase(from, to - from);
    caret_ = anchor_ = from;
    TextChanged();
}

size_t CommandBarView::PreviousCharacter(size_t at) const {
    while (at > 0) {
        if (characterStarts_[--at]) return at;
    }
    return 0;
}

size_t CommandBarView::NextCharacter(size_t at) const {
    while (at < text_.size()) {
        if (characterStarts_[++at]) return at;
    }
    return text_.size();
}

size_t CommandBarView::PreviousWord(size_t at) const {
    while (at > 0 && Classify(CodePointAt(text_, PreviousCharacter(at))) == WordClass::Space) at = PreviousCharacter(at);
    if (at == 0) return 0;
    const WordClass run = Classify(CodePointAt(text_, PreviousCharacter(at)));
    while (at > 0 && Classify(CodePointAt(text_, PreviousCharacter(at))) == run) at = PreviousCharacter(at);
    return at;
}

size_t CommandBarView::NextWord(size_t at) const {
    if (at < text_.size()) {
        const WordClass run = Classify(CodePointAt(text_, at));
        if (run != WordClass::Space) {
            while (at < text_.size() && Classify(CodePointAt(text_, at)) == run) at = NextCharacter(at);
        }
    }
    while (at < text_.size() && Classify(CodePointAt(text_, at)) == WordClass::Space) at = NextCharacter(at);
    return at;
}

void CommandBarView::Copy() const {
    if (!HasSelection() || !OpenClipboard(window_)) return;
    const std::wstring selected = text_.substr(SelectionStart(), SelectionEnd() - SelectionStart());
    EmptyClipboard();
    if (HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, (selected.size() + 1) * sizeof(wchar_t))) {
        if (auto* out = static_cast<wchar_t*>(GlobalLock(memory))) {
            std::copy(selected.begin(), selected.end(), out);
            out[selected.size()] = L'\0';
            GlobalUnlock(memory);
            if (!SetClipboardData(CF_UNICODETEXT, memory)) GlobalFree(memory);
        } else {
            GlobalFree(memory);
        }
    }
    CloseClipboard();
}

void CommandBarView::Paste() {
    if (!OpenClipboard(window_)) return;
    std::wstring pasted;
    if (HANDLE data = GetClipboardData(CF_UNICODETEXT)) {
        if (const auto* text = static_cast<const wchar_t*>(GlobalLock(data))) {
            pasted = text;
            GlobalUnlock(data);
        }
    }
    CloseClipboard();
    // One line: each line break (CR LF, CR or LF) and other control character becomes a space.
    std::wstring line;
    line.reserve(pasted.size());
    for (size_t i = 0; i < pasted.size(); ++i) {
        const wchar_t c = pasted[i];
        if (c == L'\r' && i + 1 < pasted.size() && pasted[i + 1] == L'\n') continue;
        line.push_back(c < 0x20 || c == 0x7F ? L' ' : c);
    }
    if (!line.empty()) Insert(line);
}

bool CommandBarView::KeyDown(UINT key, bool ctrl, bool shift) {
    const size_t end = text_.size();
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
    case VK_LEFT:
    case VK_RIGHT:
    case VK_HOME:
    case VK_END: {
        size_t to = caret_;
        if (key == VK_HOME) to = 0;
        else if (key == VK_END) to = end;
        else if (HasSelection() && !shift && !ctrl) to = key == VK_LEFT ? SelectionStart() : SelectionEnd();
        else if (key == VK_LEFT) to = ctrl ? PreviousWord(caret_) : PreviousCharacter(caret_);
        else to = ctrl ? NextWord(caret_) : NextCharacter(caret_);
        caret_ = to;
        if (!shift) anchor_ = to;
        SelectionChanged();
        return true;
    }
    case VK_BACK:
        if (HasSelection()) DeleteRange(SelectionStart(), SelectionEnd());
        else if (caret_ > 0) DeleteRange(ctrl ? PreviousWord(caret_) : PreviousCharacter(caret_), caret_);
        return true;
    case VK_DELETE:
        if (shift && !ctrl) {  // Shift+Delete: cut
            Copy();
            DeleteRange(SelectionStart(), SelectionEnd());
        } else if (HasSelection()) {
            DeleteRange(SelectionStart(), SelectionEnd());
        } else if (caret_ < end) {
            DeleteRange(caret_, ctrl ? NextWord(caret_) : NextCharacter(caret_));
        }
        return true;
    case VK_INSERT:
        if (ctrl && !shift) Copy();
        else if (shift && !ctrl) Paste();
        return true;
    default:
        break;
    }
    if (!ctrl || shift) return false;
    switch (key) {
    case 'A':
        anchor_ = 0;
        caret_ = end;
        SelectionChanged();
        return true;
    case 'C':
        Copy();
        return true;
    case 'X':
        Copy();
        DeleteRange(SelectionStart(), SelectionEnd());
        return true;
    case 'V':
        Paste();
        return true;
    case 'W':  // the Mac's closeTab closes an open bar rather than the tab
        Hide();
        return true;
    default:
        return false;  // Ctrl+T and the rest go on to the window's shortcuts
    }
}

void CommandBarView::Character(wchar_t c) {
    if (IsHighSurrogate(c)) {
        highSurrogate_ = c;
        return;
    }
    if (IsLowSurrogate(c)) {
        if (!highSurrogate_) return;
        const wchar_t pair[2] = {highSurrogate_, c};
        highSurrogate_ = 0;
        Insert(std::wstring_view(pair, 2));
        return;
    }
    highSurrogate_ = 0;
    // Control characters (Ctrl+A's 0x01, Backspace's 0x08, Enter's 0x0D, Ctrl+Backspace's
    // 0x7F) are the keys KeyDown already handled.
    if (c < 0x20 || c == 0x7F) return;
    Insert(std::wstring_view(&c, 1));
}

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
    Draw();
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
    DWRITE_LINE_METRICS line{};
    UINT32 count = 0;
    IDWriteTextLayout* layout = textLayout_ ? textLayout_.Get() : placeholderLayout_.Get();
    if (layout) layout->GetLineMetrics(&line, 1, &count);
    return C::kFieldBaseline - line.baseline;
}

float CommandBarView::LineHeight() const {
    DWRITE_LINE_METRICS line{};
    UINT32 count = 0;
    IDWriteTextLayout* layout = textLayout_ ? textLayout_.Get() : placeholderLayout_.Get();
    if (layout) layout->GetLineMetrics(&line, 1, &count);
    return line.height;
}

size_t CommandBarView::TextIndexAt(float x) const {
    if (!textLayout_ || text_.empty()) return 0;
    BOOL trailing = FALSE, inside = FALSE;
    DWRITE_HIT_TEST_METRICS hit{};
    textLayout_->HitTestPoint(x - C::kTextX + scrollX_, 0, &trailing, &inside, &hit);
    size_t index = std::min<size_t>(hit.textPosition + (trailing ? hit.length : 0), text_.size());
    while (index > 0 && !characterStarts_[index]) --index;
    return index;
}

float CommandBarView::CaretX() const {
    if (!textLayout_) return 0;
    FLOAT x = 0, y = 0;
    DWRITE_HIT_TEST_METRICS hit{};
    textLayout_->HitTestTextPosition(static_cast<UINT32>(caret_), FALSE, &x, &y, &hit);
    return x;
}

void CommandBarView::KeepCaretVisible() {
    const float visible = std::max(geometry_.width - C::kIconX - C::kTextX, 1.0f);
    DWRITE_TEXT_METRICS metrics{};
    if (textLayout_) textLayout_->GetMetrics(&metrics);
    const float x = CaretX();
    if (x - scrollX_ > visible) scrollX_ = x - visible;
    if (x - scrollX_ < 0) scrollX_ = x;
    // Never scrolled past the text's end, once it's shorter again.
    scrollX_ = std::clamp(scrollX_, 0.0f, std::max(metrics.widthIncludingTrailingWhitespace + 1 - visible, 0.0f));
}

void CommandBarView::PlaceImeWindow() {
    if (!open_) return;
    HIMC context = ImmGetContext(window_);
    if (!context) return;
    const float scale = geometry_.scale;
    const POINT caret{geometry_.leftPx + std::lround((C::kTextX + CaretX() - scrollX_) * scale),
                      geometry_.topPx + std::lround(TextTop() * scale)};
    COMPOSITIONFORM composition{};
    composition.dwStyle = CFS_POINT;
    composition.ptCurrentPos = caret;
    ImmSetCompositionWindow(context, &composition);
    CANDIDATEFORM candidates{};
    candidates.dwIndex = 0;
    candidates.dwStyle = CFS_CANDIDATEPOS;
    candidates.ptCurrentPos = {caret.x, caret.y + std::lround(LineHeight() * scale)};
    ImmSetCandidateWindow(context, &candidates);
    // The composition in the field's own size.
    LOGFONTW font{};
    font.lfHeight = -std::lround(C::kFieldFontSize * scale);
    font.lfWeight = FW_MEDIUM;
    font.lfCharSet = DEFAULT_CHARSET;
    lstrcpynW(font.lfFaceName, textFamily_.c_str(), LF_FACESIZE);
    ImmSetCompositionFontW(context, &font);
    ImmReleaseContext(window_, context);
}

void CommandBarView::RestartCaretBlink() {
    caretOn_ = true;
    const UINT blink = GetCaretBlinkTime();
    // INFINITE: the user turned blinking off.
    if (open_ && focused_ && blink && blink != INFINITE) SetTimer(window_, kCaretTimer, blink, nullptr);
    else KillTimer(window_, kCaretTimer);
}

// Messages -------------------------------------------------------------------------------

bool CommandBarView::HandleMessage(UINT message, WPARAM wParam, LPARAM lParam, LRESULT& result) {
    if (!open_) return false;
    result = 0;
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
    case WM_IME_COMPOSITION:
        PlaceImeWindow();
        return false;  // Windows' composition window draws it; the result comes as WM_CHAR
    case WM_SETFOCUS:
        focused_ = true;
        RestartCaretBlink();
        Draw();
        return false;
    case WM_KILLFOCUS:
        focused_ = false;
        selecting_ = false;
        RestartCaretBlink();
        Draw();
        return false;
    case WM_TIMER:
        if (wParam != kCaretTimer) return false;
        caretOn_ = !caretOn_;
        Draw();
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
            caret_ = TextIndexAt(p.x);
            if (!(wParam & MK_SHIFT)) anchor_ = caret_;
            SelectionChanged();
        } else if (const int row = RowAt(p); row >= 0) {
            pressed_ = row;
        }
        return true;
    }
    case WM_MOUSEMOVE: {
        const D2D1_POINT_2F p = PanelPoint(lParam);
        if (selecting_) {
            if (const size_t at = TextIndexAt(p.x); at != caret_) {
                caret_ = at;
                SelectionChanged();
            }
        } else if (const int row = RowAt(p); row >= 0) {
            SetHighlighted(row);  // the Mac's onHover
        }
        return true;
    }
    case WM_LBUTTONUP: {
        if (selecting_) {
            selecting_ = false;
            ReleaseCapture();
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
    context_->SetTarget(backBuffer_.Get());
    context_->SetDpi(static_cast<float>(g.dpi), static_cast<float>(g.dpi));
    context_->BeginDraw();
    context_->Clear(Color(0, 0, 0, 0));
    context_->SetTransform(D2D1::Matrix3x2F::Identity());
    context_->DrawImage(shadow_.Get());
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
    if (FAILED(hr = swapChain_->Present(1, 0))) {
        deviceLost_ = IsDeviceLost(hr);
        return HResultMessage(L"presenting the command bar", hr);
    }
    if (FAILED(hr = composition_->Commit())) return HResultMessage(L"committing the command bar", hr);
    return {};
}

D2D1_COLOR_F CommandBarView::Primary() const { return look_.dark ? Color(1, 1, 1, 1) : Color(0, 0, 0, 1); }

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
    const D2D1_POINT_2F origin{C::kTextX - scrollX_, top};
    // The caret sits on the text's first point; the clip leaves it room.
    context->PushAxisAlignedClip(D2D1::RectF(C::kTextX - 1, 0, width - C::kIconX, C::kFieldHeight), D2D1_ANTIALIAS_MODE_ALIASED);
    if (text_.empty()) {
        brush_->SetColor(WithAlpha(Primary(), C::kPlaceholderOpacity));
        if (placeholderLayout_) context->DrawTextLayout(origin, placeholderLayout_.Get(), brush_.Get());
    } else if (textLayout_) {
        if (HasSelection()) {
            UINT32 count = 0;
            const auto start = static_cast<UINT32>(SelectionStart());
            const auto length = static_cast<UINT32>(SelectionEnd() - SelectionStart());
            textLayout_->HitTestTextRange(start, length, 0, 0, nullptr, 0, &count);
            std::vector<DWRITE_HIT_TEST_METRICS> ranges(count);
            if (count && SUCCEEDED(textLayout_->HitTestTextRange(start, length, 0, 0, ranges.data(), count, &count))) {
                const D2D1_COLOR_F selection = look_.dark ? kDarkSelection : kLightSelection;
                // Grey when the window isn't the one in front, as on the Mac.
                brush_->SetColor(focused_ ? selection : WithAlpha(Primary(), 0.15f));
                for (const auto& r : ranges) {
                    context->FillRectangle(D2D1::RectF(origin.x + r.left, origin.y + r.top, origin.x + r.left + r.width,
                                                       origin.y + r.top + r.height),
                                           brush_.Get());
                }
            }
        }
        brush_->SetColor(Primary());
        context->DrawTextLayout(origin, textLayout_.Get(), brush_.Get());
    }
    // The caret: only in the window with the keyboard, and not over a selection.
    if (focused_ && caretOn_ && !HasSelection()) {
        const float x = std::round((origin.x + CaretX()) * geometry_.scale) / geometry_.scale;
        brush_->SetColor(Primary());
        context->FillRectangle(D2D1::RectF(x - 0.5f, origin.y, x + 0.5f, origin.y + LineHeight()), brush_.Get());
    }
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
        // Favicons come with the sidebar (W4); until then the Mac's no-favicon globe.
        icon = kGlobeGlyph;
        iconOpacity = kNoFaviconOpacity;
        break;
    }
    Glyph(context, icon, C::kRowIconSize, tile, WithAlpha(highlighted ? accent : Primary(), iconOpacity));

    // The arrow in its 24pt box, 13pt from the fill's right.
    const float boxRight = fill.right - C::kActionBoxTrailing;
    const float boxTop = fill.top + (C::kRowFillHeight - C::kActionBoxSize) / 2;
    const D2D1_RECT_F box{boxRight - C::kActionBoxSize, boxTop, boxRight, boxTop + C::kActionBoxSize};
    const float boxOpacity = highlighted ? 1 : 0.7f;
    brush_->SetColor(highlighted ? white : WithAlpha(Primary(), 0.06f * boxOpacity));
    context->FillRoundedRectangle(D2D1::RoundedRect(box, 6, 6), brush_.Get());
    Glyph(context, kArrowGlyph, 13, box, highlighted ? accent : WithAlpha(Primary(), boxOpacity));

    if (index >= rowText_.size()) return;
    const RowText& text = rowText_[index];
    if (text.detail) {
        const float right = box.left - C::kActionGap;
        brush_->SetColor(highlighted ? WithAlpha(white, 0.8f) : WithAlpha(Primary(), C::kRowDetailOpacity));
        context->DrawTextLayout(D2D1::Point2F(right - text.detailWidth, fill.top), text.detail.Get(), brush_.Get());
    }
    if (text.title) {
        brush_->SetColor(highlighted ? white : WithAlpha(Primary(), C::kRowTextOpacity));
        context->DrawTextLayout(D2D1::Point2F(fill.left + C::kRowTitleX, fill.top), text.title.Get(), brush_.Get(),
                                D2D1_DRAW_TEXT_OPTIONS_CLIP);
    }
}

}  // namespace kite
