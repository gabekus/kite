// See SpaceIconPickerView.h.

#include "shell/SpaceIconPickerView.h"

#include <windowsx.h>

#include <algorithm>
#include <cmath>
#include <iterator>

#include "shell/Errors.h"
#include "shell/Text.h"

using Microsoft::WRL::ComPtr;

namespace kite {

namespace {

namespace P = icon_picker_metrics;

constexpr wchar_t kClassName[] = L"KiteSpaceIconPicker";

// NSColor.labelColor's alpha.
constexpr float kLabelAlpha = 0.85f;
// A plain button's label while it's held down over it (SwiftUI dims it; not measured on the Mac).
constexpr float kPressedOpacity = 0.5f;
// The tabs' titles and Search: AppKit's regular controls' 13pt system font.
constexpr float kTextSize = 13;
// The grid's 22pt emoji as the space bar sets its 12.5pt one (SpaceBarView): Apple Color Emoji
// inks 14.5pt where Segoe UI Emoji inks 12.75pt at 12.5, so it's set that much larger, and
// centred on its ink.
constexpr float kEmojiSize = P::kEmojiFontSize * 14.5f / 12.75f;
// AppKit's controls as drawn here, until the UI gate measures the Mac's: the segmented control's
// track and its selected segment's knob, the rounded-border field (its text 5pt in), and the
// popover's own fill and edge, in each appearance.
constexpr float kTabsRadius = 6, kKnobInset = 2, kKnobRadius = 4.5f;
constexpr float kFieldRadius = 5, kFieldTextInset = 5;
constexpr float kPlaceholderOpacity = 0.25f;  // placeholderTextColor
constexpr float kDisabledOpacity = 0.25f;     // disabledControlTextColor
constexpr D2D1_COLOR_F kDarkFill{0.172f, 0.172f, 0.18f, 1}, kLightFill{0.965f, 0.965f, 0.965f, 1};
constexpr D2D1_COLOR_F kDarkSelection{63 / 255.0f, 99 / 255.0f, 139 / 255.0f, 1};  // selectedTextBackgroundColor
constexpr D2D1_COLOR_F kLightSelection{179 / 255.0f, 215 / 255.0f, 1, 1};
constexpr float kDarkTextBackground = 30 / 255.0f;  // textBackgroundColor (#1E1E1E; white when light)
// The emoji grid's rows kept drawn around those in view, above and below (the rest are let go).
constexpr size_t kKeptRows = 10;
// A wheel notch scrolls 100pt for Windows' default 3 lines, as the sidebar's list does.
constexpr float kWheelLine = 100.0f / 3;

D2D1_RECT_F ToD2D(const PickerRect& r) { return D2D1_RECT_F{r.left, r.top, r.right, r.bottom}; }

bool RegisterOnce(HINSTANCE instance, WNDPROC proc) {
    static const bool registered = [&] {
        WNDCLASSEXW wc{};
        wc.cbSize = sizeof(wc);
        wc.lpfnWndProc = proc;
        wc.hInstance = instance;
        wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        wc.lpszClassName = kClassName;
        return RegisterClassExW(&wc) != 0 || GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
    }();
    return registered;
}

}  // namespace

std::unique_ptr<SpaceIconPickerView> SpaceIconPickerView::Create(HWND owner, IDWriteFactory* dwrite, SpaceIconPainter* painter,
                                                                 Callbacks callbacks, bool keepInOwner, std::wstring& error) {
    std::unique_ptr<SpaceIconPickerView> view(new SpaceIconPickerView(owner, dwrite, painter, std::move(callbacks), keepInOwner));
    ComPtr<IDWriteFontCollection> fonts;
    dwrite->GetSystemFontCollection(fonts.GetAddressOf());
    auto installed = [&](const wchar_t* family) {
        UINT32 index = 0;
        BOOL exists = FALSE;
        return fonts && SUCCEEDED(fonts->FindFamilyName(family, &index, &exists)) && exists;
    };
    const wchar_t* text = installed(L"Segoe UI Variable Text") ? L"Segoe UI Variable Text" : L"Segoe UI";
    HRESULT hr = dwrite->CreateTextFormat(text, nullptr, DWRITE_FONT_WEIGHT_REGULAR, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
                                          kTextSize, L"", view->textFormat_.GetAddressOf());
    if (SUCCEEDED(hr)) hr = view->textFormat_->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    if (SUCCEEDED(hr)) {
        hr = dwrite->CreateTextFormat(L"Segoe UI Emoji", nullptr, DWRITE_FONT_WEIGHT_REGULAR, DWRITE_FONT_STYLE_NORMAL,
                                      DWRITE_FONT_STRETCH_NORMAL, kEmojiSize, L"", view->emojiFormat_.GetAddressOf());
    }
    if (SUCCEEDED(hr)) hr = view->emojiFormat_->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    for (const IconPickerTab tab : kIconPickerTabs) {
        if (FAILED(hr)) break;
        const std::wstring title = Widen(IconPickerTabTitle(tab));
        view->tabTitles_.emplace_back();
        hr = dwrite->CreateTextLayout(title.c_str(), static_cast<UINT32>(title.size()), view->textFormat_.Get(), 1000, 100,
                                      view->tabTitles_.back().GetAddressOf());
    }
    static constexpr wchar_t kSearch[] = L"Search";
    if (SUCCEEDED(hr)) {
        hr = dwrite->CreateTextLayout(kSearch, static_cast<UINT32>(std::size(kSearch) - 1), view->textFormat_.Get(), 1000, 100,
                                      view->placeholder_.GetAddressOf());
    }
    if (FAILED(hr)) {
        error = HResultMessage(L"the icon picker's text", hr);
        return nullptr;
    }
    view->search_.SetFormat(dwrite, view->textFormat_.Get(), P::kSearchHeight);
    const HINSTANCE instance = reinterpret_cast<HINSTANCE>(GetWindowLongPtrW(owner, GWLP_HINSTANCE));
    if (!RegisterOnce(instance, &SpaceIconPickerView::WindowProc)) {
        error = L"registering the icon picker's window class failed";
        return nullptr;
    }
    // Owned by the browser window (over it, minimized with it), never activated, never in the
    // taskbar or Alt+Tab; DirectComposition draws all of it.
    view->window_ = CreateWindowExW(WS_EX_NOREDIRECTIONBITMAP | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, kClassName, L"", WS_POPUP, 0, 0, 1, 1,
                                    owner, nullptr, instance, view.get());
    if (!view->window_) {
        error = L"creating the icon picker's window failed";
        return nullptr;
    }
    return view;
}

SpaceIconPickerView::~SpaceIconPickerView() {
    search_.StopBlink();
    callbacks_ = {};
    UseCompositor(nullptr);
    if (window_) DestroyWindow(window_);
}

LRESULT CALLBACK SpaceIconPickerView::WindowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    if (message == WM_NCCREATE) {
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(reinterpret_cast<CREATESTRUCTW*>(lParam)->lpCreateParams));
    }
    auto* view = reinterpret_cast<SpaceIconPickerView*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (message == WM_NCDESTROY && view) {
        // Destroyed with its owner (the browser window's close): forgotten, never used again.
        view->window_ = nullptr;
        view->state_.reset();
    }
    if (view && view->window_ == hwnd) return view->Handle(message, wParam, lParam);
    return DefWindowProcW(hwnd, message, wParam, lParam);
}

LRESULT SpaceIconPickerView::Handle(UINT message, WPARAM wParam, LPARAM lParam) {
    switch (message) {
    case WM_MOUSEACTIVATE: return MA_NOACTIVATE;  // the browser window keeps the keyboard
    case WM_NCHITTEST: {
        // Beside the arrow there's nothing: the window under it takes the pointer.
        POINT at{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};
        ScreenToClient(window_, &at);
        const float x = static_cast<float>(at.x) / Scale(), y = static_cast<float>(at.y) / Scale();
        if (y < P::kArrowHeight && std::abs(x - placement_.arrowX) > P::kArrowWidth / 2 * (1 - y / P::kArrowHeight) + 0.5f) {
            return HTTRANSPARENT;
        }
        return HTCLIENT;
    }
    // Windows shows an owned window again with its restored owner: only Open shows it.
    case WM_SHOWWINDOW:
        if (wParam && lParam == SW_PARENTOPENING) return 0;
        break;
    case WM_SETCURSOR: {
        POINT at{};
        GetCursorPos(&at);
        ScreenToClient(window_, &at);
        const D2D1_POINT_2F p = ToContent(at);
        const bool field = state_ && layout_.search && layout_.search->Contains(p.x, p.y);
        SetCursor(LoadCursorW(nullptr, field ? IDC_IBEAM : IDC_ARROW));
        return TRUE;
    }
    case WM_LBUTTONDOWN:
    case WM_LBUTTONDBLCLK:
        SetCapture(window_);
        Press(ToContent(POINT{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)}));
        return 0;
    case WM_MOUSEMOVE:
        Move(ToContent(POINT{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)}));
        return 0;
    case WM_LBUTTONUP: {
        // Acts first: letting the mouse go reports WM_CAPTURECHANGED, which drops a press.
        Release(ToContent(POINT{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)}));
        if (window_ && GetCapture() == window_) ReleaseCapture();
        return 0;
    }
    case WM_CAPTURECHANGED:
        // The press goes without acting (the mouse was taken away).
        selecting_ = false;
        if (pressed_) {
            pressed_.reset();
            PressChanged();
        }
        return 0;
    case WM_MOUSEWHEEL:
        HandleWheel(wParam, lParam);
        return 0;
    default: break;
    }
    return DefWindowProcW(window_, message, wParam, lParam);
}

void SpaceIconPickerView::UseCompositor(Compositor* compositor) {
    if (compositor == compositor_ && compositor) return;
    Close();
    caret_.Release();
    target_.Reset();
    root_.Reset();
    frame_.Reset();
    gridClip_.Reset();
    grid_.Reset();
    frameSurface_.Reset();
    gridSurface_.Reset();
    brush_.Reset();
    frameWidth_ = frameHeight_ = gridWidth_ = gridHeight_ = 0;
    rowsDrawn_.clear();
    compositor_ = compositor;
    deviceLost_ = false;
}

std::wstring SpaceIconPickerView::Fail(const wchar_t* what, HRESULT hr) {
    deviceLost_ = IsDeviceLost(hr);
    return HResultMessage(what, hr);
}

bool SpaceIconPickerView::MakeTree(HRESULT& hr) {
    if (target_) return true;
    IDCompositionDevice* device = compositor_->Device();
    if (FAILED(hr = device->CreateTargetForHwnd(window_, TRUE, target_.GetAddressOf())) ||
        FAILED(hr = device->CreateVisual(root_.GetAddressOf())) || FAILED(hr = device->CreateVisual(frame_.GetAddressOf())) ||
        FAILED(hr = device->CreateVisual(gridClip_.GetAddressOf())) || FAILED(hr = device->CreateVisual(grid_.GetAddressOf())) ||
        FAILED(hr = root_->AddVisual(frame_.Get(), FALSE, nullptr)) || FAILED(hr = gridClip_->AddVisual(grid_.Get(), FALSE, nullptr)) ||
        FAILED(hr = target_->SetRoot(root_.Get())) ||
        FAILED(hr = compositor_->D2D()->CreateSolidColorBrush(D2D1_COLOR_F{1, 1, 1, 1}, brush_.GetAddressOf()))) {
        target_.Reset();
        root_.Reset();
        frame_.Reset();
        gridClip_.Reset();
        grid_.Reset();
        return false;
    }
    return true;
}

// MARK: Opening and closing

std::wstring SpaceIconPickerView::Open(IconPickerState state, const std::string& icon, const PickerRect& anchor, UINT dpi, bool dark) {
    Close();
    if (!window_) return L"the icon picker's window is gone";
    if (!compositor_) return L"no compositor";
    state_ = std::move(state);
    icon_ = icon;
    anchor_ = anchor;
    dpi_ = dpi;
    dark_ = dark;
    search_.Edit().SetText(Widen(state_->query), Widen(state_->query).size(), Widen(state_->query).size());
    search_.Relayout();
    focused_ = GetFocus() == owner_;
    search_.RestartBlink(focused_ && state_->tab == IconPickerTab::Emoji);
    Relayout();
    frameDirty_ = true;
    rowsDrawn_.clear();
    std::wstring problem = Redraw();
    if (!problem.empty()) {
        Close();
        return problem;
    }
    PlaceWindow();
    return {};
}

void SpaceIconPickerView::Close() {
    if (!state_) return;
    const std::string spaceID = state_->spaceID;
    state_.reset();
    pressed_.reset();
    selecting_ = false;
    search_.StopBlink();
    if (window_) {
        if (GetCapture() == window_) ReleaseCapture();
        ShowWindow(window_, SW_HIDE);
    }
    // Its pixels go with it (a picker opens fresh); the next commit, whoever's, carries it.
    caret_.Release();
    if (frame_) frame_->SetContent(nullptr);
    if (grid_) grid_->SetContent(nullptr);
    frameSurface_.Reset();
    gridSurface_.Reset();
    frameWidth_ = frameHeight_ = gridWidth_ = gridHeight_ = 0;
    rowsDrawn_.clear();
    if (callbacks_.closed) callbacks_.closed(spaceID);
}

void SpaceIconPickerView::SpaceChanged(const std::string& icon) {
    if (!state_ || icon == icon_) return;
    const bool removable = !icon_.empty();
    icon_ = icon;
    if (removable == !icon_.empty()) return;
    // The bin came or went: the tabs' row lays out again.
    Relayout();
    frameDirty_ = true;
    if (std::wstring problem = Redraw(); !problem.empty()) OutputDebugStringW((L"Kite: the icon picker couldn't draw: " + problem + L"\n").c_str());
}

void SpaceIconPickerView::Relayout() {
    if (!state_) return;
    const std::vector<std::string> before = std::move(cells_);
    layout_ = LayOutIconPicker(state_->tab, !icon_.empty());
    cells_ = IconPickerCells(*state_);
    // Other cells: the grid's rows draw again (its surface is made again at its new height).
    if (cells_ != before) rowsDrawn_.clear();
    placement_ = Placement(keepInOwner_);
    if (layout_.search) search_.SetVisibleWidth(layout_.search->Width() - 2 * kFieldTextInset);
    search_.KeepCaretVisible();
}

IconPickerPlacement SpaceIconPickerView::Placement(bool inOwner) const {
    const float scale = Scale();
    POINT origin{0, 0};
    ClientToScreen(owner_, &origin);
    const float ox = static_cast<float>(origin.x) / scale, oy = static_cast<float>(origin.y) / scale;
    const PickerRect anchor{anchor_.left + ox, anchor_.top + oy, anchor_.right + ox, anchor_.bottom + oy};
    PickerRect bounds;
    if (inOwner) {
        RECT client{};
        GetClientRect(owner_, &client);
        bounds = PickerRect{ox, oy, ox + static_cast<float>(client.right) / scale, oy + static_cast<float>(client.bottom) / scale};
    } else {
        MONITORINFO monitor{sizeof(monitor)};
        GetMonitorInfoW(MonitorFromWindow(owner_, MONITOR_DEFAULTTONEAREST), &monitor);
        const RECT& work = monitor.rcWork;
        bounds = PickerRect{static_cast<float>(work.left) / scale, static_cast<float>(work.top) / scale, static_cast<float>(work.right) / scale,
                            static_cast<float>(work.bottom) / scale};
    }
    return PlaceIconPicker(anchor, layout_.width, layout_.height, bounds);
}

void SpaceIconPickerView::PlaceWindow() {
    if (!state_ || !window_) return;
    const float scale = Scale();
    SetWindowPos(window_, nullptr, std::lround(placement_.left * scale), std::lround(placement_.top * scale), static_cast<int>(frameWidth_),
                 static_cast<int>(frameHeight_), SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_NOOWNERZORDER | SWP_NOZORDER);
}

D2D1_POINT_2F SpaceIconPickerView::ToContent(POINT client) const {
    return D2D1_POINT_2F{static_cast<float>(client.x) / Scale(), static_cast<float>(client.y) / Scale() - P::kArrowHeight};
}

POINT SpaceIconPickerView::ContentToClient(float x, float y) const {
    return POINT{std::lround(x * Scale()), std::lround((y + P::kArrowHeight) * Scale())};
}

std::optional<POINT> SpaceIconPickerView::CellCentre(size_t index) {
    if (!state_ || index >= cells_.size()) return std::nullopt;
    if (state_->tab == IconPickerTab::Emoji) {
        // Scrolled so its row shows, as far as it has to.
        const float top = static_cast<float>(index / layout_.columns) * P::kRowPitch;
        const float scroll = state_->scroll;
        if (top < scroll) ScrollIconPicker(*state_, top - scroll);
        else if (top + P::kRowPitch > scroll + layout_.grid.Height()) ScrollIconPicker(*state_, top + P::kRowPitch - layout_.grid.Height() - scroll);
        if (state_->scroll != scroll) Scrolled();
    }
    const PickerRect frame = IconPickerCellFrame(layout_, index, state_->tab == IconPickerTab::Emoji ? state_->scroll : 0);
    return ContentToClient((frame.left + frame.right) / 2, (frame.top + frame.bottom) / 2);
}

size_t SpaceIconPickerView::RowsDrawn() const { return static_cast<size_t>(std::count(rowsDrawn_.begin(), rowsDrawn_.end(), true)); }

// MARK: Drawing

D2D1_COLOR_F SpaceIconPickerView::Label(float alpha) const {
    const float c = dark_ ? 1.0f : 0.0f;
    return D2D1_COLOR_F{c, c, c, kLabelAlpha * alpha};
}

void SpaceIconPickerView::PaintGlyph(ID2D1DeviceContext* context, const SymbolGlyph& glyph, D2D1_POINT_2F centre, float size, float alpha) {
    SpaceIconLook look;
    look.kind = SpaceIconLook::Kind::Symbol;
    look.glyph = glyph;
    painter_->Draw(context, brush_.Get(), look, centre, size, Scale(), Label(alpha), dark_);
}

void SpaceIconPickerView::PaintFrame(ID2D1DeviceContext* context) {
    const float width = placement_.width, height = placement_.height, arrow = P::kArrowHeight, r = P::kCornerRadius;
    const float ax = placement_.arrowX, half = P::kArrowWidth / 2;
    ComPtr<ID2D1Factory> factory;
    context->GetFactory(factory.GetAddressOf());
    ComPtr<ID2D1PathGeometry> body;
    ComPtr<ID2D1GeometrySink> sink;
    if (SUCCEEDED(factory->CreatePathGeometry(body.GetAddressOf())) && SUCCEEDED(body->Open(sink.GetAddressOf()))) {
        // NSPopover's rounded body, its arrow on the top edge pointing up at the icon.
        auto arc = [&](float x, float y) {
            sink->AddArc(D2D1::ArcSegment(D2D1::Point2F(x, y), D2D1::SizeF(r, r), 0, D2D1_SWEEP_DIRECTION_CLOCKWISE, D2D1_ARC_SIZE_SMALL));
        };
        sink->BeginFigure(D2D1::Point2F(r, arrow), D2D1_FIGURE_BEGIN_FILLED);
        sink->AddLine(D2D1::Point2F(ax - half, arrow));
        sink->AddLine(D2D1::Point2F(ax, 0));
        sink->AddLine(D2D1::Point2F(ax + half, arrow));
        sink->AddLine(D2D1::Point2F(width - r, arrow));
        arc(width, arrow + r);
        sink->AddLine(D2D1::Point2F(width, height - r));
        arc(width - r, height);
        sink->AddLine(D2D1::Point2F(r, height));
        arc(0, height - r);
        sink->AddLine(D2D1::Point2F(0, arrow + r));
        arc(r, arrow);
        sink->EndFigure(D2D1_FIGURE_END_CLOSED);
        if (SUCCEEDED(sink->Close())) {
            brush_->SetColor(dark_ ? kDarkFill : kLightFill);
            context->FillGeometry(body.Get(), brush_.Get());
            // Its edge: a pixel, light in the dark and dark in the light.
            brush_->SetColor(dark_ ? D2D1_COLOR_F{1, 1, 1, 0.15f} : D2D1_COLOR_F{0, 0, 0, 0.12f});
            context->DrawGeometry(body.Get(), brush_.Get(), 2 / Scale());
        }
    }
    D2D1_MATRIX_3X2_F base{};
    context->GetTransform(&base);
    context->SetTransform(D2D1::Matrix3x2F::Translation(0, arrow) * base);
    PaintTabs(context);
    if (layout_.remove) {
        const bool held = pressed_ && pressedInside_ && pressed_->target == IconPickerHit::Target::Remove;
        const PickerRect& bin = *layout_.remove;
        PaintGlyph(context, RemoveIconGlyph(), D2D1::Point2F((bin.left + bin.right) / 2, (bin.top + bin.bottom) / 2), P::kBarSymbolSize,
                   held ? kPressedOpacity : 1);
    }
    if (state_->tab == IconPickerTab::Emoji) {
        PaintSearch(context);
        PaintCategories(context);
    } else if (state_->tab == IconPickerTab::Icon) {
        PaintSymbols(context);
    }
    context->SetTransform(base);
}

void SpaceIconPickerView::PaintTabs(ID2D1DeviceContext* context) {
    const PickerRect& tabs = layout_.tabs;
    brush_->SetColor(dark_ ? D2D1_COLOR_F{1, 1, 1, 0.1f} : D2D1_COLOR_F{0, 0, 0, 0.06f});
    context->FillRoundedRectangle(D2D1::RoundedRect(ToD2D(tabs), kTabsRadius, kTabsRadius), brush_.Get());
    for (size_t i = 0; i < layout_.segments.size() && i < tabTitles_.size(); ++i) {
        const PickerRect& segment = layout_.segments[i];
        const IconPickerTab tab = kIconPickerTabs[i];
        if (tab == state_->tab) {
            // The selected segment's knob.
            const D2D1_RECT_F knob{segment.left + kKnobInset, segment.top + kKnobInset, segment.right - kKnobInset, segment.bottom - kKnobInset};
            brush_->SetColor(dark_ ? D2D1_COLOR_F{1, 1, 1, 0.22f} : D2D1_COLOR_F{1, 1, 1, 1});
            context->FillRoundedRectangle(D2D1::RoundedRect(knob, kKnobRadius, kKnobRadius), brush_.Get());
            if (!dark_) {
                brush_->SetColor(D2D1_COLOR_F{0, 0, 0, 0.08f});
                context->DrawRoundedRectangle(D2D1::RoundedRect(knob, kKnobRadius, kKnobRadius), brush_.Get(), 1 / Scale());
            }
        } else if (i > 0 && kIconPickerTabs[i - 1] != state_->tab) {
            // A hairline between two segments neither of which is selected.
            brush_->SetColor(Label(0.2f));
            context->FillRectangle(D2D1::RectF(segment.left - 0.5f, segment.top + 5, segment.left + 0.5f, segment.bottom - 5), brush_.Get());
        }
        DWRITE_TEXT_METRICS metrics{};
        tabTitles_[i]->GetMetrics(&metrics);
        const bool held = pressed_ && pressedInside_ && pressed_->target == IconPickerHit::Target::Tab && pressed_->index == i;
        brush_->SetColor(Label(!IconPickerTabAvailable(tab) ? kDisabledOpacity : held ? 0.7f : 1));
        context->DrawTextLayout(D2D1::Point2F((segment.left + segment.right - metrics.width) / 2, (segment.top + segment.bottom - metrics.height) / 2),
                                tabTitles_[i].Get(), brush_.Get());
    }
}

void SpaceIconPickerView::PaintSearch(ID2D1DeviceContext* context) {
    const PickerRect& field = *layout_.search;
    const D2D1_RECT_F box = ToD2D(field);
    const float shade = dark_ ? kDarkTextBackground : 1.0f;
    brush_->SetColor(D2D1_COLOR_F{shade, shade, shade, 1});
    context->FillRoundedRectangle(D2D1::RoundedRect(box, kFieldRadius, kFieldRadius), brush_.Get());
    brush_->SetColor(dark_ ? D2D1_COLOR_F{1, 1, 1, 0.15f} : D2D1_COLOR_F{0, 0, 0, 0.15f});
    const float hair = 0.5f / Scale();
    context->DrawRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(box.left + hair, box.top + hair, box.right - hair, box.bottom - hair), kFieldRadius,
                                                    kFieldRadius),
                                  brush_.Get(), 1 / Scale());
    const D2D1_POINT_2F text{field.left + kFieldTextInset - search_.ScrollX(), field.top + (field.Height() - search_.LineHeight()) / 2};
    context->PushAxisAlignedClip(D2D1::RectF(field.left + 1, field.top + 1, field.right - 1, field.bottom - 1), D2D1_ANTIALIAS_MODE_ALIASED);
    if (search_.Edit().Text().empty()) {
        brush_->SetColor(Label(kPlaceholderOpacity));
        context->DrawTextLayout(D2D1::Point2F(field.left + kFieldTextInset, text.y), placeholder_.Get(), brush_.Get());
    } else if (IDWriteTextLayout* layout = search_.Layout()) {
        search_.DrawSelection(context, brush_.Get(), text, text.y, text.y + search_.LineHeight(),
                              focused_ ? (dark_ ? kDarkSelection : kLightSelection) : Label(0.15f));
        brush_->SetColor(Label(1));
        context->DrawTextLayout(text, layout, brush_.Get(), D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
    }
    context->PopAxisAlignedClip();
}

void SpaceIconPickerView::PaintCategories(ID2D1DeviceContext* context) {
    if (layout_.divider) {
        brush_->SetColor(dark_ ? D2D1_COLOR_F{1, 1, 1, 0.1f} : D2D1_COLOR_F{0, 0, 0, 0.1f});
        context->FillRectangle(ToD2D(*layout_.divider), brush_.Get());
    }
    const auto& categories = EmojiCategories();
    for (size_t i = 0; i < layout_.categories.size() && i < categories.size(); ++i) {
        const PickerRect& button = layout_.categories[i];
        const bool held = pressed_ && pressedInside_ && pressed_->target == IconPickerHit::Target::Category && pressed_->index == i;
        const float alpha = (state_->category == i ? 1 : P::kCategoryDimmed) * (held ? kPressedOpacity : 1);
        PaintGlyph(context, categories[i].glyph, D2D1::Point2F((button.left + button.right) / 2, (button.top + button.bottom) / 2),
                   P::kBarSymbolSize, alpha);
    }
}

void SpaceIconPickerView::PaintSymbols(ID2D1DeviceContext* context) {
    const Theme theme;
    for (size_t i = 0; i < cells_.size(); ++i) {
        const SpaceIconLook look = SpaceIconLookOf(cells_[i], theme);
        if (look.kind != SpaceIconLook::Kind::Symbol) continue;
        const PickerRect frame = IconPickerCellFrame(layout_, i, 0);
        const bool held = pressed_ && pressedInside_ && pressed_->target == IconPickerHit::Target::Cell && pressed_->index == i;
        // Image(systemName:).font(.system(size: 16, weight: .semibold)) in labelColor.
        painter_->Draw(context, brush_.Get(), look, D2D1::Point2F((frame.left + frame.right) / 2, (frame.top + frame.bottom) / 2), P::kSymbolSize,
                       Scale(), Label(held ? kPressedOpacity : 1), dark_);
    }
}

void SpaceIconPickerView::PaintEmoji(ID2D1DeviceContext* context, size_t first, size_t end) {
    brush_->SetColor(Label(1));
    for (size_t row = first; row < end; ++row) {
        for (size_t column = 0; column < layout_.columns; ++column) {
            const size_t index = row * layout_.columns + column;
            if (index >= cells_.size()) return;
            const PickerRect frame = IconPickerCellFrame(layout_, index, layout_.grid.top);  // the grid's own points
            const std::wstring emoji = Widen(cells_[index]);
            ComPtr<IDWriteTextLayout> layout;
            if (FAILED(dwrite_->CreateTextLayout(emoji.c_str(), static_cast<UINT32>(emoji.size()), emojiFormat_.Get(), frame.Width(), frame.Height(),
                                                 layout.GetAddressOf()))) {
                continue;
            }
            // Its ink in the middle of the cell, as the bar centres its emoji.
            DWRITE_OVERHANG_METRICS overhang{};
            float x = frame.left, y = frame.top;
            if (SUCCEEDED(layout->GetOverhangMetrics(&overhang))) {
                x += frame.Width() / 2 - (frame.Width() + overhang.right - overhang.left) / 2;
                y += frame.Height() / 2 - (frame.Height() + overhang.bottom - overhang.top) / 2;
            }
            const bool held = pressed_ && pressedInside_ && pressed_->target == IconPickerHit::Target::Cell && pressed_->index == index;
            // A colour glyph ignores the brush's alpha: a held one fades in a layer.
            if (held) context->PushLayer(D2D1::LayerParameters1(D2D1::InfiniteRect(), nullptr, D2D1_ANTIALIAS_MODE_PER_PRIMITIVE,
                                                                D2D1::IdentityMatrix(), kPressedOpacity),
                                         nullptr);
            context->DrawTextLayout(D2D1::Point2F(x, y), layout.Get(), brush_.Get(), D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
            if (held) context->PopLayer();
        }
    }
}

void SpaceIconPickerView::PaintAll(ID2D1DeviceContext* context) {
    PaintFrame(context);
    if (state_->tab != IconPickerTab::Emoji) return;
    const PickerRect& grid = layout_.grid;
    const float top = P::kArrowHeight + grid.top;
    context->PushAxisAlignedClip(D2D1::RectF(grid.left, top, grid.right, top + grid.Height()), D2D1_ANTIALIAS_MODE_ALIASED);
    D2D1_MATRIX_3X2_F base{};
    context->GetTransform(&base);
    const float scroll = std::round(state_->scroll * Scale()) / Scale();
    context->SetTransform(D2D1::Matrix3x2F::Translation(0, top - scroll) * base);
    const auto [first, end] = IconPickerVisibleRows(layout_, cells_.size(), state_->scroll);
    PaintEmoji(context, first, end);
    context->SetTransform(base);
    context->PopAxisAlignedClip();
}

std::wstring SpaceIconPickerView::Redraw() {
    if (!state_ || !compositor_) return {};
    HRESULT hr = S_OK;
    if (!MakeTree(hr)) return Fail(L"building the icon picker's composition", hr);
    const float scale = Scale();
    const UINT width = static_cast<UINT>(std::ceil(placement_.width * scale));
    const UINT height = static_cast<UINT>(std::ceil(placement_.height * scale));
    if (!frameSurface_) {
        if (FAILED(hr = compositor_->Device()->CreateVirtualSurface(width, height, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED,
                                                                     frameSurface_.GetAddressOf())) ||
            FAILED(hr = frame_->SetContent(frameSurface_.Get()))) {
            frameSurface_.Reset();
            return Fail(L"creating the icon picker's surface", hr);
        }
        frameDirty_ = true;
    } else if (width != frameWidth_ || height != frameHeight_) {
        if (FAILED(hr = frameSurface_->Resize(width, height))) return Fail(L"resizing the icon picker's surface", hr);
        frameDirty_ = true;
    }
    const bool resized = width != frameWidth_ || height != frameHeight_;
    frameWidth_ = width;
    frameHeight_ = height;
    const auto paint = [this](ID2D1DeviceContext* context) { PaintFrame(context); };
    if (frameDirty_) {
        if (std::wstring error = compositor_->DrawSurface(frameSurface_.Get(), width, height, dpi_, paint, nullptr, hr); !error.empty()) {
            deviceLost_ = IsDeviceLost(hr);
            return error;
        }
        ++draws_;
    } else {
        for (const RECT& part : frameParts_) {
            if (std::wstring error = compositor_->DrawSurfaceRect(frameSurface_.Get(), part, dpi_, paint, hr); !error.empty()) {
                deviceLost_ = IsDeviceLost(hr);
                return error;
            }
            ++draws_;
        }
    }
    frameDirty_ = false;
    frameParts_.clear();
    if (std::wstring error = DrawGridRows(hr); !error.empty()) {
        deviceLost_ = IsDeviceLost(hr);
        return error;
    }
    PlaceGrid();
    UpdateCaret();
    if (FAILED(hr = compositor_->Commit())) return Fail(L"showing the icon picker", hr);
    // The tab's frame is another size: the window follows, after the commit that draws it.
    if (resized && IsWindowVisible(window_)) PlaceWindow();
    return {};
}

std::wstring SpaceIconPickerView::DrawGridRows(HRESULT& hr) {
    hr = S_OK;
    if (state_->tab != IconPickerTab::Emoji) {
        if (gridClip_) root_->RemoveVisual(gridClip_.Get());
        gridPart_.reset();
        return {};
    }
    const float scale = Scale();
    const size_t rows = IconPickerRows(cells_.size(), layout_.columns);
    const auto rowTop = [&](size_t row) { return static_cast<LONG>(std::floor(static_cast<float>(row) * P::kRowPitch * scale)); };
    const UINT width = static_cast<UINT>(std::ceil(layout_.width * scale));
    const UINT height = std::max<UINT>(1, static_cast<UINT>(rowTop(rows)));
    if (rowsDrawn_.size() != rows) {
        // New cells (or the first draw): every row's pixels go, and the grid is as tall as its rows.
        rowsDrawn_.assign(rows, false);
        if (gridSurface_ && FAILED(hr = gridSurface_->Trim(nullptr, 0))) return HResultMessage(L"clearing the emoji grid", hr);
    }
    if (!gridSurface_) {
        if (FAILED(hr = compositor_->Device()->CreateVirtualSurface(width, height, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED,
                                                                     gridSurface_.GetAddressOf())) ||
            FAILED(hr = grid_->SetContent(gridSurface_.Get()))) {
            gridSurface_.Reset();
            return HResultMessage(L"creating the emoji grid's surface", hr);
        }
        // A new surface holds nothing yet.
        rowsDrawn_.assign(rows, false);
    } else if (width != gridWidth_ || height != gridHeight_) {
        if (FAILED(hr = gridSurface_->Resize(width, height))) return HResultMessage(L"resizing the emoji grid's surface", hr);
    }
    gridWidth_ = width;
    gridHeight_ = height;
    // Only the rows in view that aren't drawn yet, in runs.
    const auto [first, end] = IconPickerVisibleRows(layout_, cells_.size(), state_->scroll);
    for (size_t row = first; row < end;) {
        if (rowsDrawn_[row]) {
            ++row;
            continue;
        }
        size_t last = row;
        while (last < end && !rowsDrawn_[last]) ++last;
        const RECT rect{0, rowTop(row), static_cast<LONG>(width), std::min(rowTop(last), static_cast<LONG>(height))};
        const size_t from = row, to = last;
        if (std::wstring error = compositor_->DrawSurfaceRect(
                gridSurface_.Get(), rect, dpi_, [&](ID2D1DeviceContext* context) { PaintEmoji(context, from, to); }, hr);
            !error.empty()) {
            return error;
        }
        ++draws_;
        for (size_t r = from; r < to; ++r) rowsDrawn_[r] = true;
        row = last;
    }
    // A held cell alone.
    if (gridPart_) {
        const size_t index = *gridPart_, row = index / layout_.columns;
        gridPart_.reset();
        if (row < rows && rowsDrawn_[row]) {
            const PickerRect frame = IconPickerCellFrame(layout_, index, layout_.grid.top);
            const RECT rect{std::lround(std::floor(frame.left * scale)), rowTop(row), std::lround(std::ceil(frame.right * scale)), rowTop(row + 1)};
            if (std::wstring error = compositor_->DrawSurfaceRect(
                    gridSurface_.Get(), rect, dpi_, [&](ID2D1DeviceContext* context) { PaintEmoji(context, row, row + 1); }, hr);
                !error.empty()) {
                return error;
            }
            ++draws_;
        }
    }
    // Rows far from view are let go, so scrolling the whole catalog keeps a screenful or so.
    const size_t keepFrom = first > kKeptRows ? first - kKeptRows : 0, keepTo = std::min(rows, end + kKeptRows);
    bool outside = false;
    for (size_t r = 0; r < rows; ++r) outside = outside || (rowsDrawn_[r] && (r < keepFrom || r >= keepTo));
    if (outside) {
        const RECT keep{0, rowTop(keepFrom), static_cast<LONG>(width), std::min(rowTop(keepTo), static_cast<LONG>(height))};
        if (FAILED(hr = gridSurface_->Trim(&keep, 1))) return HResultMessage(L"trimming the emoji grid", hr);
        for (size_t r = 0; r < rows; ++r) {
            if (r < keepFrom || r >= keepTo) rowsDrawn_[r] = false;
        }
    }
    return {};
}

void SpaceIconPickerView::PlaceGrid() {
    if (!gridClip_ || state_->tab != IconPickerTab::Emoji) return;
    const float scale = Scale();
    const float top = std::round((P::kArrowHeight + layout_.grid.top) * scale);
    gridClip_->SetOffsetY(top);
    gridClip_->SetClip(D2D1::RectF(0, 0, static_cast<float>(frameWidth_), std::round(layout_.grid.Height() * scale)));
    grid_->SetOffsetY(-std::round(state_->scroll * scale));
    // Over the frame, under the caret.
    root_->RemoveVisual(gridClip_.Get());
    root_->AddVisual(gridClip_.Get(), TRUE, frame_.Get());
}

void SpaceIconPickerView::UpdateCaret() {
    if (!compositor_ || !root_ || !state_) return;
    const float scale = Scale();
    bool wanted = false;
    POINT at{};
    UINT height = 1;
    if (layout_.search) {
        const PickerRect& field = *layout_.search;
        const float x = field.left + kFieldTextInset - search_.ScrollX() + search_.CaretX();
        const float top = P::kArrowHeight + field.top + (field.Height() - search_.LineHeight()) / 2;
        wanted = focused_ && search_.CaretOn() && !search_.Edit().HasSelection() && x >= field.left && x <= field.right;
        const UINT width = static_cast<UINT>(std::max(1L, std::lround(scale)));
        height = static_cast<UINT>(std::max(1L, std::lround(search_.LineHeight() * scale)));
        at = POINT{std::lround(x * scale) - static_cast<LONG>(width) / 2, std::lround(top * scale)};
        if (const HRESULT hr = caret_.Update(compositor_->Device(), compositor_->D2D(), root_.Get(), wanted, at, width, height, Label(1)); FAILED(hr)) {
            deviceLost_ = IsDeviceLost(hr);
        }
        return;
    }
    caret_.Update(compositor_->Device(), compositor_->D2D(), root_.Get(), false, at, 1, height, Label(1));
}

std::wstring SpaceIconPickerView::Render(Pixels& out, POINT& origin) {
    if (!state_ || !compositor_) return L"the icon picker isn't open";
    const float scale = Scale();
    const IconPickerPlacement placement = Placement(true);
    POINT client{0, 0};
    ClientToScreen(owner_, &client);
    origin = POINT{std::lround(placement.left * scale) - client.x, std::lround(placement.top * scale) - client.y};
    const IconPickerPlacement shown = placement_;
    placement_ = placement;
    const UINT width = static_cast<UINT>(std::ceil(placement.width * scale)), height = static_cast<UINT>(std::ceil(placement.height * scale));
    HRESULT hr = S_OK;
    ComPtr<IDCompositionVirtualSurface> surface;
    std::wstring error;
    if (!brush_ && FAILED(hr = compositor_->D2D()->CreateSolidColorBrush(D2D1_COLOR_F{1, 1, 1, 1}, brush_.GetAddressOf()))) {
        error = HResultMessage(L"the icon picker's brush", hr);
    } else if (FAILED(hr = compositor_->Device()->CreateVirtualSurface(width, height, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED,
                                                                        surface.GetAddressOf()))) {
        error = HResultMessage(L"creating the icon picker's surface", hr);
    } else {
        error = compositor_->DrawSurface(surface.Get(), width, height, dpi_, [this](ID2D1DeviceContext* context) { PaintAll(context); }, &out, hr);
    }
    placement_ = shown;
    return error;
}

// MARK: Input

void SpaceIconPickerView::Press(D2D1_POINT_2F p) {
    if (!state_) return;
    const IconPickerHit hit = IconPickerHitTest(layout_, *state_, cells_.size(), p.x, p.y);
    if (hit.target == IconPickerHit::Target::Search) {
        selecting_ = true;
        const bool shift = GetKeyState(VK_SHIFT) < 0;
        QueryEdited(search_.Edit().Select(search_.IndexAt(p.x - layout_.search->left - kFieldTextInset), shift));
        return;
    }
    if (hit.target == IconPickerHit::Target::None) return;
    pressed_ = hit;
    pressedInside_ = true;
    PressChanged();
}

void SpaceIconPickerView::Move(D2D1_POINT_2F p) {
    if (!state_) return;
    if (selecting_ && layout_.search) {
        const size_t at = search_.IndexAt(p.x - layout_.search->left - kFieldTextInset);
        if (at != search_.Edit().Caret()) QueryEdited(search_.Edit().Select(at, true));
        return;
    }
    // Only a held button changes as the pointer moves (it dims while over itself); hover draws nothing.
    if (!pressed_) return;
    const bool inside = IconPickerHitTest(layout_, *state_, cells_.size(), p.x, p.y) == *pressed_;
    if (inside == pressedInside_) return;
    pressedInside_ = inside;
    PressChanged();
}

void SpaceIconPickerView::Release(D2D1_POINT_2F p) {
    selecting_ = false;
    if (!state_ || !pressed_) return;
    const IconPickerHit pressed = *pressed_;
    const bool inside = IconPickerHitTest(layout_, *state_, cells_.size(), p.x, p.y) == pressed;
    pressedInside_ = false;
    PressChanged();
    pressed_.reset();
    if (!inside) return;
    // A button acts when let go over itself.
    switch (pressed.target) {
    case IconPickerHit::Target::Tab: SetTab(kIconPickerTabs[pressed.index]); break;
    case IconPickerHit::Target::Remove: Pick(""); break;
    case IconPickerHit::Target::Cell:
        if (pressed.index < cells_.size()) Pick(cells_[pressed.index]);
        break;
    case IconPickerHit::Target::Category: SetCategory(pressed.index); break;
    case IconPickerHit::Target::Search:
    case IconPickerHit::Target::None: break;
    }
}

void SpaceIconPickerView::PressChanged() {
    if (!state_ || !pressed_) {
        if (state_) Redraw();
        return;
    }
    const float scale = Scale();
    auto framePart = [&](const PickerRect& r) {
        frameParts_.push_back(RECT{std::lround(std::floor(r.left * scale)), std::lround(std::floor((r.top + P::kArrowHeight) * scale)),
                                   std::lround(std::ceil(r.right * scale)), std::lround(std::ceil((r.bottom + P::kArrowHeight) * scale))});
    };
    switch (pressed_->target) {
    case IconPickerHit::Target::Tab: framePart(layout_.segments[pressed_->index]); break;
    case IconPickerHit::Target::Remove: framePart(*layout_.remove); break;
    case IconPickerHit::Target::Category: framePart(layout_.categories[pressed_->index]); break;
    case IconPickerHit::Target::Cell:
        if (state_->tab == IconPickerTab::Emoji) gridPart_ = pressed_->index;
        else framePart(IconPickerCellFrame(layout_, pressed_->index, 0));
        break;
    case IconPickerHit::Target::Search:
    case IconPickerHit::Target::None: break;
    }
    if (std::wstring problem = Redraw(); !problem.empty()) OutputDebugStringW((L"Kite: the icon picker couldn't draw: " + problem + L"\n").c_str());
}

void SpaceIconPickerView::SetTab(IconPickerTab tab) {
    if (!state_ || tab == state_->tab) return;
    SelectIconPickerTab(*state_, tab);
    search_.RestartBlink(focused_ && state_->tab == IconPickerTab::Emoji);
    Relayout();
    frameDirty_ = true;
    if (std::wstring problem = Redraw(); !problem.empty()) OutputDebugStringW((L"Kite: the icon picker couldn't draw: " + problem + L"\n").c_str());
}

void SpaceIconPickerView::SetCategory(size_t category) {
    if (!state_) return;
    const std::string query = state_->query;
    SelectIconPickerCategory(*state_, category);
    if (!query.empty()) {
        // Search cleared with it.
        search_.Edit().SetText(L"", 0, 0);
        search_.Relayout();
    }
    Relayout();
    frameDirty_ = true;  // the bar's light and the field
    if (std::wstring problem = Redraw(); !problem.empty()) OutputDebugStringW((L"Kite: the icon picker couldn't draw: " + problem + L"\n").c_str());
}

void SpaceIconPickerView::QueryEdited(TextEditing::Change change) {
    if (!state_ || change == TextEditing::Change::None) return;
    if (change == TextEditing::Change::Text) {
        search_.Relayout();
        SetIconPickerQuery(*state_, Narrow(search_.Edit().Text()));
        Relayout();
    } else {
        search_.KeepCaretVisible();
    }
    search_.RestartBlink(focused_);
    // The field alone; the grid's rows draw again only for new cells.
    if (layout_.search) {
        const float scale = Scale();
        const PickerRect& r = *layout_.search;
        frameParts_.push_back(RECT{std::lround(std::floor(r.left * scale)), std::lround(std::floor((r.top + P::kArrowHeight) * scale)),
                                   std::lround(std::ceil(r.right * scale)), std::lround(std::ceil((r.bottom + P::kArrowHeight) * scale))});
    }
    if (std::wstring problem = Redraw(); !problem.empty()) OutputDebugStringW((L"Kite: the icon picker couldn't draw: " + problem + L"\n").c_str());
}

void SpaceIconPickerView::Scrolled() {
    if (std::wstring problem = Redraw(); !problem.empty()) OutputDebugStringW((L"Kite: the icon picker couldn't draw: " + problem + L"\n").c_str());
}

void SpaceIconPickerView::Pick(const std::string& icon) {
    if (!state_ || !callbacks_.pick) return;
    const std::string spaceID = state_->spaceID;
    callbacks_.pick(spaceID, icon);
}

void SpaceIconPickerView::Type(std::string_view text) {
    if (!state_ || state_->tab != IconPickerTab::Emoji) return;
    TextEditing::Change change = TextEditing::Change::None;
    for (const wchar_t c : Widen(text)) {
        if (search_.Edit().Character(c) == TextEditing::Change::Text) change = TextEditing::Change::Text;
    }
    QueryEdited(change);
}

bool SpaceIconPickerView::HandleKey(UINT message, WPARAM wParam, LPARAM) {
    if (!state_) return false;
    const bool searching = state_->tab == IconPickerTab::Emoji;
    switch (message) {
    case WM_KEYDOWN: {
        // Escape closes it, as a transient popover's cancelOperation.
        if (wParam == VK_ESCAPE) {
            Close();
            return true;
        }
        if (!searching) return false;
        const bool alt = GetKeyState(VK_MENU) < 0;
        const bool ctrl = GetKeyState(VK_CONTROL) < 0 && !alt;
        const bool shift = GetKeyState(VK_SHIFT) < 0;
        const std::optional<TextEditing::Change> change = search_.Edit().KeyDown(static_cast<UINT>(wParam), ctrl, shift);
        if (!change) return wParam == VK_RETURN;  // the field takes Return and does nothing with it
        QueryEdited(*change);
        return true;
    }
    case WM_CHAR:
        if (!searching) return false;
        QueryEdited(search_.Edit().Character(static_cast<wchar_t>(wParam)));
        return true;
    case WM_IME_STARTCOMPOSITION: {
        if (!searching || !layout_.search) return false;
        const float scale = Scale();
        const PickerRect& field = *layout_.search;
        POINT caret{std::lround((field.left + kFieldTextInset - search_.ScrollX() + search_.CaretX()) * scale),
                    std::lround((P::kArrowHeight + field.top + (field.Height() - search_.LineHeight()) / 2) * scale)};
        ClientToScreen(window_, &caret);
        ScreenToClient(owner_, &caret);
        search_.PlaceIme(caret, std::lround(search_.LineHeight() * scale));
        return false;
    }
    case WM_SETFOCUS:
        focused_ = true;
        search_.RestartBlink(searching);
        if (layout_.search) QueryEdited(TextEditing::Change::Selection);
        return false;
    case WM_KILLFOCUS:
        // The page taking the keyboard is a click outside the popover: it closes. Another app's
        // comes with the browser window's deactivation, which closes it too.
        if (wParam && IsChild(owner_, reinterpret_cast<HWND>(wParam))) {
            Close();
            return false;
        }
        focused_ = false;
        search_.StopBlink();
        if (layout_.search) QueryEdited(TextEditing::Change::Selection);
        return false;
    default: return false;
    }
}

bool SpaceIconPickerView::HandleTimer(WPARAM timer) {
    if (!search_.HandleTimer(timer)) return false;
    UpdateCaret();
    if (compositor_) compositor_->Commit();
    return true;
}

bool SpaceIconPickerView::HandleWheel(WPARAM wParam, LPARAM lParam) {
    if (!state_ || !window_) return false;
    POINT at{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};
    RECT bounds{};
    GetWindowRect(window_, &bounds);
    if (!PtInRect(&bounds, at)) return false;
    ScreenToClient(window_, &at);
    const D2D1_POINT_2F p = ToContent(at);
    if (state_->tab == IconPickerTab::Emoji && layout_.grid.Contains(p.x, p.y)) {
        UINT lines = 3;
        SystemParametersInfoW(SPI_GETWHEELSCROLLLINES, 0, &lines, 0);
        const float notches = -static_cast<float>(GET_WHEEL_DELTA_WPARAM(wParam)) / WHEEL_DELTA;
        const float before = state_->scroll;
        ScrollIconPicker(*state_, notches * kWheelLine * static_cast<float>(lines == WHEEL_PAGESCROLL ? 3 : lines));
        if (state_->scroll != before) Scrolled();
    }
    return true;  // over the picker, whatever it hit: not the sidebar's
}

}  // namespace kite
