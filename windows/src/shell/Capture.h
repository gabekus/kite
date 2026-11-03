#pragma once
// Saves a window's client area as a PNG: Kite for Windows' side of the Helix UI gate
// (docs/helix.md), the counterpart of `kite ui capture` on the Mac.

#include <windows.h>

#include <filesystem>
#include <string>

namespace kite {

// Empty on success, otherwise what failed. Uses PrintWindow with PW_RENDERFULLCONTENT, so
// DirectComposition and GPU content are included, and WIC (first-party) for the PNG.
std::wstring CaptureClientToPng(HWND hwnd, const std::filesystem::path& file);

}  // namespace kite
