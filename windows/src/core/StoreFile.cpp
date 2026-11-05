// See StoreFile.h.

#include "core/StoreFile.h"

#include <atomic>
#include <cstdio>
#include <system_error>
#include <thread>

#include "core/Uuid.h"

#ifdef _WIN32
#include <io.h>  // _commit: FlushFileBuffers through the CRT
#else
#include <fstream>
#include <iterator>
#endif

namespace kite::store_file {

namespace fs = std::filesystem;

std::string PathText(const fs::path& path) {
    auto u8 = path.u8string();
    return std::string(u8.begin(), u8.end());
}

namespace {

// Drawn once per process: two processes' temps never share a name. Plain chars (trivially
// destructible), so a writer thread still running as the process ends never reads a destroyed
// string.
struct Token {
    char text[9];
};
const char* ProcessToken() {
    static const Token token = [] {
        Token t{};
        const std::string uuid = NewUuid();
        for (size_t i = 0; i < 8; ++i) t.text[i] = uuid[i];
        return t;
    }();
    return token.text;
}

std::atomic<unsigned long long> nextTemp{0};

fs::path TempPath(const fs::path& file, unsigned long long n) {
    const std::string suffix = std::string(".") + ProcessToken() + "-" + std::to_string(n) + ".tmp";
    fs::path temp = file;
    temp += fs::path(std::u8string(suffix.begin(), suffix.end()));
    return temp;
}

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

fs::path NextTempPath(const fs::path& file) { return TempPath(file, nextTemp.load()); }

std::string WriteAtomically(const fs::path& file, std::string_view bytes) {
    const fs::path temp = TempPath(file, nextTemp++);
    if (std::string problem = WriteTemp(temp, bytes); !problem.empty()) {
        std::error_code ignored;
        fs::remove(temp, ignored);
        return problem;
    }
    // Windows refuses a replace while another writer's replace of the same file is under way,
    // and so do virus scanners and sync clients holding the file for a moment: access denied or
    // a sharing violation (both permission_denied in MSVC's mapping), or a lock violation. Those
    // are retried, for 250 ms at most by the clock (a sleep lasts a timer tick, 15.6 ms, not the
    // 5 asked for); any other failure is final at once.
    std::error_code error;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(250);
    for (;;) {
        fs::rename(temp, file, error);
        const bool passing = error == std::errc::permission_denied || error == std::errc::no_lock_available;
        if (!error || !passing || std::chrono::steady_clock::now() >= deadline) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    if (error) {
        std::error_code ignored;
        fs::remove(temp, ignored);
        return "couldn't replace " + PathText(file) + ": " + error.message();
    }
    return {};
}

// Whether `name` is a temp WriteAtomically made: <target>.<8 hex>-<digits>.tmp, or the one name
// it used before W11, <target>.json.tmp.
bool IsTempName(std::string_view name) {
    if (!name.ends_with(".tmp")) return false;
    if (name.ends_with(".json.tmp") && name.size() > 9) return true;
    name.remove_suffix(4);
    const size_t dash = name.rfind('-');
    if (dash == std::string_view::npos || dash + 1 == name.size() || dash < 9 || name[dash - 9] != '.') return false;
    for (size_t i = dash + 1; i < name.size(); ++i) {
        if (name[i] < '0' || name[i] > '9') return false;
    }
    for (size_t i = dash - 8; i < dash; ++i) {
        const char c = name[i];
        if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F') || (c >= 'a' && c <= 'f'))) return false;
    }
    return dash > 9;  // a target name before it
}

size_t RemoveStaleTemps(const fs::path& directory, std::chrono::seconds age) {
    const auto now = fs::file_time_type::clock::now();
    size_t removed = 0;
    std::error_code error;
    for (fs::directory_iterator it(directory, error), end; !error && it != end; it.increment(error)) {
        const std::u8string name = it->path().filename().u8string();
        if (!IsTempName(std::string_view(reinterpret_cast<const char*>(name.data()), name.size()))) continue;
        std::error_code failed;
        if (!fs::is_regular_file(it->path(), failed) || failed) continue;
        const auto written = fs::last_write_time(it->path(), failed);
        if (failed || now - written < age) continue;
        removed += fs::remove(it->path(), failed) ? 1 : 0;
    }
    return removed;
}

std::optional<std::string> Read(const fs::path& file) { return Read(file, std::string().max_size()); }

std::optional<std::string> Read(const fs::path& file, size_t maxBytes, bool* tooLarge) {
    if (tooLarge) *tooLarge = false;
    std::string text;
    char buffer[16384];
    bool ok = true;
#ifdef _WIN32
    std::FILE* in = nullptr;
    if (_wfopen_s(&in, file.c_str(), L"rb") != 0 || !in) return std::nullopt;
    for (size_t got; (got = std::fread(buffer, 1, sizeof buffer, in)) > 0;) {
        if (got > maxBytes - text.size()) {
            ok = false;
            if (tooLarge) *tooLarge = true;
            break;
        }
        text.append(buffer, got);
    }
    if (std::ferror(in)) ok = false;
    std::fclose(in);
#else
    std::error_code error;
    if (!fs::is_regular_file(file, error)) return std::nullopt;
    std::ifstream in(file, std::ios::binary);
    if (!in) return std::nullopt;
    while (in.read(buffer, sizeof buffer) || in.gcount() > 0) {
        const size_t got = static_cast<size_t>(in.gcount());
        if (got > maxBytes - text.size()) {
            ok = false;
            if (tooLarge) *tooLarge = true;
            break;
        }
        text.append(buffer, got);
        if (!in) break;
    }
    if (in.bad()) ok = false;
#endif
    if (!ok) return std::nullopt;
    return text;
}

}  // namespace kite::store_file
