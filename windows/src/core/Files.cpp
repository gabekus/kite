// See Files.h.

#include "core/Files.h"

#include <fstream>

namespace kite {

namespace fs = std::filesystem;

std::string PathText(const fs::path& path) {
    auto u8 = path.u8string();
    return std::string(u8.begin(), u8.end());
}

std::optional<std::string> ReadFile(const fs::path& file, size_t maxBytes) {
    std::error_code error;
    if (!fs::is_regular_file(file, error)) return std::nullopt;
    const auto size = fs::file_size(file, error);
    if (error || size > maxBytes) return std::nullopt;
    std::ifstream in(file, std::ios::binary);
    if (!in) return std::nullopt;
    // One read of the size it had; a file that grew since is cut there, one that shrank ends early.
    std::string text(static_cast<size_t>(size), '\0');
    in.read(text.data(), static_cast<std::streamsize>(size));
    text.resize(static_cast<size_t>(in.gcount()));
    return text;
}

std::string WriteFileAtomically(const fs::path& file, const std::string& text) {
    std::error_code error;
    fs::create_directories(file.parent_path(), error);
    if (error) return "couldn't create " + PathText(file.parent_path()) + ": " + error.message();
    fs::path temp = file;
    temp += ".tmp";
    {
        std::ofstream out(temp, std::ios::binary | std::ios::trunc);
        if (!out) return "couldn't write " + PathText(temp);
        out.write(text.data(), static_cast<std::streamsize>(text.size()));
        out.flush();
        if (!out) return "couldn't write " + PathText(temp);
    }
    fs::rename(temp, file, error);
    if (error) {
        std::error_code ignored;
        fs::remove(temp, ignored);
        return "couldn't replace " + PathText(file) + ": " + error.message();
    }
    return {};
}

}  // namespace kite
