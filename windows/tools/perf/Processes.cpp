// See Processes.h.

#include "Processes.h"

#include <pdh.h>
#include <pdhmsg.h>
#include <psapi.h>

#include <algorithm>
#include <cwctype>

namespace kiteperf {

namespace {

// ntdll's process listing and command lines, looked up at run time (docs/windows-architecture.md:
// never linked). The structs are the documented x64 layouts in full (winternl.h's hide the
// fields used here).
struct UnicodeString {
    USHORT Length, MaximumLength;
    PWSTR Buffer;
};
struct SystemProcessInformation {
    ULONG NextEntryOffset, NumberOfThreads;
    LARGE_INTEGER WorkingSetPrivateSize;
    ULONG HardFaultCount, NumberOfThreadsHighWatermark;
    ULONGLONG CycleTime;
    LARGE_INTEGER CreateTime, UserTime, KernelTime;
    UnicodeString ImageName;
    LONG BasePriority;
    HANDLE UniqueProcessId, InheritedFromUniqueProcessId;
    ULONG HandleCount, SessionId;
    ULONG_PTR UniqueProcessKey;
    SIZE_T PeakVirtualSize, VirtualSize;
    ULONG PageFaultCount;
    SIZE_T PeakWorkingSetSize, WorkingSetSize, QuotaPeakPagedPoolUsage, QuotaPagedPoolUsage, QuotaPeakNonPagedPoolUsage,
        QuotaNonPagedPoolUsage, PagefileUsage, PeakPagefileUsage, PrivatePageCount;
    LARGE_INTEGER ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount,
        OtherTransferCount;
};
struct SystemThreadInformation {
    LARGE_INTEGER KernelTime, UserTime, CreateTime;
    ULONG WaitTime;
    PVOID StartAddress;
    struct {
        HANDLE UniqueProcess, UniqueThread;
    } ClientId;
    LONG Priority, BasePriority;
    ULONG ContextSwitches, ThreadState, WaitReason;
};
static_assert(sizeof(void*) != 8 || sizeof(SystemProcessInformation) == 0x100);
static_assert(sizeof(void*) != 8 || sizeof(SystemThreadInformation) == 0x50);
// psapi.h's PROCESS_MEMORY_COUNTERS_EX2 (Windows 10 21H2's SDK and later), mirrored.
struct MemoryCounters2 {
    DWORD cb, PageFaultCount;
    SIZE_T PeakWorkingSetSize, WorkingSetSize, QuotaPeakPagedPoolUsage, QuotaPagedPoolUsage, QuotaPeakNonPagedPoolUsage,
        QuotaNonPagedPoolUsage, PagefileUsage, PeakPagefileUsage, PrivateUsage, PrivateWorkingSetSize;
    ULONG64 SharedCommitUsage;
};
constexpr ULONG kSystemProcessInformation = 5;
constexpr ULONG kProcessCommandLineInformation = 60;
constexpr LONG kInfoLengthMismatch = static_cast<LONG>(0xC0000004);
using NtQuerySystemInformationFn = LONG(WINAPI*)(ULONG, PVOID, ULONG, PULONG);
using NtQueryInformationProcessFn = LONG(WINAPI*)(HANDLE, ULONG, PVOID, ULONG, PULONG);

template <typename F>
F Ntdll(const char* name) {
    static HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    return ntdll ? reinterpret_cast<F>(reinterpret_cast<void*>(GetProcAddress(ntdll, name))) : nullptr;
}

double Ms(const FILETIME& t) { return static_cast<double>((static_cast<ULONGLONG>(t.dwHighDateTime) << 32) | t.dwLowDateTime) / 1e4; }
double Ms(const LARGE_INTEGER& t) { return static_cast<double>(t.QuadPart) / 1e4; }

std::wstring Lower(std::wstring s) {
    for (wchar_t& c : s) c = static_cast<wchar_t>(std::towlower(c));
    return s;
}

std::wstring CommandLine(HANDLE process) {
    static const auto query = Ntdll<NtQueryInformationProcessFn>("NtQueryInformationProcess");
    if (!query) return {};
    std::vector<unsigned char> buffer(4096);
    ULONG needed = 0;
    LONG status = query(process, kProcessCommandLineInformation, buffer.data(), static_cast<ULONG>(buffer.size()), &needed);
    if (status == kInfoLengthMismatch || (status < 0 && needed > buffer.size())) {
        buffer.resize(needed + 16);
        status = query(process, kProcessCommandLineInformation, buffer.data(), static_cast<ULONG>(buffer.size()), &needed);
    }
    if (status < 0) return {};
    const auto* text = reinterpret_cast<const UnicodeString*>(buffer.data());
    return text->Buffer ? std::wstring(text->Buffer, text->Length / sizeof(wchar_t)) : std::wstring{};
}

// A switch's value on a Chromium command line ("--type=renderer").
std::string SwitchValue(const std::wstring& line, const std::wstring& name) {
    const std::wstring key = L"--" + name + L"=";
    const size_t at = line.find(key);
    if (at == std::wstring::npos) return {};
    size_t end = line.find_first_of(L" \"", at + key.size());
    if (end == std::wstring::npos) end = line.size();
    std::string out;
    for (size_t i = at + key.size(); i < end; ++i) out += static_cast<char>(line[i] < 0x80 ? line[i] : '?');
    return out;
}

// "pid_1234_luid_..." → 1234.
DWORD PidOfInstance(const wchar_t* name) {
    if (!name || std::wcsncmp(name, L"pid_", 4) != 0) return 0;
    return static_cast<DWORD>(std::wcstoul(name + 4, nullptr, 10));
}

// A wildcard counter's raw values, summed by process.
std::map<DWORD, double> RawByPid(PDH_HCOUNTER counter) {
    std::map<DWORD, double> out;
    if (!counter) return out;
    DWORD bytes = 0, count = 0;
    if (PdhGetRawCounterArrayW(counter, &bytes, &count, nullptr) != static_cast<PDH_STATUS>(PDH_MORE_DATA) || !bytes) return out;
    std::vector<unsigned char> buffer(bytes);
    auto* items = reinterpret_cast<PDH_RAW_COUNTER_ITEM_W*>(buffer.data());
    if (PdhGetRawCounterArrayW(counter, &bytes, &count, items) != ERROR_SUCCESS) return out;
    for (DWORD i = 0; i < count; ++i) {
        if (DWORD pid = PidOfInstance(items[i].szName)) out[pid] += static_cast<double>(items[i].RawValue.FirstValue);
    }
    return out;
}

}  // namespace

int64_t Qpc() {
    LARGE_INTEGER now{};
    QueryPerformanceCounter(&now);
    return now.QuadPart;
}

double QpcFrequency() {
    static const double frequency = [] {
        LARGE_INTEGER f{};
        QueryPerformanceFrequency(&f);
        return static_cast<double>(f.QuadPart);
    }();
    return frequency;
}

std::unique_ptr<Processes> Processes::Create(std::wstring& error) {
    std::unique_ptr<Processes> p(new Processes());
    p->job_ = CreateJobObjectW(nullptr, nullptr);
    p->port_ = CreateIoCompletionPort(INVALID_HANDLE_VALUE, nullptr, 0, 1);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    JOBOBJECT_ASSOCIATE_COMPLETION_PORT port{reinterpret_cast<PVOID>(1), p->port_};
    if (!p->job_ || !p->port_ || !SetInformationJobObject(p->job_, JobObjectExtendedLimitInformation, &limits, sizeof limits) ||
        !SetInformationJobObject(p->job_, JobObjectAssociateCompletionPortInformation, &port, sizeof port)) {
        error = L"couldn't make the job object (" + std::to_wstring(GetLastError()) + L")";
        return nullptr;
    }
    p->watcher_ = std::thread([raw = p.get()] { raw->WatchJob(); });
    // GPU memory and engine time per process: wildcard counters, expanded on every collect, so
    // processes that come later are in them too. Missing (no WDDM GPU, as on CI's WARP) leaves
    // the GPU fields empty.
    PDH_HQUERY query = nullptr;
    if (PdhOpenQueryW(nullptr, 0, &query) == ERROR_SUCCESS) {
        p->query_ = query;
        PDH_HCOUNTER dedicated = nullptr, shared = nullptr, engine = nullptr;
        const bool ok = PdhAddEnglishCounterW(query, L"\\GPU Process Memory(*)\\Dedicated Usage", 0, &dedicated) == ERROR_SUCCESS &&
                        PdhAddEnglishCounterW(query, L"\\GPU Process Memory(*)\\Shared Usage", 0, &shared) == ERROR_SUCCESS &&
                        PdhAddEnglishCounterW(query, L"\\GPU Engine(*)\\Running Time", 0, &engine) == ERROR_SUCCESS;
        if (ok) {
            p->dedicated_ = dedicated;
            p->shared_ = shared;
            p->engine_ = engine;
            p->gpuCounters_ = PdhCollectQueryData(query) == ERROR_SUCCESS;
        }
    }
    return p;
}

Processes::~Processes() {
    if (port_) PostQueuedCompletionStatus(port_, 0, 0, nullptr);  // key 0: quit
    if (watcher_.joinable()) watcher_.join();
    for (auto& [pid, known] : known_) CloseHandle(known.handle);
    if (query_) PdhCloseQuery(static_cast<PDH_HQUERY>(query_));
    if (job_) {
        TerminateJobObject(job_, 1);
        CloseHandle(job_);
    }
    if (port_) CloseHandle(port_);
}

void Processes::WatchJob() {
    for (;;) {
        DWORD message = 0;
        ULONG_PTR key = 0;
        LPOVERLAPPED data = nullptr;
        if (!GetQueuedCompletionStatus(port_, &message, &key, &data, INFINITE) || key == 0) return;
        const DWORD pid = static_cast<DWORD>(reinterpret_cast<ULONG_PTR>(data));
        std::lock_guard lock(eventsMutex_);
        switch (message) {
        case JOB_OBJECT_MSG_NEW_PROCESS: events_.push_back({Qpc(), true, pid}); break;
        case JOB_OBJECT_MSG_EXIT_PROCESS:
        case JOB_OBJECT_MSG_ABNORMAL_EXIT_PROCESS: events_.push_back({Qpc(), false, pid}); break;
        case JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO: emptyAt_ = Qpc(); break;
        default: break;
        }
    }
}

std::vector<JobEvent> Processes::Events() const {
    std::lock_guard lock(eventsMutex_);
    return events_;
}

int64_t Processes::EmptyAt() const {
    std::lock_guard lock(eventsMutex_);
    return emptyAt_;
}

void Processes::SetRoot(DWORD pid, const std::wstring& imageName) {
    root_ = pid;
    imageName_ = Lower(imageName);
}

// What a process of Kite's is, from its command line: no --type is the browser process.
Processes::Known Processes::Identify(HANDLE process) {
    const std::wstring line = CommandLine(process);
    std::string type = SwitchValue(line, L"type");
    if (type.empty()) type = "browser";
    else if (type == "crashpad-handler") type = "crashpad";
    else if (type != "renderer" && type != "gpu-process" && type != "utility") type = "other";
    return Known{process, type, SwitchValue(line, L"utility-sub-type")};
}

void Processes::Add(DWORD pid) {
    if (known_.contains(pid)) return;
    if (HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ | SYNCHRONIZE, FALSE, pid)) known_[pid] = Identify(h);
}

Snapshot Processes::Take() {
    Snapshot snap;
    // The whole machine's processes: context switches, handles and threads, and the parent of
    // each (children that left the job are still Kite's if their parent is and they're Kite.exe).
    static const auto querySystem = Ntdll<NtQuerySystemInformationFn>("NtQuerySystemInformation");
    struct Nt {
        DWORD parent;
        std::wstring image;
        double cswitches, handles, threads, cpuMs;
    };
    std::map<DWORD, Nt> nt;
    if (querySystem) {
        if (ntBuffer_.empty()) ntBuffer_.resize(1 << 20);
        ULONG needed = 0;
        LONG status;
        while ((status = querySystem(kSystemProcessInformation, ntBuffer_.data(), static_cast<ULONG>(ntBuffer_.size()), &needed)) ==
               kInfoLengthMismatch) {
            ntBuffer_.resize(std::max<size_t>(needed + 65536, ntBuffer_.size() * 2));
        }
        if (status >= 0) {
            for (size_t offset = 0;;) {
                const auto* p = reinterpret_cast<const SystemProcessInformation*>(ntBuffer_.data() + offset);
                const auto* threads = reinterpret_cast<const SystemThreadInformation*>(p + 1);
                double switches = 0;
                for (ULONG t = 0; t < p->NumberOfThreads; ++t) switches += threads[t].ContextSwitches;
                Nt entry{static_cast<DWORD>(reinterpret_cast<ULONG_PTR>(p->InheritedFromUniqueProcessId)),
                         p->ImageName.Buffer ? Lower(std::wstring(p->ImageName.Buffer, p->ImageName.Length / sizeof(wchar_t))) : L"",
                         switches, static_cast<double>(p->HandleCount), static_cast<double>(p->NumberOfThreads),
                         Ms(p->KernelTime) + Ms(p->UserTime)};
                nt[static_cast<DWORD>(reinterpret_cast<ULONG_PTR>(p->UniqueProcessId))] = std::move(entry);
                if (!p->NextEntryOffset) break;
                offset += p->NextEntryOffset;
            }
        }
    }
    // The job's list, then the parent walk: Kite.exe children of known processes that left the job.
    std::vector<unsigned char> buffer(sizeof(JOBOBJECT_BASIC_PROCESS_ID_LIST) + 512 * sizeof(ULONG_PTR));
    auto* list = reinterpret_cast<JOBOBJECT_BASIC_PROCESS_ID_LIST*>(buffer.data());
    if (QueryInformationJobObject(job_, JobObjectBasicProcessIdList, list, static_cast<DWORD>(buffer.size()), nullptr)) {
        for (DWORD i = 0; i < list->NumberOfProcessIdsInList; ++i) Add(static_cast<DWORD>(list->ProcessIdList[i]));
    }
    if (root_) Add(root_);
    for (bool added = true; added;) {
        added = false;
        for (const auto& [pid, entry] : nt) {
            if (known_.contains(pid) || !known_.contains(entry.parent) || entry.image != imageName_) continue;
            Add(pid);
            added = added || known_.contains(pid);
        }
    }
    // Gone: their handle is signalled.
    for (auto it = known_.begin(); it != known_.end();) {
        if (WaitForSingleObject(it->second.handle, 0) == WAIT_OBJECT_0) {
            CloseHandle(it->second.handle);
            it = known_.erase(it);
        } else {
            ++it;
        }
    }

    std::map<DWORD, double> dedicated, shared, engine;
    bool gpu = false;
    if (gpuCounters_ && PdhCollectQueryData(static_cast<PDH_HQUERY>(query_)) == ERROR_SUCCESS) {
        gpu = true;
        dedicated = RawByPid(static_cast<PDH_HCOUNTER>(dedicated_));
        shared = RawByPid(static_cast<PDH_HCOUNTER>(shared_));
        engine = RawByPid(static_cast<PDH_HCOUNTER>(engine_));  // 100 ns units
    }
    snap.qpc = Qpc();
    for (const auto& [pid, known] : known_) {
        ProcessSample s;
        s.pid = pid;
        s.type = known.type;
        s.subtype = known.subtype;
        FILETIME created, exited, kernel, user;
        if (GetProcessTimes(known.handle, &created, &exited, &kernel, &user)) s.cpuMs = Ms(kernel) + Ms(user);
        MemoryCounters2 memory{};
        memory.cb = sizeof memory;
        if (GetProcessMemoryInfo(known.handle, reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&memory), sizeof memory)) {
            s.privateWsBytes = static_cast<double>(memory.PrivateWorkingSetSize);
            s.commitBytes = static_cast<double>(memory.PrivateUsage);
        }
        IO_COUNTERS io{};
        if (GetProcessIoCounters(known.handle, &io)) {
            s.ioWriteBytes = static_cast<double>(io.WriteTransferCount);
            s.ioWriteOps = static_cast<double>(io.WriteOperationCount);
        }
        if (auto it = nt.find(pid); it != nt.end()) {
            s.contextSwitches = it->second.cswitches;
            s.handles = it->second.handles;
            s.threads = it->second.threads;
        }
        if (gpu) {
            s.gpuDedicatedBytes = dedicated.contains(pid) ? dedicated[pid] : 0;
            s.gpuSharedBytes = shared.contains(pid) ? shared[pid] : 0;
            s.gpuRunningMs = (engine.contains(pid) ? engine[pid] : 0) / 1e4;
        }
        snap.processes.push_back(std::move(s));
    }
    for (const auto& [pid, entry] : nt) {
        if (entry.image != L"dwm.exe") continue;
        snap.dwmCpuMs += entry.cpuMs;
        if (gpu) snap.dwmGpuMs = snap.dwmGpuMs.value_or(0) + (engine.contains(pid) ? engine[pid] : 0) / 1e4;
    }
    FILETIME idle, kernel, user;
    if (GetSystemTimes(&idle, &kernel, &user)) {
        snap.systemIdleMs = Ms(idle);
        snap.systemTotalMs = Ms(kernel) + Ms(user);
    }
    return snap;
}

}  // namespace kiteperf
