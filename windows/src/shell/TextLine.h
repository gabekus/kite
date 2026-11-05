#pragma once
// What Kite's one-line fields share around their text (shell/TextEditing): the line as DirectWrite
// lays it out, scrolled sideways to keep the caret in view, hit tests, the selection's highlight,
// the caret's blink and Windows' caret timeout, the IME's windows at the caret, and the caret
// itself as a small visual of its own, so a blink is a commit and not a redraw. The command bar's
// field and the sidebar's rename fields (shell/RenameField) each place and draw it.

#include <windows.h>  // first: the DirectX headers need its types

#include <d2d1_1.h>
#include <dcomp.h>
#include <dwrite.h>
#include <wrl/client.h>

#include "shell/TextEditing.h"

namespace kite {

class TextLine {
public:
    // `window` owns the clipboard and gets the blink's `timer`.
    TextLine(HWND window, UINT_PTR timer) : window_(window), timer_(timer), edit_(window) {}

    TextEditing& Edit() { return edit_; }
    const TextEditing& Edit() const { return edit_; }

    // The format the text is laid out in (one line, no trimming), `height` points tall.
    void SetFormat(IDWriteFactory* dwrite, IDWriteTextFormat* format, float height);
    // The text changed: a new layout, the caret kept in view.
    void Relayout();
    IDWriteTextLayout* Layout() const { return layout_.Get(); }
    // The first line's baseline from the layout's top, and its height (an empty line's too).
    float Baseline() const;
    float LineHeight() const;

    // How much of it shows, in points from the field's left; the scroll keeps the caret there.
    void SetVisibleWidth(float width) { visible_ = width; }
    void KeepCaretVisible();
    float ScrollX() const { return scrollX_; }
    // The caret's x from the layout's left (subtract ScrollX for the field's).
    float CaretX() const;
    // The character boundary nearest `x`, in points from the field's left.
    size_t IndexAt(float x) const;
    // The selection's highlight under the text, the layout drawn at `origin`, each range filled
    // from `top` to `bottom` (the line's, or a box's as NSTextView fills it).
    void DrawSelection(ID2D1DeviceContext* context, ID2D1SolidColorBrush* brush, D2D1_POINT_2F origin, float top, float bottom,
                       D2D1_COLOR_F color) const;

    // The blink: the caret shows again and blinks while `blinking` (the field has the keyboard
    // and Windows blinks carets); HandleTimer is its tick (true when `timer` was the blink's).
    // After Windows' caret timeout it stops, the caret left showing.
    void RestartBlink(bool blinking);
    void StopBlink();
    bool CaretOn() const { return caretOn_; }
    bool HandleTimer(WPARAM timer);
    // The IME's composition window at `caret` (client px) and its candidates under a line
    // `lineHeight` px tall, in `font` when given.
    void PlaceIme(POINT caret, LONG lineHeight, const LOGFONTW* font = nullptr) const;

private:
    HWND window_;
    UINT_PTR timer_;
    TextEditing edit_;
    Microsoft::WRL::ComPtr<IDWriteFactory> dwrite_;
    Microsoft::WRL::ComPtr<IDWriteTextFormat> format_;
    Microsoft::WRL::ComPtr<IDWriteTextLayout> layout_;
    float height_ = 0;
    float visible_ = 1;
    float scrollX_ = 0;
    bool caretOn_ = true;
    ULONGLONG blinkSince_ = 0;
};

// A field's caret: a visual of its own with a small surface of the caret's colour, filled once
// (again only for a new size or colour), placed and shown or hidden without drawing the field.
class CaretVisual {
public:
    // Shows it `width` × `height` px in `color` with its top-left at `at` (px) in `parent`, filling
    // its surface with `context` (on the composition device's GPU), or hides it. Commits nothing.
    // A failure's HRESULT says whether the GPU went (IsDeviceLost).
    HRESULT Update(IDCompositionDevice* device, ID2D1DeviceContext* context, IDCompositionVisual* parent, bool show, POINT at,
                   UINT width, UINT height, D2D1_COLOR_F color);
    // Takes it out of its parent and lets its GPU objects go.
    void Release();

private:
    Microsoft::WRL::ComPtr<IDCompositionVisual> visual_;
    Microsoft::WRL::ComPtr<IDCompositionSurface> surface_;
    UINT width_ = 0, height_ = 0;
    D2D1_COLOR_F color_{};
    IDCompositionVisual* shownIn_ = nullptr;
};

}  // namespace kite
