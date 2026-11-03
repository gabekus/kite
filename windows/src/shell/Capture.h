#pragma once
// Saves pixels as a PNG: Kite for Windows' side of the Helix UI gate (docs/helix.md), the
// counterpart of `kite ui capture` on the Mac. The pixels come from Renderer::Render, which
// draws the window's layers offscreen at any scale, so a 2× capture works on any monitor.

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

// Empty on success, otherwise what failed. Encodes with WIC (first-party).
std::wstring SavePng(const Pixels& pixels, const std::filesystem::path& file);

}  // namespace kite
