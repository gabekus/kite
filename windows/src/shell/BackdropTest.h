#pragma once
// Kite.exe --backdrop-test: draws the theme backdrop on the GPU (hardware, or WARP on CI) for
// every preset, a crossfade and two scales, and compares each pixel with core's CPU reference
// of Kite.metal (core/ThemeBackdrop.h). The check that Theme.hlsl does what the Mac's shader does.

#include <string>

namespace kite {

// Empty when every case matches, otherwise what didn't. `report` gets one line per case.
std::wstring RunBackdropTest(std::wstring& report);

}  // namespace kite
