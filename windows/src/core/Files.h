#pragma once
// Reading and writing the profile's small files (session.json and the others both apps read):
// whole-file reads with a size cap, and atomic writes, so a crash mid-write never leaves half a
// file. Paths come out as UTF-8 for messages.

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <variant>

namespace kite {

// A path as UTF-8 text. path::string() throws on Windows for names outside the ANSI code page.
std::string PathText(const std::filesystem::path& path);

// Kite's own files are far smaller than this; anything bigger isn't one of them. Import from
// Arc reads Arc's files with a cap of its own (ArcImportController.h).
inline constexpr size_t kMaxReadBytes = size_t{64} << 20;

// Why a file didn't read: not there (or not a regular file), over the cap (with its size), or
// there but unreadable.
struct ReadProblem {
    enum class Kind { Missing, TooLarge, Unreadable };
    Kind kind = Kind::Missing;
    uint64_t size = 0;  // TooLarge
};

// The file's bytes, in one read of the size it has, or why not.
std::variant<std::string, ReadProblem> ReadFileOrProblem(const std::filesystem::path& file, size_t maxBytes = kMaxReadBytes);
// The same, nullopt for any problem.
std::optional<std::string> ReadFile(const std::filesystem::path& file, size_t maxBytes = kMaxReadBytes);
// The file's first `bytes` bytes (fewer if it's shorter); nullopt when it isn't there or can't
// be read.
std::optional<std::string> ReadFilePrefix(const std::filesystem::path& file, size_t bytes);

// Writes a sibling temp file and renames it over `file` (MoveFileExW with replace on Windows),
// making the folder first. Empty on success, otherwise what went wrong.
std::string WriteFileAtomically(const std::filesystem::path& file, const std::string& text);

}  // namespace kite
