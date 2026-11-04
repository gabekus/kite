// See StoreFile.h.

#include "core/StoreFile.h"

#include <cstdio>
#include <fstream>
#include <system_error>

#ifdef _WIN32
#include <io.h>  // _commit: FlushFileBuffers through the CRT
#endif

namespace kite::store_file {

namespace fs = std::filesystem;

std::string PathText(const fs::path& path) {
    auto u8 = path.u8string();
    return std::string(u8.begin(), u8.end());
}

namespace {

// Writes and flushes the temp file. On Windows the bytes are also committed to the disk before
// the rename, so a power cut can't leave the renamed file empty (NTFS journals the rename, not
// the data).
std::string WriteTemp(const fs::path& temp, std::string_view bytes) {
#ifdef _WIN32
    std::FILE* out = nullptr;
    if (_wfopen_s(&out, temp.c_str(), L"wb") != 0 || !out) return "couldn't write " + PathText(temp);
    bool ok = std::fwrite(bytes.data(), 1, bytes.size(), out) == bytes.size();
    ok = std::fflush(out) == 0 && ok;
    ok = _commit(_fileno(out)) == 0 && ok;
    ok = std::fclose(out) == 0 && ok;
    return ok ? std::string{} : "couldn't write " + PathText(temp);
#else
    std::ofstream out(temp, std::ios::binary | std::ios::trunc);
    if (!out) return "couldn't write " + PathText(temp);
    out.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
    out.flush();
    return out ? std::string{} : "couldn't write " + PathText(temp);
#endif
}

}  // namespace

std::string WriteAtomically(const fs::path& file, std::string_view bytes) {
    fs::path temp = file;
    temp += ".tmp";
    if (std::string problem = WriteTemp(temp, bytes); !problem.empty()) {
        std::error_code ignored;
        fs::remove(temp, ignored);
        return problem;
    }
    std::error_code error;
    fs::rename(temp, file, error);
    if (error) {
        std::error_code ignored;
        fs::remove(temp, ignored);
        return "couldn't replace " + PathText(file) + ": " + error.message();
    }
    return {};
}

std::optional<std::string> Read(const fs::path& file) {
    std::error_code error;
    const auto size = fs::file_size(file, error);
    if (error) return std::nullopt;
    std::ifstream in(file, std::ios::binary);
    if (!in) return std::nullopt;
    std::string text(static_cast<size_t>(size), '\0');
    if (!in.read(text.data(), static_cast<std::streamsize>(size))) return std::nullopt;
    return text;
}

}  // namespace kite::store_file
