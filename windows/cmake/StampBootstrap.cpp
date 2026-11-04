// Makes Kite.exe from CEF's bootstrap.exe (W6b, docs/windows.md "Chromium's sandbox"): a copy
// with Kite's process manifest and version resource in place of CEF's, without CEF's icon, and
// with chrome.exe's 8 MiB main-thread stack (the bootstrap reserves 1 MiB; Kite.exe had 8, as
// CEF_EXE_LINKER_FLAGS give an x64 executable, and a renderer's main thread runs deep pages).
// The bootstrap is otherwise untouched: it enters Chromium's sandbox and calls Kite.dll's
// RunWinMain in every process. A build tool, run after Kite.dll links:
//
//   stamp-bootstrap BOOTSTRAP.exe OUT.exe MANIFEST VERSION_SOURCE.dll
//
// MANIFEST is embedded as the process manifest (resource 1); VERSION_SOURCE's RT_VERSION
// (Kite.dll's, from resources/Version.rc) replaces the bootstrap's "CEF Bootstrap
// Application", which Task Manager would show as each process's name.

#include <windows.h>

#include <imagehlp.h>

#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>
#include <utility>
#include <vector>

namespace {

constexpr ULONGLONG kStackReserve = 0x800000;

struct Resource {
    std::wstring type, name;  // "#n" for an integer id
    WORD language = 0;
};

std::wstring Id(LPCWSTR id) {
    return IS_INTRESOURCE(id) ? L"#" + std::to_wstring(reinterpret_cast<ULONG_PTR>(id)) : std::wstring(id);
}

LPCWSTR AsId(const std::wstring& id) {
    return id.starts_with(L"#") ? MAKEINTRESOURCEW(std::stoi(id.substr(1))) : id.c_str();
}

int Fail(const std::wstring& message) {
    fwprintf(stderr, L"stamp-bootstrap: %ls (error %lu)\n", message.c_str(), GetLastError());
    return 1;
}

// Every resource of the types Kite replaces or drops: the manifest, the version, CEF's icon.
std::vector<Resource> Replaced(HMODULE module) {
    std::vector<Resource> found;
    for (LPCWSTR type : {RT_MANIFEST, RT_VERSION, RT_GROUP_ICON, RT_ICON}) {
        struct Walk {
            std::vector<Resource>* out;
            std::wstring type, name;
        } walk{&found, Id(type), {}};
        EnumResourceNamesW(
            module, type,
            [](HMODULE m, LPCWSTR t, LPWSTR n, LONG_PTR p) -> BOOL {
                auto* w = reinterpret_cast<Walk*>(p);
                w->name = Id(n);
                EnumResourceLanguagesW(
                    m, t, n,
                    [](HMODULE, LPCWSTR, LPCWSTR, WORD language, LONG_PTR q) -> BOOL {
                        auto* v = reinterpret_cast<Walk*>(q);
                        v->out->push_back({v->type, v->name, language});
                        return TRUE;
                    },
                    p);
                return TRUE;
            },
            reinterpret_cast<LONG_PTR>(&walk));
    }
    return found;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc != 5) {
        fwprintf(stderr, L"usage: stamp-bootstrap BOOTSTRAP.exe OUT.exe MANIFEST VERSION_SOURCE.dll\n");
        return 2;
    }
    const std::wstring bootstrap = argv[1], out = argv[2], manifestPath = argv[3], versionSource = argv[4];
    const std::wstring temp = out + L".stamping";

    std::ifstream manifestFile(manifestPath, std::ios::binary);
    const std::string manifest{std::istreambuf_iterator<char>(manifestFile), std::istreambuf_iterator<char>()};
    if (!manifestFile || manifest.empty()) return Fail(L"can't read " + manifestPath);

    std::vector<BYTE> version;
    WORD versionLanguage = MAKELANGID(LANG_NEUTRAL, SUBLANG_NEUTRAL);
    {
        HMODULE source = LoadLibraryExW(versionSource.c_str(), nullptr, LOAD_LIBRARY_AS_DATAFILE | LOAD_LIBRARY_AS_IMAGE_RESOURCE);
        if (!source) return Fail(L"can't open " + versionSource);
        for (const Resource& r : Replaced(source)) {
            if (r.type != Id(RT_VERSION)) continue;
            HRSRC found = FindResourceExW(source, RT_VERSION, AsId(r.name), r.language);
            HGLOBAL loaded = found ? LoadResource(source, found) : nullptr;
            const auto* bytes = loaded ? static_cast<const BYTE*>(LockResource(loaded)) : nullptr;
            if (bytes) {
                version.assign(bytes, bytes + SizeofResource(source, found));
                versionLanguage = r.language;
            }
            break;
        }
        FreeLibrary(source);
        if (version.empty()) return Fail(versionSource + L" has no version resource");
    }

    if (!CopyFileW(bootstrap.c_str(), temp.c_str(), FALSE)) return Fail(L"can't copy " + bootstrap);
    SetFileAttributesW(temp.c_str(), FILE_ATTRIBUTE_NORMAL);
    std::vector<Resource> old;
    {
        HMODULE copy = LoadLibraryExW(temp.c_str(), nullptr, LOAD_LIBRARY_AS_DATAFILE | LOAD_LIBRARY_AS_IMAGE_RESOURCE);
        if (!copy) return Fail(L"can't open " + temp);
        old = Replaced(copy);
        FreeLibrary(copy);
    }
    HANDLE update = BeginUpdateResourceW(temp.c_str(), FALSE);
    if (!update) return Fail(L"can't update " + temp);
    bool ok = true;
    for (const Resource& r : old) ok = ok && UpdateResourceW(update, AsId(r.type), AsId(r.name), r.language, nullptr, 0);
    ok = ok && UpdateResourceW(update, RT_MANIFEST, MAKEINTRESOURCEW(1), MAKELANGID(LANG_NEUTRAL, SUBLANG_NEUTRAL),
                               const_cast<char*>(manifest.data()), static_cast<DWORD>(manifest.size()));
    ok = ok && UpdateResourceW(update, RT_VERSION, MAKEINTRESOURCEW(1), versionLanguage, version.data(), static_cast<DWORD>(version.size()));
    if (!EndUpdateResourceW(update, !ok) || !ok) return Fail(L"can't write the resources of " + temp);

    // The stack reserve, and the checksum after it (and after the resources moved).
    {
        HANDLE file = CreateFileW(temp.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr);
        if (file == INVALID_HANDLE_VALUE) return Fail(L"can't open " + temp);
        LARGE_INTEGER size{};
        GetFileSizeEx(file, &size);
        HANDLE mapping = CreateFileMappingW(file, nullptr, PAGE_READWRITE, 0, 0, nullptr);
        void* view = mapping ? MapViewOfFile(mapping, FILE_MAP_WRITE, 0, 0, 0) : nullptr;
        bool patched = false;
        if (view) {
            auto* dos = static_cast<IMAGE_DOS_HEADER*>(view);
            auto* nt = reinterpret_cast<IMAGE_NT_HEADERS64*>(static_cast<BYTE*>(view) + dos->e_lfanew);
            if (dos->e_magic == IMAGE_DOS_SIGNATURE && nt->Signature == IMAGE_NT_SIGNATURE &&
                nt->OptionalHeader.Magic == IMAGE_NT_OPTIONAL_HDR64_MAGIC) {
                nt->OptionalHeader.SizeOfStackReserve = kStackReserve;
                DWORD headerSum = 0, checkSum = 0;
                if (CheckSumMappedFile(view, static_cast<DWORD>(size.QuadPart), &headerSum, &checkSum)) {
                    nt->OptionalHeader.CheckSum = checkSum;
                    patched = true;
                }
            }
            FlushViewOfFile(view, 0);
            UnmapViewOfFile(view);
        }
        if (mapping) CloseHandle(mapping);
        CloseHandle(file);
        if (!patched) return Fail(L"can't set the stack size of " + temp + L" (not an x64 executable?)");
    }
    if (!MoveFileExW(temp.c_str(), out.c_str(), MOVEFILE_REPLACE_EXISTING)) return Fail(L"can't replace " + out + L" (is Kite running?)");
    return 0;
}
