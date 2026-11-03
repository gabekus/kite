#pragma once
// Kite.exe --backdrop-test: draws the theme backdrop on the GPU (on CI, the runner's software
// adapter) for every preset at two scales, crossfades and an odd size, in 32-bit float, and
// compares each pixel with core's CPU reference of Kite.metal (core/ThemeBackdrop.h). The check
// that Theme.hlsl does what the Mac's shader does.

#include <string>

namespace kite {

enum class BackdropTestOutcome { Matches, Differs, CouldNotRun };

// `report` gets the device and one line per case. On Differs, `problem` has the cases that
// didn't match; on CouldNotRun, why the GPU couldn't draw (not a shader mismatch).
BackdropTestOutcome RunBackdropTest(std::wstring& report, std::wstring& problem);

}  // namespace kite
