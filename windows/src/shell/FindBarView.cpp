// See FindBarView.h. Ports KiteMac/Views/FindBar.swift's find style (Arc's FindInPageView).

#include "shell/FindBarView.h"

#include <windowsx.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <initializer_list>
#include <utility>
#include <vector>

#include "shell/Errors.h"
#include "shell/SystemFont.h"
#include "shell/Text.h"

using Microsoft::WRL::ComPtr;

namespace kite {

namespace {

// FindBar.Metrics, measured from Arc in points: x from the bar's leading edge at its full 300pt,
// everything right of the query laid out from the trailing edge.
namespace M {
constexpr float kFullWidth = 300;
constexpr float kIconCenterX = 16.5f;  // the magnifier's glyph lands at 10, 13pt wide
constexpr float kTextX = 32;           // FindInPageView.leftTitleMargin
constexpr float kCounterTrailingX = 207;
constexpr float kCounterGap = 8;       // the field stops 8pt before the counter
constexpr float kPreviousCenterX = 225.5f;
constexpr float kNextCenterX = 252;
constexpr float kDividerX = 269.5f;    // 1.5pt left of the close button (26pt wide, 3pt from the edge)
constexpr float kCloseCenterX = 283.5f;
constexpr float kButtonSize = 20;
constexpr float kFieldFontSize = 13;
constexpr float kCounterFontSize = 11.5f;
// FindInPageView's NSShadow: blur 5 (a Gaussian of Ïƒ 2.5), 3pt down.
constexpr float kShadowSigma = 2.5f;
constexpr float kShadowY = 3;
constexpr float kShadowMargin = 12;  // room for it around the bar: 3Ïƒ and the offset
}  // namespace M

// Segoe Fluent Icons (Windows 11) and Segoe MDL2 Assets (Windows 10) share it: the counterpart
// of the Mac's SF Symbols magnifyingglass.
constexpr wchar_t kSearchGlyph = 0xE721;
// The arrows and close are Kite's own strokes, at the box, weight and centre the Mac's SF Symbols
// draw at (arrow.up and arrow.down 13pt medium, xmark 11pt semibold), measured in the Mac's 2x
// reference (review/w21-mac): each arrow 10 x 12pt, the X 9pt square, 1.6pt and 1.55pt strokes with round
// ends. Segoe's glyphs are about half that weight.
constexpr float kStroke = 1.6f;       // the arrows
constexpr float kCloseStroke = 1.55f;  // the X (xmark is lighter for its size)
constexpr float kArrowWidth = 10, kArrowHeight = 12;
constexpr float kCloseSize = 9;

D2D1_COLOR_F Srgb(int r, int g, int b, float a = 1) { return D2D1_COLOR_F{r / 255.0f, g / 255.0f, b / 255.0f, a}; }

// Arc's named colours (FindBar.Metrics), light and dark.
D2D1_COLOR_F Fill(bool dark) { return dark ? Srgb(0x15, 0x1C, 0x30) : Srgb(0xFA, 0xFB, 0xFF); }  // PopoverBackground
D2D1_COLOR_F TextColor(bool dark) { return dark ? D2D1_COLOR_F{1, 1, 1, 0.8f} : Srgb(0x0E, 0x0F, 0x10, 0.9f); }  // ForegroundPrimary
D2D1_COLOR_F IconColor(bool dark) { return dark ? D2D1_COLOR_F{1, 1, 1, 0.5f} : D2D1_COLOR_F{0, 0, 0, 0.5f}; }  // ForegroundSecondary
D2D1_COLOR_F CounterColor(bool dark) { return dark ? Srgb(0xFA, 0xFB, 0xFF, 0.9f) : Srgb(0x0E, 0x0F, 0x10, 0.8f); }  // PopoverInputText
constexpr D2D1_COLOR_F kDivider{0, 0, 0, 0.1f};  // FindInPageSeparator, both appearances
// FindInPageError, Display P3 (0.788, 0.2, 0.2), in sRGB.
constexpr D2D1_COLOR_F kError{0.859f, 0.100f, 0.161f, 1};
// PopoverShadow: #151C32 at 30% (light) or 80% (dark).
constexpr float kShadowR = 0x15 / 255.0f, kShadowG = 0x1C / 255.0f, kShadowB = 0x32 / 255.0f;
float ShadowAlpha(bool dark) { return dark ? 0.8f : 0.3f; }
constexpr D2D1_COLOR_F kCaret{0x11 / 255.0f, 0x7A / 255.0f, 0xFD / 255.0f, 1};
// The Mac's default text selection colours (NSColor.selectedTextBackgroundColor), as the
// command bar's.
constexpr D2D1_COLOR_F kDarkSelection{63 / 255.0f, 99 / 255.0f, 139 / 255.0f, 1};
constexpr D2D1_COLOR_F kLightSelection{179 / 255.0f, 215 / 255.0f, 1, 1};

float GaussianCoverage(float x, float from, float to, float sigma) {
    const float s = sigma * std::sqrt(2.0f);
    return 0.5f * (std::erf((x - from) / s) - std::erf((x - to) / s));
}

}  // namespace

std::unique_ptr<FindBarView> FindBarView::Create(HWND window, Callbacks callbacks, std::wstring& error) {
    std::unique_ptr<FindBarView> view(new FindBarView(window, std::move(callbacks)));
    HRESULT hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                                     reinterpret_cast<IUnknown**>(view->dwrite_.GetAddressOf()));
    if (FAILED(hr)) {
        error = HResultMessage(L"DWriteCreateFactory", hr);
        return nullptr;
    }
    // The Mac's bar sets its field in SF Pro regular and its counter in medium (shell/SystemFont).
    auto nowrap = [](HRESULT made, ComPtr<IDWriteTextFormat>& out) {
        return SUCCEEDED(made) ? out->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP) : made;
    };
    IDWriteFactory* dwrite = view->dwrite_.Get();
    if (FAILED(hr = nowrap(system_font::CreateTextFormat(dwrite, MacWeight::Regular, M::kFieldFontSize, view->fieldFormat_), view->fieldFormat_)) ||
        FAILED(hr = nowrap(system_font::CreateTextFormat(dwrite, MacWeight::Medium, M::kCounterFontSize, view->counterFormat_),
                           view->counterFormat_)) ||
        FAILED(hr = nowrap(system_font::CreateIconFormat(dwrite, system_font::IconFont::Symbols, DWRITE_FONT_WEIGHT_NORMAL, 13, view->iconFormat_),
                           view->iconFormat_))) {
        error = HResultMessage(L"CreateTextFormat", hr);
        return nullptr;
    }
    view->iconFormat_->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
    view->iconFormat_->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    view->counterFormat_->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    const std::wstring placeholder = Widen(ask_on_page::Placeholder(false, false));
    view->field_.SetFormat(view->dwrite_.Get(), view->fieldFormat_.Get(), placeholder);
    return view;
}

FindBarView::~FindBarView() { UseCompositor(nullptr); }

void FindBarView::UseCompositor(Compositor* compositor) {
    field_.ReleaseCaret();
    if (visual_ && compositor_) {
        visual_->SetContent(nullptr);
        compositor_->PageOverlay()->RemoveVisual(visual_.Get());
        compositor_->Commit();
    }
    visual_.Reset();
    fieldVisual_.Reset();
    surface_.Reset();
    brush_.Reset();
    shadow_.Reset();
    roundStroke_.Reset();
    surfaceWidth_ = surfaceHeight_ = 0;
    shadowWidth_ = -1;
    shadowDpi_ = 0;
    compositor_ = compositor;
    deviceLost_ = false;
    if (open_ && compositor_) Draw();
}

void FindBarView::Show(bool dark) {
    if (open_) return SetDark(dark);
    open_ = true;
    dark_ = dark;
    pressed_ = Button::None;
    query_.Clear();
    field_.SetText(L"", false);
    LabelChanged();
    ComputeFrame();
    Draw();
}

void FindBarView::Hide() {
    if (!open_) return;
    open_ = false;
    keyboard_ = false;
    FocusChanged();
    if (GetCapture() == window_) ReleaseCapture();
    field_.Release();
    pressed_ = Button::None;
    // The query and counter go with the bar (the Mac's clearQuery once it's out of sight).
    query_.Clear();
    field_.SetText(L"", false);
    LabelChanged();
    // Its surface goes until it opens again; the visual stays.
    pressedOver_ = false;
    field_.ReleaseCaret();
    if (visual_) visual_->SetContent(nullptr);
    surface_.Reset();
    surfaceWidth_ = surfaceHeight_ = 0;
    if (compositor_) compositor_->Commit();
}

void FindBarView::SetDark(bool dark) {
    if (dark == dark_) return;
    dark_ = dark;
    if (open_) Draw();
}

void FindBarView::SetCard(const RECT& card) {
    card_ = card;
    if (open_) Draw();  // which lays it out again
}

void FindBarView::ComputeFrame() {
    dpi_ = callbacks_.dpi ? callbacks_.dpi() : GetDpiForWindow(window_);
    const float scale = Scale();
    frame_ = FindBarFrameIn(card_.left / scale, card_.top / scale, card_.right / scale);
    leftPx_ = std::lround(frame_.left * scale);
    topPx_ = std::lround(frame_.top * scale);
    marginPx_ = static_cast<LONG>(std::ceil(M::kShadowMargin * scale));
    PlaceField();
}

RECT FindBarView::Frame() const {
    if (!open_) return RECT{};
    const float scale = Scale();
    return RECT{leftPx_, topPx_, leftPx_ + std::lround(static_cast<float>(frame_.width) * scale),
                topPx_ + std::lround(static_cast<float>(frame_.height) * scale)};
}

float FindBarView::FieldRight() const {
    const float w = static_cast<float>(frame_.width);
    const float counterRight = M::kCounterTrailingX - M::kFullWidth + w;
    return std::max(M::kTextX + 1, counterRight - counterWidth_ - M::kCounterGap);
}

void FindBarView::PlaceField() {
    field_.Place(M::kTextX, FieldRight() - M::kTextX, 0, static_cast<float>(kFindBarHeight), POINT{leftPx_, topPx_}, Scale());
}

void FindBarView::LabelChanged() {
    counter_.Reset();
    counterWidth_ = 0;
    const std::wstring label = Widen(query_.Label());
    if (!label.empty()) {
        dwrite_->CreateTextLayout(label.c_str(), static_cast<UINT32>(label.size()), counterFormat_.Get(), 100000,
                                  static_cast<float>(kFindBarHeight), counter_.GetAddressOf());
        DWRITE_TEXT_METRICS metrics{};
        if (counter_ && SUCCEEDED(counter_->GetMetrics(&metrics))) counterWidth_ = metrics.widthIncludingTrailingWhitespace;
    }
    PlaceField();
}

// MARK: Input

void FindBarView::Focus() {
    if (!open_) return;
    keyboard_ = true;
    // The keyboard, when Kite is the window in front (a quiet test run never activates).
    if (GetForegroundWindow() == window_ && GetFocus() != window_) SetFocus(window_);
    field_.SelectAll();
    FocusChanged();
    Draw();
}

void FindBarView::LoseKeyboard() {
    if (!keyboard_) return;
    keyboard_ = false;
    // The Mac's field editor goes: no selection shown, nothing left to undo.
    field_.EndEditing();
    FocusChanged();
    if (open_) Draw();
}

float FindBarView::CornerRadiusPx() const {
    return static_cast<float>(find_bar_style::CornerRadius(FindBarStyle::Find)) * Scale();
}

POINT FindBarView::ClientPointOf(Part part) const {
    const float w = static_cast<float>(frame_.width);
    float x = 0;
    switch (part) {
    case Part::Field: x = (M::kTextX + FieldRight()) / 2; break;
    case Part::FieldStart: x = M::kTextX + 8; break;
    case Part::FieldEnd: x = FieldRight() - 4; break;
    case Part::Previous: x = M::kPreviousCenterX - M::kFullWidth + w; break;
    case Part::Next: x = M::kNextCenterX - M::kFullWidth + w; break;
    case Part::Close: x = M::kCloseCenterX - M::kFullWidth + w; break;
    }
    const float scale = Scale();
    return POINT{leftPx_ + std::lround(x * scale), topPx_ + std::lround(static_cast<float>(kFindBarHeight) / 2 * scale)};
}

void FindBarView::FocusChanged() { field_.SetFocused(open_ && keyboard_ && GetFocus() == window_); }

bool FindBarView::FieldFocused() const { return field_.Focused(); }

std::pair<size_t, size_t> FindBarView::FieldSelection() const { return {field_.SelectionStart(), field_.SelectionEnd()}; }

void FindBarView::Step(bool forward) {
    if (!open_) return;
    if (auto search = query_.Step(forward); search && callbacks_.search) callbacks_.search(*search);
}

void FindBarView::Type(std::string_view text) {
    if (open_) Edited(field_.Type(Widen(text)));
}

void FindBarView::Edited(TextField::Change change) {
    if (change == TextField::Change::None) return;
    if (change == TextField::Change::Text) {
        // As the Mac's controlTextDidChange: every keystroke searches, with no debounce.
        const FindQuery::Search search = query_.TextChanged(Narrow(field_.Text()));
        LabelChanged();
        if (callbacks_.search) callbacks_.search(search);
    }
    Draw();
}

void FindBarView::ShowResult(const FindResult& result) {
    if (!open_ || !query_.Searching()) return;
    const std::string before = query_.Label();
    query_.Show(result);
    if (query_.Label() == before) return;  // Chromium's interim reports often repeat
    LabelChanged();
    Draw();
}

void FindBarView::Press(Button button) {
    switch (button) {
    case Button::Previous: Step(false); break;
    case Button::Next: Step(true); break;
    case Button::Close:
        if (callbacks_.close) callbacks_.close();
        break;
    case Button::None: break;
    }
}

D2D1_POINT_2F FindBarView::BarPoint(LPARAM clientPixels) const {
    const float scale = Scale();
    return {static_cast<float>(GET_X_LPARAM(clientPixels) - leftPx_) / scale, static_cast<float>(GET_Y_LPARAM(clientPixels) - topPx_) / scale};
}

bool FindBarView::InBar(D2D1_POINT_2F p) const {
    return p.x >= 0 && p.x < static_cast<float>(frame_.width) && p.y >= 0 && p.y < static_cast<float>(frame_.height);
}

FindBarView::Button FindBarView::ButtonAt(D2D1_POINT_2F p) const {
    const float w = static_cast<float>(frame_.width);
    const float top = (static_cast<float>(kFindBarHeight) - M::kButtonSize) / 2;
    if (p.y < top || p.y >= top + M::kButtonSize) return Button::None;
    for (auto [center, button] : {std::pair{M::kPreviousCenterX, Button::Previous}, std::pair{M::kNextCenterX, Button::Next},
                                  std::pair{M::kCloseCenterX, Button::Close}}) {
        const float x = center - M::kFullWidth + w;
        if (std::abs(p.x - x) < M::kButtonSize / 2) return button;
    }
    return Button::None;
}

LOGFONTW FindBarView::FieldFont() const {
    LOGFONTW font{};
    font.lfHeight = -std::lround(M::kFieldFontSize * Scale());
    font.lfWeight = system_font::GdiWeight(MacWeight::Regular, M::kFieldFontSize);
    font.lfCharSet = DEFAULT_CHARSET;
    lstrcpynW(font.lfFaceName, system_font::GdiFaceName(), LF_FACESIZE);
    return font;
}

bool FindBarView::HandleMessage(UINT message, WPARAM wParam, LPARAM lParam, LRESULT& result) {
    result = 0;
    if (!open_) return false;
    switch (message) {
    case WM_KEYDOWN: {
        if (!field_.Focused()) return false;
        // AltGr is Ctrl+Alt: its characters come as WM_CHAR, never as a Ctrl key.
        const bool alt = GetKeyState(VK_MENU) < 0;
        const bool ctrl = GetKeyState(VK_CONTROL) < 0 && !alt;
        const bool shift = GetKeyState(VK_SHIFT) < 0;
        const auto key = static_cast<UINT>(wParam);
        if (key == VK_RETURN) {
            // FindBar's insertNewline: the next match, the previous with Shift.
            Step(!shift);
            return true;
        }
        if (key == VK_ESCAPE) {
            if (callbacks_.close) callbacks_.close();
            return true;
        }
        const std::optional<TextField::Change> change = field_.KeyDown(key, ctrl, shift);
        if (!change) return false;
        Edited(*change);
        return true;
    }
    case WM_CHAR:
        if (!field_.Focused()) return false;
        Edited(field_.Character(static_cast<wchar_t>(wParam)));
        return true;
    case WM_IME_STARTCOMPOSITION:
        if (!field_.Focused()) return false;
        {
            const LOGFONTW font = FieldFont();
            field_.CompositionStarted(&font);
        }
        Draw();  // the placeholder goes, as NSTextField's does under marked text
        return false;  // Windows' composition window draws it; the result comes as WM_CHAR
    case WM_IME_ENDCOMPOSITION:
        if (!field_.Composing()) return false;
        field_.CompositionEnded();
        Draw();
        return false;
    case WM_KILLFOCUS:
        // The page took it (a click in it): the field lets it go and the bar stays. Another app
        // or a window of Kite's own (the space tip) leaves it the first responder.
        if (const auto to = reinterpret_cast<HWND>(wParam); to && IsChild(window_, to) && keyboard_) {
            keyboard_ = false;
            field_.EndEditing();
        }
        if (GetCapture() == window_) ReleaseCapture();
        FocusChanged();
        Draw();
        return false;
    case WM_SETFOCUS:
        FocusChanged();
        Draw();
        return false;
    case WM_TIMER:
        if (!field_.HandleTimer(wParam)) return false;
        if (compositor_ && fieldVisual_) {
            field_.UpdateCaret(compositor_->Device(), compositor_->D2D(), fieldVisual_.Get(), kCaret);
            compositor_->Commit();
        }
        return true;
    case WM_SETCURSOR: {
        if (LOWORD(lParam) != HTCLIENT) return false;
        POINT cursor{};
        GetCursorPos(&cursor);
        ScreenToClient(window_, &cursor);
        const D2D1_POINT_2F p = BarPoint(MAKELPARAM(cursor.x, cursor.y));
        if (!InBar(p)) return false;
        SetCursor(LoadCursorW(nullptr, field_.Contains(p.x, p.y) ? IDC_IBEAM : IDC_ARROW));
        result = TRUE;
        return true;
    }
    case WM_LBUTTONDOWN:
    case WM_LBUTTONDBLCLK: {
        const D2D1_POINT_2F p = BarPoint(lParam);
        if (!InBar(p)) return false;
        if (field_.Contains(p.x, p.y)) {
            // A press in the field makes it the first responder, as clicking an NSTextField does
            // (the controller takes the keyboard from the other fields first). One that already
            // has it just moves the caret, so Shift extends from where the selection was.
            if (!keyboard_) {
                if (callbacks_.takeKeyboard) callbacks_.takeKeyboard();
                keyboard_ = true;
            }
            // A real click has activated the window by now; a quiet test run is never brought forward.
            if (GetForegroundWindow() == window_ && GetFocus() != window_) SetFocus(window_);
            FocusChanged();
            SetCapture(window_);
            Edited(field_.Press(p.x, (wParam & MK_SHIFT) != 0));  // draws once, with the caret
            return true;
        }
        // The arrows and close are borderless NSButtons, which never become first responder:
        // the keyboard stays where it was.
        pressed_ = ButtonAt(p);
        pressedOver_ = pressed_ != Button::None;
        if (pressedOver_) {
            SetCapture(window_);
            Draw();
        }
        return true;
    }
    case WM_MOUSEMOVE: {
        const D2D1_POINT_2F p = BarPoint(lParam);
        if (field_.Selecting()) {
            Edited(field_.Drag(p.x));
            return true;
        }
        if (pressed_ != Button::None) {
            // NSButton's highlight follows the pointer in and out while it's held.
            if (const bool over = ButtonAt(p) == pressed_; over != pressedOver_) {
                pressedOver_ = over;
                Draw();
            }
            return true;
        }
        return InBar(p);
    }
    case WM_LBUTTONUP: {
        const D2D1_POINT_2F p = BarPoint(lParam);
        if (GetCapture() == window_) ReleaseCapture();
        if (field_.Selecting()) {
            field_.Release();
            return true;
        }
        // As NSButton, on release over what was pressed.
        const Button pressed = pressed_;
        pressed_ = Button::None;
        if (pressed != Button::None) {
            pressedOver_ = false;
            Draw();
            if (ButtonAt(p) == pressed) Press(pressed);
            return true;
        }
        return InBar(p);
    }
    case WM_CAPTURECHANGED:
        field_.Release();
        if (pressed_ != Button::None) {
            pressed_ = Button::None;
            pressedOver_ = false;
            Draw();
        }
        return false;
    case WM_RBUTTONDOWN:
    case WM_RBUTTONUP:
    case WM_MBUTTONDOWN:
    case WM_MBUTTONUP:
        return InBar(BarPoint(lParam));  // the bar has no menu; nothing under it takes them
    default:
        return false;
    }
}

// MARK: Drawing

bool FindBarView::EnsureShadow(std::wstring& error) {
    const float width = static_cast<float>(frame_.width);
    if (shadow_ && shadowWidth_ == width && shadowDpi_ == dpi_ && shadowDark_ == dark_) return true;
    // A Gaussian of the bar's rectangle (its 5pt corners make little difference under the blur):
    // separable, so its falloff across times its falloff down, at PopoverShadow's alpha.
    const float scale = Scale();
    const float margin = static_cast<float>(marginPx_) / scale;
    std::vector<float> across(surfaceWidth_), down(surfaceHeight_);
    for (UINT i = 0; i < surfaceWidth_; ++i) across[i] = GaussianCoverage((static_cast<float>(i) + 0.5f) / scale - margin, 0, width, M::kShadowSigma);
    for (UINT j = 0; j < surfaceHeight_; ++j) {
        down[j] = GaussianCoverage((static_cast<float>(j) + 0.5f) / scale - margin - M::kShadowY, 0, static_cast<float>(kFindBarHeight),
                                   M::kShadowSigma);
    }
    std::vector<uint8_t> pixels(static_cast<size_t>(surfaceWidth_) * surfaceHeight_ * 4);
    const float opacity = ShadowAlpha(dark_);
    for (UINT j = 0; j < surfaceHeight_; ++j) {
        for (UINT i = 0; i < surfaceWidth_; ++i) {
            const float a = std::clamp(opacity * across[i] * down[j], 0.0f, 1.0f);
            uint8_t* p = &pixels[(static_cast<size_t>(j) * surfaceWidth_ + i) * 4];
            p[0] = static_cast<uint8_t>(std::lround(kShadowB * a * 255));
            p[1] = static_cast<uint8_t>(std::lround(kShadowG * a * 255));
            p[2] = static_cast<uint8_t>(std::lround(kShadowR * a * 255));
            p[3] = static_cast<uint8_t>(std::lround(a * 255));
        }
    }
    D2D1_BITMAP_PROPERTIES1 props{};
    props.pixelFormat = D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED);
    props.dpiX = props.dpiY = static_cast<float>(dpi_);
    const HRESULT hr = compositor_->D2D()->CreateBitmap(D2D1::SizeU(surfaceWidth_, surfaceHeight_), pixels.data(), surfaceWidth_ * 4,
                                                        &props, shadow_.ReleaseAndGetAddressOf());
    if (FAILED(hr)) {
        deviceLost_ = IsDeviceLost(hr);
        error = HResultMessage(L"making the find bar's shadow", hr);
        return false;
    }
    shadowWidth_ = width;
    shadowDpi_ = dpi_;
    shadowDark_ = dark_;
    return true;
}

void FindBarView::Glyph(ID2D1DeviceContext* context, IDWriteTextFormat* format, wchar_t glyph, float centerX, D2D1_COLOR_F color) {
    brush_->SetColor(color);
    const float half = M::kButtonSize / 2;
    context->DrawText(&glyph, 1, format, D2D1::RectF(centerX - half, 0, centerX + half, static_cast<float>(kFindBarHeight)), brush_.Get(),
                      D2D1_DRAW_TEXT_OPTIONS_NONE);
}

ID2D1StrokeStyle* FindBarView::RoundStroke(ID2D1DeviceContext* context) {
    if (roundStroke_) return roundStroke_.Get();
    ComPtr<ID2D1Factory> factory;
    context->GetFactory(factory.GetAddressOf());
    ComPtr<ID2D1Factory1> factory1;
    if (!factory || FAILED(factory.As(&factory1))) return nullptr;
    D2D1_STROKE_STYLE_PROPERTIES1 round{};
    round.startCap = round.endCap = round.dashCap = D2D1_CAP_STYLE_ROUND;
    round.lineJoin = D2D1_LINE_JOIN_ROUND;
    round.miterLimit = 10;
    round.dashStyle = D2D1_DASH_STYLE_SOLID;
    round.transformType = D2D1_STROKE_TRANSFORM_TYPE_NORMAL;
    factory1->CreateStrokeStyle(round, nullptr, 0, roundStroke_.GetAddressOf());
    return roundStroke_.Get();
}

// One geometry each, so where its strokes meet (the arrow's tip, the X's middle) the colour's
// alpha isn't laid down twice.
void FindBarView::Strokes(ID2D1DeviceContext* context, std::initializer_list<std::pair<D2D1_POINT_2F, D2D1_POINT_2F>> lines, float width,
                          D2D1_COLOR_F color) {
    ComPtr<ID2D1Factory> factory;
    context->GetFactory(factory.GetAddressOf());
    ComPtr<ID2D1PathGeometry> path;
    ComPtr<ID2D1GeometrySink> sink;
    if (!factory || FAILED(factory->CreatePathGeometry(path.GetAddressOf())) || FAILED(path->Open(sink.GetAddressOf()))) return;
    for (const auto& [from, to] : lines) {
        sink->BeginFigure(from, D2D1_FIGURE_BEGIN_HOLLOW);
        sink->AddLine(to);
        sink->EndFigure(D2D1_FIGURE_END_OPEN);
    }
    if (FAILED(sink->Close())) return;
    brush_->SetColor(color);
    context->DrawGeometry(path.Get(), brush_.Get(), width, RoundStroke(context));
}

void FindBarView::Arrow(ID2D1DeviceContext* context, float centerX, bool up, D2D1_COLOR_F color) {
    // The box holds the round ends: the lines stop half a stroke inside it.
    const float half = kStroke / 2;
    const float centerY = static_cast<float>(kFindBarHeight) / 2;
    const float sign = up ? 1.0f : -1.0f;
    const float tipY = centerY - sign * (kArrowHeight / 2 - half);
    const float tailY = centerY + sign * (kArrowHeight / 2 - half);
    const float arm = kArrowWidth / 2 - half;  // the head's arms at 45°
    const D2D1_POINT_2F tip{centerX, tipY};
    Strokes(context,
            {{tip, D2D1::Point2F(centerX, tailY)}, {tip, D2D1::Point2F(centerX - arm, tipY + sign * arm)},
             {tip, D2D1::Point2F(centerX + arm, tipY + sign * arm)}},
            kStroke, color);
}

void FindBarView::Cross(ID2D1DeviceContext* context, float centerX, D2D1_COLOR_F color) {
    const float reach = kCloseSize / 2 - kCloseStroke / 2;
    const float centerY = static_cast<float>(kFindBarHeight) / 2;
    Strokes(context,
            {{D2D1::Point2F(centerX - reach, centerY - reach), D2D1::Point2F(centerX + reach, centerY + reach)},
             {D2D1::Point2F(centerX - reach, centerY + reach), D2D1::Point2F(centerX + reach, centerY - reach)}},
            kCloseStroke, color);
}

void FindBarView::DrawContent(ID2D1DeviceContext* context) {
    const float scale = Scale();
    const float margin = static_cast<float>(marginPx_) / scale;
    const float w = static_cast<float>(frame_.width);
    const float h = static_cast<float>(kFindBarHeight);
    D2D1::Matrix3x2F base;
    context->GetTransform(&base);
    context->SetTransform(D2D1::Matrix3x2F::Translation(margin, margin) * base);
    // The shadow under the bar, which is opaque.
    context->DrawBitmap(shadow_.Get(),
                        D2D1::RectF(-margin, -margin, static_cast<float>(surfaceWidth_) / scale - margin,
                                    static_cast<float>(surfaceHeight_) / scale - margin),
                        1, D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR, nullptr);
    // FindInPageView.updateLayer: a 5pt corner, circular.
    const auto radius = static_cast<float>(find_bar_style::CornerRadius(FindBarStyle::Find));
    brush_->SetColor(Fill(dark_));
    context->FillRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(0, 0, w, h), radius, radius), brush_.Get());

    Glyph(context, iconFormat_.Get(), kSearchGlyph, M::kIconCenterX, IconColor(dark_));
    const D2D1_COLOR_F selection = field_.Focused() ? (dark_ ? kDarkSelection : kLightSelection)
                                                    : (dark_ ? D2D1_COLOR_F{1, 1, 1, 0.15f} : D2D1_COLOR_F{0, 0, 0, 0.15f});
    field_.Draw(context, brush_.Get(), TextColor(dark_), IconColor(dark_), selection);

    if (counter_) {
        brush_->SetColor(query_.LabelIsNotFound() ? kError : CounterColor(dark_));
        const float right = M::kCounterTrailingX - M::kFullWidth + w;
        context->DrawTextLayout(D2D1::Point2F(right - counterWidth_, 0), counter_.Get(), brush_.Get());
    }
    const auto x = [w](float fromFull) { return fromFull - M::kFullWidth + w; };
    // A held button dims its glyph while the pointer is over it, as a borderless NSButton's image does.
    const auto tint = [this](Button button) {
        D2D1_COLOR_F color = CounterColor(dark_);
        if (pressedOver_ && pressed_ == button) color.a *= 0.5f;
        return color;
    };
    Arrow(context, x(M::kPreviousCenterX), true, tint(Button::Previous));
    Arrow(context, x(M::kNextCenterX), false, tint(Button::Next));
    const auto divider = static_cast<float>(find_bar_style::DividerHeight(h));
    brush_->SetColor(kDivider);
    context->FillRectangle(D2D1::RectF(x(M::kDividerX), (h - divider) / 2, x(M::kDividerX) + 1, (h + divider) / 2), brush_.Get());
    Cross(context, x(M::kCloseCenterX), tint(Button::Close));
    context->SetTransform(base);
}

std::wstring FindBarView::Draw(Pixels* readBack, POINT* origin) {
    if (!open_) return {};
    if (!compositor_) return L"no compositor";
    if (deviceLost_) return L"the GPU device was lost";
    RECT client{};
    GetClientRect(window_, &client);
    if (client.right <= 0 || client.bottom <= 0) return {};  // minimized: drawn again on restore
    ComputeFrame();
    const float scale = Scale();
    const UINT width = std::max(1u, static_cast<UINT>(std::ceil(static_cast<float>(frame_.width) * scale)) + 2 * static_cast<UINT>(marginPx_));
    const UINT height = static_cast<UINT>(std::ceil(static_cast<float>(kFindBarHeight) * scale)) + 2 * static_cast<UINT>(marginPx_);
    auto fail = [this](const wchar_t* what, HRESULT hr) {
        deviceLost_ = IsDeviceLost(hr);
        return HResultMessage(what, hr);
    };
    HRESULT hr = S_OK;
    IDCompositionDevice* device = compositor_->Device();
    if (!visual_) {
        if (FAILED(hr = compositor_->D2D()->CreateSolidColorBrush(D2D1_COLOR_F{0, 0, 0, 1}, brush_.ReleaseAndGetAddressOf())) ||
            FAILED(hr = device->CreateVisual(visual_.ReleaseAndGetAddressOf())) ||
            FAILED(hr = device->CreateVisual(fieldVisual_.ReleaseAndGetAddressOf())) ||
            FAILED(hr = visual_->AddVisual(fieldVisual_.Get(), TRUE, nullptr)) ||
            FAILED(hr = compositor_->PageOverlay()->AddVisual(visual_.Get(), TRUE, nullptr))) {
            visual_.Reset();
            fieldVisual_.Reset();
            return fail(L"creating the find bar's visual", hr);
        }
    }
    if (!surface_) {
        if (FAILED(hr = device->CreateVirtualSurface(width, height, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED,
                                                     surface_.GetAddressOf())) ||
            FAILED(hr = visual_->SetContent(surface_.Get()))) {
            surface_.Reset();
            return fail(L"creating the find bar's surface", hr);
        }
    } else if (width != surfaceWidth_ || height != surfaceHeight_) {
        if (FAILED(hr = surface_->Resize(width, height))) return fail(L"resizing the find bar's surface", hr);
    }
    surfaceWidth_ = width;
    surfaceHeight_ = height;
    visual_->SetOffsetX(static_cast<float>(leftPx_ - marginPx_));
    visual_->SetOffsetY(static_cast<float>(topPx_ - marginPx_));
    // The field's coordinates are the bar's: its caret's visual sits at the bar's top-left.
    fieldVisual_->SetOffsetX(static_cast<float>(marginPx_));
    fieldVisual_->SetOffsetY(static_cast<float>(marginPx_));
    std::wstring error;
    if (!EnsureShadow(error)) return error;
    error = compositor_->DrawSurface(perf::View::FindBar, surface_.Get(), width, height, dpi_, [this](ID2D1DeviceContext* context) { DrawContent(context); },
                                     readBack, hr);
    if (!error.empty()) {
        deviceLost_ = IsDeviceLost(hr);
        return L"the find bar: " + error;
    }
    if (FAILED(hr = field_.UpdateCaret(device, compositor_->D2D(), fieldVisual_.Get(), kCaret))) return fail(L"placing the find bar's caret", hr);
    compositor_->Commit();
    if (readBack && origin) *origin = POINT{leftPx_ - marginPx_, topPx_ - marginPx_};
    return {};
}

}  // namespace kite
