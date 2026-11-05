#pragma once
// UTF-8 and UTF-16 for the shell: the model's strings are UTF-8, Win32's are UTF-16.

#include <windows.h>

#include <algorithm>
#include <string>
#include <string_view>

namespace kite {

inline std::wstring Widen(std::string_view utf8) {
    if (utf8.empty()) return {};
    const int size = MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
    std::wstring out(static_cast<size_t>(std::max(size, 0)), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), out.data(), size);
    return out;
}

inline std::string Narrow(std::wstring_view text) {
    if (text.empty()) return {};
    const int size = WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    std::string out(static_cast<size_t>(std::max(size, 0)), '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), out.data(), size, nullptr, nullptr);
    return out;
}

// Writes `text` as UTF-8 to a standard handle, if the launcher gave us one (a GUI process
// has no console, but a launcher that redirects stdout or stderr, like CI, gets the text).
inline void WriteUtf8(DWORD which, std::wstring_view text) {
    HANDLE handle = GetStdHandle(which);
    if (!handle || handle == INVALID_HANDLE_VALUE || text.empty()) return;
    const std::string utf8 = Narrow(text);
    DWORD written = 0;
    WriteFile(handle, utf8.data(), static_cast<DWORD>(utf8.size()), &written, nullptr);
}

}  // namespace kite
