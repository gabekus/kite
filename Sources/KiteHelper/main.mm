// Entry point for Kite's Chromium helper processes (renderer, GPU, network, ...).
// The same binary is copied into each "Kite Helper (…).app" bundle.

#include "include/cef_app.h"
#include "include/wrapper/cef_library_loader.h"

int main(int argc, char* argv[]) {
    CefScopedLibraryLoader libraryLoader;
    if (!libraryLoader.LoadInHelper()) return 1;
    CefMainArgs mainArgs(argc, argv);
    return CefExecuteProcess(mainArgs, nullptr, nullptr);
}
