// See Sandbox.h.

#include "shell/Sandbox.h"

#include <vector>

namespace kite {

namespace {

struct Handle {
    HANDLE value = nullptr;
    ~Handle() {
        if (value) CloseHandle(value);
    }
};

std::wstring LastError(const wchar_t* what) { return std::wstring(what) + L" failed (error " + std::to_wstring(GetLastError()) + L")"; }

}  // namespace

std::optional<ProcessSandbox> InspectSandbox(DWORD pid, std::wstring& error) {
    Handle process{OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid)};
    if (!process.value) {
        error = LastError(L"OpenProcess");
        return std::nullopt;
    }
    Handle token;
    if (!OpenProcessToken(process.value, TOKEN_QUERY, &token.value)) {
        token.value = nullptr;
        error = LastError(L"OpenProcessToken");
        return std::nullopt;
    }
    ProcessSandbox out;
    DWORD size = 0;
    GetTokenInformation(token.value, TokenIntegrityLevel, nullptr, 0, &size);
    std::vector<BYTE> label(size ? size : 1);
    if (!size || !GetTokenInformation(token.value, TokenIntegrityLevel, label.data(), size, &size)) {
        error = LastError(L"GetTokenInformation(TokenIntegrityLevel)");
        return std::nullopt;
    }
    const PSID sid = reinterpret_cast<TOKEN_MANDATORY_LABEL*>(label.data())->Label.Sid;
    out.integrity = *GetSidSubAuthority(sid, static_cast<DWORD>(*GetSidSubAuthorityCount(sid) - 1));
    out.restricted = IsTokenRestricted(token.value) != FALSE;
    DWORD isAppContainer = 0;
    if (GetTokenInformation(token.value, TokenIsAppContainer, &isAppContainer, sizeof isAppContainer, &size)) {
        out.appContainer = isAppContainer != 0;
    }
    PROCESS_MITIGATION_SYSTEM_CALL_DISABLE_POLICY systemCalls{};
    if (!GetProcessMitigationPolicy(process.value, ProcessSystemCallDisablePolicy, &systemCalls, sizeof systemCalls)) {
        error = LastError(L"GetProcessMitigationPolicy");
        return std::nullopt;
    }
    out.win32kLockdown = systemCalls.DisallowWin32kSystemCalls != 0;
    return out;
}

std::wstring RendererSandboxProblem(const ProcessSandbox& sandbox) {
    std::wstring problem;
    const auto add = [&](const wchar_t* what) { problem += (problem.empty() ? L"" : L"; ") + std::wstring(what); };
    if (sandbox.integrity >= SECURITY_MANDATORY_MEDIUM_RID) add(L"it runs at medium integrity or above");
    if (!sandbox.restricted && !sandbox.appContainer) add(L"its token is neither restricted nor an AppContainer's");
    if (!sandbox.win32kLockdown) add(L"it can call win32k");
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
