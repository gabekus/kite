// Same cases as the Mac's profile-path handling (AppDelegate.supportDirectory) plus the refusal.

#include <filesystem>
#include <fstream>
#include <variant>

#include "Check.h"
#include "core/SupportDirectory.h"

using kite::ResolveSupportDirectory;
using kite::SupportDirectoryError;
namespace fs = std::filesystem;

namespace {
fs::path TempPath(const wchar_t* name) { return fs::temp_directory_path() / name; }
}  // namespace

TEST(defaultsToLocalAppDataKite) {
    auto result = ResolveSupportDirectory(std::nullopt, L"C:\\Users\\x\\AppData\\Local");
    CHECK(std::holds_alternative<fs::path>(result));
    CHECK(std::get<fs::path>(result) == fs::path(L"C:\\Users\\x\\AppData\\Local") / L"Kite");
}

TEST(emptyOverrideCountsAsUnset) {
    auto result = ResolveSupportDirectory(std::wstring(), L"C:\\Local");
    CHECK(std::holds_alternative<fs::path>(result));
}

TEST(usesAnOverrideThatIsADirectory) {
    fs::path dir = TempPath(L"kite-support-dir-test");
    fs::create_directories(dir);
    auto result = ResolveSupportDirectory(dir.wstring(), L"C:\\Local");
    CHECK(std::holds_alternative<fs::path>(result));
    CHECK(std::get<fs::path>(result) == dir);
    fs::remove_all(dir);
}

TEST(refusesAnOverrideThatIsAFile) {
    fs::path file = TempPath(L"kite-support-file-test");
    std::ofstream(file).put('x');
    auto result = ResolveSupportDirectory(file.wstring(), L"C:\\Local");
    CHECK(std::holds_alternative<SupportDirectoryError>(result));
    fs::remove(file);
}

TEST(refusesAMissingOverride) {
    auto result = ResolveSupportDirectory(TempPath(L"kite-support-missing-test").wstring(), L"C:\\Local");
    CHECK(std::holds_alternative<SupportDirectoryError>(result));
}

TEST(failsWithoutLocalAppData) {
    CHECK(std::holds_alternative<SupportDirectoryError>(ResolveSupportDirectory(std::nullopt, std::nullopt)));
}
