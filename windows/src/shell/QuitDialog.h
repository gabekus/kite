#pragma once
// The quit dialogs' downloads part, after the Mac's QuitDialog.runDownloadsInProgress: closing
// Kite while downloads are running asks first, with Arc's "Downloads in progress", its message
// "There are downloads in progress. Closing the application will cancel them." and two choices,
// "Close Kite" (the default) and "Keep browsing" (also Esc and the dialog's close button).
//
// The Mac draws its own window there, laid out as a macOS alert (Arc's look isn't measured);
// Windows uses its own alert, a task dialog (comctl32 6, which Kite.manifest asks for,
// delay-loaded), over Kite's window; a message box asks the same if the dialog can't be made.
// It's asked as the window closes, before the pages close, where the Mac asks at terminate
// (applicationShouldTerminate): on Windows closing the window is quitting. Logoff and shutdown
// don't ask yet (a follow-up: WM_QUERYENDSESSION with ShutdownBlockReasonCreate's reason).
//
// A quiet run shows nothing: it logs the dialog's KITE_TEST_MODAL line (shell/QuietRun.h) and
// answers as the Mac's test-safe run does (SkippedModal::DownloadsInProgress proceeds: Close
// Kite), so a test Kite never blocks a scripted close or a logoff.

#include <windows.h>

namespace kite {

// True for Close Kite, false for Keep browsing. Runs a modal loop over `owner` (Kite's window
// stays responsive to Chromium's posts meanwhile).
bool RunDownloadsInProgress(HWND owner, bool quiet);

}  // namespace kite
