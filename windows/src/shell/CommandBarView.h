#pragma once
// The command bar over the window (Ctrl+T): the Mac's CommandBarOverlay and CommandBarView,
// drawn to ArcMetrics.CommandBar. Its rows come from core (CommandBarSuggestions); this is
// the panel, its text field, the rows and the keyboard and mouse.
//
// It draws into the window's overlay (Compositor::Overlay), a DirectComposition target with
// topmost TRUE, so it shows over the page's child window, which the backdrop sits behind. It
// has no window of its own: while it's open the main window keeps the keyboard focus, and
// Chromium disables the page windows (Chromium::BlockInput), so clicks anywhere in the
// window reach the main window too (Windows hit-testing skips disabled child windows). A
// click outside the panel closes it, as on the Mac.
//
// The text field is Kite's own, since a Win32 edit control can't draw into DirectComposition:
// DirectWrite text, Windows' editing keys and the clipboard (shell/TextEditing, shell/TextLine), and IME
// through the system's composition window placed at the caret.

#include <windows.h>  // first: the DirectX headers need its types

#include <d2d1_1.h>
#include <dcomp.h>
#include <dwrite_3.h>
#include <dxgi1_3.h>
#include <wrl/client.h>

#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include "core/CommandBar.h"
#include "core/Models.h"
#include "shell/Capture.h"
#include "shell/Compositor.h"
#include "shell/Renderer.h"
#include "shell/TextLine.h"

namespace kite {

class CommandBarView {
public:
    struct Callbacks {
        // The rows for what's typed (core's CommandBarSuggestions over the current state).
        std::function<std::vector<CommandSuggestion>(std::string_view text, CommandBarMode mode)> suggestions;
        // Enter or a click on a row, after the bar has closed (as the Mac's commit).
        std::function<void(const CommandSuggestion& suggestion, CommandBarMode mode)> commit;
        // The bar opened: the pages stop taking input (Chromium::BlockInput).
        std::function<void()> opened;
        // The bar closed: the pages take input again, and the shown one the focus.
        std::function<void()> closed;
        // The DPI the window is laid out at (MainWindow::Dpi).
        std::function<UINT()> dpi;
    };
    // How the bar looks in the selected space: the window's appearance and the theme's accent
    // (core's Accent), which fills the highlighted row.
    struct Look {
        bool dark = true;
        ThemeColor accent{0.4f, 0.4f, 1.0f};
    };

    // Device-independent setup (Direct2D and DirectWrite factories, fonts). The GPU objects
    // come with UseRenderer.
    static std::unique_ptr<CommandBarView> Create(HWND window, Callbacks callbacks, std::wstring& error);
    ~CommandBarView();
    CommandBarView(const CommandBarView&) = delete;
    CommandBarView& operator=(const CommandBarView&) = delete;

    // The window's compositor, whose overlay it draws in and whose device it draws with; null
    // drops every GPU object (before the compositor is rebuilt after a lost device). An open
    // bar draws again on the new one.
    void UseCompositor(Compositor* compositor);

    // Opens the bar, or switches an open bar's mode keeping what's typed (Ctrl+T while it's
    // open, as the Mac's showCommandBar). `text` fills a newly opened bar, all selected, as
    // an NSTextField selects its text when it takes focus: the tab's address for EditCurrent.
    // It draws on the next pass of the message loop (as every change does, at most once a
    // frame), or now with Draw.
    void Show(CommandBarMode mode, const std::string& text, const Look& look);
    // Types `text` into the field, as the keyboard would (for --capture and the smoke test).
    void Type(std::string_view text);
    // Closes it (Escape, a click outside, Ctrl+W), handing the focus back.
    void Hide();
    bool IsOpen() const { return open_; }

    // The window was resized or moved to another DPI: the bar follows.
    void Layout();
    // The browser state changed while the bar is open (a title or address came in): the rows
    // are made again from it. Unchanged rows draw nothing; changed ones keep the highlight on
    // the same row (the same tab, or URL) when it's still there, so Enter never takes a row
    // that moved under it. (The Mac keeps the index.)
    void Refresh();

    // The main window's messages, first: keys, characters, the mouse, the cursor, IME and the
    // caret's timer, while the bar is open. True when it handled `message` (with `result`).
    bool HandleMessage(UINT message, WPARAM wParam, LPARAM lParam, LRESULT& result);
    // Keys typed into a page as the bar opened (Chromium's held keys), in order.
    void ForwardKey(UINT virtualKey, bool ctrl, bool shift);
    void ForwardCharacter(wchar_t character);

    // Draws the bar now, without the caret (its own visual). With `readBack`, also copies its
    // frame (premultiplied BGRA) there and its top-left, in client pixels, into `origin` (for
    // --capture). Empty on success.
    std::wstring Draw(Pixels* readBack = nullptr, POINT* origin = nullptr);

    // Posted to the window for the next draw (Invalidate).
    static constexpr UINT kRedrawMessage = WM_APP + 2;
    static constexpr UINT_PTR kCaretTimer = 0x4B42;  // 'KB'; Chromium's close deadline is 0x4B43

private:
    CommandBarView(HWND window, Callbacks callbacks) : window_(window), callbacks_(std::move(callbacks)), line_(window, kCaretTimer) {}

    struct RowText {
        Microsoft::WRL::ComPtr<IDWriteTextLayout> title, detail;
        float detailWidth = 0;
    };
    struct Geometry {
        UINT dpi = USER_DEFAULT_SCREEN_DPI;
        float scale = 1;
        float width = 0;       // the panel's, in points
        LONG leftPx = 0, topPx = 0;  // the panel's top-left in client pixels
        LONG marginPx = 0;     // room for the shadow around the panel, in the buffer
        UINT bufferWidth = 0, bufferHeight = 0;
    };

    bool CreateGpu(std::wstring& error);
    void ReleaseGpu();
    bool EnsureBuffer(std::wstring& error);
    bool EnsureShadow(float height, std::wstring& error);
    void ReleaseBuffers();
    // Something changed: one draw on the next pass of the message loop.
    void Invalidate();
    // Places, shows or hides the caret's visual (the blink), without drawing the panel.
    void UpdateCaret();
    void ComputeGeometry();
    float PanelHeight() const;
    void SetRows(std::vector<CommandSuggestion> rows);
    void BuildRowText();

    // Text editing (shell/TextEditing): what an edit changed redraws the field.
    void SetText(std::wstring text, size_t caret, size_t anchor);
    void TextChanged();
    void SelectionChanged();
    void Apply(TextEditing::Change change);
    bool KeyDown(UINT virtualKey, bool ctrl, bool shift);
    void Character(wchar_t character);
    void Commit();
    void SetHighlighted(int index);

    // Where things are, in points from the panel's top-left.
    D2D1_POINT_2F PanelPoint(LPARAM clientPixels) const;
    bool InPanel(D2D1_POINT_2F point) const;
    int RowAt(D2D1_POINT_2F point) const;
    bool InField(D2D1_POINT_2F point) const;
    float TextTop() const;     // where the field's text layout goes, for its baseline at 38.5
    size_t TextIndexAt(float x) const;
    void KeepCaretVisible();
    void PlaceImeWindow();
    void RestartCaretBlink();

    D2D1_COLOR_F Primary() const;  // white in a dark space, black in a light one
    D2D1_COLOR_F Accent() const;
    void DrawPanel(ID2D1DeviceContext* context, float height);
    void DrawField(ID2D1DeviceContext* context);
    void DrawRow(ID2D1DeviceContext* context, size_t index, float top);
    void Glyph(ID2D1DeviceContext* context, wchar_t glyph, float size, D2D1_RECT_F box, D2D1_COLOR_F color);

    HWND window_;
    Callbacks callbacks_;
    Compositor* compositor_ = nullptr;
    Renderer* renderer_ = nullptr;  // the compositor's

    // Device-independent.
    Microsoft::WRL::ComPtr<ID2D1Factory1> d2dFactory_;
    Microsoft::WRL::ComPtr<IDWriteFactory> dwrite_;
    Microsoft::WRL::ComPtr<IDWriteTextFormat> fieldFormat_, rowFormat_, rowEllipsisFormat_;
    Microsoft::WRL::ComPtr<IDWriteTextFormat> iconFormat_, arrowFormat_;  // Segoe Fluent Icons / MDL2 Assets
    Microsoft::WRL::ComPtr<IDWriteInlineObject> ellipsis_;
    Microsoft::WRL::ComPtr<ID2D1StrokeStyle1> roundStroke_;
    std::wstring textFamily_;

    // GPU.
    Microsoft::WRL::ComPtr<IDCompositionDevice> composition_;  // the compositor's
    Microsoft::WRL::ComPtr<IDCompositionVisual> visual_;        // in the compositor's overlay
    Microsoft::WRL::ComPtr<ID2D1Device> d2dDevice_;
    Microsoft::WRL::ComPtr<ID2D1DeviceContext> context_;
    Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> brush_;
    Microsoft::WRL::ComPtr<IDXGISwapChain2> swapChain_;
    HANDLE frameLatency_ = nullptr;
    Microsoft::WRL::ComPtr<ID2D1Bitmap1> backBuffer_;
    // The shadow, a Gaussian of the panel's rectangle: separable, so it's a row of its
    // horizontal falloff (per width and DPI) times a column of its vertical one (per height),
    // kept outside the panel by a mask.
    Microsoft::WRL::ComPtr<ID2D1Bitmap1> shadowRow_, shadowColumn_;
    Microsoft::WRL::ComPtr<ID2D1BitmapBrush1> shadowColumnBrush_;
    Microsoft::WRL::ComPtr<ID2D1PathGeometry> outsidePanel_;
    float shadowWidth_ = -1, shadowHeight_ = -1;
    UINT shadowDpi_ = 0;
    // The caret: its own visual over the panel, so a blink is a Commit, not a redraw.
    CaretVisual caret_;
    bool deviceLost_ = false;
    bool redrawPosted_ = false;
    bool drawOnRestore_ = false;  // a draw came while the window was minimized

    // State.
    bool open_ = false;
    CommandBarMode mode_ = CommandBarMode::NewTab;
    Look look_;
    Geometry geometry_;
    TextLine line_;  // the field's text, caret, selection, layout and blink
    Microsoft::WRL::ComPtr<IDWriteTextLayout> placeholderLayout_;
    std::vector<CommandSuggestion> rows_;
    std::vector<RowText> rowText_;
    int highlighted_ = 0;
    bool focused_ = true;
    bool composing_ = false;  // an IME composition is open
    bool selecting_ = false;  // dragging a selection in the field
    // What the left button went down on: a row's index, outside the panel, or nothing.
    static constexpr int kPressedNothing = -1;
    static constexpr int kPressedOutside = -2;
    int pressed_ = kPressedNothing;
    int hoveredRow_ = -1;  // the row under the pointer, -1 for none
};

}  // namespace kite
