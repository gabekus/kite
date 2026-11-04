#pragma once
// The sidebar, drawn to ArcMetrics.Sidebar: the address field, then the selected space's page
// (its header, pinned tabs and folders, the divider, New Tab and today's tabs). The Mac's
// SidebarColumnView, SidebarHeaderView's address field and SidebarSpaceList's rows
// (SidebarColumn.swift, SidebarHeader.swift, SidebarList.swift, SidebarListCells.swift,
// SidebarListRows.swift). What it lists comes from core (SidebarRows).
//
// It's DirectComposition surfaces in the window's chrome (Compositor::Chrome), over the backdrop
// and behind the page, drawn with Direct2D and DirectWrite only when what they show changes: the
// address field's, and one per built space page (the Mac's SidebarPagesView). The pages sit in a
// strip, each at its space's place a sidebar's width apart, and a space switch's slide is a
// DirectComposition animation of the strip's offset (SlidePages), so no frame of it runs Kite's
// code or draws anything. It shows hover and takes
// clicks and the wheel (HandleMouse); what a click does goes to Actions. Under the pages, the
// space bar (shell/SpaceBarView), whose cells drag to new places, and the space's menu on a
// right-click on a cell or the header (Actions::spaceMenu). While a space is renamed its header
// shows the name field (shell/SpaceRenameField). Over the address field, the top row: the toggle,
// back, forward and reload, each its own visual (shell/SidebarTopRowView). Everything sits in one
// root visual, which hiding and showing the sidebar slides on the compositor (SetShown, the Mac's
// updateSidebar). Not yet: favorites.

#include <windows.h>  // first: the DirectX headers need its types

#include <d2d1_1.h>
#include <dcomp.h>
#include <dwrite.h>
#include <wrl/client.h>

#include <filesystem>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "core/Models.h"
#include "core/Sidebar.h"
#include "core/SidebarTopRow.h"
#include "core/SpaceSwipe.h"
#include "shell/Capture.h"
#include "shell/Compositor.h"
#include "shell/Favicons.h"
#include "shell/SpaceBarView.h"
#include "shell/SpaceIconPainter.h"
#include "shell/SidebarTopRowView.h"
#include "shell/SpaceRenameField.h"
#include "shell/SpaceTipView.h"

namespace kite {

class SidebarView {
public:
    // `favicons` may be null (a capture): every tab shows the globe. `pictures` is where the
    // spaces' pictures come from (SpaceIconPainter); a synchronous one's (a capture's) sidebar
    // has no tooltips.
    static std::unique_ptr<SidebarView> Create(HWND window, Favicons* favicons, const SpaceIconPainter::Pictures& pictures,
                                               std::wstring& error);
    ~SidebarView();
    SidebarView(const SidebarView&) = delete;
    SidebarView& operator=(const SidebarView&) = delete;

    // What clicks do (the Mac's tapped(at:) and the header's buttons). Each changes the session;
    // the caller then calls Update.
    struct Actions {
        std::function<void(const std::string& tabID)> selectTab;
        std::function<void(const std::string& folderID, bool expanded)> setFolderExpanded;
        std::function<void(const std::string& spaceID)> togglePinnedSection;
        std::function<void()> newTab;       // the New Tab row
        std::function<void()> editAddress;  // the address field
        std::function<void(const std::string& tabID)> closeTab;  // a tab's close button
        std::function<void(const std::string& spaceID)> selectSpace;  // a space's cell in the bar
        // A cell dropped at `index` among the others, once it has settled.
        std::function<void(const std::string& spaceID, size_t index)> moveSpace;
        // A right-click on a space's cell or its header: its menu at `screen` (px).
        std::function<void(const std::string& spaceID, POINT screen)> spaceMenu;
        // The header's name field committed (Return, Done, or leaving it) with `name`.
        std::function<void(const std::string& spaceID, const std::string& name)> renameSpace;
        // A click on the current space's name: its rename field (the Mac's beginRenaming).
        std::function<void(const std::string& spaceID)> beginRenaming;
        // A click on an enabled top-row button (the toggle, back, forward, reload).
        std::function<void(TopRowButton button)> topRow;
    };
    void SetActions(Actions actions) { actions_ = std::move(actions); }

    // The window's mouse messages (client coordinates; the wheel's in screen ones): hover, presses
    // and releases over the sidebar, and the wheel over its list. True when it took `message`.
    // As on the Mac, the click that brings the window forward doesn't tap a row (rows don't
    // accept first mouse); it does press the address field, the chevron and a close button.
    bool HandleMouse(UINT message, WPARAM wParam, LPARAM lParam);
    // Forgets the pointer and any press (the command bar opened over the window).
    void ClearHover();

    // Renaming a space in its header (the Mac's renamingSpaceID): the selected space's, whose
    // header shows the name field (shell/SpaceRenameField) instead of its name, with the keyboard.
    // EndRenaming commits what's typed (renameSpace) or, with `commit` false, drops it.
    void BeginRenaming(const std::string& spaceID, const std::string& name);
    void EndRenaming(bool commit);
    // Closes the field and gives back its space and what was typed, renaming nothing (the
    // window renames it in the same update that ends it).
    std::optional<std::pair<std::string, std::string>> TakeRename();
    std::optional<std::string> Renaming() const;
    // The window's keys, characters, IME and focus while renaming (after the command bar's).
    // True when the field took `message`.
    bool HandleKey(UINT message, WPARAM wParam, LPARAM lParam);
    // Types into the field as the keyboard would (--capture, the smoke test).
    void TypeInRename(std::string_view text);
    // A drag of a space's cell that's still settling (its drop's move comes on the timer).
    bool DraggingSpace() const { return bar_->Drag().has_value(); }
    std::optional<std::string> DraggedSpace() const { return bar_->Drag() ? std::optional(bar_->Drag()->spaceID) : std::nullopt; }
    // For the tests: the rename's Done, its centre in client px; and the rename drawn with the
    // keyboard (a quiet capture's window never has it), its selection in the focused colour.
    std::optional<POINT> RenameDoneCentre() const;
    // The middle of the selected space's name in its header, client px (a click there renames).
    std::optional<POINT> HeaderNameCentre();
    void FocusRenameForCapture();
    // Where space `index`'s cell is, in client px (its centre), for the tests' presses and the
    // menu's place.
    std::optional<POINT> SpaceCellCentre(size_t index) const;
    // A left press went to something else (the command bar): the click that brought the window
    // forward is over, and the next one on a row taps.
    void ForgetActivation();

    // The window's compositor, whose chrome it draws in; null drops every GPU object (before
    // the compositor is rebuilt after a lost device).
    void UseCompositor(Compositor* compositor);

    // Hiding and showing the sidebar (the Mac's updateSidebar): it slides off the window's left
    // edge, or back, on ArcMetrics.Motion's curve on the compositor from the next commit, from
    // wherever it is (a toggle caught mid-slide turns back). How long that takes, in seconds; 0
    // when it's there at once (`animate` false, or no GPU yet). Hidden, it takes no pointer, its
    // tooltips and tip go, and any press or hover with them.
    double SetShown(bool shown, bool animate);
    // The slide has ended (the caller's timer): at rest.
    void SettleToggle();
    bool Shown() const { return shown_; }
    // Where its leading edge is now, in points (mid-slide too).
    float Left() const;
    // The selected tab's page as the top row shows it (back, forward, the X while it loads).
    void SetPageStatus(const PageStatus& page);
    // The top row's buttons, for kitecore's and the tests' sake, and where one's centre is in
    // client px; how many of its surfaces have drawn.
    const std::vector<TopRowItem>& TopRowItems() const { return topRow_->Items(); }
    std::optional<POINT> TopRowCentre(TopRowButton button) const;
    size_t TopRowSurfaceDraws() const { return topRow_->SurfaceDraws(); }

    // What it shows: the address, and the selected space's page with its neighbours' (or,
    // while the pages settle after a switch, those of `anchor`, the space it left:
    // SpaceSwipe::BuiltPages), all in the selected space's appearance. When anything changed,
    // it draws on the next pass of the message loop.
    void Update(const BrowserState& state, const std::optional<std::string>& anchor = std::nullopt);
    // Where the strip of pages sits, in points from rest (positive shows the previous space's
    // page coming in from the left), the bar's light with it (a swipe's frame). Shown at the
    // compositor's next commit; draws nothing.
    void SetPageOffset(float offset);
    // The strip settles from `from` to `to` points with Arc's page spring, on the compositor
    // from the next commit (core's SettleSegments). How long that takes, in seconds; 0 when
    // it's there at once (no GPU yet, or no distance), then SetPageOffset(to) is done.
    double SlidePages(float from, float to);
    // Where the strip is now, mid-slide too (for hit tests, and a slide caught mid-way).
    float PageOffset() const;
    // A touchpad's scroll at `at` (client px): over the selected space's list it scrolls by
    // `distance` points (positive moves it on, down the list) and is the list's (true).
    bool ScrollList(POINT at, float distance);
    // The selected space's list's scroll, in points.
    float ListScroll() const { return scrollExact_; }
    // The window's size or DPI changed: `width` is the sidebar's, in points. Draw follows.
    void Layout(float width, UINT dpi);
    // Icons arrived (Favicons::TakeResults): the pages, whose rows wait for them, draw again
    // (the address field has none).
    void InvalidatePages();
    // On the pictures' message: the bar's cells and the headers showing those that arrived draw again.
    void PicturesArrived();

    // Draws now if anything changed since the last draw; with `readBack`, always, also
    // copying the sidebar (premultiplied BGRA, at the window's top-left) there for --capture.
    // The caller commits the compositor. Empty on success.
    std::wstring Draw(Pixels* readBack = nullptr);
    bool DeviceLost() const { return deviceLost_ || (bar_ && bar_->DeviceLost()) || (topRow_ && topRow_->DeviceLost()); }

    // The window's messages: its posted redraw, and the space tip's timer. True when it handled
    // `message`; if the GPU was lost meanwhile, DeviceLost says so and the window rebuilds.
    bool HandleMessage(UINT message, WPARAM wParam);
    static constexpr UINT kRedrawMessage = WM_APP + 3;
    static constexpr UINT_PTR kTipTimer = 0x4B44;  // 'KD'; the command bar's caret is 0x4B42
    // A drop's landing: the space moves once its icon has settled (kReorderSlide).
    static constexpr UINT_PTR kDropTimer = 0x4B46;

    // Hides the space tip: the window moved, resized or minimized (an owned window would come
    // back with it, where it was).
    void HideTip();
    // For --capture: space `index`'s tip as it shows at rest over its cell, at the window's
    // scale, and its top-left in client px.
    std::wstring RenderTip(size_t index, Pixels& out, POINT& origin);

private:
    SidebarView(HWND window, Favicons* favicons) : window_(window), favicons_(favicons) {}
    // The bar's hovered cell changed: the tip goes, and a new one comes kTipDelay later.
    void TipHoverChanged(const std::optional<std::string>& spaceID);
    // The timer: the tip over the cell still hovered (SpaceCellView's tipWork).
    void ShowTip();
    // Space `spaceID`'s cell in window points.
    std::optional<BarRect> CellInWindow(const std::string& spaceID) const;

    // A built space page: its rows, drawn into its own surface.
    struct PageModel {
        std::string spaceID;
        size_t index = 0;  // the space's place in the session
        std::vector<SidebarRow> rows;
        bool operator==(const PageModel&) const = default;
    };
    struct Model {
        bool dark = true;
        std::string address;
        std::vector<SidebarRow> rows;  // the selected space's page
        std::string spaceID;
        size_t index = 0;  // the selected space's
        std::vector<PageModel> pages;  // in the session's order, the selected one among them
        bool hasTab = false;  // the top row's reload
        bool operator==(const Model&) const = default;
    };
    using FaviconKey = std::pair<std::string, UINT>;
    struct Page {
        Microsoft::WRL::ComPtr<IDCompositionVisual> visual;
        Microsoft::WRL::ComPtr<IDCompositionVirtualSurface> surface;
        UINT width = 0, height = 0;
        bool dirty = true;
        std::set<FaviconKey> icons;  // the favicons its last draw showed
    };

    bool CreateGpu(std::wstring& error);
    void ReleaseGpu();
    // The root visual everything sits in (made with the compositor, so the bar and the top row have
    // their parent), and where it's placed (at rest, or on the toggle's slide).
    void ReleaseRoot();
    void PlaceRoot();
    void DrawHeader(ID2D1DeviceContext* context);
    void DrawPage(ID2D1DeviceContext* context, const PageModel& page, float scroll, float bottom, bool selected);
    // The scroll a page draws at: the selected one's, or where another was left.
    float PageScroll(const PageModel& page) const;
    std::wstring DrawPageSurface(const PageModel& page, Page& surfaces, Pixels* readBack);
    void PlacePages();
    void PlaceStrip();
    // What has to draw again; ScheduleDraw draws it on the message loop's next pass.
    void InvalidateSelectedPage();
    void ScheduleDraw();
    bool NeedsDraw() const;
    void DrawRow(ID2D1DeviceContext* context, const SidebarRow& row, float top, bool hovered);
    D2D1_POINT_2F PointOf(POINT client) const;
    float Height() const;  // the window's, in points
    SidebarHit HitAt(D2D1_POINT_2F point) const;
    // A point in the sidebar as the selected page sees it, with the strip's offset.
    D2D1_POINT_2F OnPage(D2D1_POINT_2F point) const;
    void RefreshHover();
    // A point in the sidebar as the space bar sees it, when it's over the bar.
    std::optional<D2D1_POINT_2F> BarPoint(D2D1_POINT_2F point) const;
    // The drag of a cell, from the press that started it, to its drop and its landing.
    void DragSpaceTo(D2D1_POINT_2F barPoint);
    void DropSpace(D2D1_POINT_2F barPoint);
    void FinishDrop();
    // Where the rename field sits over the header drawn at `top` (DrawRow's).
    void PlaceRenameField(float x, float top);
    // The header's name as DrawRow lays it out at `top` (page points): where a click renames.
    D2D1_RECT_F HeaderNameRect(const SidebarRow& row, float top);
    void SetScroll(float scroll);
    bool OverList(D2D1_POINT_2F p) const;
    void Perform(const SidebarTap& tap);
    void DrawText(ID2D1DeviceContext* context, const std::string& text, IDWriteTextFormat* format, float x, float baseline,
                  float maxWidth, D2D1_COLOR_F color);
    void DrawGlyph(ID2D1DeviceContext* context, wchar_t glyph, float size, D2D1_RECT_F box, D2D1_COLOR_F color);
    void DrawFavicon(ID2D1DeviceContext* context, const SidebarRow& row, D2D1_RECT_F box);
    float Baseline(IDWriteTextFormat* format);
    D2D1_COLOR_F Primary(float alpha) const;

    HWND window_;
    Favicons* favicons_;
    Compositor* compositor_ = nullptr;

    // Device-independent.
    Microsoft::WRL::ComPtr<IDWriteFactory> dwrite_;
    Microsoft::WRL::ComPtr<IDWriteTextFormat> addressFormat_, headerFormat_, tabFormat_, folderFormat_, emojiFormat_, iconFormat_;
    std::map<IDWriteTextFormat*, float> baselines_;  // each format's first baseline from its line's top

    // GPU (drawn with the compositor's context).
    Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> brush_;
    // The root (what hiding slides), in it the address field's visual and surface, then over it
    // the pages: a container that clips them to the sidebar, the strip in it that the slide
    // moves, and each page in the strip.
    Microsoft::WRL::ComPtr<IDCompositionVisual> root_, visual_, pagesClip_, strip_;
    Microsoft::WRL::ComPtr<IDCompositionVirtualSurface> surface_;
    std::map<std::string, Page> pages_;  // by space id: the built pages' GPU side
    std::map<FaviconKey, Microsoft::WRL::ComPtr<ID2D1Bitmap1>> faviconBitmaps_;
    std::unique_ptr<SpaceIconPainter> icons_;  // the headers' and the bar's symbols and pictures
    std::set<FaviconKey>* drawnIcons_ = nullptr;  // the page being drawn's
    UINT surfaceWidth_ = 0, surfaceHeight_ = 0;
    UINT clipWidth_ = 0;  // the pages' clip, in px
    bool deviceLost_ = false;

    // State.
    Model model_;
    float width_ = 240;
    UINT dpi_ = USER_DEFAULT_SCREEN_DPI;
    bool dirty_ = true;  // the address field
    float pageOffset_ = 0;  // the strip's, in points: at rest, or where a slide ends
    std::vector<size_t> built_;  // the built pages' spaces, by index (model_.pages')
    struct Slide {
        std::vector<CubicSegment> segments;
        double duration;
        float to;
        double start;  // FrameClock seconds
        Microsoft::WRL::ComPtr<IDCompositionAnimation> animation;
    };
    std::optional<Slide> slide_;
    bool barSlidePending_ = false;  // the bar relights with the slide once it has the new cells
    bool redrawPosted_ = false;
    std::unique_ptr<SpaceBarView> bar_;
    std::unique_ptr<SidebarTopRowView> topRow_;
    PageStatus page_;
    // Hidden or shown, and the slide there: from and to (points, the leading edge), since when.
    bool shown_ = true;
    struct Toggle {
        float from, to;
        double start;  // FrameClock seconds
        Microsoft::WRL::ComPtr<IDCompositionAnimation> animation;
    };
    std::optional<Toggle> toggle_;
    std::unique_ptr<SpaceTipView> tip_;
    std::unique_ptr<SpaceRenameField> rename_;  // while a space is renamed
    Microsoft::WRL::ComPtr<IDWriteTextFormat> doneFormat_;  // the rename's Done
    bool barDragging_ = false;  // the press on a cell dragged it (BeginDrag)
    bool renamePressed_ = false;  // a left press went to the rename field
    std::map<std::string, SpaceTip> tips_;  // each space's, by id (from the last Update)
    std::optional<std::string> tipHover_;  // the cell the tip's timer, or the tip, is for

    // Pointer.
    Actions actions_;
    float scroll_ = 0;                // points the list is drawn scrolled down (whole pixels)
    float scrollExact_ = 0;           // and where the wheel has taken it
    std::map<std::string, float> scrolls_;  // other spaces' places in their lists
    std::optional<POINT> pointer_;    // client px, while it's over the window
    bool trackingLeave_ = false;
    std::optional<std::pair<SidebarRow::Kind, std::string>> hover_;  // the hovered row's kind and id
    std::optional<SidebarPress> press_;
    std::optional<SpaceBarPress> barPress_;  // a press on a space's cell (core's)
    std::optional<TopRowButton> topPress_;   // a press on an enabled top-row button
    bool activating_ = false;         // the next press brings the window forward
    int clicks_ = 0;
    DWORD lastClickTime_ = 0;
    POINT lastClickAt_{};
};

}  // namespace kite
