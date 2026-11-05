// Port of the Mac's QuitDialog.runDownloadsInProgress; see QuitDialog.h.

#include "shell/QuitDialog.h"

#include <commctrl.h>

#include <iterator>
#include <string>

#include "core/SkippedModal.h"
#include "shell/QuietRun.h"

namespace kite {

namespace {

constexpr wchar_t kTitle[] = L"Downloads in progress";
constexpr wchar_t kMessage[] = L"There are downloads in progress. Closing the application will cancel them.";
constexpr wchar_t kClose[] = L"Close Kite";
constexpr wchar_t kKeep[] = L"Keep browsing";
constexpr int kCloseButton = 100;
constexpr int kKeepButton = 101;

}  // namespace

bool RunDownloadsInProgress(HWND owner, bool quiet) {
    if (quiet) {
        // The Mac's WindowPresenter.logSkipped line for its own dialog windows.
        LogSkippedModal(std::wstring(L"dialog: ") + kTitle + L" | [" + kClose + L", " + kKeep + L"]");
        return Proceeds(SkippedModal::DownloadsInProgress);
    }
    {
        const TASKDIALOG_BUTTON buttons[] = {{kCloseButton, kClose}, {kKeepButton, kKeep}};
        TASKDIALOGCONFIG config{};
        config.cbSize = sizeof config;
        config.hwndParent = owner;
        // Esc and the close button answer Keep browsing, as the Mac's cancel action.
        config.dwFlags = TDF_ALLOW_DIALOG_CANCELLATION | TDF_POSITION_RELATIVE_TO_WINDOW;
        config.pszWindowTitle = L"Kite";
        config.pszMainInstruction = kTitle;
        config.pszContent = kMessage;
        config.cButtons = static_cast<UINT>(std::size(buttons));
        config.pButtons = buttons;
        config.nDefaultButton = kCloseButton;
        int picked = 0;
        // comctl32 is delay-loaded (only the window's process asks), as 6, which Kite.manifest asks for.
        if (SUCCEEDED(TaskDialogIndirect(&config, &picked, nullptr, nullptr))) return picked == kCloseButton;
    }
    // The dialog couldn't be made (out of memory, say): the same question in a message box.
    const std::wstring text = std::wstring(kMessage) + L"\n\nClose Kite?";
    return MessageBoxW(owner, text.c_str(), kTitle, MB_OKCANCEL | MB_ICONWARNING | MB_DEFBUTTON1) == IDOK;
}

}  // namespace kite
