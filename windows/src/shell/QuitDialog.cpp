// Port of the Mac's QuitDialog.runDownloadsInProgress; see QuitDialog.h.

#include "shell/QuitDialog.h"

#include <commctrl.h>

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

using TaskDialogIndirectFunction = HRESULT(WINAPI*)(const TASKDIALOGCONFIG*, int*, int*, BOOL*);

// comctl32 6's TaskDialogIndirect, looked up rather than linked: Kite.exe is also Chromium's
// helper processes, which never ask, and a system with only comctl32 5 has none.
TaskDialogIndirectFunction TaskDialogEntry() {
    static const TaskDialogIndirectFunction entry = [] {
        HMODULE comctl = LoadLibraryExW(L"comctl32.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        return comctl ? reinterpret_cast<TaskDialogIndirectFunction>(GetProcAddress(comctl, "TaskDialogIndirect")) : nullptr;
    }();
    return entry;
}

}  // namespace

bool RunDownloadsInProgress(HWND owner, bool quiet) {
    if (quiet) {
        // The Mac's WindowPresenter.logSkipped line for its own dialog windows.
        LogSkippedModal(std::wstring(L"dialog: ") + kTitle + L" | [" + kClose + L", " + kKeep + L"]");
        return Proceeds(SkippedModal::DownloadsInProgress);
    }
    if (TaskDialogIndirectFunction taskDialog = TaskDialogEntry()) {
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
        if (SUCCEEDED(taskDialog(&config, &picked, nullptr, nullptr))) return picked == kCloseButton;
    }
    const std::wstring text = std::wstring(kMessage) + L"\n\nClose Kite?";
    return MessageBoxW(owner, text.c_str(), kTitle, MB_OKCANCEL | MB_ICONWARNING | MB_DEFBUTTON1) == IDOK;
}

}  // namespace kite
