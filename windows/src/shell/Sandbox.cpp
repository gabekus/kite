// See Sandbox.h.

#include "shell/Sandbox.h"

#include <tlhelp32.h>
#include <winternl.h>

#include <string_view>

#include "shell/Errors.h"
#include "shell/Handle.h"

namespace kite {

namespace {

std::wstring LastError(const wchar_t* what) { return HResultMessage(what, HRESULT_FROM_WIN32(GetLastError())); }

// A process's command line (NtQueryInformationProcess's ProcessCommandLineInformation, Windows
// 8.1 and later), which is how a helper's type is known from outside it: Chromium passes it as
// --type. Looked up at run time, as ntdll's import library isn't one Kite links.
std::optional<std::wstring> CommandLine(HANDLE process) {
    using Query = NTSTATUS(NTAPI*)(HANDLE, PROCESSINFOCLASS, PVOID, ULONG, PULONG);
    static const auto query =
        reinterpret_cast<Query>(reinterpret_cast<void*>(GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtQueryInformationProcess")));
    constexpr auto kProcessCommandLineInformation = static_cast<PROCESSINFOCLASS>(60);
    if (!query) return std::nullopt;
    ULONG size = 0;
    query(process, kProcessCommandLineInformation, nullptr, 0, &size);
    if (size < sizeof(UNICODE_STRING)) return std::nullopt;
    std::vector<BYTE> buffer(size);
    if (query(process, kProcessCommandLineInformation, buffer.data(), size, &size) < 0) return std::nullopt;
    const auto* text = reinterpret_cast<const UNICODE_STRING*>(buffer.data());
    return std::wstring(text->Buffer, text->Length / sizeof(wchar_t));
}

// `--name=value`'s value in a command line, or empty.
std::wstring Switch(std::wstring_view line, std::wstring_view name) {
    const std::wstring key = L"--" + std::wstring(name) + L"=";
    const size_t at = line.find(key);
    if (at == std::wstring_view::npos) return {};
    const size_t start = at + key.size();
    const size_t end = line.find_first_of(L" \"", start);
    return std::wstring(line.substr(start, end == std::wstring_view::npos ? std::wstring_view::npos : end - start));
}

std::optional<ProcessSandbox> Inspect(HANDLE process, std::wstring& error) {
    KernelHandle token;
    if (!OpenProcessToken(process, TOKEN_QUERY, token.Put())) {
        error = LastError(L"OpenProcessToken");
        return std::nullopt;
    }
    ProcessSandbox out;
    DWORD size = 0;
    GetTokenInformation(token.Get(), TokenIntegrityLevel, nullptr, 0, &size);
    std::vector<BYTE> label(size ? size : 1);
    if (!size || !GetTokenInformation(token.Get(), TokenIntegrityLevel, label.data(), size, &size)) {
        error = LastError(L"GetTokenInformation(TokenIntegrityLevel)");
        return std::nullopt;
    }
    const PSID sid = reinterpret_cast<TOKEN_MANDATORY_LABEL*>(label.data())->Label.Sid;
    out.integrity = *GetSidSubAuthority(sid, static_cast<DWORD>(*GetSidSubAuthorityCount(sid) - 1));
    out.restricted = IsTokenRestricted(token.Get()) != FALSE;
    DWORD isAppContainer = 0;
    if (GetTokenInformation(token.Get(), TokenIsAppContainer, &isAppContainer, sizeof isAppContainer, &size)) {
        out.appContainer = isAppContainer != 0;
    }
    PROCESS_MITIGATION_SYSTEM_CALL_DISABLE_POLICY systemCalls{};
    if (!GetProcessMitigationPolicy(process, ProcessSystemCallDisablePolicy, &systemCalls, sizeof systemCalls)) {
        error = LastError(L"GetProcessMitigationPolicy");
        return std::nullopt;
    }
    out.win32kLockdown = systemCalls.DisallowWin32kSystemCalls != 0;
    return out;
}

}  // namespace

std::optional<ProcessSandbox> InspectSandbox(DWORD pid, std::wstring& error) {
    KernelHandle process{OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid)};
    if (!process) {
        error = LastError(L"OpenProcess");
        return std::nullopt;
    }
    return Inspect(process.Get(), error);
}

std::wstring RendererSandboxProblem(const ProcessSandbox& sandbox) {
    std::wstring problem;
    const auto add = [&](const wchar_t* what) { problem += (problem.empty() ? L"" : L"; ") + std::wstring(what); };
    if (sandbox.integrity >= SECURITY_MANDATORY_MEDIUM_RID) add(L"it runs at medium integrity or above");
    if (!sandbox.restricted && !sandbox.appContainer) add(L"its token is neither restricted nor an AppContainer's");
    if (!sandbox.win32kLockdown) add(L"it can call win32k");
    return problem;
}

std::vector<Helper> Helpers(std::wstring& error) {
    const HANDLE snapshotHandle = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshotHandle == INVALID_HANDLE_VALUE) {
        error = LastError(L"CreateToolhelp32Snapshot");
        return {};
    }
    const KernelHandle snapshot{snapshotHandle};
    std::vector<Helper> helpers;
    PROCESSENTRY32W entry{};
    entry.dwSize = sizeof entry;
    for (BOOL more = Process32FirstW(snapshot.Get(), &entry); more; more = Process32NextW(snapshot.Get(), &entry)) {
        if (entry.th32ParentProcessID != GetCurrentProcessId()) continue;
        KernelHandle process{OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, entry.th32ProcessID)};
        if (!process) continue;  // gone since the snapshot
        Helper helper;
        helper.pid = entry.th32ProcessID;
        if (const auto line = CommandLine(process.Get())) {
            helper.type = Switch(*line, L"type");
            if (const std::wstring sub = Switch(*line, L"utility-sub-type"); !sub.empty()) helper.type += L":" + sub;
        }
        if (helper.type.empty()) helper.type = L"(no --type)";
        std::wstring problem;
        const auto sandbox = Inspect(process.Get(), problem);
        if (!sandbox) {
            error = helper.type + L" (" + std::to_wstring(helper.pid) + L"): " + problem;
            return {};
        }
        helper.sandbox = *sandbox;
        helpers.push_back(std::move(helper));
    }
    return helpers;
}

std::wstring HelperSandboxProblem(const std::vector<Helper>& helpers) {
    std::wstring problem;
    for (const Helper& helper : helpers) {
        if (helper.sandbox.integrity < SECURITY_MANDATORY_MEDIUM_RID || helper.type == L"utility:network.mojom.NetworkService") continue;
        problem += (problem.empty() ? L"" : L"; ") + helper.type + L" runs at medium integrity or above";
    }
    return problem;
}

std::wstring Describe(const ProcessSandbox& sandbox) {
    std::wstring level;
    switch (sandbox.integrity) {
    case SECURITY_MANDATORY_UNTRUSTED_RID: level = L"untrusted"; break;
    case SECURITY_MANDATORY_LOW_RID: level = L"low"; break;
    case SECURITY_MANDATORY_MEDIUM_RID: level = L"medium"; break;
    case SECURITY_MANDATORY_HIGH_RID: level = L"high"; break;
    case SECURITY_MANDATORY_SYSTEM_RID: level = L"system"; break;
    default: level = std::to_wstring(sandbox.integrity); break;
    }
    return L"integrity " + level + (sandbox.restricted ? L", restricted" : L"") + (sandbox.appContainer ? L", AppContainer" : L"") +
           (sandbox.win32kLockdown ? L", win32k off" : L", win32k on");
}

}  // namespace kite
