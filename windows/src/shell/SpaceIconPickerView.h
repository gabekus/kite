#pragma once
// Change Space Icon…'s popover: the Mac's SpaceIconPicker (SpaceIconPicker.swift) in NSPopover's
// place, a window of its own owned by the browser window, hanging under the header's icon with
// an arrow. Its tabs (Emoji and Icon; Image disabled until Windows has pictures of your own), the
// bin once the space has an icon, and on the Emoji tab a search field, the emoji grid by
// category and the category bar; on the Icon tab, Kite's 56 symbols as Windows draws them
// (core/SpaceIcon.h's glyphs and core/SymbolShape.h's shapes, through the sidebar's painter).
// What it shows and what a point hits is core's (core/SpaceIconPicker.h); this draws it and
// takes the pointer and the keys.
//
// It never takes activation (the browser window keeps the keyboard, which the controller passes
// on while it's open), and closes as AppKit's transient popover does: Escape, a press anywhere
// else, another app coming forward. A pick sets the icon and leaves it open (the Mac's pick).
//
// Drawing, all with DirectComposition in its own target on the window's compositor: the popover's
// frame and controls in one surface, the Icon tab's grid in it too; the emoji grid in a virtual
// surface as tall as all its rows, in a clip, scrolled by moving it (a scroll draws only the rows
// that come into view, and the rows far from view are let go); the search field's caret as a
// visual of its own (shell/TextLine). A pressed cell draws only itself; the pointer moving over
// the grid draws nothing (the Mac's plain buttons show no hover). Nothing runs while it's idle
// but the caret's blink, which Windows' caret timeout ends.

#include <windows.h>  // first: the DirectX headers need its types

#include <d2d1_1.h>
#include <dcomp.h>
#include <dwrite.h>
#include <wrl/client.h>

#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "core/SpaceIconPicker.h"
#include "shell/Capture.h"
#include "shell/Compositor.h"
#include "shell/SpaceIconPainter.h"
#include "shell/TextLine.h"

namespace kite {

class SpaceIconPickerView {
public:
    struct Callbacks {
        // A cell or the bin: space `spaceID` gets `icon` ("" for none). The caller sets it and
        // calls SpaceChanged with what the space shows now.
        std::function<void(const std::string& spaceID, const std::string& icon)> pick;
        // It closed (the header's placeholder goes, the Mac's closeHandler).
        std::function<void(const std::string& spaceID)> closed;
    };
    // A hidden window owned by `owner` (the browser window). `painter` is the sidebar's, for
    // the symbols and the bar's glyphs. `keepInOwner`: a --capture run, where the popover is kept
    // inside the window rather than the screen (so the capture has all of it).
    static std::unique_ptr<SpaceIconPickerView> Create(HWND owner, IDWriteFactory* dwrite, SpaceIconPainter* painter, Callbacks callbacks,
                                                       bool keepInOwner, std::wstring& error);
    ~SpaceIconPickerView();
    SpaceIconPickerView(const SpaceIconPickerView&) = delete;
    SpaceIconPickerView& operator=(const SpaceIconPickerView&) = delete;

    // The compositor to draw with; null drops every GPU object (it closes).
    void UseCompositor(Compositor* compositor);

    // Opens `state`'s picker (OpenIconPicker's) for a space whose icon is `icon`, hanging from
    // `anchor` (the header's icon, the owner's client points) at the owner's `dpi`, in its
    // appearance. One already open closes first (present's shown?.close()). Empty on success.
    std::wstring Open(IconPickerState state, const std::string& icon, const PickerRect& anchor, UINT dpi, bool dark);
    // The space's icon after a pick: the bin comes or goes, and the frame with it.
    void SpaceChanged(const std::string& icon);
    void Close();
    bool IsOpen() const { return state_.has_value(); }
    std::optional<std::string> SpaceID() const { return state_ ? std::optional(state_->spaceID) : std::nullopt; }
    const std::optional<IconPickerState>& State() const { return state_; }

    // The owner's keys, characters, IME and focus while it's open (the search field's, and
    // Escape). True when it took `message`.
    bool HandleKey(UINT message, WPARAM wParam, LPARAM lParam);
    // The owner's timers: the caret's blink. True when `timer` was its.
    bool HandleTimer(WPARAM timer);
    // The wheel over it, as the owner got it (screen coordinates): true when it was over the picker.
    bool HandleWheel(WPARAM wParam, LPARAM lParam);
    // Types into Search as the keyboard would (the smoke test, a capture).
    void Type(std::string_view text);

    // For the tests: the popover's window, where content point (x, y) is in its client px,
    // the grid's cell `index` there (scrolled into view first), and its surfaces' draws so far.
    HWND Window() const { return window_; }
    POINT ContentToClient(float x, float y) const;
    std::optional<POINT> CellCentre(size_t index);
    size_t Draws() const { return draws_; }
    // The emoji grid's rows drawn and kept in its surface now.
    size_t RowsDrawn() const;

    // For --capture: the popover as it shows, drawn without its window, and its top-left in the
    // owner's client px.
    std::wstring Render(Pixels& out, POINT& origin);

    bool DeviceLost() const { return deviceLost_; }
    // The caret's blink (the owner's timer, a view's: 0x4B42–0x4B48 are taken).
    static constexpr UINT_PTR kCaretTimer = 0x4B49;

private:
    SpaceIconPickerView(HWND owner, IDWriteFactory* dwrite, SpaceIconPainter* painter, Callbacks callbacks, bool keepInOwner)
        : owner_(owner), dwrite_(dwrite), painter_(painter), callbacks_(std::move(callbacks)), keepInOwner_(keepInOwner),
          search_(owner, kCaretTimer) {}
    static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam);
    LRESULT Handle(UINT message, WPARAM wParam, LPARAM lParam);

    float Scale() const { return static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI; }
    // The layout, the cells and where the frame goes, for the state now; then the window there.
    void Relayout();
    void PlaceWindow();
    IconPickerPlacement Placement(bool inOwner) const;
    // A point of the window's client area (px) in the content's points.
    D2D1_POINT_2F ToContent(POINT client) const;

    bool MakeTree(HRESULT& hr);
    // Draws what's changed: the whole frame, or only its search field or a pressed cell, and the
    // emoji grid's rows that came into view. Commits.
    std::wstring Redraw();
    std::wstring DrawGridRows(HRESULT& hr);
    void PlaceGrid();
    void UpdateCaret();
    std::wstring Fail(const wchar_t* what, HRESULT hr);

    // The drawing, in the window's points (the frame's top-left at the origin).
    void PaintFrame(ID2D1DeviceContext* context);
    void PaintTabs(ID2D1DeviceContext* context);
    void PaintSearch(ID2D1DeviceContext* context);
    void PaintCategories(ID2D1DeviceContext* context);
    void PaintSymbols(ID2D1DeviceContext* context);
    // The emoji grid's rows [first, end), in the grid's own points (its top at 0).
    void PaintEmoji(ID2D1DeviceContext* context, size_t first, size_t end);
    void PaintGlyph(ID2D1DeviceContext* context, const SymbolGlyph& glyph, D2D1_POINT_2F centre, float size, float alpha);
    void PaintAll(ID2D1DeviceContext* context);  // a capture's: everything, the grid clipped and scrolled
    D2D1_COLOR_F Label(float alpha) const;

    // Pointer.
    void Press(D2D1_POINT_2F p);
    void Move(D2D1_POINT_2F p);
    void Release(D2D1_POINT_2F p);
    // The pressed control's look changed (it dims while held over it).
    void PressChanged();
    // State changes from the controls.
    void SetTab(IconPickerTab tab);
    void SetCategory(size_t category);
    void QueryEdited(TextEditing::Change change);
    void Scrolled();
    void Pick(const std::string& icon);

    HWND owner_;
    HWND window_ = nullptr;
    Microsoft::WRL::ComPtr<IDWriteFactory> dwrite_;
    SpaceIconPainter* painter_;
    Callbacks callbacks_;
    const bool keepInOwner_;
    Microsoft::WRL::ComPtr<IDWriteTextFormat> textFormat_, emojiFormat_;
    std::vector<Microsoft::WRL::ComPtr<IDWriteTextLayout>> tabTitles_;
    Microsoft::WRL::ComPtr<IDWriteTextLayout> placeholder_;

    Compositor* compositor_ = nullptr;
    Microsoft::WRL::ComPtr<IDCompositionTarget> target_;
    Microsoft::WRL::ComPtr<IDCompositionVisual> root_, frame_, gridClip_, grid_;
    Microsoft::WRL::ComPtr<IDCompositionVirtualSurface> frameSurface_, gridSurface_;
    Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> brush_;
    CaretVisual caret_;
    UINT frameWidth_ = 0, frameHeight_ = 0, gridWidth_ = 0, gridHeight_ = 0;
    std::vector<bool> rowsDrawn_;
    bool deviceLost_ = false;

    // What's open.
    std::optional<IconPickerState> state_;
    std::string icon_;
    PickerRect anchor_;
    UINT dpi_ = USER_DEFAULT_SCREEN_DPI;
    bool dark_ = true;
    IconPickerLayout layout_;
    IconPickerPlacement placement_;
    std::vector<std::string> cells_;
    TextLine search_;
    bool focused_ = false;  // the owner has the keyboard (the field's caret shows)
    // What needs drawing again: everything, or just these (frame px).
    bool frameDirty_ = true;
    std::vector<RECT> frameParts_;
    std::optional<size_t> gridPart_;  // an emoji cell to draw again alone
    std::optional<IconPickerHit> pressed_;
    bool pressedInside_ = false;
    bool selecting_ = false;  // a press in the field drags its selection
    size_t draws_ = 0;
};

}  // namespace kite
