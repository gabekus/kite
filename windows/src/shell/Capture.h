#pragma once
// Saves pixels as a PNG: Kite for Windows' side of the Helix UI gate (docs/helix.md), the
// counterpart of `kite ui capture` on the Mac. The pixels are the window's own presented frame
// (Compositor::Draw's read-back), laid out at --capture-scale× on any monitor.

#include <windows.h>

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace kite {

// Top-down rows of B, G, R, A bytes (premultiplied; opaque for a window capture).
struct Pixels {
    UINT width = 0, height = 0;
    std::vector<uint8_t> bgra;
};

// Composes premultiplied `top` over `base` with its top-left at `origin` (px), clipped to
// `base`, as DirectComposition puts one visual over another.
void ComposeOver(Pixels& base, const Pixels& top, POINT origin);

// Empty on success, otherwise what failed. Encodes with WIC (first-party).
std::wstring SavePng(const Pixels& pixels, const std::filesystem::path& file);

}  // namespace kite
