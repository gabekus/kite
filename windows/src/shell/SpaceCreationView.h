#pragma once
// Arc's Create a Space page, which + › New Space opens in place of everything under the sidebar's
// top row: the Mac's SpaceCreationView (SpaceCreationView.swift). Three cards fanned out, "Create
// a Space" and its line about spaces, the name field ("Space name…"), Kite's own "What's it for?"
// field, the profile with its pill, Choose a Theme, then Create Space (enabled once there's a
// name) and Cancel at the bottom. Return in either field creates, Escape cancels, Tab moves
// between the fields. What sits where is core's (core/SpaceCreation.h's LayOutSpaceCreation);
// SidebarView owns it, puts it in the sidebar's root (so it slides with the sidebar) and hands it
// the pointer; the window controller hands it the keyboard (its KeyboardField::Creation).
//
// Its own visuals in the sidebar, each with its own surface: the page (drawn when it opens, and
// again only for a new size, scale, appearance or profile), each field (a keystroke draws only
// its field), and Create Space (drawn again only when it turns on or off). The fields are
// shell/TextField, so their carets are visuals of their own and a blink draws nothing. Nothing
// runs while it's idle but the focused field's blink, which Windows' caret timeout ends.

#include <windows.h>  // first: the DirectX headers need its types

#include <d2d1_1.h>
#include <dcomp.h>
#include <dwrite.h>
#include <wrl/client.h>

#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <string_view>

#include "core/SpaceCreation.h"
#include "shell/Capture.h"
#include "shell/Compositor.h"
#include "shell/TextField.h"

namespace kite {

class SpaceCreationView {
public:
    enum class Field { Name, About };
    struct Callbacks {
        // Return in a field, or Create Space, with a name (CanCreateSpace): the controller makes it.
        std::function<void(const std::string& name, const std::string& about)> create;
        // Cancel, or Escape in a field.
        std::function<void()> cancel;
        // The Choose a Theme row: its popover (`row`, window points, to hang it from).
        std::function<void(const BarRect& row)> chooseTheme;
        // The profile's pill: its menu, at `screen` (px, under the pill).
        std::function<void(POINT screen)> profileMenu;
        // A press in `field` while it doesn't have the keyboard: the controller takes it from its
        // other fields first (GiveKeyboard), so one caret is left, then focuses `field` (Focus).
        std::function<void(Field field)> takeKeyboard;
        // A draw of its own (a keystroke's, the caret's, the focus's) failed: the owner draws again
        // on its next pass, which rebuilds the GPU when it's gone.
        std::function<void()> drawFailed;
    };
    // What it shows besides its own fields: the space's appearance and its profile's name, and
    // whether the pill's menu can change it.
    struct Model {
        bool dark = true;
        std::string profile = "Default";
        bool profileEnabled = true;
        bool operator==(const Model&) const = default;
    };

    static std::unique_ptr<SpaceCreationView> Create(HWND window, IDWriteFactory* dwrite, std::wstring& error);
    ~SpaceCreationView();
    SpaceCreationView(const SpaceCreationView&) = delete;
    SpaceCreationView& operator=(const SpaceCreationView&) = delete;

    void SetCallbacks(Callbacks callbacks) { callbacks_ = std::move(callbacks); }
    // The compositor and the visual it sits in (the sidebar's root); null drops every GPU object.
    void UseCompositor(Compositor* compositor, IDCompositionVisual* parent);
    // The sidebar's width and the window's height (points) and scale.
    void Layout(float width, float height, UINT dpi);
    // Where the sidebar's leading edge is in the window (points), for the IME's window and the
    // system caret.
    void SetLeft(float left);

    // The page appears (onAppear) with its fields empty, or shows `model` when it's already there.
    void Show(const Model& model);
    // It goes (its fields with it, as the Mac's view and its @State do), the keyboard too.
    void Hide();
    bool Shown() const { return shown_; }

    // The keyboard: `field` takes it (its text all selected with `selectAll`), the window taking
    // the focus when it's the one in front; or it goes (a press elsewhere, the page, another field
    // of Kite's), the selection collapsing as the Mac's field editor ends.
    void Focus(Field field, bool selectAll = false);
    void LoseKeyboard();
    bool HasKeyboard() const { return shown_ && keyboard_.has_value(); }
    std::optional<Field> KeyboardField() const { return shown_ ? keyboard_ : std::nullopt; }

    // The pointer, in the sidebar's points (SidebarView's). Press: true when it's on the page
    // (anywhere between the top row and the bar), which takes it. Release acts on what was pressed
    // when it's let go over it, as a button does.
    bool Contains(D2D1_POINT_2F p) const;
    bool Press(D2D1_POINT_2F p, bool shift);
    void Move(D2D1_POINT_2F p);
    void Release(D2D1_POINT_2F p);
    void CaptureLost();
    bool OverField(D2D1_POINT_2F p) const;
    // The window's keys, characters, IME, focus and the carets' timers, while it's shown. True
    // when it took `message`.
    bool HandleKey(UINT message, WPARAM wParam, LPARAM lParam);

    bool NeedsDraw() const;
    // Draws what changed and places the carets; with `readBack`, always, also the page as it
    // shows (premultiplied BGRA, the sidebar's width from the window's top-left). The caller commits.
    std::wstring Draw(Pixels* readBack = nullptr);
    bool DeviceLost() const { return deviceLost_; }

    // For kitecore's and the tests' sake: what it lays out, a field's text (and typing into it as
    // the keyboard would), Create Space's state, where a part's middle is (sidebar points), and
    // how many times each surface has drawn.
    const SpaceCreationLayout& Geometry() const { return layout_; }
    std::string Text(Field field) const;
    void Type(Field field, std::string_view text);
    bool CanCreate() const;
    std::optional<D2D1_POINT_2F> CentreOf(SpaceCreationPart part) const;
    size_t PageDraws() const { return pageDraws_; }
    size_t FieldDraws() const { return fieldDraws_; }
    size_t CreateDraws() const { return createDraws_; }
    // For the smoke test, whose window never has the keyboard (a quiet run never comes to the front):
    // the fields act as when it has, so their system carets and focus can be checked.
    void AssumeWindowFocusForTest(bool assume) {
        assumeFocus_ = assume;
        FocusChanged();
    }
    bool FieldFocused(Field field) const { return FieldOf(field).Focused(); }

    // The fields' caret blinks (view timers: 0x4B42 to 0x4B49 are taken or reserved, W9e's icon
    // picker's caret at 0x4B49).
    static constexpr UINT_PTR kNameCaretTimer = 0x4B4A;   // the name field's caret (W9f)
    static constexpr UINT_PTR kAboutCaretTimer = 0x4B4B;  // the about field's caret (W9f)

private:
    SpaceCreationView(HWND window, IDWriteFactory* dwrite)
        : window_(window), dwrite_(dwrite), name_(window, kNameCaretTimer), about_(window, kAboutCaretTimer) {}

    struct FieldGpu {
        Microsoft::WRL::ComPtr<IDCompositionVisual> visual;  // at the field's box: the caret's parent
        Microsoft::WRL::ComPtr<IDCompositionVirtualSurface> surface;
        UINT width = 0, height = 0;
        bool dirty = true;
    };
    TextField& FieldOf(Field field) { return field == Field::Name ? name_ : about_; }
    const TextField& FieldOf(Field field) const { return field == Field::Name ? name_ : about_; }
    FieldGpu& GpuOf(Field field) { return field == Field::Name ? nameGpu_ : aboutGpu_; }
    const BarRect& BoxOf(Field field) const { return field == Field::Name ? layout_.nameField : layout_.aboutField; }
    float Scale() const { return static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI; }
    void PlaceFields();
    void Measure();
    // A field changed: it draws again, and Create Space with it when the name turns it on or off.
    void Edited(Field field, TextField::Change change);
    void FocusChanged();
    // Draws what an input changed now and commits (a field's own redraw); a failure goes to drawFailed.
    void Redraw();
    void Submit();
    LOGFONTW FieldFont() const;
    void ReleaseGpu();
    std::wstring DrawField(Field field, Pixels* readBack);
    void DrawPage(ID2D1DeviceContext* context);
    void DrawCreate(ID2D1DeviceContext* context);
    void DrawIllustration(ID2D1DeviceContext* context);
    void DrawDashedPlus(ID2D1DeviceContext* context, D2D1_POINT_2F centre, D2D1_COLOR_F color);
    void Glyph(ID2D1DeviceContext* context, wchar_t glyph, float size, D2D1_POINT_2F centre, D2D1_COLOR_F color);
    // `text` in `format` with its SwiftUI line box of `lineHeight` from `top` (several lines that far
    // apart), its baseline where SF Pro's is, left-aligned from `left` or centred in `box`.
    void DrawLabel(ID2D1DeviceContext* context, std::string_view text, IDWriteTextFormat* format, float lineHeight, const BarRect& box,
                   bool centred, D2D1_COLOR_F color);
    float Width(std::string_view text, IDWriteTextFormat* format) const;
    D2D1_COLOR_F Primary(float alpha) const;

    HWND window_;
    IDWriteFactory* dwrite_;
    Callbacks callbacks_;
    Compositor* compositor_ = nullptr;
    IDCompositionVisual* parent_ = nullptr;

    Microsoft::WRL::ComPtr<IDWriteTextFormat> titleFormat_, subtitleFormat_, rowFormat_, rowBoldFormat_, pillFormat_, cancelFormat_,
        iconFormat_;
    std::wstring textFamily_;

    // GPU.
    Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> brush_;
    Microsoft::WRL::ComPtr<IDCompositionVisual> visual_, createVisual_;
    Microsoft::WRL::ComPtr<IDCompositionVirtualSurface> surface_, createSurface_;
    UINT surfaceWidth_ = 0, surfaceHeight_ = 0, createWidth_ = 0, createHeight_ = 0;
    FieldGpu nameGpu_, aboutGpu_;
    bool deviceLost_ = false;

    // State.
    bool shown_ = false;
    Model model_;
    float width_ = 240, height_ = 820, left_ = 0;
    UINT dpi_ = USER_DEFAULT_SCREEN_DPI;
    SpaceCreationLayout layout_ = LayOutSpaceCreation(240, 820);
    BarRect pill_;            // the profile's pill (measured)
    float cancelWidth_ = 44;  // Cancel's label
    bool dirty_ = true, createDirty_ = true, placed_ = false;
    bool canCreate_ = false;  // as Create Space last drew
    std::optional<Field> keyboard_;
    std::optional<SpaceCreationPart> pressed_;  // a button held (Create Space, Cancel, the row, the pill)
    std::optional<Field> selecting_;            // a field being drag-selected
    TextField name_, about_;
    size_t pageDraws_ = 0, fieldDraws_ = 0, createDraws_ = 0;
    bool assumeFocus_ = false;  // AssumeWindowFocusForTest
};

}  // namespace kite
