// See SpaceCreationView.h. Ports KiteMac/Views/SpaceCreationView.swift (SpaceCreationView, its
// Illustration, ProfilePill and ChooseThemeRow) with ArcMetrics.SpaceCreation.

#include "shell/SpaceCreationView.h"

#include <dwrite_3.h>

#include <algorithm>
#include <cmath>

#include "shell/Errors.h"
#include "shell/Text.h"

using Microsoft::WRL::ComPtr;

namespace kite {

namespace {

namespace M = space_creation_metrics;

// NSColor.labelColor: black or white at 85%; SwiftUI's .primary, which the page's text takes.
constexpr float kLabelAlpha = 0.85f;
// placeholderTextColor, as the rename field's.
constexpr float kPlaceholderOpacity = 0.25f;
// SF Pro's ascender and descender, of the size: where SwiftUI puts a line's baseline in its box.
constexpr float kAscender = 0.952f, kDescender = 0.241f;
// The caret and the selection, as the find field's (the Mac's insertion point and
// selectedTextBackgroundColor), the selection grey while the window doesn't have the keyboard.
constexpr D2D1_COLOR_F kCaret{0x11 / 255.0f, 0x7A / 255.0f, 0xFD / 255.0f, 1};
constexpr D2D1_COLOR_F kDarkSelection{63 / 255.0f, 99 / 255.0f, 139 / 255.0f, 1};
constexpr D2D1_COLOR_F kLightSelection{179 / 255.0f, 215 / 255.0f, 1, 1};

// The SF Symbols the page shows, in Segoe Fluent Icons (Windows 11) and Segoe MDL2 Assets
// (Windows 10), which share these code points: text.bubble, face.smiling, info.circle,
// paintbrush.pointed.fill and chevron.down; the cards' leaf.fill (core/SpaceIcon's stand-in),
// books.vertical.fill (book.fill's) and laptopcomputer. plus.square.dashed has none: it's drawn.
constexpr wchar_t kTextBubble = 0xE8BD;
constexpr wchar_t kFaceSmiling = 0xE76E;
constexpr wchar_t kInfoCircle = 0xE946;
constexpr wchar_t kPaintbrush = 0xE771;
constexpr wchar_t kChevronDown = 0xE70D;
constexpr wchar_t kLeaf = 0xE8BE;
constexpr wchar_t kBooks = 0xE82D;
constexpr wchar_t kLaptop = 0xE7F8;
// The icon font's em, which Glyph scales to the Mac's point size: Segoe's glyphs fill about 90%
// of it, as an SF Symbol fills its point size (SidebarView's kGlyphInk).
constexpr float kIconEm = 16;
constexpr float kGlyphInk = 0.9f;
// chevron.down at 9pt bold is about 8pt wide.
constexpr float kChevronWidth = 8;

D2D1_COLOR_F Srgb(uint32_t hex, float alpha = 1) {
    return D2D1_COLOR_F{static_cast<float>((hex >> 16) & 0xFF) / 255.0f, static_cast<float>((hex >> 8) & 0xFF) / 255.0f,
                        static_cast<float>(hex & 0xFF) / 255.0f, alpha};
}

D2D1_RECT_F RectOf(const BarRect& r) { return D2D1::RectF(r.left, r.top, r.right, r.bottom); }

// The system colours the cards' symbols take (.green, .orange, .gray), in each appearance.
D2D1_COLOR_F Green(bool dark) { return Srgb(dark ? 0x30D158 : 0x34C759); }
D2D1_COLOR_F Orange(bool dark) { return Srgb(dark ? 0xFF9F0A : 0xFF9500); }
D2D1_COLOR_F Gray(bool dark) { return Srgb(dark ? 0x98989D : 0x8E8E93); }

}  // namespace

std::unique_ptr<SpaceCreationView> SpaceCreationView::Create(HWND window, IDWriteFactory* dwrite, std::wstring& error) {
    std::unique_ptr<SpaceCreationView> view(new SpaceCreationView(window, dwrite));
    // SF Pro's stand-in, as the sidebar's: Segoe UI Variable on Windows 11, Segoe UI before it.
    ComPtr<IDWriteFontCollection> fonts;
    dwrite->GetSystemFontCollection(fonts.GetAddressOf());
    auto installed = [&](const wchar_t* family) {
        UINT32 index = 0;
        BOOL exists = FALSE;
        return fonts && SUCCEEDED(fonts->FindFamilyName(family, &index, &exists)) && exists;
    };
    view->textFamily_ = installed(L"Segoe UI Variable Text") ? L"Segoe UI Variable Text" : L"Segoe UI";
    const wchar_t* icons = installed(L"Segoe Fluent Icons") ? L"Segoe Fluent Icons" : L"Segoe MDL2 Assets";
    auto format = [&](const wchar_t* family, DWRITE_FONT_WEIGHT weight, float size, ComPtr<IDWriteTextFormat>& out) {
        HRESULT made = dwrite->CreateTextFormat(family, nullptr, weight, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, size, L"",
                                                out.GetAddressOf());
        if (SUCCEEDED(made)) made = out->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        return made;
    };
    const wchar_t* text = view->textFamily_.c_str();
    HRESULT hr = S_OK;
    if (FAILED(hr = format(text, DWRITE_FONT_WEIGHT_BOLD, M::kTitleFontSize, view->titleFormat_)) ||
        FAILED(hr = format(text, DWRITE_FONT_WEIGHT_REGULAR, M::kSubtitleFontSize, view->subtitleFormat_)) ||
        FAILED(hr = format(text, DWRITE_FONT_WEIGHT_REGULAR, M::kRowFontSize, view->rowFormat_)) ||
        FAILED(hr = format(text, DWRITE_FONT_WEIGHT_SEMI_BOLD, M::kRowFontSize, view->rowBoldFormat_)) ||
        FAILED(hr = format(text, DWRITE_FONT_WEIGHT_SEMI_BOLD, M::kPillFontSize, view->pillFormat_)) ||
        FAILED(hr = format(text, DWRITE_FONT_WEIGHT_MEDIUM, M::kCancelFontSize, view->cancelFormat_)) ||
        FAILED(hr = format(icons, DWRITE_FONT_WEIGHT_REGULAR, kIconEm, view->iconFormat_))) {
        error = HResultMessage(L"CreateTextFormat", hr);
        return nullptr;
    }
    // Segoe UI Variable has no Medium instance: its weight axis gives Cancel's 500.
    if (view->textFamily_ == L"Segoe UI Variable Text") {
        const DWRITE_FONT_AXIS_VALUE medium{DWRITE_FONT_AXIS_TAG_WEIGHT, 500};
        ComPtr<IDWriteTextFormat3> variable;
        if (SUCCEEDED(view->cancelFormat_->QueryInterface(IID_PPV_ARGS(variable.GetAddressOf())))) variable->SetFontAxisValues(&medium, 1);
    }
    view->iconFormat_->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
    view->iconFormat_->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    view->name_.SetFormat(dwrite, view->rowFormat_.Get(), Widen(M::kNamePlaceholder));
    view->about_.SetFormat(dwrite, view->rowFormat_.Get(), Widen(M::kAboutPlaceholder));
    view->Measure();
    view->PlaceFields();
    return view;
}

SpaceCreationView::~SpaceCreationView() { ReleaseGpu(); }

void SpaceCreationView::ReleaseGpu() {
    name_.ReleaseCaret();
    about_.ReleaseCaret();
    for (IDCompositionVisual* visual : {visual_.Get(), createVisual_.Get(), nameGpu_.visual.Get(), aboutGpu_.visual.Get()}) {
        if (!visual) continue;
        visual->SetContent(nullptr);
        if (parent_) parent_->RemoveVisual(visual);
    }
    visual_.Reset();
    createVisual_.Reset();
    surface_.Reset();
    createSurface_.Reset();
    nameGpu_ = FieldGpu{};
    aboutGpu_ = FieldGpu{};
    brush_.Reset();
    surfaceWidth_ = surfaceHeight_ = createWidth_ = createHeight_ = 0;
    dirty_ = createDirty_ = true;
    placed_ = false;
}

void SpaceCreationView::UseCompositor(Compositor* compositor, IDCompositionVisual* parent) {
    ReleaseGpu();
    compositor_ = compositor;
    parent_ = parent;
    deviceLost_ = false;
}

void SpaceCreationView::Layout(float width, float height, UINT dpi) {
    if (width == width_ && height == height_ && dpi == dpi_) return;
    width_ = width;
    height_ = height;
    dpi_ = dpi;
    layout_ = LayOutSpaceCreation(width_, height_);
    Measure();
    PlaceFields();
    dirty_ = createDirty_ = true;
    nameGpu_.dirty = aboutGpu_.dirty = true;
    placed_ = false;
}

void SpaceCreationView::SetLeft(float left) {
    if (left == left_) return;
    left_ = left;
    PlaceFields();
}

void SpaceCreationView::PlaceFields() {
    const float scale = Scale();
    for (Field field : {Field::Name, Field::About}) {
        const BarRect& box = BoxOf(field);
        // The field's coordinates are its own surface's, whose top-left is the box's on the pixel grid.
        const POINT origin{std::lround((left_ + box.left) * scale), std::lround(box.top * scale)};
        FieldOf(field).Place(0, box.Width(), 0, box.Height(), origin, scale);
    }
}

float SpaceCreationView::Width(std::string_view text, IDWriteTextFormat* format) const {
    const std::wstring wide = Widen(text);
    ComPtr<IDWriteTextLayout> layout;
    DWRITE_TEXT_METRICS metrics{};
    if (FAILED(dwrite_->CreateTextLayout(wide.c_str(), static_cast<UINT32>(wide.size()), format, 100000, 100, layout.GetAddressOf())) ||
        FAILED(layout->GetMetrics(&metrics))) {
        return 0;
    }
    return metrics.widthIncludingTrailingWhitespace;
}

void SpaceCreationView::Measure() {
    // ProfilePill: after "Profile" (the row's HStack spacing), its name and chevron 4pt apart,
    // 10pt in from its ends, 24pt tall in the row's middle.
    const BarRect& row = layout_.profile;
    const float left = M::kRowTextX + Width(M::kProfileTitle, rowBoldFormat_.Get()) + M::kRowSpacing;
    const float width = M::kPillPadding + Width(model_.profile, pillFormat_.Get()) + M::kPillGap + kChevronWidth + M::kPillPadding;
    const float middle = (row.top + row.bottom) / 2;
    pill_ = BarRect{left, middle - M::kPillHeight / 2, left + width, middle + M::kPillHeight / 2};
    cancelWidth_ = Width(M::kCancelTitle, cancelFormat_.Get());
}

// MARK: Showing

void SpaceCreationView::Show(const Model& model) {
    if (shown_) {
        if (model == model_) return;
        const bool dark = model.dark != model_.dark;
        model_ = model;
        Measure();
        dirty_ = true;
        if (dark) createDirty_ = nameGpu_.dirty = aboutGpu_.dirty = true;
        return;
    }
    // onAppear: a new page, its fields empty (the Mac's @State), the name about to take the keyboard.
    shown_ = true;
    model_ = model;
    windowFocused_ = GetFocus() == window_;
    keyboard_.reset();
    pressed_.reset();
    selecting_.reset();
    name_.SetText(L"", false);
    about_.SetText(L"", false);
    canCreate_ = false;
    Measure();
    dirty_ = createDirty_ = nameGpu_.dirty = aboutGpu_.dirty = true;
    placed_ = false;
}

void SpaceCreationView::Hide() {
    if (!shown_) return;
    LoseKeyboard();
    shown_ = false;
    pressed_.reset();
    selecting_.reset();
    if (GetCapture() == window_) ReleaseCapture();
    name_.SetText(L"", false);
    about_.SetText(L"", false);
    // Its visuals go until it opens again (the caller's pass commits).
    ReleaseGpu();
}

// MARK: The keyboard

void SpaceCreationView::Focus(Field field, bool selectAll) {
    if (!shown_) return;
    if (keyboard_ && *keyboard_ != field) FieldOf(*keyboard_).EndEditing();
    if (keyboard_ != field) GpuOf(field == Field::Name ? Field::About : Field::Name).dirty = true;
    keyboard_ = field;
    if (selectAll) FieldOf(field).SelectAll();
    FocusChanged();
    GpuOf(field).dirty = true;
}

void SpaceCreationView::LoseKeyboard() {
    if (!keyboard_) return;
    const Field had = *keyboard_;
    keyboard_.reset();
    selecting_.reset();
    // The Mac's field editor goes: no selection shown, nothing left to undo.
    FieldOf(had).EndEditing();
    FocusChanged();
    GpuOf(had).dirty = true;
}

void SpaceCreationView::FocusChanged() {
    const bool window = windowFocused_;
    const bool name = shown_ && keyboard_ == Field::Name && window;
    const bool about = shown_ && keyboard_ == Field::About && window;
    // The field losing the keyboard first: a thread has one system caret, and the loser's
    // DestroyCaret would take the gainer's with it.
    if (!name) name_.SetFocused(false);
    if (!about) about_.SetFocused(false);
    if (name) name_.SetFocused(true);
    if (about) about_.SetFocused(true);
}

void SpaceCreationView::Redraw() {
    if (!compositor_) return;
    if (std::wstring problem = Draw(); !problem.empty()) {
        OutputDebugStringW((L"Kite: Create a Space couldn't draw: " + problem + L"\n").c_str());
        if (callbacks_.drawFailed) callbacks_.drawFailed();
        return;
    }
    compositor_->Commit();
}

bool SpaceCreationView::CanCreate() const { return CanCreateSpace(Narrow(name_.Text())); }

std::string SpaceCreationView::Text(Field field) const { return Narrow(FieldOf(field).Text()); }

void SpaceCreationView::Type(Field field, std::string_view text) {
    if (!shown_) return;
    Edited(field, FieldOf(field).Type(Widen(text)));
}

void SpaceCreationView::Edited(Field field, TextField::Change change) {
    if (change == TextField::Change::None) return;
    GpuOf(field).dirty = true;
    // Create Space turns on with a name and off without one: it alone draws again then.
    if (CanCreate() != canCreate_) createDirty_ = true;
    // At once, as the field's own redraw: the page and the other field stay as they are.
    Redraw();
}

void SpaceCreationView::Submit() {
    // Return and Create Space alike: only with a name (Create Space's canCreate guard).
    if (!CanCreate() || !callbacks_.create) return;
    callbacks_.create(Text(Field::Name), Text(Field::About));
}

LOGFONTW SpaceCreationView::FieldFont() const {
    LOGFONTW font{};
    font.lfHeight = -std::lround(M::kRowFontSize * Scale());
    font.lfWeight = FW_NORMAL;
    font.lfCharSet = DEFAULT_CHARSET;
    lstrcpynW(font.lfFaceName, textFamily_.c_str(), LF_FACESIZE);
    return font;
}

bool SpaceCreationView::HandleKey(UINT message, WPARAM wParam, LPARAM lParam) {
    if (!shown_) return false;
    switch (message) {
    case WM_KEYDOWN: {
        if (!keyboard_) return false;
        // AltGr is Ctrl+Alt: its characters come as WM_CHAR, never as a Ctrl key.
        const bool alt = GetKeyState(VK_MENU) < 0;
        const bool ctrl = GetKeyState(VK_CONTROL) < 0 && !alt;
        const bool shift = GetKeyState(VK_SHIFT) < 0;
        const auto key = static_cast<UINT>(wParam);
        const Field field = *keyboard_;
        if (key == VK_RETURN) {
            // Either field's onSubmit: create.
            Submit();
            return true;
        }
        if (key == VK_ESCAPE) {
            // The page's onExitCommand.
            if (callbacks_.cancel) callbacks_.cancel();
            return true;
        }
        if (key == VK_TAB && !ctrl && !alt) {
            // The key view loop between the two fields; the one tabbed into has its text selected.
            Focus(field == Field::Name ? Field::About : Field::Name, true);
            Redraw();
            return true;
        }
        const std::optional<TextField::Change> change = FieldOf(field).KeyDown(key, ctrl, shift);
        if (!change) return false;
        Edited(field, *change);
        return true;
    }
    case WM_CHAR:
        if (!keyboard_) return false;
        // Return, Escape and Tab were their keys' (above).
        if (wParam == L'\r' || wParam == L'\t' || wParam == 0x1B) return true;
        Edited(*keyboard_, FieldOf(*keyboard_).Character(static_cast<wchar_t>(wParam)));
        return true;
    case WM_IME_STARTCOMPOSITION:
        if (!keyboard_) return false;
        {
            const LOGFONTW font = FieldFont();
            FieldOf(*keyboard_).CompositionStarted(&font);
        }
        Edited(*keyboard_, TextField::Change::Selection);  // the placeholder goes under marked text
        return false;  // Windows' composition window draws it; the result comes as WM_CHAR
    case WM_IME_ENDCOMPOSITION:
        if (!keyboard_ || !FieldOf(*keyboard_).Composing()) return false;
        FieldOf(*keyboard_).CompositionEnded();
        Edited(*keyboard_, TextField::Change::Selection);
        return false;
    case WM_SETFOCUS:
        windowFocused_ = true;
        FocusChanged();
        nameGpu_.dirty = aboutGpu_.dirty = true;
        Redraw();
        return false;
    case WM_KILLFOCUS:
        // The page took it (a click in it): the field lets it go, as the web view becoming first
        // responder ends the Mac's field editor. Another app, or a window of Kite's own (the
        // swatches, the tip), leaves it the first responder.
        windowFocused_ = false;
        if (const auto to = reinterpret_cast<HWND>(wParam); to && IsChild(window_, to)) LoseKeyboard();
        if (selecting_ && GetCapture() == window_) ReleaseCapture();
        FocusChanged();
        nameGpu_.dirty = aboutGpu_.dirty = true;
        Redraw();
        return false;
    case WM_TIMER: {
        TextField* field = name_.HandleTimer(wParam) ? &name_ : about_.HandleTimer(wParam) ? &about_ : nullptr;
        if (!field) return false;
        FieldGpu& gpu = field == &name_ ? nameGpu_ : aboutGpu_;
        if (compositor_ && gpu.visual) {
            if (const HRESULT hr = field->UpdateCaret(compositor_->Device(), compositor_->D2D(), gpu.visual.Get(), kCaret); FAILED(hr)) {
                deviceLost_ = IsDeviceLost(hr);
                if (callbacks_.drawFailed) callbacks_.drawFailed();
            } else {
                compositor_->Commit();
            }
        }
        return true;
    }
    case WM_SETCURSOR: {
        if (LOWORD(lParam) != HTCLIENT) return false;
        POINT cursor{};
        GetCursorPos(&cursor);
        ScreenToClient(window_, &cursor);
        const float scale = Scale();
        const D2D1_POINT_2F p{static_cast<float>(cursor.x) / scale - left_, static_cast<float>(cursor.y) / scale};
        if (!OverField(p)) return false;
        SetCursor(LoadCursorW(nullptr, IDC_IBEAM));
        return true;
    }
    default:
        return false;
    }
}

// MARK: The pointer

bool SpaceCreationView::Contains(D2D1_POINT_2F p) const {
    // The whole room between the top row and the bar, the sidebar's width (SidebarIslandHost).
    return shown_ && p.x >= 0 && p.x < width_ && p.y >= layout_.page.top && p.y < layout_.page.bottom;
}

bool SpaceCreationView::OverField(D2D1_POINT_2F p) const {
    return shown_ && (layout_.nameField.Contains(p.x, p.y) || layout_.aboutField.Contains(p.x, p.y));
}

bool SpaceCreationView::Press(D2D1_POINT_2F p, bool shift) {
    if (!Contains(p)) return false;
    pressed_.reset();
    const SpaceCreationPart part = SpaceCreationPartAt(layout_, p.x, p.y, cancelWidth_, pill_);
    if (part == SpaceCreationPart::NameField || part == SpaceCreationPart::AboutField) {
        const Field field = part == SpaceCreationPart::NameField ? Field::Name : Field::About;
        // A press makes the field the first responder, as clicking an NSTextField does (the
        // controller takes the keyboard from its other fields first); one that has it just moves
        // the caret, so Shift extends from where the selection was.
        if (keyboard_ != field) {
            if (callbacks_.takeKeyboard) callbacks_.takeKeyboard(field);
            if (keyboard_ != field) Focus(field);
        }
        selecting_ = field;
        SetCapture(window_);
        Edited(field, FieldOf(field).Press(p.x - BoxOf(field).left, shift));
        return true;
    }
    // The buttons act when let go over them; the rest of the page takes the press and does nothing.
    if (part != SpaceCreationPart::None) {
        pressed_ = part;
        SetCapture(window_);
    }
    return true;
}

void SpaceCreationView::Move(D2D1_POINT_2F p) {
    if (!selecting_) return;
    Edited(*selecting_, FieldOf(*selecting_).Drag(p.x - BoxOf(*selecting_).left));
}

void SpaceCreationView::Release(D2D1_POINT_2F p) {
    if (selecting_) {
        FieldOf(*selecting_).Release();
        selecting_.reset();
        if (GetCapture() == window_) ReleaseCapture();
        return;
    }
    if (!pressed_) return;
    const SpaceCreationPart pressed = *pressed_;
    pressed_.reset();
    if (GetCapture() == window_) ReleaseCapture();
    if (SpaceCreationPartAt(layout_, p.x, p.y, cancelWidth_, pill_) != pressed) return;
    switch (pressed) {
    case SpaceCreationPart::Create: Submit(); break;
    case SpaceCreationPart::Cancel:
        if (callbacks_.cancel) callbacks_.cancel();
        break;
    case SpaceCreationPart::ChooseTheme:
        if (callbacks_.chooseTheme) {
            BarRect row = layout_.theme;
            row.left += left_;
            row.right += left_;
            callbacks_.chooseTheme(row);
        }
        break;
    case SpaceCreationPart::ProfilePill:
        if (model_.profileEnabled && callbacks_.profileMenu) {
            // The Menu's list opens under its pill, from its leading edge.
            const float scale = Scale();
            POINT screen{std::lround((left_ + pill_.left) * scale), std::lround(pill_.bottom * scale)};
            ClientToScreen(window_, &screen);
            callbacks_.profileMenu(screen);
        }
        break;
    case SpaceCreationPart::NameField:
    case SpaceCreationPart::AboutField:
    case SpaceCreationPart::None: break;
    }
}

void SpaceCreationView::CaptureLost() {
    if (selecting_) FieldOf(*selecting_).Release();
    selecting_.reset();
    pressed_.reset();
}

std::optional<D2D1_POINT_2F> SpaceCreationView::CentreOf(SpaceCreationPart part) const {
    const auto middle = [](const BarRect& r) { return D2D1_POINT_2F{(r.left + r.right) / 2, (r.top + r.bottom) / 2}; };
    switch (part) {
    case SpaceCreationPart::NameField: return middle(layout_.nameField);
    case SpaceCreationPart::AboutField: return middle(layout_.aboutField);
    case SpaceCreationPart::ProfilePill: return middle(pill_);
    case SpaceCreationPart::ChooseTheme: return middle(layout_.theme);
    case SpaceCreationPart::Create: return middle(layout_.create);
    case SpaceCreationPart::Cancel: return middle(layout_.cancel);
    case SpaceCreationPart::None: break;
    }
    return std::nullopt;
}

// MARK: Drawing

D2D1_COLOR_F SpaceCreationView::Primary(float alpha) const {
    const float c = model_.dark ? 1.0f : 0.0f;
    return D2D1_COLOR_F{c, c, c, alpha};
}

bool SpaceCreationView::NeedsDraw() const {
    return shown_ && (dirty_ || createDirty_ || nameGpu_.dirty || aboutGpu_.dirty || !placed_ || !visual_);
}

void SpaceCreationView::DrawLabel(ID2D1DeviceContext* context, std::string_view text, IDWriteTextFormat* format, float lineHeight,
                                  const BarRect& box, bool centred, D2D1_COLOR_F color) {
    const std::wstring wide = Widen(text);
    ComPtr<IDWriteTextLayout> layout;
    if (FAILED(dwrite_->CreateTextLayout(wide.c_str(), static_cast<UINT32>(wide.size()), format, centred ? box.Width() : 100000,
                                         box.Height(), layout.GetAddressOf()))) {
        return;
    }
    // SwiftUI's line box: SF's ascender and descender centred in it, the baseline at the ascender.
    const float size = format->GetFontSize();
    layout->SetLineSpacing(DWRITE_LINE_SPACING_METHOD_UNIFORM, lineHeight, kAscender * size + (lineHeight - (kAscender + kDescender) * size) / 2);
    if (centred) layout->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
    brush_->SetColor(color);
    context->DrawTextLayout(D2D1::Point2F(box.left, box.top), layout.Get(), brush_.Get(), D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
}

void SpaceCreationView::Glyph(ID2D1DeviceContext* context, wchar_t glyph, float size, D2D1_POINT_2F centre, D2D1_COLOR_F color) {
    D2D1_MATRIX_3X2_F base{};
    context->GetTransform(&base);
    const float scale = size / (kIconEm * kGlyphInk);
    context->SetTransform(D2D1::Matrix3x2F::Scale(scale, scale) * D2D1::Matrix3x2F::Translation(centre.x, centre.y) * base);
    brush_->SetColor(color);
    context->DrawText(&glyph, 1, iconFormat_.Get(), D2D1::RectF(-kIconEm, -kIconEm, kIconEm, kIconEm), brush_.Get(),
                      D2D1_DRAW_TEXT_OPTIONS_NONE);
    context->SetTransform(base);
}

void SpaceCreationView::DrawDashedPlus(ID2D1DeviceContext* context, D2D1_POINT_2F centre, D2D1_COLOR_F color) {
    // plus.square.dashed at 16pt: a dashed rounded square about 14.5pt across with a plus in it.
    ComPtr<ID2D1Factory> factory;
    context->GetFactory(factory.GetAddressOf());
    ComPtr<ID2D1StrokeStyle> dashed, round;
    if (!factory) return;
    const float dashes[] = {2.2f, 1.6f};
    D2D1_STROKE_STYLE_PROPERTIES dash{};
    dash.startCap = dash.endCap = dash.dashCap = D2D1_CAP_STYLE_ROUND;
    dash.dashStyle = D2D1_DASH_STYLE_CUSTOM;
    factory->CreateStrokeStyle(dash, dashes, 2, dashed.GetAddressOf());
    D2D1_STROKE_STYLE_PROPERTIES caps{};
    caps.startCap = caps.endCap = D2D1_CAP_STYLE_ROUND;
    factory->CreateStrokeStyle(caps, nullptr, 0, round.GetAddressOf());
    constexpr float kSide = 13.5f, kStroke = 1.3f, kArm = 3.6f;
    brush_->SetColor(color);
    const float h = kSide / 2;
    context->DrawRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(centre.x - h, centre.y - h, centre.x + h, centre.y + h), 3.2f, 3.2f),
                                  brush_.Get(), kStroke, dashed.Get());
    context->DrawLine(D2D1::Point2F(centre.x - kArm, centre.y), D2D1::Point2F(centre.x + kArm, centre.y), brush_.Get(), kStroke, round.Get());
    context->DrawLine(D2D1::Point2F(centre.x, centre.y - kArm), D2D1::Point2F(centre.x, centre.y + kArm), brush_.Get(), kStroke, round.Get());
}

void SpaceCreationView::DrawIllustration(ID2D1DeviceContext* context) {
    // Three cards fanned out over each other (Kite's own picture where Arc has one of its own):
    // the leaf turned 12° left and the books 12° right, 18pt out and 2pt down, the laptop on top.
    const BarRect& frame = layout_.illustration;
    const D2D1_POINT_2F centre{(frame.left + frame.right) / 2, (frame.top + frame.bottom) / 2};
    D2D1_MATRIX_3X2_F base{};
    context->GetTransform(&base);
    struct Card {
        wchar_t symbol;
        D2D1_COLOR_F color;
        float turn, dx, dy;
    };
    const Card cards[] = {{kLeaf, Green(model_.dark), -M::kCardTurn, -M::kCardSpread, M::kCardDrop},
                          {kBooks, Orange(model_.dark), M::kCardTurn, M::kCardSpread, M::kCardDrop},
                          {kLaptop, Gray(model_.dark), 0, 0, 0}};
    const float w = M::kCardWidth / 2, h = M::kCardHeight / 2;
    for (const Card& card : cards) {
        const D2D1_MATRIX_3X2_F at = D2D1::Matrix3x2F::Rotation(card.turn) *
                                     D2D1::Matrix3x2F::Translation(centre.x + card.dx, centre.y + card.dy) * base;
        context->SetTransform(at);
        // .shadow(color: .black.opacity(0.25), radius: 2, y: 1), as two soft rings under the card.
        for (const auto& [grow, alpha] : {std::pair{1.5f, 0.06f}, std::pair{0.75f, 0.1f}}) {
            brush_->SetColor(D2D1_COLOR_F{0, 0, 0, alpha});
            context->FillRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(-w - grow, -h - grow + 1, w + grow, h + grow + 1), M::kCardRadius + grow,
                                                            M::kCardRadius + grow),
                                          brush_.Get());
        }
        brush_->SetColor(D2D1_COLOR_F{1, 1, 1, 1});
        context->FillRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(-w, -h, w, h), M::kCardRadius, M::kCardRadius), brush_.Get());
        // The symbol turns with its card.
        Glyph(context, card.symbol, M::kCardSymbolSize, D2D1::Point2F(0, 0), card.color);
        context->SetTransform(base);
    }
}

void SpaceCreationView::DrawPage(ID2D1DeviceContext* context) {
    context->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
    DrawIllustration(context);
    DrawLabel(context, M::kTitle, titleFormat_.Get(), M::kTitleLineHeight, layout_.title, true, Primary(kLabelAlpha));
    DrawLabel(context, M::kSubtitle, subtitleFormat_.Get(), M::kSubtitleLineHeight, layout_.subtitle, true,
              Primary(kLabelAlpha * M::kSubtitleOpacity));
    // The rows: white over the tint, 8pt corners.
    brush_->SetColor(D2D1_COLOR_F{1, 1, 1, M::kRowFill});
    for (const BarRect* row : {&layout_.name, &layout_.about, &layout_.profile, &layout_.theme}) {
        context->FillRoundedRectangle(D2D1::RoundedRect(RectOf(*row), M::kCornerRadius, M::kCornerRadius), brush_.Get());
    }
    const float iconX = M::kRowIconX + M::kIconSize / 2;
    const auto mid = [](const BarRect& r) { return (r.top + r.bottom) / 2; };
    DrawDashedPlus(context, D2D1::Point2F(iconX, mid(layout_.name)), Primary(kLabelAlpha * 0.6f));
    Glyph(context, kTextBubble, 14, D2D1::Point2F(iconX, mid(layout_.about)), Primary(kLabelAlpha * 0.6f));
    // The profile: its name in a pill that opens the profiles (dimmed while it can't change).
    const BarRect& profile = layout_.profile;
    Glyph(context, kFaceSmiling, 15, D2D1::Point2F(iconX, mid(profile)), Primary(kLabelAlpha * 0.7f));
    // A 15pt line (18pt at 2x) in the row's middle.
    constexpr float kRowLine = 18;
    const auto rowText = [&](const BarRect& row) { return BarRect{M::kRowTextX, mid(row) - kRowLine / 2, row.right, mid(row) + kRowLine / 2}; };
    DrawLabel(context, M::kProfileTitle, rowBoldFormat_.Get(), kRowLine, rowText(profile), false, Primary(kLabelAlpha));
    const float pillAlpha = model_.profileEnabled ? 1.0f : 0.45f;
    brush_->SetColor(D2D1_COLOR_F{1, 1, 1, M::kPillFill * pillAlpha});
    const float r = M::kPillHeight / 2;
    context->FillRoundedRectangle(D2D1::RoundedRect(RectOf(pill_), r, r), brush_.Get());
    constexpr float kPillLine = 15.5f;  // 13pt
    DrawLabel(context, model_.profile, pillFormat_.Get(), kPillLine,
              BarRect{pill_.left + M::kPillPadding, mid(pill_) - kPillLine / 2, pill_.right, mid(pill_) + kPillLine / 2}, false,
              Primary(kLabelAlpha * pillAlpha));
    Glyph(context, kChevronDown, M::kPillChevronSize, D2D1::Point2F(pill_.right - M::kPillPadding - kChevronWidth / 2, mid(pill_)),
          Primary(kLabelAlpha * pillAlpha));
    Glyph(context, kInfoCircle, 14, D2D1::Point2F(profile.right - M::kRowTrailing - 7, mid(profile)), Primary(kLabelAlpha * 0.7f));
    // Choose a Theme.
    Glyph(context, kPaintbrush, 14, D2D1::Point2F(iconX, mid(layout_.theme)), Primary(kLabelAlpha * 0.7f));
    DrawLabel(context, M::kThemeTitle, rowBoldFormat_.Get(), kRowLine, rowText(layout_.theme), false, Primary(kLabelAlpha));
    // Cancel, under Create Space (which draws in its own surface).
    DrawLabel(context, M::kCancelTitle, cancelFormat_.Get(), M::kCancelLineHeight, layout_.cancel, true,
              Primary(kLabelAlpha * M::kCancelOpacity));
}

void SpaceCreationView::DrawCreate(ID2D1DeviceContext* context) {
    // #2C4AFC, at half strength until there's a name; "Create Space" white, at 45% then.
    const float w = layout_.create.Width(), h = layout_.create.Height();
    const bool on = CanCreate();
    brush_->SetColor(Srgb(M::kCreateColor, on ? 1 : M::kCreateDisabledOpacity));
    context->FillRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(0, 0, w, h), M::kCornerRadius, M::kCornerRadius), brush_.Get());
    constexpr float kLine = 18;
    context->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
    DrawLabel(context, M::kCreateTitle, rowBoldFormat_.Get(), kLine, BarRect{0, (h - kLine) / 2, w, (h + kLine) / 2}, true,
              D2D1_COLOR_F{1, 1, 1, on ? 1 : M::kCreateDisabledTextOpacity});
}

std::wstring SpaceCreationView::DrawField(Field field, Pixels* readBack) {
    FieldGpu& gpu = GpuOf(field);
    const BarRect& box = BoxOf(field);
    const float scale = Scale();
    const UINT width = std::max(1u, static_cast<UINT>(std::ceil(box.Width() * scale)));
    const UINT height = std::max(1u, static_cast<UINT>(std::ceil(box.Height() * scale)));
    HRESULT hr = S_OK;
    if (!gpu.surface) {
        if (FAILED(hr = compositor_->Device()->CreateVirtualSurface(width, height, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED,
                                                                     gpu.surface.GetAddressOf())) ||
            FAILED(hr = gpu.visual->SetContent(gpu.surface.Get()))) {
            gpu.surface.Reset();
            deviceLost_ = IsDeviceLost(hr);
            return HResultMessage(L"creating a Create a Space field's surface", hr);
        }
        gpu.dirty = true;
    } else if (width != gpu.width || height != gpu.height) {
        if (FAILED(hr = gpu.surface->Resize(width, height))) {
            deviceLost_ = IsDeviceLost(hr);
            return HResultMessage(L"resizing a Create a Space field's surface", hr);
        }
        gpu.dirty = true;
    }
    gpu.width = width;
    gpu.height = height;
    if (gpu.dirty || readBack) {
        const TextField& text = FieldOf(field);
        const D2D1_COLOR_F selection = text.Focused() ? (model_.dark ? kDarkSelection : kLightSelection) : Primary(0.15f);
        std::wstring error = compositor_->DrawSurface(
            perf::View::Sidebar, gpu.surface.Get(), width, height, dpi_,
            [&](ID2D1DeviceContext* context) { text.Draw(context, brush_.Get(), Primary(kLabelAlpha), Primary(kPlaceholderOpacity), selection); },
            readBack, hr);
        if (!error.empty()) {
            deviceLost_ = IsDeviceLost(hr);
            return L"a Create a Space field: " + error;
        }
        if (gpu.dirty) ++fieldDraws_;
        gpu.dirty = false;
    }
    if (FAILED(hr = FieldOf(field).UpdateCaret(compositor_->Device(), compositor_->D2D(), gpu.visual.Get(), kCaret))) {
        deviceLost_ = IsDeviceLost(hr);
        return HResultMessage(L"placing a Create a Space field's caret", hr);
    }
    return {};
}

std::wstring SpaceCreationView::Draw(Pixels* readBack) {
    if (!shown_) return {};
    if (!compositor_ || !parent_) return L"no compositor";
    if (deviceLost_) return L"the GPU device was lost";
    const float scale = Scale();
    auto fail = [this](const wchar_t* what, HRESULT hr) {
        deviceLost_ = IsDeviceLost(hr);
        return HResultMessage(what, hr);
    };
    HRESULT hr = S_OK;
    IDCompositionDevice* device = compositor_->Device();
    if (!visual_) {
        // The page, then Create Space and the fields over it.
        if (FAILED(hr = compositor_->D2D()->CreateSolidColorBrush(D2D1_COLOR_F{0, 0, 0, 1}, brush_.ReleaseAndGetAddressOf())) ||
            FAILED(hr = device->CreateVisual(visual_.ReleaseAndGetAddressOf())) ||
            FAILED(hr = device->CreateVisual(createVisual_.ReleaseAndGetAddressOf())) ||
            FAILED(hr = device->CreateVisual(nameGpu_.visual.ReleaseAndGetAddressOf())) ||
            FAILED(hr = device->CreateVisual(aboutGpu_.visual.ReleaseAndGetAddressOf())) ||
            FAILED(hr = parent_->AddVisual(visual_.Get(), TRUE, nullptr)) ||
            FAILED(hr = parent_->AddVisual(createVisual_.Get(), TRUE, visual_.Get())) ||
            FAILED(hr = parent_->AddVisual(nameGpu_.visual.Get(), TRUE, createVisual_.Get())) ||
            FAILED(hr = parent_->AddVisual(aboutGpu_.visual.Get(), TRUE, nameGpu_.visual.Get()))) {
            ReleaseGpu();
            return fail(L"creating Create a Space's visuals", hr);
        }
        dirty_ = createDirty_ = nameGpu_.dirty = aboutGpu_.dirty = true;
        placed_ = false;
    }
    // The page's surface: the sidebar's width, from its top down to the bar (the top row's band
    // left clear).
    const UINT width = std::max(1u, static_cast<UINT>(std::ceil(width_ * scale)));
    const UINT height = std::max(1u, static_cast<UINT>(std::ceil(layout_.page.bottom * scale)));
    if (!surface_) {
        if (FAILED(hr = device->CreateVirtualSurface(width, height, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED, surface_.GetAddressOf())) ||
            FAILED(hr = visual_->SetContent(surface_.Get()))) {
            surface_.Reset();
            return fail(L"creating Create a Space's surface", hr);
        }
        dirty_ = true;
    } else if (width != surfaceWidth_ || height != surfaceHeight_) {
        if (FAILED(hr = surface_->Resize(width, height))) return fail(L"resizing Create a Space's surface", hr);
        dirty_ = true;
    }
    surfaceWidth_ = width;
    surfaceHeight_ = height;
    Pixels page;
    if (dirty_ || readBack) {
        std::wstring error = compositor_->DrawSurface(
            perf::View::Sidebar, surface_.Get(), width, height, dpi_, [this](ID2D1DeviceContext* context) { DrawPage(context); },
            readBack ? &page : nullptr, hr);
        if (!error.empty()) {
            deviceLost_ = IsDeviceLost(hr);
            return L"Create a Space: " + error;
        }
        if (dirty_) ++pageDraws_;
        dirty_ = false;
    }
    // Create Space.
    const UINT createWidth = std::max(1u, static_cast<UINT>(std::ceil(layout_.create.Width() * scale)));
    const UINT createHeight = std::max(1u, static_cast<UINT>(std::ceil(layout_.create.Height() * scale)));
    if (!createSurface_) {
        if (FAILED(hr = device->CreateVirtualSurface(createWidth, createHeight, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED,
                                                     createSurface_.GetAddressOf())) ||
            FAILED(hr = createVisual_->SetContent(createSurface_.Get()))) {
            createSurface_.Reset();
            return fail(L"creating Create Space's surface", hr);
        }
        createDirty_ = true;
    } else if (createWidth != createWidth_ || createHeight != createHeight_) {
        if (FAILED(hr = createSurface_->Resize(createWidth, createHeight))) return fail(L"resizing Create Space's surface", hr);
        createDirty_ = true;
    }
    createWidth_ = createWidth;
    createHeight_ = createHeight;
    Pixels create;
    if (createDirty_ || readBack) {
        std::wstring error = compositor_->DrawSurface(
            perf::View::Sidebar, createSurface_.Get(), createWidth, createHeight, dpi_, [this](ID2D1DeviceContext* context) { DrawCreate(context); },
            readBack ? &create : nullptr, hr);
        if (!error.empty()) {
            deviceLost_ = IsDeviceLost(hr);
            return L"Create Space: " + error;
        }
        if (createDirty_) ++createDraws_;
        createDirty_ = false;
        canCreate_ = CanCreate();
    }
    // Each on the pixel grid where the layout has it.
    const auto px = [scale](float points) { return static_cast<float>(std::lround(points * scale)); };
    if (!placed_) {
        createVisual_->SetOffsetX(px(layout_.create.left));
        createVisual_->SetOffsetY(px(layout_.create.top));
        for (Field field : {Field::Name, Field::About}) {
            GpuOf(field).visual->SetOffsetX(px(BoxOf(field).left));
            GpuOf(field).visual->SetOffsetY(px(BoxOf(field).top));
        }
        placed_ = true;
    }
    Pixels name, about;
    if (std::wstring error = DrawField(Field::Name, readBack ? &name : nullptr); !error.empty()) return error;
    if (std::wstring error = DrawField(Field::About, readBack ? &about : nullptr); !error.empty()) return error;
    if (readBack) {
        *readBack = std::move(page);
        ComposeOver(*readBack, create, POINT{std::lround(layout_.create.left * scale), std::lround(layout_.create.top * scale)});
        ComposeOver(*readBack, name, POINT{std::lround(layout_.nameField.left * scale), std::lround(layout_.nameField.top * scale)});
        ComposeOver(*readBack, about, POINT{std::lround(layout_.aboutField.left * scale), std::lround(layout_.aboutField.top * scale)});
    }
    return {};
}

}  // namespace kite
