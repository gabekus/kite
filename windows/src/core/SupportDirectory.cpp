// Profile directory resolution; see SupportDirectory.h. Ports AppDelegate.supportDirectory.

#include "core/SupportDirectory.h"

#include <cstdlib>

namespace kite {

std::variant<std::filesystem::path, SupportDirectoryError> ResolveSupportDirectory(
    const std::optional<std::filesystem::path>& overridePath,
    const std::optional<std::filesystem::path>& localAppData) {
    if (overridePath) {
        // Set but empty (KITE_SUPPORT_PATH= or --profile "$UNSET") is a mistake, not "use the
        // real profile": a test run must never touch it.
        if (overridePath->empty()) return SupportDirectoryError{"KITE_SUPPORT_PATH is set but empty"};
        std::error_code error;
        if (!std::filesystem::is_directory(*overridePath, error)) {
            auto text = overridePath->u8string();
            return SupportDirectoryError{"KITE_SUPPORT_PATH is not an existing directory: " + std::string(text.begin(), text.end())};
        }
        return *overridePath;
    }
    if (!localAppData || localAppData->empty()) return SupportDirectoryError{"LOCALAPPDATA isn't set"};
    return *localAppData / "Kite";
}

std::optional<std::filesystem::path> EnvironmentPath(const char* name) {
#ifdef _WIN32
    std::wstring wide(name, name + std::char_traits<char>::length(name));  // names are ASCII
    // Read once at startup, before any thread could change the environment. _wdupenv_s
    // would avoid C4996, but MinGW's msvcrt doesn't export it.
#ifdef _MSC_VER
#pragma warning(push)
#pragma warning(disable : 4996)
#endif
    const wchar_t* value = _wgetenv(wide.c_str());
#ifdef _MSC_VER
#pragma warning(pop)
#endif
#else
    const char* value = std::getenv(name);
#endif
    if (!value) return std::nullopt;
    return std::filesystem::path(value);
}

}  // namespace kite
