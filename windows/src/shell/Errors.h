#pragma once
// Win32 and COM failures as the messages Kite.exe prints and shows.

#include <windows.h>

#include <string>

namespace kite {

// "what failed (0x887A0005)".
inline std::wstring HResultMessage(const wchar_t* what, HRESULT hr) {
    wchar_t buffer[16];
    wsprintfW(buffer, L"0x%08X", static_cast<unsigned>(hr));
    return std::wstring(what) + L" failed (" + buffer + L")";
}

}  // namespace kite
