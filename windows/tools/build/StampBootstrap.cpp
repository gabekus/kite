// Makes Kite.exe from CEF's bootstrap.exe, and checks a Kite.exe it made (docs/windows.md,
// "Chromium's sandbox"). A build tool (windows/tools/build): run after Kite.dll links.
//
//   stamp-bootstrap BOOTSTRAP.exe OUT.exe MANIFEST VERSION_MODULE [ICON.ico | @ICON_FILE]
//       copies the bootstrap with MANIFEST as its process manifest, VERSION_MODULE's version
//       resource in place of CEF's, CEF's icon replaced by ICON (Kite's, as its first and only
//       icon group; no icon without it), and an 8 MiB main-thread stack. @ICON_FILE names a
//       file holding the icon's path, or nothing for no icon (the build's kite-exe-icon.txt).
//   stamp-bootstrap --check KITE.exe MANIFEST [ICON.ico]
//       exits 0 when KITE.exe is such a copy: MANIFEST embedded as is, with per-monitor DPI v2,
//       the UTF-8 code page, long paths and common controls v6; Kite's version naming
//       Kite.exe as an application; ICON as its first icon group (no icon without it); the
//       8 MiB stack. Prints what's wrong otherwise.

#include <windows.h>

#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace {

constexpr ULONGLONG kStackReserve = 0x800000;
constexpr WORD kEnglishUS = MAKELANGID(LANG_ENGLISH, SUBLANG_ENGLISH_US);  // Version.rc's LANGUAGE
constexpr WORD kNeutral = MAKELANGID(LANG_NEUTRAL, SUBLANG_NEUTRAL);
// Kite's icon group, the only one, so it's the first Explorer, the taskbar and Alt+Tab find;
// its images are RT_ICON 1 to n.
constexpr WORD kIconGroup = 1;

std::wstring Win32Error(const std::wstring& what) { return what + L" (error " + std::to_wstring(GetLastError()) + L")"; }

class Module {
public:
    explicit Module(const std::wstring& path)
        : value_(LoadLibraryExW(path.c_str(), nullptr, LOAD_LIBRARY_AS_DATAFILE | LOAD_LIBRARY_AS_IMAGE_RESOURCE)) {}
    ~Module() {
        if (value_) FreeLibrary(value_);
    }
    Module(const Module&) = delete;
    Module& operator=(const Module&) = delete;
    HMODULE Get() const { return value_; }

private:
    HMODULE value_;
};

class File {
public:
    explicit File(HANDLE value) : value_(value) {}
    ~File() {
        if (Valid()) CloseHandle(value_);
    }
    File(const File&) = delete;
    File& operator=(const File&) = delete;
    HANDLE Get() const { return value_; }
    bool Valid() const { return value_ && value_ != INVALID_HANDLE_VALUE; }

private:
    HANDLE value_;
};

// A resource by type, name (an id or a string) and language.
struct Resource {
    LPCWSTR type = nullptr;
    WORD id = 0;
    std::wstring name;  // when it has no id
    WORD language = 0;
    LPCWSTR Name() const { return name.empty() ? MAKEINTRESOURCEW(id) : name.c_str(); }
};

// Every resource of the types Kite replaces or drops: the manifest, the version, CEF's icon.
std::vector<Resource> Replaced(HMODULE module) {
    struct Walk {
        std::vector<Resource> found;
        Resource current;
    } walk;
    for (LPCWSTR type : {RT_MANIFEST, RT_VERSION, RT_GROUP_ICON, RT_ICON}) {
        walk.current = {type};
        EnumResourceNamesW(
            module, type,
            [](HMODULE m, LPCWSTR t, LPWSTR n, LONG_PTR p) -> BOOL {
                auto* w = reinterpret_cast<Walk*>(p);
                w->current = {w->current.type};
                if (IS_INTRESOURCE(n)) w->current.id = static_cast<WORD>(reinterpret_cast<ULONG_PTR>(n));
                else w->current.name = n;
                EnumResourceLanguagesW(
                    m, t, n,
                    [](HMODULE, LPCWSTR, LPCWSTR, WORD language, LONG_PTR q) -> BOOL {
                        auto* v = reinterpret_cast<Walk*>(q);
                        Resource r = v->current;
                        r.language = language;
                        v->found.push_back(std::move(r));
                        return TRUE;
                    },
                    p);
                return TRUE;
            },
            reinterpret_cast<LONG_PTR>(&walk));
    }
    return walk.found;
}

std::optional<std::string> ReadFileBytes(const std::wstring& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return std::nullopt;
    return std::string{std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
}

// A module's resource bytes, or nullopt when it has none.
std::optional<std::string> ResourceBytes(HMODULE module, LPCWSTR type, LPCWSTR name) {
    HRSRC found = FindResourceW(module, name, type);
    HGLOBAL loaded = found ? LoadResource(module, found) : nullptr;
    const auto* bytes = loaded ? static_cast<const char*>(LockResource(loaded)) : nullptr;
    if (!bytes) return std::nullopt;
    return std::string(bytes, SizeofResource(module, found));
}

// An .ico file's images, and the icon group resource (GRPICONDIR) listing them as RT_ICON
// resources 1 to n.
struct Icon {
    std::vector<std::string> images;
    std::string group;
};

#pragma pack(push, 2)
struct IconDirectory {
    WORD reserved, type, count;
};
struct IconFileEntry {
    BYTE width, height, colors, reserved;
    WORD planes, bitCount;
    DWORD bytes, offset;
};
struct IconGroupEntry {
    BYTE width, height, colors, reserved;
    WORD planes, bitCount;
    DWORD bytes;
    WORD id;
};
#pragma pack(pop)

std::optional<Icon> ReadIcon(const std::wstring& path, std::wstring& problem) {
    const std::optional<std::string> file = ReadFileBytes(path);
    if (!file) {
        problem = L"can't read " + path;
        return std::nullopt;
    }
    IconDirectory directory{};
    if (file->size() >= sizeof directory) memcpy(&directory, file->data(), sizeof directory);
    if (directory.reserved != 0 || directory.type != 1 || directory.count == 0 ||
        file->size() < sizeof directory + directory.count * sizeof(IconFileEntry)) {
        problem = path + L" isn't an icon";
        return std::nullopt;
    }
    Icon icon;
    icon.group.append(reinterpret_cast<const char*>(&directory), sizeof directory);
    for (WORD i = 0; i < directory.count; ++i) {
        IconFileEntry entry{};
        memcpy(&entry, file->data() + sizeof directory + i * sizeof entry, sizeof entry);
        if (entry.offset > file->size() || entry.bytes > file->size() - entry.offset) {
            problem = path + L"'s image " + std::to_wstring(i + 1) + L" runs past the file's end";
            return std::nullopt;
        }
        icon.images.emplace_back(file->data() + entry.offset, entry.bytes);
        const IconGroupEntry group{entry.width, entry.height, entry.colors, 0, entry.planes, entry.bitCount, entry.bytes,
                                   static_cast<WORD>(i + 1)};
        icon.group.append(reinterpret_cast<const char*>(&group), sizeof group);
    }
    return icon;
}

// A module's first icon group (the one Explorer shows), or nullopt when it has none.
std::optional<Resource> FirstIconGroup(HMODULE module) {
    std::optional<Resource> first;
    EnumResourceNamesW(
        module, RT_GROUP_ICON,
        [](HMODULE, LPCWSTR, LPWSTR n, LONG_PTR p) -> BOOL {
            auto* out = reinterpret_cast<std::optional<Resource>*>(p);
            Resource r{RT_GROUP_ICON};
            if (IS_INTRESOURCE(n)) r.id = static_cast<WORD>(reinterpret_cast<ULONG_PTR>(n));
            else r.name = n;
            *out = std::move(r);
            return FALSE;  // the first is enough
        },
        reinterpret_cast<LONG_PTR>(&first));
    return first;
}

// Visits the image's 64-bit optional header, mapped for writing when `write`.
template <typename Visit>
std::wstring WithOptionalHeader(const std::wstring& path, bool write, Visit visit) {
    File file(CreateFileW(path.c_str(), GENERIC_READ | (write ? GENERIC_WRITE : 0), FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr));
    if (!file.Valid()) return Win32Error(L"can't open " + path);
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(file.Get(), &size)) return Win32Error(L"can't read the size of " + path);
    File mapping(CreateFileMappingW(file.Get(), nullptr, write ? PAGE_READWRITE : PAGE_READONLY, 0, 0, nullptr));
    if (!mapping.Valid()) return Win32Error(L"can't map " + path);
    void* view = MapViewOfFile(mapping.Get(), write ? FILE_MAP_WRITE : FILE_MAP_READ, 0, 0, 0);
    if (!view) return Win32Error(L"can't map " + path);
    std::wstring problem;
    auto* base = static_cast<BYTE*>(view);
    const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    if (size.QuadPart < static_cast<LONGLONG>(sizeof(IMAGE_DOS_HEADER)) || dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew < 0 ||
        size.QuadPart < static_cast<LONGLONG>(dos->e_lfanew) + static_cast<LONGLONG>(sizeof(IMAGE_NT_HEADERS64))) {
        problem = path + L" isn't an executable";
    } else {
        auto* nt = reinterpret_cast<IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
        if (nt->Signature != IMAGE_NT_SIGNATURE || nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC) {
            problem = path + L" isn't an x64 executable";
        } else {
            problem = visit(nt->OptionalHeader);
        }
    }
    if (write && problem.empty() && !FlushViewOfFile(view, 0)) problem = Win32Error(L"can't write " + path);
    UnmapViewOfFile(view);
    return problem;
}

std::wstring Stamp(const std::wstring& bootstrap, const std::wstring& out, const std::wstring& manifestPath, const std::wstring& versionModule,
                   const std::wstring& iconPath) {
    const std::optional<std::string> manifest = ReadFileBytes(manifestPath);
    if (!manifest || manifest->empty()) return L"can't read " + manifestPath;
    std::optional<Icon> icon;
    if (!iconPath.empty()) {
        std::wstring problem;
        if (icon = ReadIcon(iconPath, problem); !icon) return problem;
    }
    std::optional<std::string> version;
    {
        Module source(versionModule);
        if (!source.Get()) return Win32Error(L"can't open " + versionModule);
        version = ResourceBytes(source.Get(), RT_VERSION, MAKEINTRESOURCEW(VS_VERSION_INFO));
        if (!version) return versionModule + L" has no version resource";
    }

    // Written beside OUT and moved over it at the end, and deleted on any failure, so a build
    // that fails halfway leaves the last good Kite.exe (or none), never a half-stamped one.
    const std::wstring temp = out + L".stamping";
    struct Discard {
        const std::wstring& path;
        bool keep = false;
        ~Discard() {
            if (!keep) DeleteFileW(path.c_str());
        }
    } discard{temp};
    if (!CopyFileW(bootstrap.c_str(), temp.c_str(), FALSE)) return Win32Error(L"can't copy " + bootstrap);
    SetFileAttributesW(temp.c_str(), FILE_ATTRIBUTE_NORMAL);
    std::vector<Resource> old;
    {
        Module copy(temp);
        if (!copy.Get()) return Win32Error(L"can't open " + temp);
        old = Replaced(copy.Get());
    }
    HANDLE update = BeginUpdateResourceW(temp.c_str(), FALSE);
    if (!update) return Win32Error(L"can't update " + temp);
    bool ok = true;
    for (const Resource& r : old) ok = ok && UpdateResourceW(update, r.type, r.Name(), r.language, nullptr, 0);
    ok = ok && UpdateResourceW(update, RT_MANIFEST, CREATEPROCESS_MANIFEST_RESOURCE_ID, MAKELANGID(LANG_NEUTRAL, SUBLANG_NEUTRAL),
                               const_cast<char*>(manifest->data()), static_cast<DWORD>(manifest->size()));
    ok = ok && UpdateResourceW(update, RT_VERSION, MAKEINTRESOURCEW(VS_VERSION_INFO), kEnglishUS, version->data(),
                               static_cast<DWORD>(version->size()));
    if (icon) {
        for (size_t i = 0; i < icon->images.size(); ++i) {
            ok = ok && UpdateResourceW(update, RT_ICON, MAKEINTRESOURCEW(i + 1), kNeutral, icon->images[i].data(),
                                       static_cast<DWORD>(icon->images[i].size()));
        }
        ok = ok && UpdateResourceW(update, RT_GROUP_ICON, MAKEINTRESOURCEW(kIconGroup), kNeutral, icon->group.data(),
                                   static_cast<DWORD>(icon->group.size()));
    }
    if (!ok) {
        const std::wstring problem = Win32Error(L"can't change the resources of " + temp);
        EndUpdateResourceW(update, TRUE);
        return problem;
    }
    if (!EndUpdateResourceW(update, FALSE)) return Win32Error(L"can't write the resources of " + temp);

    // The checksum is cleared rather than left stale: Windows checks it only for drivers and
    // boot images, and signing doesn't need it.
    if (std::wstring problem = WithOptionalHeader(temp, true,
                                                  [](IMAGE_OPTIONAL_HEADER64& header) {
                                                      header.SizeOfStackReserve = kStackReserve;
                                                      header.CheckSum = 0;
                                                      return std::wstring();
                                                  });
        !problem.empty()) {
        return problem;
    }
    if (!MoveFileExW(temp.c_str(), out.c_str(), MOVEFILE_REPLACE_EXISTING)) return Win32Error(L"can't replace " + out + L" (is Kite running?)");
    discard.keep = true;
    return {};
}

std::wstring Check(const std::wstring& exe, const std::wstring& manifestPath, const std::wstring& iconPath) {
    std::wstring problems;
    const auto problem = [&](const std::wstring& what) { problems += (problems.empty() ? L"" : L"\n") + what; };
    const std::optional<std::string> expected = ReadFileBytes(manifestPath);
    if (!expected) return L"can't read " + manifestPath;
    std::optional<Icon> icon;
    if (!iconPath.empty()) {
        std::wstring error;
        if (icon = ReadIcon(iconPath, error); !icon) return error;
    }
    {
        Module image(exe);
        if (!image.Get()) return Win32Error(L"can't open " + exe);
        const std::optional<std::string> manifest = ResourceBytes(image.Get(), RT_MANIFEST, CREATEPROCESS_MANIFEST_RESOURCE_ID);
        if (!manifest) {
            problem(L"no process manifest");
        } else {
            if (*manifest != *expected) problem(L"the process manifest isn't " + manifestPath);
            for (std::string_view setting : {std::string_view(">PerMonitorV2</dpiAwareness>"), std::string_view(">UTF-8</activeCodePage>"),
                                             std::string_view(">true</longPathAware>"),
                                             std::string_view("name=\"Microsoft.Windows.Common-Controls\" version=\"6.0.0.0\"")}) {
                if (manifest->find(setting) == std::string::npos) {
                    problem(L"the process manifest lacks " + std::wstring(setting.begin(), setting.end()));
                }
            }
        }
        const std::optional<Resource> group = FirstIconGroup(image.Get());
        if (!icon) {
            if (group) problem(L"it has an icon, and was given none");
        } else if (!group || ResourceBytes(image.Get(), RT_GROUP_ICON, group->Name()) != icon->group) {
            problem(L"its first icon group isn't " + iconPath);
        } else {
            for (size_t i = 0; i < icon->images.size(); ++i) {
                if (ResourceBytes(image.Get(), RT_ICON, MAKEINTRESOURCEW(i + 1)) != icon->images[i]) {
                    problem(L"its icon image " + std::to_wstring(i + 1) + L" isn't " + iconPath + L"'s");
                }
            }
        }
    }
    DWORD ignored = 0;
    const DWORD size = GetFileVersionInfoSizeW(exe.c_str(), &ignored);
    std::vector<BYTE> info(size ? size : 1);
    if (!size || !GetFileVersionInfoW(exe.c_str(), 0, size, info.data())) {
        problem(Win32Error(L"no version resource"));
    } else {
        const auto text = [&](const wchar_t* key) {
            void* value = nullptr;
            UINT length = 0;
            const std::wstring path = std::wstring(L"\\StringFileInfo\\040904B0\\") + key;
            return VerQueryValueW(info.data(), path.c_str(), &value, &length) && length
                       ? std::wstring(static_cast<const wchar_t*>(value), length - 1)
                       : std::wstring();
        };
        if (text(L"FileDescription") != L"Kite") problem(L"the version's description is '" + text(L"FileDescription") + L"', not Kite");
        if (text(L"OriginalFilename") != L"Kite.exe") problem(L"the version names '" + text(L"OriginalFilename") + L"', not Kite.exe");
        void* fixed = nullptr;
        UINT length = 0;
        if (!VerQueryValueW(info.data(), L"\\", &fixed, &length) || static_cast<VS_FIXEDFILEINFO*>(fixed)->dwFileType != VFT_APP) {
            problem(L"the version doesn't say it's an application");
        }
    }
    if (std::wstring header = WithOptionalHeader(exe, false,
                                                 [](IMAGE_OPTIONAL_HEADER64& h) {
                                                     return h.SizeOfStackReserve == kStackReserve ? std::wstring()
                                                                                                  : std::wstring(L"the stack reserve isn't 8 MiB");
                                                 });
        !header.empty()) {
        problem(header);
    }
    return problems;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    std::wstring problem;
    if ((argc == 4 || argc == 5) && std::wstring_view(argv[1]) == L"--check") {
        problem = Check(argv[2], argv[3], argc == 5 ? argv[4] : L"");
    } else if (argc == 5 || argc == 6) {
        std::wstring icon = argc == 6 ? argv[5] : L"";
        if (icon.starts_with(L"@")) {
            const std::optional<std::string> named = ReadFileBytes(icon.substr(1));
            if (!named) {
                fwprintf(stderr, L"stamp-bootstrap: can't read %ls\n", icon.c_str() + 1);
                return 1;
            }
            // The path without the whitespace or line ends an editor or another generator adds.
            std::string_view path(*named);
            const size_t first = path.find_first_not_of(" \t\r\n");
            path = first == std::string_view::npos ? std::string_view() : path.substr(first, path.find_last_not_of(" \t\r\n") - first + 1);
            icon.clear();
            if (!path.empty()) {
                const int length = MultiByteToWideChar(CP_UTF8, 0, path.data(), static_cast<int>(path.size()), nullptr, 0);
                icon.resize(static_cast<size_t>(length > 0 ? length : 0));
                if (length > 0) MultiByteToWideChar(CP_UTF8, 0, path.data(), static_cast<int>(path.size()), icon.data(), length);
            }
        }
        problem = Stamp(argv[1], argv[2], argv[3], argv[4], icon);
    } else {
        fwprintf(stderr, L"usage: stamp-bootstrap BOOTSTRAP.exe OUT.exe MANIFEST VERSION_MODULE [ICON.ico]\n"
                         L"       stamp-bootstrap --check KITE.exe MANIFEST [ICON.ico]\n");
        return 2;
    }
    if (problem.empty()) return 0;
    fwprintf(stderr, L"stamp-bootstrap: %ls\n", problem.c_str());
    return 1;
}
