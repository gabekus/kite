#pragma once
// Writing Kite's JSON stores without ever leaving half a file: the counterpart of
// Foundation's `Data.write(to:options: .atomic)`, which the Mac's SessionStore.save and
// SessionBackups.backUp use (StoreFile.swift keeps the load side: a file that won't decode is
// moved aside, which SessionStore::Load does for the session).
//
// The bytes go to a sibling temp file, are flushed to the disk, and the temp file is renamed
// over the target (MoveFileExW with replace on Windows), so the rename is the only moment the
// target changes: a crash or power cut before it leaves the previous file as it was, after it
// the new one. Each write has its own temp, `<name>.<process>-<n>.tmp` (a token drawn once per
// process, and a count), so two writers of one file (a Kite quitting and one starting, two
// threads) never write into the same temp; each rename is whole (retried for 250 ms at most
// while Windows refuses to replace a file another rename is replacing), and the last one wins.
// A crash can leave a temp behind: RemoveStaleTemps clears those, at launch.
//
// On Windows the reads and writes here use the CRT's FILE (no iostreams), so a writer thread
// still running as the process ends touches nothing the C++ library tears down.

#include <chrono>
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>

namespace kite::store_file {

// Empty on success, otherwise what went wrong (the target is then untouched).
std::string WriteAtomically(const std::filesystem::path& file, std::string_view bytes);

// The temp file the next WriteAtomically of `file` in this process goes through, without
// taking it (the tests use it to put something in a write's way).
std::filesystem::path NextTempPath(const std::filesystem::path& file);

// Whether `name` is a temp WriteAtomically made (<target>.<8 hex>-<n>.tmp, or the
// <target>.json.tmp it used before W11).
bool IsTempName(std::string_view name);

// Removes the temps in `directory` (any process's) last written over `age` ago: left by a
// crash, since no write takes that long. Returns how many went.
size_t RemoveStaleTemps(const std::filesystem::path& directory, std::chrono::seconds age);

// The whole file, or none when it can't be read. With `maxBytes`, a file longer than that isn't
// read past it: none, and `tooLarge` set. History reads history.json with kMaxHistoryReadBytes;
// this becomes W15's core/Files.h kMaxReadBytes when both have landed.
std::optional<std::string> Read(const std::filesystem::path& file);
std::optional<std::string> Read(const std::filesystem::path& file, size_t maxBytes, bool* tooLarge = nullptr);
// 64 MB: fifteen times the biggest history.json the Mac's 20,000-page cap makes.
inline constexpr size_t kMaxHistoryReadBytes = size_t{64} << 20;

// UTF-8 for messages; path::string() throws on Windows for names outside the ANSI code page.
std::string PathText(const std::filesystem::path& path);

}  // namespace kite::store_file
