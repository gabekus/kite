#pragma once
// kiteperf's view of Kite's processes: the job they run in, which of them exist (the job's list
// and a Toolhelp walk from parent to child), what each is (its command line's --type), and a
// snapshot of what each uses, once a second: CPU, private working set and commit, writes,
// context switches, handles, threads, GPU memory and GPU engine time (PDH), and dwm.exe's and
// the whole machine's CPU for context.

#include <windows.h>

#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace kiteperf {

// One process at one moment. Times and counts are running totals; rates come from two
// snapshots.
struct ProcessSample {
    DWORD pid = 0;
    std::string type;     // browser, renderer, gpu-process, utility, crashpad or other
    std::string subtype;  // a utility's --utility-sub-type, a renderer's nothing
    double cpuMs = 0;     // kernel + user (GetProcessTimes)
    double privateWsBytes = 0, commitBytes = 0;  // PROCESS_MEMORY_COUNTERS_EX2
    double ioWriteBytes = 0, ioWriteOps = 0;
    double contextSwitches = 0, handles = 0, threads = 0;  // SystemProcessInformation
    std::optional<double> gpuDedicatedBytes, gpuSharedBytes, gpuRunningMs;  // none without PDH's GPU counters
};

struct Snapshot {
    int64_t qpc = 0;
    std::vector<ProcessSample> processes;  // Kite's
    double dwmCpuMs = 0;
    std::optional<double> dwmGpuMs;
    // GetSystemTimes, in ms: idle, and kernel + user (kernel includes idle).
    double systemIdleMs = 0, systemTotalMs = 0;
};

// Job notifications: a process came or went (exact, unlike the 1 Hz sampling).
struct JobEvent {
    int64_t qpc;
    bool started;
    DWORD pid;
};

class Processes {
public:
    // Kite's job: every process it starts is in it, and all of them end with it (closing the
    // handle kills them).
    static std::unique_ptr<Processes> Create(std::wstring& error);
    ~Processes();
    Processes(const Processes&) = delete;
    Processes& operator=(const Processes&) = delete;

    HANDLE Job() const { return job_; }
    // The process kiteperf started: its children are found from it too, and must have its
    // image name.
    void SetRoot(DWORD pid, const std::wstring& imageName);
    Snapshot Take();
    // Every process start and exit in the job so far, and whether the job is empty again.
    std::vector<JobEvent> Events() const;
    // When the job's last process ended (its QPC), or 0 while any is left.
    int64_t EmptyAt() const;
    // Whether PDH's GPU counters exist here (not on a machine with only WARP).
    bool HasGpuCounters() const { return gpuCounters_; }

private:
    Processes() = default;
    void WatchJob();
    struct Known {
        HANDLE handle = nullptr;
        std::string type, subtype;
    };
    static Known Identify(HANDLE process);
    void Add(DWORD pid);
    HANDLE job_ = nullptr;
    HANDLE port_ = nullptr;
    std::thread watcher_;
    DWORD root_ = 0;
    std::wstring imageName_;
    std::map<DWORD, Known> known_;
    mutable std::mutex eventsMutex_;
    std::vector<JobEvent> events_;
    int64_t emptyAt_ = 0;
    // PDH
    void* query_ = nullptr;
    void* dedicated_ = nullptr;
    void* shared_ = nullptr;
    void* engine_ = nullptr;
    bool gpuCounters_ = false;
    std::vector<unsigned char> ntBuffer_;
};

int64_t Qpc();
double QpcFrequency();

}  // namespace kiteperf
