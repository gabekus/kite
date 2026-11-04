#pragma once
// Reading and writing the profile's small files (session.json and the others both apps read):
// whole-file reads with a size cap, and atomic writes, so a crash mid-write never leaves half a
// file. Paths come out as UTF-8 for messages.

#include <cstddef>
#include <filesystem>
#include <optional>
#include <string>

namespace kite {

// A path as UTF-8 text. path::string() throws on Windows for names outside the ANSI code page.
std::string PathText(const std::filesystem::path& path);

// Files Kite reads whole are far smaller than this; anything bigger isn't one of them.
inline constexpr size_t kMaxReadBytes = size_t{64} << 20;

// The file's bytes, or nullopt when it isn't a regular file, can't be read, or is over `maxBytes`.
std::optional<std::string> ReadFile(const std::filesystem::path& file, size_t maxBytes = kMaxReadBytes);

// Writes a sibling temp file and renames it over `file` (MoveFileExW with replace on Windows),
// making the folder first. Empty on success, otherwise what went wrong.
std::string WriteFileAtomically(const std::filesystem::path& file, const std::string& text);

}  // namespace kite
