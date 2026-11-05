// See SidebarView.h.

#include "shell/SidebarView.h"

#include <d3d11.h>
#include <windowsx.h>

#include <algorithm>
#include <cmath>

#include "core/OKLab.h"
#include "core/SpaceSwipe.h"
#include "core/SymbolShape.h"
#include "shell/Errors.h"
#include "shell/FrameClock.h"
#include "shell/Text.h"

using Microsoft::WRL::ComPtr;

namespace kite {

namespace {

// ArcMetrics.Sidebar, in points: the rows' geometry from core, and how the view draws them.
namespace M {
using namespace sidebar_metrics;
constexpr float kUrlFieldTextInset = 12;
constexpr float kUrlFieldFontSize = 13;
constexpr float kUrlFieldTextOpacity = 0.6f;
constexpr float kCornerRadius = 11;  // the address field and the pills
constexpr float kFieldFill = 0.10f;  // white over the theme, for the address field
constexpr float kHeaderIconX = 13;   // in the window
constexpr float kHeaderTextX = 41;   // in the window
constexpr float kHeaderFontSize = 13;
constexpr float kHeaderTextOpacity = 0.45f;
// SpaceIconImageView's size in the header: emoji, symbols, pictures. The drawn symbols' header
// places are for this size (PlaceDrawnSymbol), so it's theirs.
constexpr float kHeaderIconFontSize = kHeaderSymbolSize;
constexpr float kDoneFontSize = kHeaderFontSize - 1;  // the rename's Done (SidebarDoneButton)
constexpr float kIconSize = 18;
constexpr float kIconTextGap = 8;
constexpr float kNestingIndent = 16;
constexpr float kTabFontSize = 14;
constexpr float kTabTextOpacity = 0.865f;
constexpr float kSelectedFill = 0.20f;
constexpr float kSelectedFillLight = 0.85f;
// A hovered pill: white 10% on a dark theme. A hovered tab on a light one is a dark wash
// instead (tabPillFill); folders and New Tab keep the white wash, 3.5 times as strong.
constexpr float kHoverFill = 0.10f;
constexpr float kHoverFillLight = 0.05f;
constexpr D2D1_COLOR_F kHoverWashLight{0.055f, 0.059f, 0.063f, kHoverFillLight};
constexpr float kDividerInset = 10;
constexpr float kDividerThickness = 0.5f;
constexpr float kDividerOpacity = 0.08f;
}  // namespace M

// NSColor.labelColor: black (light) or white (dark) at 85%. The Mac's sidebar labels are that
// colour, faded further by their view's alphaValue.
constexpr float kLabelAlpha = 0.85f;
// The Mac's SidebarLabel line box: SF Pro's ascender plus descender (0.952 + 0.241 of the
// size), rounded up to whole points; its text sits in the middle of the row, rounded down,
// with SF's baseline at the ascender. Kite puts Segoe UI's baseline where SF's is.
constexpr float kAscender = 0.952f;
constexpr float kDescender = 0.241f;
float LineHeight(float size) { return std::ceil(size * (kAscender + kDescender)); }
// The text's top in a box `height` tall: SidebarLabel's centring, half a point when odd.
float TextTop(float height, float line) {
    return std::floor((height - line) / 2) + std::fmod(height - line, 2.0f) / 2;
}
// Folder rows' trailing chevron (chevron.right, 9pt bold) is about this wide; its slot and
// gap stay reserved even while it's hidden (the Mac shows it on hover).
constexpr float kFolderChevronWidth = 6.5f;
// The header's chevron button and the gap around its Spacer (HStack spacing 2).
constexpr float kHeaderGap = M::kHeaderTextX - M::kHeaderIconX - M::kHeaderIconSize;
// FaviconImageView: corners of 19% of its side; the globe at 60% and Kite's page symbols at 80%.
constexpr float kFaviconCorner = 0.19f;
constexpr float kGlobeOpacity = 0.6f;
constexpr float kSymbolOpacity = 0.8f;
// The folder's symbol and New Tab's content (SidebarListCells.swift).
constexpr float kFolderIconOpacity = 0.75f;
constexpr float kNewTabOpacity = M::kTabTextOpacity * 0.75f;
constexpr float kHeaderChevronOpacity = 0.5f;
constexpr float kFolderChevronOpacity = 0.5f;
constexpr float kCloseButtonOpacity = 0.6f;  // SymbolButton's opacity, the same hovered or not
// A wheel notch scrolls 100pt for Windows' default 3 lines, as Chromium scrolls a page.
constexpr float kWheelLine = 100.0f / 3;

// Segoe Fluent Icons (Windows 11) and Segoe MDL2 Assets (Windows 10) code points for the SF
// Symbols the Mac draws: globe, folder / folder.fill, plus, chevron.right, and the symbols of
// Kite's own pages (clock.arrow.circlepath, archivebox, gearshape, magnifyingglass).
constexpr wchar_t kGlobe = 0xE774;
constexpr wchar_t kFolder = 0xE8B7;
constexpr wchar_t kFolderFill = 0xE8D5;
constexpr wchar_t kPlus = 0xE710;
constexpr wchar_t kChevronRight = 0xE76C;
constexpr wchar_t kClose = 0xE711;  // xmark
constexpr wchar_t kChevronDown = 0xE70D;  // chevron.right turned a quarter (an open folder or section)
constexpr wchar_t kHistory = 0xE81C;
constexpr wchar_t kArchive = 0xE7B8;
constexpr wchar_t kSettings = 0xE713;
constexpr wchar_t kSearch = 0xE721;
// The glyphs fill about this much of their em square, so a symbol meant to fill a box is set
// at the box's size over it, and one the Mac sets at a point size at that size over it (an
// SF Symbol is about as big as its point size).
constexpr float kGlyphInk = 0.9f;

D2D1_RECT_F Rect(float left, float top, float right, float bottom) { return D2D1_RECT_F{left, top, right, bottom}; }

}  // namespace

std::unique_ptr<SidebarView> SidebarView::Create(HWND window, Favicons* favicons, const SpaceIconPainter::Pictures& pictures,
                                                 std::wstring& error) {
    std::unique_ptr<SidebarView> view(new SidebarView(window, favicons));
    HRESULT hr = S_OK;
    if (FAILED(hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                                        reinterpret_cast<IUnknown**>(view->dwrite_.GetAddressOf())))) {
        error = HResultMessage(L"DWriteCreateFactory", hr);
        return nullptr;
    }
    // The system UI font for the Mac's SF Pro, as the command bar: Segoe UI Variable on
    // Windows 11, Segoe UI before it. Both have Regular and Semibold.
    ComPtr<IDWriteFontCollection> fonts;
    view->dwrite_->GetSystemFontCollection(fonts.GetAddressOf());
    auto installed = [&](const wchar_t* family) {
        UINT32 index = 0;
        BOOL exists = FALSE;
        return fonts && SUCCEEDED(fonts->FindFamilyName(family, &index, &exists)) && exists;
    };
    const wchar_t* text = installed(L"Segoe UI Variable Text") ? L"Segoe UI Variable Text" : L"Segoe UI";
    auto format = [&](const wchar_t* family, DWRITE_FONT_WEIGHT weight, float size, ComPtr<IDWriteTextFormat>& out) {
        HRESULT made = view->dwrite_->CreateTextFormat(family, nullptr, weight, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, size,
                                                       L"", out.GetAddressOf());
        if (SUCCEEDED(made)) made = out->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        return made;
    };
    if (FAILED(hr = format(text, DWRITE_FONT_WEIGHT_REGULAR, M::kUrlFieldFontSize, view->addressFormat_)) ||
        FAILED(hr = format(text, DWRITE_FONT_WEIGHT_SEMI_BOLD, M::kHeaderFontSize, view->headerFormat_)) ||
        FAILED(hr = format(text, DWRITE_FONT_WEIGHT_SEMI_BOLD, M::kDoneFontSize, view->doneFormat_)) ||
        FAILED(hr = format(text, DWRITE_FONT_WEIGHT_REGULAR, M::kTabFontSize, view->tabFormat_)) ||
        FAILED(hr = format(text, DWRITE_FONT_WEIGHT_SEMI_BOLD, M::kTabFontSize, view->folderFormat_)) ||
        FAILED(hr = format(L"Segoe UI Emoji", DWRITE_FONT_WEIGHT_REGULAR, M::kHeaderIconFontSize, view->emojiFormat_)) ||
        FAILED(hr = format(installed(L"Segoe Fluent Icons") ? L"Segoe Fluent Icons" : L"Segoe MDL2 Assets", DWRITE_FONT_WEIGHT_REGULAR,
                           M::kIconSize, view->iconFormat_))) {
        error = HResultMessage(L"CreateTextFormat", hr);
        return nullptr;
    }
    // One line, cut off at the end with "…" in the label's own font (SidebarLabel's
    // byTruncatingTail).
    const DWRITE_TRIMMING trimming{DWRITE_TRIMMING_GRANULARITY_CHARACTER, 0, 0};
    for (IDWriteTextFormat* f : {view->addressFormat_.Get(), view->headerFormat_.Get(), view->tabFormat_.Get(), view->folderFormat_.Get()}) {
        ComPtr<IDWriteInlineObject> ellipsis;
        if (SUCCEEDED(view->dwrite_->CreateEllipsisTrimmingSign(f, ellipsis.GetAddressOf()))) f->SetTrimming(&trimming, ellipsis.Get());
    }
    view->icons_ = SpaceIconPainter::Create(view->dwrite_.Get(), window, pictures, error);
    if (!view->icons_) return nullptr;
    view->bar_ = SpaceBarView::Create(view->dwrite_.Get(), view->icons_.get(), error);
    if (!view->bar_) return nullptr;
    view->tip_ = SpaceTipView::Create(window, view->dwrite_.Get(), error);
    if (!view->tip_) return nullptr;
    // Emoji and symbols sit in the middle of their box.
    for (IDWriteTextFormat* f : {view->emojiFormat_.Get(), view->iconFormat_.Get()}) {
        f->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
        f->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    }
    return view;
}

SidebarView::~SidebarView() { ReleaseGpu(); }

void SidebarView::UseCompositor(Compositor* compositor) {
    ReleaseGpu();
    bar_->UseCompositor(compositor, compositor ? compositor->Chrome() : nullptr);
    tip_->UseCompositor(compositor);
    compositor_ = compositor;
    deviceLost_ = false;
    dirty_ = true;
}

bool SidebarView::CreateGpu(std::wstring& error) {
    IDCompositionDevice* device = compositor_->Device();
    HRESULT hr = compositor_->D2D()->CreateSolidColorBrush(D2D1_COLOR_F{0, 0, 0, 1}, brush_.ReleaseAndGetAddressOf());
    if (SUCCEEDED(hr)) hr = device->CreateVisual(visual_.ReleaseAndGetAddressOf());
    if (SUCCEEDED(hr)) hr = compositor_->Chrome()->AddVisual(visual_.Get(), FALSE, nullptr);
    // The pages over the address field.
    if (SUCCEEDED(hr)) hr = device->CreateVisual(pagesClip_.ReleaseAndGetAddressOf());
    if (SUCCEEDED(hr)) hr = compositor_->Chrome()->AddVisual(pagesClip_.Get(), TRUE, visual_.Get());
    if (SUCCEEDED(hr)) hr = device->CreateVisual(strip_.ReleaseAndGetAddressOf());
    if (SUCCEEDED(hr)) hr = pagesClip_->AddVisual(strip_.Get(), FALSE, nullptr);
    if (FAILED(hr)) {
        deviceLost_ = IsDeviceLost(hr);
        error = HResultMessage(L"creating the sidebar's visuals", hr);
        ReleaseGpu();
        return false;
    }
    clipWidth_ = 0;
    return true;
}

void SidebarView::ReleaseGpu() {
    faviconBitmaps_.clear();
    if (tip_) tip_->UseCompositor(nullptr);
    if (rename_) rename_->UseCompositor(nullptr, nullptr);
    if (icons_) icons_->ReleaseDevice();
    for (auto& [id, page] : pages_) {
        if (page.visual && strip_) {
            page.visual->SetContent(nullptr);
            strip_->RemoveVisual(page.visual.Get());
        }
        page = Page{};
    }
    if (strip_ && pagesClip_) pagesClip_->RemoveVisual(strip_.Get());
    if (compositor_) {
        if (pagesClip_) compositor_->Chrome()->RemoveVisual(pagesClip_.Get());
        if (visual_) {
            visual_->SetContent(nullptr);
            compositor_->Chrome()->RemoveVisual(visual_.Get());
        }
    }
    // A slide's animation is the old device's: the rebuilt strip sits where it was going.
    slide_.reset();
    strip_.Reset();
    pagesClip_.Reset();
    visual_.Reset();
    surface_.Reset();
    surfaceWidth_ = surfaceHeight_ = 0;
    clipWidth_ = 0;
    brush_.Reset();
}

void SidebarView::Update(const BrowserState& state, const std::optional<std::string>& anchor) {
    Model next;
    const size_t selected = state.SelectedSpaceIndex();
    next.dark = !PrefersDarkForeground(state.SelectedSpace().theme);
    // The space bar's cells, and their light along a slide that has just begun.
    std::vector<SpaceCell> cells = SpaceCells(state);
    // The pictures any space shows, in the bar or its header: the painter keeps only these.
    std::set<std::string> pictures;
    for (const SpaceCell& cell : cells) {
        if (cell.look.kind == SpaceIconLook::Kind::Picture) pictures.insert(cell.look.text);
    }
    icons_->Retain(pictures);
    bar_->Update(std::move(cells), next.dark);
    // The spaces' tips; one showing (or waiting) for a space that's gone goes (the Mac's bar
    // hides a removed cell's).
    tips_.clear();
    for (size_t i = 0; i < state.spaces.size(); ++i) tips_.emplace(state.spaces[i].id, SpaceTipOf(state, i));
    if (tipHover_ && !tips_.contains(*tipHover_)) TipHoverChanged(std::nullopt);
    if (barSlidePending_) {
        barSlidePending_ = false;
        const std::optional<size_t> left = anchor ? state.SpaceIndex(*anchor) : std::nullopt;
        if (slide_) {
            bar_->Slide(slide_->segments, slide_->duration,
                        slide_->to + (slide_->segments.empty() ? 0 : ValueAt(slide_->segments, slide_->duration, 0)), slide_->to, width_, SpaceSwipe::BuiltPages(selected, left, state.spaces.size()), selected);
        } else {
            bar_->Land();
        }
    }
    if (bar_->NeedsDraw()) ScheduleDraw();
    next.address = AddressFieldText(state);
    next.spaceID = state.SelectedSpace().id;
    next.index = selected;
    const std::optional<size_t> anchorIndex = anchor ? state.SpaceIndex(*anchor) : std::nullopt;
    for (size_t index : SpaceSwipe::BuiltPages(selected, anchorIndex, state.spaces.size())) {
        PageModel page{state.spaces[index].id, index, SidebarRows(state, index)};
        if (index == selected) next.rows = page.rows;
        next.pages.push_back(std::move(page));
    }
    if (next == model_) return;
    // Each space keeps its own place in its list, as each of the Mac's has its scroll view.
    if (next.spaceID != model_.spaceID) {
        if (!model_.spaceID.empty()) scrolls_[model_.spaceID] = scrollExact_;
        auto kept = scrolls_.find(next.spaceID);
        scrollExact_ = kept == scrolls_.end() ? 0 : kept->second;
    }
    // What has to draw again: the address field when it or the appearance changed, and each
    // page that's new, lists other rows, or became or stopped being the selected one (which
    // shows hover and its own scroll).
    if (next.address != model_.address || next.dark != model_.dark) dirty_ = true;
    for (const PageModel& page : next.pages) {
        auto old = std::find_if(model_.pages.begin(), model_.pages.end(), [&](const PageModel& p) { return p.spaceID == page.spaceID; });
        const bool wasSelected = old != model_.pages.end() && old->spaceID == model_.spaceID;
        if (old == model_.pages.end() || old->rows != page.rows || next.dark != model_.dark || wasSelected != (page.spaceID == next.spaceID)) {
            pages_[page.spaceID].dirty = true;
        }
    }
    // Pages no longer built go, GPU side and all.
    for (auto it = pages_.begin(); it != pages_.end();) {
        const bool built = std::any_of(next.pages.begin(), next.pages.end(), [&](const PageModel& p) { return p.spaceID == it->first; });
        if (built) {
            ++it;
            continue;
        }
        if (it->second.visual && strip_) {
            it->second.visual->SetContent(nullptr);
            strip_->RemoveVisual(it->second.visual.Get());
        }
        // And its place in its list, as the Mac's list goes with its scroll view: built again,
        // it's at the top.
        if (it->first != next.spaceID) scrolls_.erase(it->first);
        it = pages_.erase(it);
    }
    model_ = std::move(next);
    built_.clear();
    for (const PageModel& page : model_.pages) built_.push_back(page.index);
    PlacePages();
    ScheduleDraw();
    // Rows moved under a still pointer: it now hovers whatever is there.
    SetScroll(scrollExact_);
    RefreshHover();
}

void SidebarView::SetPageOffset(float offset) {
    if (offset == pageOffset_ && !slide_) return;
    pageOffset_ = offset;
    slide_.reset();
    barSlidePending_ = false;
    // The bar's light with them: a swipe's frame lights the cells between the pages it shows.
    bar_->Follow(offset, width_, built_, model_.index);
    if (bar_->NeedsDraw()) ScheduleDraw();
    PlaceStrip();
    // At rest the rows have moved under a still pointer; mid-swipe, as AppKit's, hover waits.
    if (offset == 0) RefreshHover();
}

double SidebarView::SlidePages(float from, float to) {
    const double duration = SettleDuration(from - to, space_motion::kPageResponse);
    // Where it rests, and where a rebuilt tree (a lost GPU) puts it.
    pageOffset_ = to;
    slide_.reset();
    if (duration > 0 && strip_ && compositor_) {
        const float scale = static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI;
        Slide slide{SettleSegments(from - to, space_motion::kPageResponse), duration, to, FrameClock::Now(), nullptr};
        HRESULT hr = compositor_->Device()->CreateAnimation(slide.animation.GetAddressOf());
        for (const CubicSegment& segment : slide.segments) {
            if (FAILED(hr)) break;
            hr = slide.animation->AddCubic(segment.begin, static_cast<float>((segment.constant + to) * scale),
                                           static_cast<float>(segment.linear * scale), static_cast<float>(segment.quadratic * scale),
                                           static_cast<float>(segment.cubic * scale));
        }
        if (SUCCEEDED(hr)) hr = slide.animation->End(duration, to * scale);
        if (SUCCEEDED(hr)) slide_ = std::move(slide);
    }
    PlaceStrip();
    // The bar's cells relight with it, once Update has given it the new selection.
    barSlidePending_ = true;
    return slide_ ? duration : 0;
}

float SidebarView::PageOffset() const {
    if (!slide_) return pageOffset_;
    return static_cast<float>(slide_->to + ValueAt(slide_->segments, slide_->duration, FrameClock::Now() - slide_->start));
}

void SidebarView::PlaceStrip() {
    if (!strip_) return;
    // The slide runs on the compositor from the next commit; at rest the strip just sits.
    if (slide_) strip_->SetOffsetX(slide_->animation.Get());
    else strip_->SetOffsetX(pageOffset_ * static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI);
}

void SidebarView::PlacePages() {
    if (!strip_) return;
    // A sidebar's width apart, in whole pixels, the selected page at rest at the strip's origin.
    const float pitch = static_cast<float>(clipWidth_);
    for (const PageModel& page : model_.pages) {
        auto found = pages_.find(page.spaceID);
        if (found == pages_.end() || !found->second.visual) continue;
        found->second.visual->SetOffsetX((static_cast<float>(page.index) - static_cast<float>(model_.index)) * pitch);
    }
}

void SidebarView::Layout(float width, UINT dpi) {
    // The height comes with the window's: Draw draws again only when it changes what's shown.
    if (width != width_ || dpi != dpi_) {
        width_ = width;
        dpi_ = dpi;
        dirty_ = true;
        for (auto& [id, page] : pages_) page.dirty = true;
        bar_->Layout(width, dpi);
        HideTip();
        // A slide's animation is in the old scale's pixels: it lands.
        if (slide_) SetPageOffset(pageOffset_);
    }
    // A taller window (or another scale) can leave the list past its end, and the pointer
    // over something else.
    SetScroll(scrollExact_);
    RefreshHover();
}

void SidebarView::InvalidatePages() {
    for (auto& [id, page] : pages_) page.dirty = true;
    ScheduleDraw();
}

void SidebarView::PicturesArrived() {
    const std::set<std::string> changed = icons_->TakeResults();
    if (changed.empty()) return;
    bar_->InvalidatePictures(changed);
    // The built pages whose header shows one of them.
    for (const PageModel& model : model_.pages) {
        const SidebarRow* header = model.rows.empty() ? nullptr : &model.rows.front();
        if (header && header->look.kind == SpaceIconLook::Kind::Picture && changed.contains(header->look.text)) {
            if (auto page = pages_.find(model.spaceID); page != pages_.end()) page->second.dirty = true;
        }
    }
    ScheduleDraw();
}

void SidebarView::InvalidateSelectedPage() {
    if (auto found = pages_.find(model_.spaceID); found != pages_.end()) found->second.dirty = true;
    ScheduleDraw();
}

void SidebarView::ScheduleDraw() {
    if (!redrawPosted_) redrawPosted_ = PostMessageW(window_, kRedrawMessage, 0, 0) != FALSE;
}

bool SidebarView::NeedsDraw() const {
    return dirty_ || bar_->NeedsDraw() || (rename_ && rename_->NeedsDraw()) || std::any_of(pages_.begin(), pages_.end(), [](const auto& entry) { return entry.second.dirty; });
}

void SidebarView::TipHoverChanged(const std::optional<std::string>& spaceID) {
    if (spaceID == tipHover_) return;
    // mouseExited hides the old cell's tip; mouseEntered starts the new one's 0.4 s.
    tipHover_ = spaceID;
    KillTimer(window_, kTipTimer);
    tip_->Hide();
    if (spaceID) SetTimer(window_, kTipTimer, static_cast<UINT>(std::lround(space_bar_metrics::kTipDelay * 1000)), nullptr);
}

void SidebarView::HideTip() {
    // Until the pointer comes onto a cell again.
    KillTimer(window_, kTipTimer);
    tip_->Hide();
    tipHover_.reset();
}

std::optional<BarRect> SidebarView::CellInWindow(const std::string& spaceID) const {
    const auto& cells = bar_->Cells();
    const auto cell = std::find_if(cells.begin(), cells.end(), [&](const SpaceCell& c) { return c.spaceID == spaceID; });
    if (cell == cells.end()) return std::nullopt;
    const BarRect& r = bar_->Geometry().cells[static_cast<size_t>(cell - cells.begin())];
    // From the bar's points to the window's: the bar starts at SpaceBarTop, at the sidebar's left.
    const float top = SpaceBarTop(Height());
    return BarRect{r.left, r.top + top, r.right, r.bottom + top};
}

void SidebarView::ShowTip() {
    // guard self.hovering, !self.dragging, self.window != nil: still over the cell, not dragging
    // it, and the window on screen.
    const bool dragging = barPress_ && barPress_->dragged && bar_->Cells().size() > 1;
    if (!tipHover_ || !compositor_ || dragging || !IsWindowVisible(window_) || IsIconic(window_)) return;
    const auto tip = tips_.find(*tipHover_);
    const std::optional<BarRect> cell = CellInWindow(*tipHover_);
    if (!cell || tip == tips_.end()) return;
    if (std::wstring problem = tip_->Show(*tipHover_, tip->second, *cell, dpi_); !problem.empty()) {
        OutputDebugStringW((L"Kite: the space tip couldn't show: " + problem + L"\n").c_str());
        if (tip_->DeviceLost()) deviceLost_ = true;
    }
}

std::wstring SidebarView::RenderTip(size_t index, Pixels& out, POINT& origin) {
    const auto& cells = bar_->Cells();
    if (index >= cells.size()) return L"there's no such space";
    const auto tip = tips_.find(cells[index].spaceID);
    const std::optional<BarRect> cell = CellInWindow(cells[index].spaceID);
    if (tip == tips_.end() || !cell) return L"there's no such space";
    return tip_->Render(tip->second, *cell, dpi_, out, origin);
}

bool SidebarView::HandleMessage(UINT message, WPARAM wParam) {
    if (message == WM_TIMER && wParam == kTipTimer) {
        KillTimer(window_, kTipTimer);
        ShowTip();
        return true;
    }
    if (message == WM_TIMER && wParam == kDropTimer) {
        FinishDrop();
        return true;
    }
    if (message == WM_TIMER && rename_ && rename_->HandleTimer(wParam)) return true;
    if (message != kRedrawMessage) return false;
    redrawPosted_ = false;
    if (NeedsDraw() && compositor_) {
        if (std::wstring problem = Draw(); !problem.empty()) {
            OutputDebugStringW((L"Kite: the sidebar couldn't draw: " + problem + L"\n").c_str());
        } else {
            compositor_->Commit();
        }
    }
    return true;
}

float SidebarView::PageScroll(const PageModel& page) const {
    if (page.spaceID == model_.spaceID) return scroll_;
    auto kept = scrolls_.find(page.spaceID);
    if (kept == scrolls_.end()) return 0;
    // Where it was left, as SetScroll draws it: whole pixels, within its list.
    const float scale = static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI;
    const float limit = SidebarMaxScroll(page.rows, Height(), scale);
    return std::min(std::round(std::clamp(kept->second, 0.0f, limit) * scale) / scale, limit);
}

std::wstring SidebarView::DrawPageSurface(const PageModel& page, Page& gpu, Pixels* readBack) {
    const float scale = static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI;
    const float scroll = PageScroll(page);
    // The page's surface runs from the sidebar's top (so it draws in the sidebar's points, as
    // the address field's does) down to its last row, or to where the list is cut off above the
    // space bar, whichever is higher: a window resize that moves neither draws nothing.
    const float contentBottom = M::kHeaderAreaHeight + SidebarContentHeight(page.rows) - scroll;
    const float bottom = std::max(M::kHeaderAreaHeight, std::min(contentBottom, SidebarListBottom(Height())));
    const UINT largest = compositor_->GetRenderer().MaxTextureSize();
    const UINT width = std::clamp(static_cast<UINT>(std::ceil(width_ * scale)), 1u, largest);
    const UINT height = std::clamp(static_cast<UINT>(std::ceil(bottom * scale)), 1u, largest);
    if (width != gpu.width || height != gpu.height) gpu.dirty = true;
    if (!gpu.dirty && !readBack) return {};
    auto fail = [this](const wchar_t* what, HRESULT hr) {
        deviceLost_ = IsDeviceLost(hr);
        return HResultMessage(what, hr);
    };
    HRESULT hr = S_OK;
    if (!gpu.visual) {
        if (FAILED(hr = compositor_->Device()->CreateVisual(gpu.visual.GetAddressOf())) ||
            FAILED(hr = strip_->AddVisual(gpu.visual.Get(), FALSE, nullptr))) {
            gpu.visual.Reset();
            return fail(L"creating a sidebar page's visual", hr);
        }
        PlacePages();
    }
    if (!gpu.surface) {
        if (FAILED(hr = compositor_->Device()->CreateVirtualSurface(width, height, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED,
                                                                     gpu.surface.GetAddressOf())) ||
            FAILED(hr = gpu.visual->SetContent(gpu.surface.Get()))) {
            gpu.surface.Reset();
            return fail(L"creating a sidebar page's surface", hr);
        }
    } else if (width != gpu.width || height != gpu.height) {
        if (FAILED(hr = gpu.surface->Resize(width, height))) return fail(L"resizing a sidebar page's surface", hr);
    }
    gpu.width = width;
    gpu.height = height;
    // The header's picture's bitmap, made before the page's draw begins.
    if (!page.rows.empty() && page.rows.front().kind == SidebarRow::Kind::Header) {
        icons_->Prepare(compositor_->D2D(), page.rows.front().look, M::kHeaderIconFontSize, scale);
    }
    std::set<FaviconKey> icons;
    drawnIcons_ = &icons;
    std::wstring error = compositor_->DrawSurface(
        gpu.surface.Get(), width, height, dpi_,
        [&](ID2D1DeviceContext* context) {
            DrawPage(context, page, scroll, static_cast<float>(height) / scale, page.spaceID == model_.spaceID);
        },
        readBack, hr);
    drawnIcons_ = nullptr;
    if (!error.empty()) {
        deviceLost_ = IsDeviceLost(hr);
        return L"a sidebar page: " + error;
    }
    gpu.icons = std::move(icons);
    gpu.dirty = false;
    return {};
}

std::wstring SidebarView::Draw(Pixels* readBack) {
    // The pictures this draw asks for (the pages' headers and the bar's) go to the worker together.
    struct SendRequests {
        SpaceIconPainter* icons;
        ~SendRequests() { if (icons) icons->SendRequests(); }
    } sendRequests{icons_.get()};
    if (!compositor_) return L"no compositor";
    if (deviceLost_) return L"the GPU device was lost";
    RECT client{};
    GetClientRect(window_, &client);
    // Minimized: nothing to draw into until it's restored (onSize lays it out again).
    if (client.bottom <= 0 || client.right <= 0) return {};
    std::wstring error;
    if (!visual_ && !CreateGpu(error)) return error;
    const float scale = static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI;
    const UINT largest = compositor_->GetRenderer().MaxTextureSize();
    const UINT width = std::clamp(static_cast<UINT>(std::ceil(width_ * scale)), 1u, largest);
    // The pages show only over the sidebar, whichever way they slide.
    if (width != clipWidth_) {
        clipWidth_ = width;
        pagesClip_->SetClip(D2D_RECT_F{0, 0, static_cast<float>(width), static_cast<float>(largest)});
        PlacePages();
        PlaceStrip();
    }

    // The address field's surface: the sidebar's top, down to the list.
    const UINT height = std::clamp(static_cast<UINT>(std::ceil(M::kHeaderAreaHeight * scale)), 1u, largest);
    if (height != surfaceHeight_ || width != surfaceWidth_) dirty_ = true;
    auto fail = [this](const wchar_t* what, HRESULT hr) {
        deviceLost_ = IsDeviceLost(hr);
        return HResultMessage(what, hr);
    };
    HRESULT hr = S_OK;
    Pixels header;
    std::vector<std::pair<size_t, Pixels>> pageShots;  // each built page's, by its space's place
    if (dirty_ || readBack) {
        if (!surface_) {
            if (FAILED(hr = compositor_->Device()->CreateVirtualSurface(width, height, DXGI_FORMAT_B8G8R8A8_UNORM,
                                                                         DXGI_ALPHA_MODE_PREMULTIPLIED, surface_.GetAddressOf())) ||
                FAILED(hr = visual_->SetContent(surface_.Get()))) {
                surface_.Reset();
                return fail(L"creating the sidebar's surface", hr);
            }
        } else if (width != surfaceWidth_ || height != surfaceHeight_) {
            if (FAILED(hr = surface_->Resize(width, height))) return fail(L"resizing the sidebar's surface", hr);
        }
        surfaceWidth_ = width;
        surfaceHeight_ = height;
        error = compositor_->DrawSurface(
            surface_.Get(), width, height, dpi_, [&](ID2D1DeviceContext* context) { DrawHeader(context); }, readBack ? &header : nullptr,
            hr);
        if (!error.empty()) {
            deviceLost_ = IsDeviceLost(hr);
            return L"the sidebar: " + error;
        }
        dirty_ = false;
    }

    // The built pages, each in its own surface.
    for (const PageModel& page : model_.pages) {
        Pixels* shot = nullptr;
        if (readBack) shot = &pageShots.emplace_back(page.index, Pixels{}).second;
        if (error = DrawPageSurface(page, pages_[page.spaceID], shot); !error.empty()) return error;
    }
    // Only the icons the pages show stay on the GPU.
    std::erase_if(faviconBitmaps_, [this](const auto& entry) {
        return std::none_of(pages_.begin(), pages_.end(), [&](const auto& page) { return page.second.icons.contains(entry.first); });
    });

    // The space bar under them.
    Pixels bar;
    if (error = bar_->Draw(static_cast<UINT>(client.bottom), readBack ? &bar : nullptr); !error.empty()) return error;
    // The rename field over its page's header, in the page's visual (it slides with it).
    Pixels field;
    POINT fieldAt{};
    if (rename_) {
        const auto page = pages_.find(rename_->SpaceID());
        IDCompositionVisual* parent = page != pages_.end() ? page->second.visual.Get() : nullptr;
        if (parent != rename_->Parent()) rename_->UseCompositor(compositor_, parent);
        rename_->SetPageOrigin(POINT{std::lround(PageOffset() * scale), 0});
        if (error = rename_->Draw(readBack ? &field : nullptr, &fieldAt); !error.empty()) {
            deviceLost_ = deviceLost_ || rename_->DeviceLost();
            return error;
        }
    }

    if (readBack) {
        // As the screen shows it: the pages over the address field where the strip has them
        // (at rest, the selected one), clipped to the sidebar, and the bar at the window's
        // bottom.
        readBack->width = width;
        readBack->height = std::max(header.height, static_cast<UINT>(client.bottom));
        for (const auto& [index, shot] : pageShots) readBack->height = std::max(readBack->height, shot.height);
        readBack->bgra.assign(static_cast<size_t>(readBack->width) * readBack->height * 4, 0);
        ComposeOver(*readBack, header, POINT{0, 0});
        const RECT clip{0, 0, static_cast<LONG>(width), static_cast<LONG>(readBack->height)};
        const float strip = PageOffset() * scale;
        for (const auto& [index, shot] : pageShots) {
            const float x = (static_cast<float>(index) - static_cast<float>(model_.index)) * static_cast<float>(clipWidth_) + strip;
            if (std::abs(x) < static_cast<float>(width)) ComposeOver(*readBack, shot, POINT{std::lround(x), 0}, 1, &clip);
            if (rename_ && index == model_.index && !field.bgra.empty()) {
                ComposeOver(*readBack, field, POINT{std::lround(x) + fieldAt.x, fieldAt.y}, 1, &clip);
            }
        }
        ComposeOver(*readBack, bar, POINT{0, client.bottom - static_cast<LONG>(bar.height)});
    }
    return {};
}

D2D1_COLOR_F SidebarView::Primary(float alpha) const {
    const float c = model_.dark ? 1.0f : 0.0f;
    return D2D1_COLOR_F{c, c, c, alpha};
}

float SidebarView::Baseline(IDWriteTextFormat* format) {
    if (auto found = baselines_.find(format); found != baselines_.end()) return found->second;
    float baseline = format->GetFontSize() * 0.9f;
    ComPtr<IDWriteTextLayout> layout;
    DWRITE_LINE_METRICS line{};
    UINT32 count = 0;
    if (SUCCEEDED(dwrite_->CreateTextLayout(L"Ag", 2, format, 1000, 1000, layout.GetAddressOf())) &&
        SUCCEEDED(layout->GetLineMetrics(&line, 1, &count)) && count == 1) {
        baseline = line.baseline;
    }
    baselines_[format] = baseline;
    return baseline;
}

void SidebarView::DrawText(ID2D1DeviceContext* context, const std::string& text, IDWriteTextFormat* format, float x, float baseline,
                           float maxWidth, D2D1_COLOR_F color) {
    if (text.empty() || maxWidth <= 0) return;
    const std::wstring wide = Widen(text);
    ComPtr<IDWriteTextLayout> layout;
    if (FAILED(dwrite_->CreateTextLayout(wide.c_str(), static_cast<UINT32>(wide.size()), format, maxWidth, format->GetFontSize() * 2,
                                         layout.GetAddressOf()))) {
        return;
    }
    brush_->SetColor(color);
    context->DrawTextLayout(D2D1::Point2F(x, baseline - Baseline(format)), layout.Get(), brush_.Get(),
                            D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
}

void SidebarView::DrawGlyph(ID2D1DeviceContext* context, wchar_t glyph, float size, D2D1_RECT_F box, D2D1_COLOR_F color) {
    ComPtr<IDWriteTextLayout> layout;
    if (FAILED(dwrite_->CreateTextLayout(&glyph, 1, iconFormat_.Get(), box.right - box.left, box.bottom - box.top, layout.GetAddressOf()))) {
        return;
    }
    const DWRITE_TEXT_RANGE all{0, 1};
    layout->SetFontSize(size, all);
    brush_->SetColor(color);
    context->DrawTextLayout(D2D1::Point2F(box.left, box.top), layout.Get(), brush_.Get());
}

void SidebarView::DrawFavicon(ID2D1DeviceContext* context, const SidebarRow& row, D2D1_RECT_F box) {
    const float side = box.right - box.left;
    if (row.favicon.symbol) {
        // Kite's own pages: their symbol, fitted to the square.
        wchar_t glyph = kSettings;
        switch (*row.favicon.symbol) {
        case InternalPage::History: glyph = kHistory; break;
        case InternalPage::Archive: glyph = kArchive; break;
        case InternalPage::SiteSettings:
        case InternalPage::Settings: glyph = kSettings; break;
        case InternalPage::SearchEngines: glyph = kSearch; break;
        }
        DrawGlyph(context, glyph, side / kGlyphInk, box, Primary(kLabelAlpha * kSymbolOpacity));
        return;
    }
    if (row.favicon.url && favicons_) {
        const UINT px = static_cast<UINT>(std::lround(side * static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI));
        const auto key = std::make_pair(*row.favicon.url, px);
        // Asked every draw, so an icon on screen stays recently used in the cache.
        const Pixels* pixels = favicons_->Get(*row.favicon.url, px);
        auto found = faviconBitmaps_.find(key);
        if (found == faviconBitmaps_.end()) {
            if (pixels) {
                D2D1_BITMAP_PROPERTIES1 props{};
                props.pixelFormat = D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED);
                props.dpiX = props.dpiY = static_cast<float>(dpi_);
                ComPtr<ID2D1Bitmap1> bitmap;
                if (SUCCEEDED(context->CreateBitmap(D2D1::SizeU(pixels->width, pixels->height), pixels->bgra.data(), pixels->width * 4,
                                                    &props, bitmap.GetAddressOf()))) {
                    found = faviconBitmaps_.emplace(key, bitmap).first;
                }
            }
        }
        if (found != faviconBitmaps_.end()) {
            if (drawnIcons_) drawnIcons_->insert(key);
            // Stretched to the square, its corners rounded (FaviconImageView's layer).
            ComPtr<ID2D1BitmapBrush1> brush;
            const D2D1_BITMAP_BRUSH_PROPERTIES1 props{D2D1_EXTEND_MODE_CLAMP, D2D1_EXTEND_MODE_CLAMP, D2D1_INTERPOLATION_MODE_LINEAR};
            if (SUCCEEDED(context->CreateBitmapBrush(found->second.Get(), &props, nullptr, brush.GetAddressOf()))) {
                const D2D1_SIZE_F size = found->second->GetSize();
                brush->SetTransform(D2D1::Matrix3x2F::Scale(side / size.width, side / size.height) *
                                    D2D1::Matrix3x2F::Translation(box.left, box.top));
                const float corner = side * kFaviconCorner;
                context->FillRoundedRectangle(D2D1::RoundedRect(box, corner, corner), brush.Get());
                return;
            }
        }
    }
    // No icon (yet): the globe, stretched to the square.
    DrawGlyph(context, kGlobe, side / kGlyphInk, box, Primary(kLabelAlpha * kGlobeOpacity));
}

D2D1_RECT_F SidebarView::HeaderNameRect(const SidebarRow& row, float top) {
    // As DrawRow lays the header out: the name from the icon's slot (or its place, with no
    // icon), up to the chevron's slot and the gaps, as wide as its text.
    const float x = row.icon.empty() ? M::kHeaderIconX : M::kHeaderTextX;
    float end = width_ - M::kPadding;
    if (row.hasPinned) end -= (M::kIconInset - M::kPadding) + M::kHeaderIconSize + kHeaderGap;
    end -= kHeaderGap;
    const std::wstring title = Widen(row.title);
    ComPtr<IDWriteTextLayout> layout;
    DWRITE_TEXT_METRICS metrics{};
    if (FAILED(dwrite_->CreateTextLayout(title.c_str(), static_cast<UINT32>(title.size()), headerFormat_.Get(), 100000, 100,
                                         layout.GetAddressOf())) ||
        FAILED(layout->GetMetrics(&metrics))) {
        return {};
    }
    const float rowTop = top + M::kHeaderIconTop;
    const float line = LineHeight(M::kHeaderFontSize);
    const float textY = rowTop + std::floor((M::kHeaderIconSize - line) / 2);
    return Rect(x, textY, x + std::min(metrics.width, std::max(end - x, 0.0f)), textY + line);
}

void SidebarView::PlaceRenameField(float x, float top) {
    // SpaceHeaderRowCell.layout while renaming: no chevron; from the cell's end, a gap and the
    // icon inset, Done (its label's width), a gap, then the field takes the room from the name's
    // place. The field's line and Done's label each sit in the 26pt row, rounded down.
    const float right = width_ - M::kPadding;
    const float rowTop = top + M::kHeaderIconTop;
    float end = right - (kHeaderGap + (M::kIconInset - M::kPadding));
    end -= rename_->DoneWidth();
    const D2D1_RECT_F done = Rect(end, rowTop, end + rename_->DoneWidth(), rowTop + M::kHeaderIconSize);
    end -= kHeaderGap;
    const float line = LineHeight(M::kHeaderFontSize);
    const float lineTop = rowTop + std::floor((M::kHeaderIconSize - line) / 2);
    const float doneBaseline = rowTop + std::floor((M::kHeaderIconSize - LineHeight(M::kDoneFontSize)) / 2) + M::kDoneFontSize * kAscender;
    rename_->Place(x, std::max(end, x), lineTop, line, lineTop + M::kHeaderFontSize * kAscender, done, doneBaseline, dpi_, model_.dark);
}

void SidebarView::DrawRow(ID2D1DeviceContext* context, const SidebarRow& row, float top, bool hovered) {
    const float left = M::kPadding, right = width_ - M::kPadding;  // the row, in window points
    // The pill sits 2.5pt into its row: whole pixels at 2x as on the Mac's screens, snapped to
    // them at other scales so its edges and the favicon stay sharp.
    const float scale = static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI;
    auto snap = [scale](float points) { return std::round(points * scale) / scale; };
    const float pillTop = snap(top + (M::kRowPitch - M::kPillHeight) / 2);
    const float pillBottom = snap(pillTop + M::kPillHeight);
    // The favicon's square, a whole number of pixels on the pixel grid.
    const float iconSide = std::round(M::kIconSize * scale) / scale;
    auto washPill = [&](D2D1_COLOR_F color) {
        brush_->SetColor(color);
        context->FillRoundedRectangle(D2D1::RoundedRect(Rect(snap(left), pillTop, snap(right), pillBottom), M::kCornerRadius, M::kCornerRadius),
                                      brush_.Get());
    };
    // chromeFill(hoverFill): the folder's and New Tab's hover.
    const D2D1_COLOR_F hoverWash{1, 1, 1, model_.dark ? M::kHoverFill : std::min(M::kHoverFill * 3.5f, 0.7f)};
    auto faviconBox = [&](float x) {
        const float iconLeft = snap(x), iconTop = snap(pillTop + (M::kPillHeight - M::kIconSize) / 2);
        return Rect(iconLeft, iconTop, iconLeft + iconSide, iconTop + iconSide);
    };
    const float tabLine = LineHeight(M::kTabFontSize);
    const float tabBaseline = pillTop + TextTop(M::kPillHeight, tabLine) + M::kTabFontSize * kAscender;
    switch (row.kind) {
    case SidebarRow::Kind::Header: {
        // An icon-less space has no icon slot: its name starts at the icon's place. Any icon keeps
        // the slot (SpaceHeaderRowCell's showsIcon), even one that draws nothing: a symbol with
        // no stand-in.
        float x = M::kHeaderIconX;
        const D2D1_RECT_F iconBox = Rect(x, top + M::kHeaderIconTop, x + M::kHeaderIconSize, top + M::kHeaderIconTop + M::kHeaderIconSize);
        if (!row.icon.empty()) {
            if (row.look.kind == SpaceIconLook::Kind::Dot) {
                // Blank.
            } else if (row.look.kind != SpaceIconLook::Kind::Emoji) {
                // A symbol in the theme's accent, or a picture (SpaceIconImageView, never greyed here).
                const ThemeColor& a = row.look.accent;
                icons_->Draw(context, brush_.Get(), row.look,
                             D2D1::Point2F((iconBox.left + iconBox.right) / 2, (iconBox.top + iconBox.bottom) / 2), M::kHeaderIconFontSize,
                             static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI, D2D1_COLOR_F{a.r, a.g, a.b, 1}, model_.dark);
            } else {
                const std::wstring icon = Widen(row.look.text);
                ComPtr<IDWriteTextLayout> layout;
                if (SUCCEEDED(dwrite_->CreateTextLayout(icon.c_str(), static_cast<UINT32>(icon.size()), emojiFormat_.Get(), M::kHeaderIconSize,
                                                        M::kHeaderIconSize, layout.GetAddressOf()))) {
                    brush_->SetColor(Primary(1));
                    context->DrawTextLayout(D2D1::Point2F(iconBox.left, iconBox.top), layout.Get(), brush_.Get(),
                                            D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
                }
            }
            x = M::kHeaderTextX;
        }
        if (rename_ && rename_->SpaceID() == row.id) {
            // Renaming: the field and Done (its own visual) where the name and the chevron were.
            PlaceRenameField(x, top);
            break;
        }
        float end = right;
        if (row.hasPinned) {
            // The chevron's slot: shown while the pinned tabs are collapsed (and on hover).
            end -= M::kIconInset - M::kPadding;
            end -= M::kHeaderIconSize;
            // Collapsed it shows; expanded, only while the header is hovered, turned down.
            if (row.pinnedCollapsed || hovered) {
                DrawGlyph(context, row.pinnedCollapsed ? kChevronRight : kChevronDown, 9 / kGlyphInk,
                          Rect(end, iconBox.top, end + M::kHeaderIconSize, iconBox.bottom), Primary(kLabelAlpha * kHeaderChevronOpacity));
            }
            end -= kHeaderGap;
        }
        end -= kHeaderGap;
        const float line = LineHeight(M::kHeaderFontSize);
        const float baseline = iconBox.top + std::floor((M::kHeaderIconSize - line) / 2) + M::kHeaderFontSize * kAscender;
        DrawText(context, row.title, headerFormat_.Get(), x, baseline, end - x, Primary(kLabelAlpha * M::kHeaderTextOpacity));
        break;
    }
    case SidebarRow::Kind::Tab: {
        if (row.selected) {
            // White on both appearances: 20% on a dark theme, 85% on a light one.
            washPill(D2D1_COLOR_F{1, 1, 1, model_.dark ? M::kSelectedFill : M::kSelectedFillLight});
        } else if (hovered) {
            washPill(model_.dark ? D2D1_COLOR_F{1, 1, 1, M::kHoverFill} : M::kHoverWashLight);
        }
        const float x = left + M::kIconInset + static_cast<float>(row.depth) * M::kNestingIndent;
        DrawFavicon(context, row, faviconBox(x));
        const float textX = x + M::kIconSize + M::kIconTextGap;
        // Trailing, from the pill's end (6pt in): the close button while hovered, and the title
        // up to a gap before it; with nothing there, to a gap before the 6pt.
        float textEnd = right - M::kCloseButtonEndInset - M::kIconTextGap;
        if (hovered && row.showsClose) {
            const float closeRight = right - M::kCloseButtonEndInset, closeLeft = closeRight - M::kCloseButtonSize;
            const float closeTop = pillTop + (M::kPillHeight - M::kCloseButtonSize) / 2;
            DrawGlyph(context, kClose, 9 / kGlyphInk, Rect(closeLeft, closeTop, closeRight, closeTop + M::kCloseButtonSize),
                      Primary(kLabelAlpha * kCloseButtonOpacity));
            textEnd = closeLeft - M::kIconTextGap - M::kIconTextGap;
        }
        DrawText(context, row.title, tabFormat_.Get(), textX, tabBaseline, textEnd - textX, Primary(kLabelAlpha * M::kTabTextOpacity));
        break;
    }
    case SidebarRow::Kind::Folder: {
        if (hovered) washPill(hoverWash);
        const float x = left + M::kIconInset + static_cast<float>(row.depth) * M::kNestingIndent;
        // folder (open) or folder.fill (closed) at 14pt in the favicon's square.
        DrawGlyph(context, row.expanded ? kFolder : kFolderFill, 14 / kGlyphInk, faviconBox(x), Primary(kLabelAlpha * kFolderIconOpacity));
        const float textX = x + M::kIconSize + M::kIconTextGap;
        const float textEnd = right - M::kIconInset - kFolderChevronWidth - M::kIconTextGap - M::kIconTextGap;
        DrawText(context, row.title, folderFormat_.Get(), textX, tabBaseline, textEnd - textX, Primary(kLabelAlpha * M::kTabTextOpacity));
        if (hovered) {
            // Its chevron, at the pill's end: turned down while it's open.
            const float centerX = right - M::kIconInset - kFolderChevronWidth / 2, centerY = (pillTop + pillBottom) / 2;
            DrawGlyph(context, row.expanded ? kChevronDown : kChevronRight, 9 / kGlyphInk,
                      Rect(centerX - M::kIconSize / 2, centerY - M::kIconSize / 2, centerX + M::kIconSize / 2, centerY + M::kIconSize / 2),
                      Primary(kLabelAlpha * kFolderChevronOpacity));
        }
        break;
    }
    case SidebarRow::Kind::Divider:
        if (row.showsLine) {
            // labelColor at 8% (its own alpha replaced, not multiplied).
            brush_->SetColor(Primary(M::kDividerOpacity));
            const float y = top + (M::kDividerRowHeight - M::kDividerThickness) / 2;
            context->FillRectangle(Rect(left + M::kDividerInset, y, right - M::kDividerInset, y + M::kDividerThickness), brush_.Get());
        }
        break;
    case SidebarRow::Kind::NewTab: {
        if (hovered) washPill(hoverWash);
        const float x = left + M::kIconInset;
        DrawGlyph(context, kPlus, 14 / kGlyphInk, faviconBox(x), Primary(kLabelAlpha * kNewTabOpacity));
        const float textX = x + M::kIconSize + M::kIconTextGap;
        DrawText(context, row.title, tabFormat_.Get(), textX, tabBaseline, right - M::kIconInset - textX, Primary(kLabelAlpha * kNewTabOpacity));
        break;
    }
    }
}

void SidebarView::DrawHeader(ID2D1DeviceContext* context) {
    const float left = M::kPadding, right = width_ - M::kPadding;
    // The address field: the white wash (stronger on a light theme) and the host.
    const float fieldTop = M::kTopRowY + M::kTopRowHeight + M::kUrlFieldTopGap;
    brush_->SetColor(D2D1_COLOR_F{1, 1, 1, model_.dark ? M::kFieldFill : std::min(M::kFieldFill * 3.5f, 0.7f)});
    context->FillRoundedRectangle(D2D1::RoundedRect(Rect(left, fieldTop, right, fieldTop + M::kUrlFieldHeight), M::kCornerRadius,
                                                    M::kCornerRadius),
                                  brush_.Get());
    const float addressLine = LineHeight(M::kUrlFieldFontSize);
    const float addressBaseline = fieldTop + std::floor((M::kUrlFieldHeight - addressLine) / 2) + M::kUrlFieldFontSize * kAscender;
    const float addressX = left + M::kUrlFieldTextInset;
    // With no buttons in the field, the text runs to 2pt from its end (SidebarHeader's layout).
    DrawText(context, model_.address, addressFormat_.Get(), addressX, addressBaseline, right - 2 - addressX,
             Primary(kLabelAlpha * M::kUrlFieldTextOpacity));
}

void SidebarView::DrawPage(ID2D1DeviceContext* context, const PageModel& page, float scroll, float bottom, bool selected) {
    // The space's page, under the header and above the space bar (where its surface ends);
    // rows past it are cut off (the Mac's list scrolls there). Only the selected page hovers.
    const float listTop = M::kHeaderAreaHeight;
    const float listBottom = std::max(listTop, bottom);
    context->PushAxisAlignedClip(Rect(0, listTop, width_, listBottom), D2D1_ANTIALIAS_MODE_ALIASED);
    for (const SidebarRow& row : page.rows) {
        const float top = listTop + row.top - scroll;
        if (top >= listBottom) break;
        if (top + row.height <= listTop) continue;
        const bool hovered = selected && hover_ && hover_->first == row.kind && hover_->second == row.id;
        DrawRow(context, row, top, hovered);
    }
    context->PopAxisAlignedClip();
}

// Pointer --------------------------------------------------------------------------------

D2D1_POINT_2F SidebarView::PointOf(POINT client) const {
    const float scale = static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI;
    return D2D1_POINT_2F{static_cast<float>(client.x) / scale, static_cast<float>(client.y) / scale};
}

float SidebarView::Height() const {
    RECT client{};
    GetClientRect(window_, &client);
    return static_cast<float>(client.bottom) / (static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI);
}

D2D1_POINT_2F SidebarView::OnPage(D2D1_POINT_2F p) const {
    // Under the address field the selected page is where the strip has it.
    if (p.y >= M::kHeaderAreaHeight) p.x -= PageOffset();
    return p;
}

SidebarHit SidebarView::HitAt(D2D1_POINT_2F p) const {
    if (p.x < 0 || p.x >= width_) return {};
    const D2D1_POINT_2F q = OnPage(p);
    return SidebarHitTest(model_.rows, width_, Height(), scroll_, q.x, q.y);
}

void SidebarView::RefreshHover() {
    // A press keeps the hover where it began until it's let go, as the Mac's tracking areas
    // (no .enabledDuringMouseDrag) send no enter or exit during a drag.
    if (press_ || barPress_) return;
    const SidebarHit hit = pointer_ ? HitAt(PointOf(*pointer_)) : SidebarHit{};
    // What draws hovered is a row (the header's chevron and a tab's close button are part of
    // theirs); the address field has no hover of its own yet (its buttons come with the
    // toolbar). Held by the row's item, so a row that moves (during a press, say) keeps it.
    std::optional<std::pair<SidebarRow::Kind, std::string>> hover;
    if (hit.target != SidebarHit::Target::None && hit.target != SidebarHit::Target::AddressField && hit.row < model_.rows.size()) {
        hover.emplace(model_.rows[hit.row].kind, model_.rows[hit.row].id);
    }
    // Over the bar: its cell's backing (a press elsewhere holds it, as above).
    std::optional<std::string> barHover;
    if (pointer_) {
        if (const auto b = BarPoint(PointOf(*pointer_))) barHover = bar_->SpaceAt(b->x, b->y);
    }
    bar_->SetHover(barHover);
    if (bar_->NeedsDraw()) ScheduleDraw();
    TipHoverChanged(barHover);
    if (hover == hover_) return;
    hover_ = std::move(hover);
    InvalidateSelectedPage();
}

std::optional<D2D1_POINT_2F> SidebarView::BarPoint(D2D1_POINT_2F p) const {
    // Under the space's page, in the sidebar (core's SpaceBarTop, as the page's bottom).
    if (p.x < 0 || p.x >= width_) return std::nullopt;
    const D2D1_POINT_2F b{p.x, p.y - SpaceBarTop(Height())};
    if (b.y < 0 || b.y >= space_bar_metrics::kHeight) return std::nullopt;
    return b;
}

void SidebarView::ForgetActivation() {
    activating_ = false;
}

// Dragging a space's cell ------------------------------------------------------------------

void SidebarView::DragSpaceTo(D2D1_POINT_2F b) {
    // cellDragged: the first move past 4pt picks it up (not with one space, or while another
    // drop is still landing), and each one after moves it.
    if (!barDragging_ && barPress_) barDragging_ = bar_->BeginDrag(*barPress_);
    if (!barDragging_) return;
    bar_->MoveDrag(b.x, b.y);
    if (bar_->NeedsDraw()) ScheduleDraw();
}

void SidebarView::DropSpace(D2D1_POINT_2F b) {
    // cellDragEnded: it settles into its slot, and the space moves once it's there.
    barDragging_ = false;
    bar_->DropDrag(b.x, b.y);
    // The compositor starts the landing at the commit's frame, up to a frame after now: a frame at
    // 60 Hz to spare, as the pages' settle timer.
    SetTimer(window_, kDropTimer, static_cast<UINT>(std::ceil(space_bar_metrics::kReorderSlide * 1000)) + 17, nullptr);
    if (bar_->NeedsDraw()) ScheduleDraw();
}

void SidebarView::FinishDrop() {
    KillTimer(window_, kDropTimer);
    const std::optional<SpaceDrag> drag = bar_->Drag();
    if (!drag || !drag->landing) return;
    // The completion handler: the cells back on the layout, then the move (which updates the
    // bar with the new order before anything draws).
    bar_->EndDrag();
    ScheduleDraw();
    if (actions_.moveSpace) actions_.moveSpace(drag->spaceID, drag->target.value_or(drag->from));
    RefreshHover();
}

std::optional<POINT> SidebarView::SpaceCellCentre(size_t index) const {
    const SpaceBarLayout& layout = bar_->Geometry();
    if (index >= layout.cells.size()) return std::nullopt;
    const BarRect& cell = layout.cells[index];
    const float scale = static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI;
    const float top = SpaceBarTop(Height());
    return POINT{std::lround((cell.left + cell.right) / 2 * scale), std::lround(((cell.top + cell.bottom) / 2 + top) * scale)};
}

// Renaming a space ---------------------------------------------------------------------------

void SidebarView::BeginRenaming(const std::string& spaceID, const std::string& name) {
    if (rename_ && rename_->SpaceID() == spaceID) return;
    if (rename_) EndRenaming(true);
    std::wstring error;
    rename_ = SpaceRenameField::Create(window_, dwrite_.Get(), headerFormat_.Get(), doneFormat_.Get(), spaceID, name, error);
    if (!rename_) {
        OutputDebugStringW((L"Kite: the rename field couldn't open: " + error + L"\n").c_str());
        return;
    }
    HideTip();
    InvalidateSelectedPage();
}

std::optional<std::pair<std::string, std::string>> SidebarView::TakeRename() {
    if (!rename_) return std::nullopt;
    std::pair<std::string, std::string> taken{rename_->SpaceID(), rename_->Text()};
    renamePressed_ = false;
    rename_.reset();
    if (GetCapture() == window_ && !press_ && !barPress_) ReleaseCapture();
    InvalidateSelectedPage();  // its draw's commit takes the field's visuals away too
    return taken;
}

void SidebarView::EndRenaming(bool commit) {
    const auto taken = TakeRename();
    // The Mac's commitRename: a blank name keeps the old one (renameSpace).
    if (taken && commit && actions_.renameSpace) actions_.renameSpace(taken->first, taken->second);
}

std::optional<POINT> SidebarView::RenameDoneCentre() const {
    if (!rename_) return std::nullopt;
    const D2D1_RECT_F& done = rename_->DoneBox();
    const float scale = static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI;
    return POINT{std::lround(((done.left + done.right) / 2 + PageOffset()) * scale), std::lround((done.top + done.bottom) / 2 * scale)};
}

std::optional<POINT> SidebarView::HeaderNameCentre() {
    if (model_.rows.empty() || model_.rows.front().kind != SidebarRow::Kind::Header) return std::nullopt;
    const SidebarRow& header = model_.rows.front();
    const D2D1_RECT_F name = HeaderNameRect(header, M::kHeaderAreaHeight + header.top - scroll_);
    if (name.right <= name.left) return std::nullopt;
    const float scale = static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI;
    return POINT{std::lround(((name.left + name.right) / 2 + PageOffset()) * scale), std::lround((name.top + name.bottom) / 2 * scale)};
}

void SidebarView::FocusRenameForCapture() {
    if (!rename_) return;
    rename_->SetFocused(true);
    ScheduleDraw();
}

std::optional<std::string> SidebarView::Renaming() const {
    if (!rename_) return std::nullopt;
    return rename_->SpaceID();
}

void SidebarView::TypeInRename(std::string_view text) {
    if (!rename_) return;
    for (wchar_t c : Widen(std::string(text))) rename_->Character(c);
    ScheduleDraw();
}

bool SidebarView::HandleKey(UINT message, WPARAM wParam, LPARAM lParam) {
    if (!rename_) return false;
    using Outcome = SpaceRenameField::Outcome;
    const auto apply = [this](Outcome outcome) {
        if (outcome == Outcome::Commit) EndRenaming(true);
        else if (outcome == Outcome::Cancel) EndRenaming(false);
        else if (outcome == Outcome::Changed) ScheduleDraw();  // the field alone
    };
    switch (message) {
    case WM_KEYDOWN: {
        // AltGr is Ctrl+Alt: its characters come as WM_CHAR, never as a Ctrl shortcut.
        const bool alt = GetKeyState(VK_MENU) < 0;
        const bool ctrl = GetKeyState(VK_CONTROL) < 0 && !alt;
        const bool shift = GetKeyState(VK_SHIFT) < 0;
        const std::optional<Outcome> outcome = rename_->KeyDown(static_cast<UINT>(wParam), ctrl, shift);
        if (!outcome) return false;
        apply(*outcome);
        return true;
    }
    case WM_CHAR:
        apply(rename_->Character(static_cast<wchar_t>(wParam)));
        return true;
    case WM_IME_STARTCOMPOSITION:
        rename_->PlaceImeWindow();
        return false;  // Windows' composition window draws it; the result comes as WM_CHAR
    case WM_SETFOCUS:
        rename_->SetFocused(true);
        ScheduleDraw();
        return false;
    case WM_KILLFOCUS:
        // The page taking the keyboard ends it, as the web view becoming first responder ends
        // the Mac's field editor; another app's doesn't (AppKit keeps a field's editing).
        if (wParam && IsChild(window_, reinterpret_cast<HWND>(wParam))) {
            EndRenaming(true);
        } else {
            rename_->SetFocused(false);
            ScheduleDraw();
        }
        return false;
    case WM_SETCURSOR: {
        if (LOWORD(lParam) != HTCLIENT) return false;
        POINT cursor{};
        GetCursorPos(&cursor);
        ScreenToClient(window_, &cursor);
        const D2D1_POINT_2F p = OnPage(PointOf(cursor));
        if (!rename_->InField(p.x, p.y)) return false;
        SetCursor(LoadCursorW(nullptr, IDC_IBEAM));
        return true;
    }
    default:
        return false;
    }
}

void SidebarView::ClearHover() {
    pointer_.reset();
    // A cell being dragged goes back where it came from.
    if (barDragging_) DropSpace(D2D1_POINT_2F{-1, -1});
    renamePressed_ = false;
    // A press it drops lets go of the mouse too.
    if ((press_ || barPress_) && GetCapture() == window_) {
        press_.reset();
        barPress_.reset();
        ReleaseCapture();
    }
    press_.reset();
    barPress_.reset();
    activating_ = false;
    RefreshHover();
}

bool SidebarView::OverList(D2D1_POINT_2F p) const {
    // The list's scroll view: inside its padding, between the header and the space bar.
    return p.x >= M::kPadding && p.x < width_ - M::kPadding && p.y >= M::kHeaderAreaHeight && p.y < SidebarListBottom(Height());
}

bool SidebarView::ScrollList(POINT at, float distance) {
    const D2D1_POINT_2F p = PointOf(at);
    if (!OverList(p)) return false;
    if (distance == 0) return true;
    pointer_ = at;
    SetScroll(scrollExact_ + distance);
    return true;
}

void SidebarView::SetScroll(float scroll) {
    // The wheel's position is kept as it comes (a touchpad's small steps add up); the list
    // draws and takes the pointer at it rounded to whole pixels, so rows keep crisp edges.
    const float scale = static_cast<float>(dpi_) / USER_DEFAULT_SCREEN_DPI;
    const float limit = SidebarMaxScroll(model_.rows, Height(), scale);
    scrollExact_ = std::clamp(scroll, 0.0f, limit);
    const float snapped = std::min(std::round(scrollExact_ * scale) / scale, limit);
    if (snapped == scroll_) return;
    scroll_ = snapped;
    InvalidateSelectedPage();
    RefreshHover();
}

void SidebarView::Perform(const SidebarTap& tap) {
    using Action = SidebarTap::Action;
    switch (tap.action) {
    case Action::SelectTab:
        if (actions_.selectTab) actions_.selectTab(tap.id);
        break;
    case Action::SetFolderExpanded:
        if (actions_.setFolderExpanded) actions_.setFolderExpanded(tap.id, tap.expanded);
        break;
    case Action::TogglePinnedSection:
        if (actions_.togglePinnedSection) actions_.togglePinnedSection(tap.id);
        break;
    case Action::NewTab:
        if (actions_.newTab) actions_.newTab();
        break;
    case Action::EditAddress:
        if (actions_.editAddress) actions_.editAddress();
        break;
    case Action::CloseTab:
        if (actions_.closeTab) actions_.closeTab(tap.id);
        break;
    case Action::None:
        break;
    }
}

bool SidebarView::HandleMouse(UINT message, WPARAM wParam, LPARAM lParam) {
    switch (message) {
    case WM_MOUSEACTIVATE: {
        // A click that brings the window forward: rows take no part in it (below). Only one in
        // the sidebar counts; a click on the page activates through its own window.
        POINT at{};
        GetCursorPos(&at);
        ScreenToClient(window_, &at);
        const D2D1_POINT_2F p = PointOf(at);
        // Only a left click's (the one the rows would take), and only until the next left press,
        // whoever takes it (ForgetActivation).
        activating_ = HIWORD(lParam) == WM_LBUTTONDOWN && LOWORD(lParam) == HTCLIENT && p.x >= 0 && p.x < width_;
        return false;  // DefWindowProc activates
    }
    case WM_MOUSEMOVE: {
        if (!trackingLeave_) {
            TRACKMOUSEEVENT track{sizeof(track), TME_LEAVE, window_, 0};
            trackingLeave_ = TrackMouseEvent(&track) != FALSE;
        }
        pointer_ = POINT{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};
        if (renamePressed_ && rename_) {
            const D2D1_POINT_2F q = OnPage(PointOf(*pointer_));
            if (rename_->Move(q.x, q.y) != SpaceRenameField::Outcome::None) ScheduleDraw();
            return true;
        }
        if (barPress_) {
            // In the bar's points, wherever the pointer has gone.
            const D2D1_POINT_2F p = PointOf(*pointer_);
            SpaceBarMove(*barPress_, p.x, p.y - SpaceBarTop(Height()));
            if (barPress_->dragged) DragSpaceTo(D2D1_POINT_2F{p.x, p.y - SpaceBarTop(Height())});
            // A drag takes the tip away (cellDragged's setDragging), but not with one space,
            // which can't be dragged (it returns first).
            // The hover stays (no tracking-area events during a drag), so a release over the
            // same cell doesn't bring the tip back.
            if (barPress_->dragged && bar_->Cells().size() > 1) {
                KillTimer(window_, kTipTimer);
                tip_->Hide();
            }
        }
        RefreshHover();
        return false;
    }
    case WM_MOUSELEAVE:
        trackingLeave_ = false;
        pointer_.reset();
        RefreshHover();
        return false;
    case WM_LBUTTONDOWN: {
        const bool activating = activating_;
        activating_ = false;
        const POINT at{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};
        const D2D1_POINT_2F p = PointOf(at);
        if (p.x < 0 || p.x >= width_) return false;
        // NSEvent's clickCount: presses within the double-click time and distance count up.
        const DWORD time = static_cast<DWORD>(GetMessageTime());
        const bool again = clicks_ > 0 && time - lastClickTime_ <= GetDoubleClickTime() &&
                           std::abs(at.x - lastClickAt_.x) <= GetSystemMetrics(SM_CXDOUBLECLK) / 2 &&
                           std::abs(at.y - lastClickAt_.y) <= GetSystemMetrics(SM_CYDOUBLECLK) / 2;
        clicks_ = again ? clicks_ + 1 : 1;
        lastClickTime_ = time;
        lastClickAt_ = at;
        pointer_ = at;
        // While a space is renamed, a press in its field edits it, on Done commits it on release,
        // and anywhere else ends it (keeping what was typed) and goes on as a press.
        if (rename_) {
            const D2D1_POINT_2F q = OnPage(p);
            if (rename_->Press(q.x, q.y, (wParam & MK_SHIFT) != 0)) {
                renamePressed_ = true;
                SetCapture(window_);
                ScheduleDraw();
                return true;
            }
            EndRenaming(true);
        }
        RefreshHover();
        // A space's cell, which takes the click that brings the window forward too (the Mac's
        // acceptsFirstMouse).
        if (const auto b = BarPoint(p)) {
            barPress_ = SpaceBarPressAt(bar_->Geometry(), bar_->Cells(), b->x, b->y);
            if (barPress_) SetCapture(window_);
            return true;
        }
        const D2D1_POINT_2F q = OnPage(p);
        press_ = SidebarPressAt(model_.rows, width_, Height(), scroll_, q.x, q.y, clicks_, activating);
        if (press_) SetCapture(window_);
        return true;
    }
    case WM_LBUTTONUP: {
        if (renamePressed_) {
            renamePressed_ = false;
            if (GetCapture() == window_) ReleaseCapture();
            const D2D1_POINT_2F q = OnPage(PointOf(POINT{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)}));
            if (rename_ && rename_->Release(q.x, q.y) == SpaceRenameField::Outcome::Commit) EndRenaming(true);
            return true;
        }
        if (barPress_) {
            const SpaceBarPress press = *barPress_;
            barPress_.reset();
            const bool dragging = barDragging_;
            barDragging_ = false;  // before the capture goes, so its WM_CAPTURECHANGED doesn't drop it again
            if (GetCapture() == window_) ReleaseCapture();
            if (dragging) {
                const D2D1_POINT_2F p = PointOf(POINT{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)});
                barDragging_ = true;
                DropSpace(D2D1_POINT_2F{p.x, p.y - SpaceBarTop(Height())});
                RefreshHover();
                return true;
            }
            // Let go inside the cell it pressed, without dragging: that space (mouseUp's
            // bounds.contains).
            const D2D1_POINT_2F p = PointOf(POINT{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)});
            const std::optional<std::string> space =
                SpaceBarRelease(press, bar_->Geometry(), bar_->Cells(), p.x, p.y - SpaceBarTop(Height()));
            RefreshHover();
            if (space && actions_.selectSpace) actions_.selectSpace(*space);
            return true;
        }
        if (!press_) return false;
        const SidebarPress press = *press_;
        press_.reset();
        if (GetCapture() == window_) ReleaseCapture();
        const D2D1_POINT_2F p = PointOf(POINT{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)});
        // As the Mac's mouseUp: on release, over what was pressed, wherever its row is now.
        const D2D1_POINT_2F q = OnPage(p);
        const SidebarTap tap =
            p.x < 0 || p.x >= width_ ? SidebarTap{} : SidebarRelease(press, model_.rows, width_, Height(), scroll_, q.x, q.y);
        RefreshHover();
        // A click on the current space's name renames it in place (SpaceHeaderRowCell.tapped(at:)).
        if (tap.action == SidebarTap::Action::None && press.target == SidebarHit::Target::Row && press.kind == SidebarRow::Kind::Header &&
            press.clicks == 1 && press.id == model_.spaceID && !rename_ && actions_.beginRenaming && !model_.rows.empty()) {
            const SidebarRow& header = model_.rows.front();
            if (const D2D1_RECT_F name = HeaderNameRect(header, M::kHeaderAreaHeight + header.top - scroll_);
                q.x >= name.left && q.x < name.right && q.y >= name.top && q.y < name.bottom) {
                actions_.beginRenaming(header.id);
                return true;
            }
        }
        Perform(tap);  // a copy: the action rebuilds the rows
        return true;
    }
    case WM_CAPTURECHANGED:
        // The mouse went elsewhere mid-drag (another window took it): the cell goes back.
        if (barDragging_) DropSpace(D2D1_POINT_2F{-1, -1});
        renamePressed_ = false;
        if (press_ || barPress_) {
            press_.reset();
            barPress_.reset();
            RefreshHover();
        }
        return false;
    case WM_RBUTTONDOWN: {
        const D2D1_POINT_2F p = PointOf(POINT{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)});
        return p.x >= 0 && p.x < width_ && !press_ && !barPress_;
    }
    case WM_RBUTTONUP: {
        // The space's menu, from its cell in the bar or its header (menu(for:) and the header's
        // contextMenu(at:)), on release as Windows' context menus open.
        if (press_ || barPress_) return true;
        const POINT at{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};
        const D2D1_POINT_2F p = PointOf(at);
        if (p.x < 0 || p.x >= width_) return false;
        std::optional<std::string> space;
        if (const auto b = BarPoint(p)) {
            space = bar_->SpaceAt(b->x, b->y);
        } else if (const SidebarHit hit = HitAt(p); hit.target == SidebarHit::Target::Row && hit.row < model_.rows.size() &&
                                                  model_.rows[hit.row].kind == SidebarRow::Kind::Header) {
            space = model_.rows[hit.row].id;
        }
        if (!space || !actions_.spaceMenu) return true;
        HideTip();
        POINT screen = at;
        ClientToScreen(window_, &screen);
        actions_.spaceMenu(*space, screen);
        return true;
    }
    case WM_MOUSEHWHEEL: {
        // Sideways over the space bar: its strip, when the spaces don't fit (an NSScrollView).
        POINT at{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};
        ScreenToClient(window_, &at);
        if (!BarPoint(PointOf(at))) return false;
        UINT chars = 3;
        if (!SystemParametersInfoW(SPI_GETWHEELSCROLLCHARS, 0, &chars, 0)) chars = 3;
        const float notches = static_cast<float>(GET_WHEEL_DELTA_WPARAM(wParam)) / WHEEL_DELTA;
        if (bar_->Scroll(notches * static_cast<float>(chars) * kWheelLine)) {
            pointer_ = at;
            RefreshHover();
            ScheduleDraw();
        }
        return true;
    }
    case WM_MOUSEWHEEL: {
        POINT at{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};  // screen coordinates
        ScreenToClient(window_, &at);
        const D2D1_POINT_2F p = PointOf(at);
        const float height = Height();
        // Shift turns a wheel sideways, as across Windows: over the bar, its strip.
        if ((GET_KEYSTATE_WPARAM(wParam) & MK_SHIFT) && BarPoint(p)) {
            UINT lines = 3;
            if (!SystemParametersInfoW(SPI_GETWHEELSCROLLLINES, 0, &lines, 0) || lines == WHEEL_PAGESCROLL) lines = 3;
            const float notches = static_cast<float>(GET_WHEEL_DELTA_WPARAM(wParam)) / WHEEL_DELTA;
            if (bar_->Scroll(-notches * static_cast<float>(lines) * kWheelLine)) {
                pointer_ = at;
                RefreshHover();
                ScheduleDraw();
            }
            return true;
        }
        if (!OverList(p)) return false;
        UINT lines = 3;
        if (!SystemParametersInfoW(SPI_GETWHEELSCROLLLINES, 0, &lines, 0)) lines = 3;
        const float notches = static_cast<float>(GET_WHEEL_DELTA_WPARAM(wParam)) / WHEEL_DELTA;
        const float distance = lines == WHEEL_PAGESCROLL ? notches * (SidebarListBottom(height) - M::kHeaderAreaHeight)
                                                         : notches * static_cast<float>(lines) * kWheelLine;
        pointer_ = at;
        SetScroll(scrollExact_ - distance);
        return true;
    }
    default:
        return false;
    }
}

}  // namespace kite
