#pragma once
// Writing Kite's JSON stores without ever leaving half a file: the counterpart of
// Foundation's `Data.write(to:options: .atomic)`, which the Mac's SessionStore.save and
// SessionBackups.backUp use (StoreFile.swift keeps the load side: a file that won't decode is
// moved aside, which SessionStore::Load does for the session).
//
// The bytes go to a sibling `<name>.tmp`, are flushed to the disk, and the temp file is renamed
// over the target (MoveFileExW with replace on Windows), so the rename is the only moment the
// target changes: a crash or power cut before it leaves the previous file as it was, after it
// the new one. A crash can leave the `.tmp` behind; the next write truncates it.

#include <filesystem>
#include <optional>
#include <string>
#include <string_view>

namespace kite::store_file {

// Empty on success, otherwise what went wrong (the target is then untouched).
std::string WriteAtomically(const std::filesystem::path& file, std::string_view bytes);

// The whole file, or none when it can't be read.
std::optional<std::string> Read(const std::filesystem::path& file);

// UTF-8 for messages; path::string() throws on Windows for names outside the ANSI code page.
std::string PathText(const std::filesystem::path& path);

}  // namespace kite::store_file
