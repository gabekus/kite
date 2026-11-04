// See Files.h.

#include "core/Files.h"

#include <fstream>

#include "core/StoreFile.h"

namespace kite {

namespace fs = std::filesystem;

std::string PathText(const fs::path& path) {
    auto u8 = path.u8string();
    return std::string(u8.begin(), u8.end());
}

std::variant<std::string, ReadProblem> ReadFileOrProblem(const fs::path& file, size_t maxBytes) {
    using Kind = ReadProblem::Kind;
    std::error_code error;
    if (!fs::is_regular_file(file, error)) return ReadProblem{error && fs::exists(file) ? Kind::Unreadable : Kind::Missing};
    const auto size = fs::file_size(file, error);
    if (error) return ReadProblem{Kind::Unreadable};
    if (size > maxBytes) return ReadProblem{Kind::TooLarge, static_cast<uint64_t>(size)};
    std::ifstream in(file, std::ios::binary);
    if (!in) return ReadProblem{Kind::Unreadable};
    // One read of the size it had; a file that grew since is cut there, one that shrank ends early.
    std::string text(static_cast<size_t>(size), '\0');
    in.read(text.data(), static_cast<std::streamsize>(size));
    if (in.bad()) return ReadProblem{Kind::Unreadable};
    text.resize(static_cast<size_t>(in.gcount()));
    return text;
}

std::optional<std::string> ReadFile(const fs::path& file, size_t maxBytes) {
    auto read = ReadFileOrProblem(file, maxBytes);
    if (auto* text = std::get_if<std::string>(&read)) return std::move(*text);
    return std::nullopt;
}

std::optional<std::string> ReadFilePrefix(const fs::path& file, size_t bytes) {
    std::error_code error;
    if (!fs::is_regular_file(file, error)) return std::nullopt;
    std::ifstream in(file, std::ios::binary);
    if (!in) return std::nullopt;
    std::string text(bytes, '\0');
    in.read(text.data(), static_cast<std::streamsize>(bytes));
    if (in.bad()) return std::nullopt;
    text.resize(static_cast<size_t>(in.gcount()));
    return text;
}

std::string WriteFileAtomically(const fs::path& file, const std::string& text) {
    std::error_code error;
    fs::create_directories(file.parent_path(), error);
    if (error) return "couldn't create " + PathText(file.parent_path()) + ": " + error.message();
    return store_file::WriteAtomically(file, text);
}

}  // namespace kite
