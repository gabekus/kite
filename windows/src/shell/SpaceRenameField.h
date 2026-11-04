#pragma once
// The space header's name field while the space is renamed (the Mac's SpaceRenameField and the
// header's Done, SidebarListRows.swift): the name in the header's 13pt semibold, all selected
// as it opens, in labelColor; "Space Name" when it's empty; Return or Done commits, Escape
// cancels, and leaving it (a click elsewhere in the window, the page or the command bar taking
// the keyboard) commits. SidebarView places it over the header's name and draws it with the
// header's row; its caret is a visual of its own, so a blink draws nothing.

#include <windows.h>  // first: the DirectX headers need its types

#include <d2d1_1.h>
#include <dcomp.h>
#include <dwrite.h>
#include <wrl/client.h>

#include <memory>
#include <optional>
#include <string>

#include "shell/Compositor.h"
#include "shell/TextEditing.h"

namespace kite {

class SpaceRenameField {
public:
    // `format` is the header's (13pt semibold); `done` Done's (12pt semibold). Null with
    // `error` when its layouts can't be made.
    static std::unique_ptr<SpaceRenameField> Create(HWND window, IDWriteFactory* dwrite, IDWriteTextFormat* format,
                                                    IDWriteTextFormat* done, std::string spaceID, const std::string& name,
                                                    std::wstring& error);
    ~SpaceRenameField();
    SpaceRenameField(const SpaceRenameField&) = delete;
    SpaceRenameField& operator=(const SpaceRenameField&) = delete;

    const std::string& SpaceID() const { return spaceID_; }
    std::string Text() const;

    // Done's width (its label's), for the header's layout.
    float DoneWidth() const { return doneWidth_; }
    // Where it sits, in the sidebar's points: the field's box from `left` to `right`, its line
    // from `lineTop`, `lineHeight` tall, with the text's baseline at `baseline`, and Done's box with
    // its label's baseline. UpdateCaret moves the caret there.
    void Place(float left, float right, float lineTop, float lineHeight, float baseline, D2D1_RECT_F done, float doneBaseline, UINT dpi);
    // Draws the field and Done into a page being drawn (its points are the sidebar's): the text in
    // labelColor, Done at 60% of it.
    void Draw(ID2D1DeviceContext* context, ID2D1SolidColorBrush* brush, bool dark);

    // What a key, a character or a press did. KeyDown: none for a key that isn't the field's
    // (Return, Escape or an editing key), which goes on to the window.
    enum class Outcome { None, Changed, Commit, Cancel };
    std::optional<Outcome> KeyDown(UINT key, bool ctrl, bool shift);
    Outcome Character(wchar_t character);
    // A left press at `x`, `y` (sidebar points): in the field it places the caret (Shift
    // extends) and starts a drag selecting; on Done it commits when let go there. False when it
    // was elsewhere (which commits the field).
    bool Press(float x, float y, bool shift);
    Outcome Move(float x, float y);
    Outcome Release(float x, float y);
    bool InField(float x, float y) const;

    // The keyboard came or went (the window's WM_SETFOCUS and WM_KILLFOCUS): the caret shows
    // only while the window has it, and the selection greys without it.
    void SetFocused(bool focused);
    // The caret's visual, in `parent` (the sidebar's chrome) at window pixels; null drops it.
    void UseCompositor(Compositor* compositor, IDCompositionVisual* parent);
    // Puts the caret where the field last drew (outside any surface's draw), shown while the
    // window has the keyboard, blinking, and nothing is selected; commits nothing.
    void UpdateCaret();
    // The blink's timer, and an IME's composition window at the caret.
    bool HandleTimer(WPARAM timer);
    void PlaceImeWindow();
    static constexpr UINT_PTR kCaretTimer = 0x4B45;  // the command bar's is 0x4B42, the tip's 0x4B44

private:
    SpaceRenameField(HWND window, std::string spaceID) : window_(window), spaceID_(std::move(spaceID)), edit_(window) {}
    Outcome Apply(TextEditing::Change change);
    void Relayout();
    void KeepCaretVisible();
    float CaretX() const;
    size_t IndexAt(float x) const;
    void RestartBlink();
    float Scale() const { return static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI; }

    HWND window_;
    std::string spaceID_;
    TextEditing edit_;
    Microsoft::WRL::ComPtr<IDWriteFactory> dwrite_;
    Microsoft::WRL::ComPtr<IDWriteTextFormat> format_;
    Microsoft::WRL::ComPtr<IDWriteTextLayout> layout_, placeholder_, done_;
    float doneWidth_ = 0;
    float layoutBaseline_ = 0, doneLayoutBaseline_ = 0;  // the layouts' first baselines from their top

    float left_ = 0, right_ = 0, lineTop_ = 0, lineHeight_ = 16, baseline_ = 0;
    D2D1_RECT_F doneBox_{};
    float doneBaseline_ = 0;
    UINT dpi_ = USER_DEFAULT_SCREEN_DPI;
    float scrollX_ = 0;
    bool dark_ = true;
    bool focused_ = false;
    bool selecting_ = false;
    bool pressedDone_ = false;
    bool caretOn_ = true;
    ULONGLONG blinkSince_ = 0;

    Compositor* compositor_ = nullptr;
    IDCompositionVisual* parent_ = nullptr;
    Microsoft::WRL::ComPtr<IDCompositionVisual> caretVisual_;
    Microsoft::WRL::ComPtr<IDCompositionVirtualSurface> caretSurface_;
    UINT caretWidth_ = 0, caretHeight_ = 0;
    bool caretDark_ = true;
    bool caretShown_ = false;
};

}  // namespace kite
