#pragma once
// Find in page's bar (Ctrl+F): the Mac's FindBar (KiteMac/Views/FindBar.swift) with Ask on Page
// off, which is Arc's FindInPageView: a 300 × 32 bar 10pt in from the content card's top-right
// corner, with a magnifier, the query field ("Find in page…"), the n/N counter ("Not Found" in
// red), previous and next arrows, a divider and close, in Arc's popover colours with its shadow.
// It appears and goes without animation. Return and Shift+Return step through the matches, Esc
// closes it, and every keystroke searches at once (core/FindQuery holds the rules).
//
// It's a small surface of its own in the window's page overlay (Compositor::PageOverlay), over
// the page's child window and under the command bar, so typing draws only the bar; the caret is
// a visual in it (shell/TextField), so a blink draws nothing. The page window has a hole where
// the bar is (Chromium::SetOverlayHole), so the bar's clicks come to Kite's window; the page
// keeps taking input everywhere else. The bar has the keyboard while its field is the window's
// first responder (Ctrl+F, a click in it); a click in the page takes it back, and the bar stays.

#include <windows.h>  // first: the DirectX headers need its types

#include <d2d1_1.h>
#include <dcomp.h>
#include <dwrite_3.h>
#include <wrl/client.h>

#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <initializer_list>
#include <utility>

#include "core/FindBar.h"
#include "shell/Capture.h"
#include "shell/Compositor.h"
#include "shell/TextField.h"

namespace kite {

class FindBarView {
public:
    struct Callbacks {
        // Find in the page (an empty text: stop finding and clear the highlights).
        std::function<void(const FindQuery::Search& search)> search;
        // Esc or the close button: the controller closes the bar (as the Mac's onClose).
        std::function<void()> close;
        // A press in the field is about to make it the first responder: the controller takes the
        // keyboard from its other fields (a rename) first, so one caret is left.
        std::function<void()> takeKeyboard;
        // The DPI the window is laid out at (MainWindow::Dpi).
        std::function<UINT()> dpi;
    };

    static std::unique_ptr<FindBarView> Create(HWND window, Callbacks callbacks, std::wstring& error);
    ~FindBarView();
    FindBarView(const FindBarView&) = delete;
    FindBarView& operator=(const FindBarView&) = delete;

    // The window's compositor, whose page overlay it draws in; null drops every GPU object. An
    // open bar draws again on the new one.
    void UseCompositor(Compositor* compositor);

    // Shows the bar (it just appears, as Arc's find view), in the app's appearance. Draws now.
    void Show(bool dark);
    // Hides it and clears its query and counter. It doesn't stop the page's search: the
    // controller does (FindQuery::Stopped).
    void Hide();
    bool IsOpen() const { return open_; }
    // The appearance changed (the system's, with pageAppearance automatic).
    void SetDark(bool dark);
    // The content card moved (a resize, a DPI change), in client px: the bar keeps its corner.
    void SetCard(const RECT& card);
    // The bar's rectangle, in client px (where the page's hole goes); empty while it's closed.
    RECT Frame() const;

    // Ctrl+F: the field takes the keyboard, its text all selected (the Mac's focus()).
    void Focus();
    // Whether the field is the window's first responder: it takes the window's keys, and the
    // window's focus doesn't go back to the page.
    bool HasKeyboard() const { return open_ && keyboard_; }
    // Something else took the keyboard (the page, the command bar, a rename): the field lets it
    // go, its selection and undo with it (the Mac's field editor ends), the bar staying open.
    void LoseKeyboard();
    // The bar's corners, in px (the page's hole is the bar's shape).
    float CornerRadiusPx() const;
    // For the tests: the middle of the field (or 8pt into it, or 4pt before its end) or a button, in client px; whether
    // the field has the window's focus; its selection (UTF-16 offsets, start and end).
    enum class Part { Field, FieldStart, FieldEnd, Previous, Next, Close };
    POINT ClientPointOf(Part part) const;
    bool FieldFocused() const;
    std::pair<size_t, size_t> FieldSelection() const;
    // Return, Shift+Return, Ctrl+G, Ctrl+Shift+G and the arrows.
    void Step(bool forward);
    // Types `text` into the field as the keyboard would, searching (--find, the smoke test).
    void Type(std::string_view text);
    // The page's report for the current search; ignored once finding stopped.
    void ShowResult(const FindResult& result);
    FindQuery& Query() { return query_; }
    const FindQuery& Query() const { return query_; }

    // The main window's messages while it's open: keys and characters while the field has the
    // keyboard, presses in the bar, the cursor over it, the focus, IME and the caret's timer.
    // True when it handled `message` (with `result`).
    bool HandleMessage(UINT message, WPARAM wParam, LPARAM lParam, LRESULT& result);

    // Draws the bar and places the caret, and commits. With `readBack`, also copies its pixels
    // (premultiplied BGRA, the shadow included) there and their top-left in client px into
    // `origin`, for --capture. Empty on success.
    std::wstring Draw(Pixels* readBack = nullptr, POINT* origin = nullptr);
    bool DeviceLost() const { return deviceLost_; }

    // The field's caret blink. View timers 0x4B42 to 0x4B46 are taken: the command bar's caret,
    // Chromium's close deadline, the space tip, the rename field's caret and the sidebar's drop.
    static constexpr UINT_PTR kCaretTimer = 0x4B47;

private:
    FindBarView(HWND window, Callbacks callbacks) : window_(window), callbacks_(std::move(callbacks)), field_(window, kCaretTimer) {}

    enum class Button { None, Previous, Next, Close };
    float Scale() const { return static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI; }
    void ComputeFrame();
    // The bar's point under a client-px position.
    D2D1_POINT_2F BarPoint(LPARAM clientPixels) const;
    bool InBar(D2D1_POINT_2F point) const;
    Button ButtonAt(D2D1_POINT_2F point) const;
    // Where the field ends: 8pt before the counter, which ends 93pt before the bar's end.
    float FieldRight() const;
    void PlaceField();
    void LabelChanged();
    // The field changed: a new text searches at once (FindBar.controlTextDidChange).
    void Edited(TextField::Change change);
    void Press(Button button);
    // The keyboard came to Kite's window or left it.
    void FocusChanged();
    bool EnsureShadow(std::wstring& error);
    void DrawContent(ID2D1DeviceContext* context);
    void Glyph(ID2D1DeviceContext* context, IDWriteTextFormat* format, wchar_t glyph, float centerX, D2D1_COLOR_F color);
    // The arrows (pointing up or down) and close, as strokes centred at `centerX` (bar points).
    void Arrow(ID2D1DeviceContext* context, float centerX, bool up, D2D1_COLOR_F color);
    void Cross(ID2D1DeviceContext* context, float centerX, D2D1_COLOR_F color);
    void Strokes(ID2D1DeviceContext* context, std::initializer_list<std::pair<D2D1_POINT_2F, D2D1_POINT_2F>> lines, float width,
                 D2D1_COLOR_F color);
    // Round caps and joins, made from the compositor's Direct2D factory once.
    ID2D1StrokeStyle* RoundStroke(ID2D1DeviceContext* context);
    LOGFONTW FieldFont() const;

    HWND window_;
    Callbacks callbacks_;
    Compositor* compositor_ = nullptr;

    Microsoft::WRL::ComPtr<IDWriteFactory> dwrite_;
    Microsoft::WRL::ComPtr<IDWriteTextFormat> fieldFormat_, counterFormat_, iconFormat_;
    Microsoft::WRL::ComPtr<IDWriteTextLayout> counter_;
    float counterWidth_ = 0;
    std::wstring textFamily_;

    // GPU.
    Microsoft::WRL::ComPtr<IDCompositionVisual> visual_;
    Microsoft::WRL::ComPtr<IDCompositionVisual> fieldVisual_;  // at the bar's top-left: the caret's parent
    Microsoft::WRL::ComPtr<IDCompositionVirtualSurface> surface_;
    Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> brush_;
    Microsoft::WRL::ComPtr<ID2D1Bitmap1> shadow_;
    Microsoft::WRL::ComPtr<ID2D1StrokeStyle1> roundStroke_;
    UINT surfaceWidth_ = 0, surfaceHeight_ = 0;
    float shadowWidth_ = -1;
    UINT shadowDpi_ = 0;
    bool shadowDark_ = false;
    bool deviceLost_ = false;

    // State.
    bool open_ = false;
    bool dark_ = false;
    bool keyboard_ = false;  // the field is the window's first responder
    UINT dpi_ = USER_DEFAULT_SCREEN_DPI;
    RECT card_{};
    FindBarFrame frame_;     // points
    LONG leftPx_ = 0, topPx_ = 0, marginPx_ = 0;
    Button pressed_ = Button::None;
    bool pressedOver_ = false;  // the held button is under the pointer (its glyph dims)
    FindQuery query_;
    TextField field_;
};

}  // namespace kite
