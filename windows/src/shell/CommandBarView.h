#pragma once
// The command bar over the window (Ctrl+T): the Mac's CommandBarOverlay and CommandBarView,
// drawn to ArcMetrics.CommandBar. Its rows come from core (CommandBarSuggestions); this is
// the panel, its text field, the rows and the keyboard and mouse.
//
// It draws into its own DirectComposition target on the main window with topmost TRUE, so
// it shows over the page's child window, which the window's other target sits behind. It
// has no window of its own: while it's open the main window keeps the keyboard focus, and
// Chromium disables the page windows (Chromium::BlockInput), so clicks anywhere in the
// window reach the main window too (Windows hit-testing skips disabled child windows). A
// click outside the panel closes it, as on the Mac.
//
// The text field is Kite's own, since a Win32 edit control can't draw into DirectComposition:
// DirectWrite text, Windows' editing keys, the clipboard, and IME through the system's
// composition window placed at the caret.

#include <windows.h>  // first: the DirectX headers need its types

#include <d2d1_1.h>
#include <dcomp.h>
#include <dwrite.h>
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
#include "shell/Renderer.h"

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

    // The renderer it draws with; null drops every GPU object (before the renderer is
    // rebuilt after a lost device). An open bar draws again on the new one.
    void UseRenderer(Renderer* renderer);

    // Opens the bar, or switches an open bar's mode keeping what's typed (Ctrl+T while it's
    // open, as the Mac's showCommandBar). `text` fills a newly opened bar, all selected, as
    // an NSTextField selects its text when it takes focus: the tab's address for EditCurrent.
    void Show(CommandBarMode mode, const std::string& text, const Look& look);
    // Closes it (Escape, a click outside, Ctrl+W), handing the focus back.
    void Hide();
    bool IsOpen() const { return open_; }

    // The window was resized or moved to another DPI: the bar follows.
    void Layout();
    // The browser state changed while the bar is open (a title or address came in): the rows
    // are made again from it, keeping the highlighted one where it still exists.
    void Refresh();

    // The main window's messages, first: keys, characters, the mouse, the cursor, IME and the
    // caret's timer, while the bar is open. True when it handled `message` (with `result`).
    bool HandleMessage(UINT message, WPARAM wParam, LPARAM lParam, LRESULT& result);
    // Keys typed into a page as the bar opened (Chromium's held keys), in order.
    void ForwardKey(UINT virtualKey, bool ctrl, bool shift);
    void ForwardCharacter(wchar_t character);

    // Draws the bar now. With `readBack`, also copies its frame (premultiplied BGRA) there and
    // its top-left, in client pixels, into `origin` (for --capture). Empty on success.
    std::wstring Draw(Pixels* readBack = nullptr, POINT* origin = nullptr);
    // The GPU was reset or removed: the window rebuilds its renderer and calls UseRenderer.
    bool DeviceLost() const { return deviceLost_; }

private:
    CommandBarView(HWND window, Callbacks callbacks) : window_(window), callbacks_(std::move(callbacks)) {}

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
    void ComputeGeometry();
    float PanelHeight() const;
    void SetRows(std::vector<CommandSuggestion> rows);
    void BuildRowText();

    // Text editing.
    void SetText(std::wstring text, size_t caret, size_t anchor);
    void TextChanged();
    void SelectionChanged();
    void Insert(std::wstring_view text);
    void DeleteRange(size_t from, size_t to);
    bool HasSelection() const { return caret_ != anchor_; }
    size_t SelectionStart() const { return caret_ < anchor_ ? caret_ : anchor_; }
    size_t SelectionEnd() const { return caret_ < anchor_ ? anchor_ : caret_; }
    size_t PreviousCharacter(size_t at) const;
    size_t NextCharacter(size_t at) const;
    size_t PreviousWord(size_t at) const;
    size_t NextWord(size_t at) const;
    void Copy() const;
    void Paste();
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
    float LineHeight() const;  // the field's line, for the caret
    size_t TextIndexAt(float x) const;
    float CaretX() const;
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
    Renderer* renderer_ = nullptr;

    // Device-independent.
    Microsoft::WRL::ComPtr<ID2D1Factory1> d2dFactory_;
    Microsoft::WRL::ComPtr<IDWriteFactory> dwrite_;
    Microsoft::WRL::ComPtr<IDWriteTextFormat> fieldFormat_, rowFormat_, rowEllipsisFormat_;
    Microsoft::WRL::ComPtr<IDWriteTextFormat> iconFormat_, arrowFormat_;  // Segoe Fluent Icons / MDL2 Assets
    Microsoft::WRL::ComPtr<IDWriteInlineObject> ellipsis_;
    Microsoft::WRL::ComPtr<ID2D1StrokeStyle1> roundStroke_;
    std::wstring textFamily_;

    // GPU.
    Microsoft::WRL::ComPtr<IDCompositionDevice> composition_;
    Microsoft::WRL::ComPtr<IDCompositionTarget> target_;
    Microsoft::WRL::ComPtr<IDCompositionVisual> visual_;
    Microsoft::WRL::ComPtr<ID2D1Device> d2dDevice_;
    Microsoft::WRL::ComPtr<ID2D1DeviceContext> context_;
    Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> brush_;
    Microsoft::WRL::ComPtr<IDXGISwapChain1> swapChain_;
    Microsoft::WRL::ComPtr<ID2D1Bitmap1> backBuffer_;
    Microsoft::WRL::ComPtr<ID2D1Bitmap1> shadow_;  // the panel's shadow, outside the panel
    float shadowHeight_ = -1, shadowWidth_ = -1;
    UINT shadowDpi_ = 0;
    bool deviceLost_ = false;

    // State.
    bool open_ = false;
    CommandBarMode mode_ = CommandBarMode::NewTab;
    Look look_;
    Geometry geometry_;
    std::wstring text_;
    std::vector<bool> characterStarts_;  // per UTF-16 unit of text_, and one past the end
    size_t caret_ = 0, anchor_ = 0;      // UTF-16 offsets
    wchar_t highSurrogate_ = 0;
    float scrollX_ = 0;                  // how far the text is scrolled left, in points
    Microsoft::WRL::ComPtr<IDWriteTextLayout> textLayout_, placeholderLayout_;
    std::vector<CommandSuggestion> rows_;
    std::vector<RowText> rowText_;
    int highlighted_ = 0;
    bool caretOn_ = true;
    bool focused_ = true;
    bool selecting_ = false;  // dragging a selection in the field
    // What the left button went down on: a row's index, outside the panel, or nothing.
    static constexpr int kPressedNothing = -1;
    static constexpr int kPressedOutside = -2;
    int pressed_ = kPressedNothing;
};

}  // namespace kite
