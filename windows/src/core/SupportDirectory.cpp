#include "core/SupportDirectory.h"

#include <windows.h>

namespace kite {

std::variant<std::filesystem::path, SupportDirectoryError> ResolveSupportDirectory(
    const std::optional<std::wstring>& overridePath,
    const std::optional<std::wstring>& localAppData) {
    if (overridePath && !overridePath->empty()) {
        std::error_code error;
        std::filesystem::path path(*overridePath);
        if (!std::filesystem::is_directory(path, error)) {
            return SupportDirectoryError{L"KITE_SUPPORT_PATH is not an existing directory: " + *overridePath};
        }
        return path;
    }
    if (!localAppData || localAppData->empty()) {
        return SupportDirectoryError{L"LOCALAPPDATA isn't set"};
    }
    return std::filesystem::path(*localAppData) / L"Kite";
}

std::optional<std::wstring> EnvironmentVariable(const wchar_t* name) {
    DWORD size = GetEnvironmentVariableW(name, nullptr, 0);
    if (size <= 1) return std::nullopt;
    std::wstring value(size, L'\0');
    DWORD written = GetEnvironmentVariableW(name, value.data(), size);
    if (written == 0 || written >= size) return std::nullopt;
    value.resize(written);
    return value;
}

}  // namespace kite
