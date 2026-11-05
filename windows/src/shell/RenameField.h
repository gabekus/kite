#pragma once
// The sidebar's rename fields: a space's name in its header (the Mac's SpaceRenameField and the
// header's Done, SidebarListRows.swift), and a tab's title or a folder's name in its row (the Mac's
// RenameField, SidebarListCells.swift). The text in its row's font, all selected as it opens, in
// labelColor, 2pt into AppKit's field editor over its textBackgroundColor; a placeholder when
// it's empty ("Space Name", a tab's "Keep it short and sweet!", none for a folder); Return (or the
// header's Done) commits, Escape cancels, and leaving it (a press elsewhere in the window, the page
// or the command bar taking the keyboard, its row no longer shown) commits. SidebarView places it
// over the name it edits.
//
// It's a visual of its own in the space's page (so it slides and swipes with the page, as the
// Mac's field is a subview of its row), with its own small surface, so a keystroke draws only
// the field; the caret is a visual in it (shell/TextLine), so a blink draws nothing.

#include <windows.h>  // first: the DirectX headers need its types

#include <d2d1_1.h>
#include <dcomp.h>
#include <dwrite.h>
#include <wrl/client.h>

#include <memory>
#include <optional>
#include <string>
#include <string_view>

#include "shell/Capture.h"
#include "shell/Compositor.h"
#include "shell/TextLine.h"

namespace kite {

class RenameField {
public:
    // `format` is its row's (the header's 13pt semibold, a tab's 14pt regular, a folder's 14pt
    // semibold); `done` Done's (12pt semibold), null for a field with no Done (a row's);
    // `placeholder` what an empty one shows. `id` is the space's, tab's or folder's. Null with
    // `error` when its layouts can't be made.
    static std::unique_ptr<RenameField> Create(HWND window, IDWriteFactory* dwrite, IDWriteTextFormat* format, IDWriteTextFormat* done,
                                               std::string id, const std::string& text, std::wstring_view placeholder,
                                               std::wstring& error);
    ~RenameField();
    RenameField(const RenameField&) = delete;
    RenameField& operator=(const RenameField&) = delete;

    const std::string& Id() const { return id_; }
    std::string Text() const;

    // Done's width (its label's), for the header's layout; 0 with no Done.
    float DoneWidth() const { return doneWidth_; }
    // Where it sits, in its page's points (the sidebar's, the list scrolled): the field's box
    // from `left` to `right`, its line from `lineTop`, `lineHeight` tall, with the text's
    // baseline at `baseline`, and Done's box with its label's baseline (with no Done, a box of no
    // width at the editor's end, as tall as the row: what the field's surface spans); shown only
    // between `clipTop` and `clipBottom` (the list's); in the space's appearance. Draw puts it there.
    void Place(float left, float right, float lineTop, float lineHeight, float baseline, D2D1_RECT_F done, float doneBaseline,
               float clipTop, float clipBottom, UINT dpi, bool dark);
    // The editor's background past the field's end (kBackgroundAfter), for a row's Done box.
    static constexpr float kEditorAfter = 1;
    // Where its page's top-left is in the window, client px (for the IME and the system caret).
    void SetPageOrigin(POINT origin) { pageOrigin_ = origin; }

    // Its visual, in `parent` (its page's) on `compositor`; null drops every GPU object.
    void UseCompositor(Compositor* compositor, IDCompositionVisual* parent);
    IDCompositionVisual* Parent() const { return parent_; }
    bool NeedsDraw() const { return dirty_ || !caretPlaced_; }
    // Draws what changed into its surface and places the caret; with `readBack`, always, also
    // its pixels there and their top-left in its page's px in `origin` (--capture). The caller
    // commits. Empty on success.
    std::wstring Draw(Pixels* readBack = nullptr, POINT* origin = nullptr);
    bool DeviceLost() const { return deviceLost_; }

    // What a key, a character or a press did. KeyDown: none for a key that isn't the field's
    // (Return, Escape or an editing key), which goes on to the window.
    enum class Outcome { None, Changed, Commit, Cancel };
    std::optional<Outcome> KeyDown(UINT key, bool ctrl, bool shift);
    Outcome Character(wchar_t character);
    // A left press at `x`, `y` (page points): in the field it places the caret (Shift
    // extends) and starts a drag selecting; on Done it commits when let go there. False when it
    // was elsewhere (which commits the field).
    bool Press(float x, float y, bool shift);
    Outcome Move(float x, float y);
    Outcome Release(float x, float y);
    bool InField(float x, float y) const;
    // Done's box, in page points (for a test's press); none with no Done.
    std::optional<D2D1_RECT_F> DoneBox() const { return done_ ? std::optional<D2D1_RECT_F>(doneBox_) : std::nullopt; }

    // The keyboard came or went (the window's WM_SETFOCUS and WM_KILLFOCUS): the caret shows
    // only while the window has it, and the selection greys without it.
    void SetFocused(bool focused);
    bool Focused() const { return focused_; }
    // The blink's tick (commits the caret), and an IME's composition window at the caret.
    bool HandleTimer(WPARAM timer);
    void PlaceImeWindow();
    static constexpr UINT_PTR kCaretTimer = 0x4B45;  // the command bar's is 0x4B42, the tip's 0x4B44

private:
    RenameField(HWND window, std::string id) : window_(window), id_(std::move(id)), line_(window, kCaretTimer) {}
    Outcome Apply(TextEditing::Change change);
    // The caret where the field drew, shown while the window has the keyboard, it blinks on and
    // nothing is selected. Commits nothing.
    void UpdateCaret();
    float Scale() const { return static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI; }

    HWND window_;
    std::string id_;
    TextLine line_;
    Microsoft::WRL::ComPtr<IDWriteTextLayout> placeholder_, done_;
    float doneWidth_ = 0;
    float doneLayoutBaseline_ = 0;  // Done's first baseline from its layout's top

    float left_ = 0, right_ = 0, lineTop_ = 0, lineHeight_ = 16, baseline_ = 0, doneBaseline_ = 0;
    float clipTop_ = 0, clipBottom_ = 0;
    D2D1_RECT_F doneBox_{};
    UINT dpi_ = USER_DEFAULT_SCREEN_DPI;
    bool dark_ = true;
    POINT pageOrigin_{};
    bool focused_ = false;
    bool selecting_ = false;
    bool pressedDone_ = false;
    bool dirty_ = true;
    bool caretPlaced_ = false;

    Compositor* compositor_ = nullptr;
    IDCompositionVisual* parent_ = nullptr;
    Microsoft::WRL::ComPtr<IDCompositionVisual> visual_;
    Microsoft::WRL::ComPtr<IDCompositionVirtualSurface> surface_;
    Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> brush_;
    UINT surfaceWidth_ = 0, surfaceHeight_ = 0;
    POINT surfaceAt_{};  // its top-left in page px
    CaretVisual caret_;
    bool deviceLost_ = false;
};

}  // namespace kite
