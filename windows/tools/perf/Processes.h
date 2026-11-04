#pragma once
// kiteperf's view of Kite's processes: the job they run in, which of them exist (the job's list,
// and a parent walk over the system's process list for Kite.exe children outside it), what
// each is (its command line's --type), and a snapshot of what each uses: CPU, private working
// set and commit, writes, context switches, handles, threads, GPU memory and GPU engine time
// (PDH), with dwm.exe's and the whole machine's CPU for context.
//
// A process is opened with PROCESS_QUERY_LIMITED_INFORMATION only, which a sandboxed helper
// still allows. Every figure is optional: an API that fails gives none, never a 0.

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
    std::string type;     // browser, renderer, gpu-process, utility, crashpad, other or unknown
    std::string subtype;  // a utility's --utility-sub-type
    uint64_t created = 0;  // FILETIME, to tell a process born since the last snapshot
    bool exited = false;   // its last sample: it has ended, and its totals are final
    std::optional<double> cpuMs;                     // kernel + user (GetProcessTimes)
    std::optional<double> privateWsBytes, commitBytes;  // PROCESS_MEMORY_COUNTERS_EX2
    std::optional<double> ioWriteBytes, ioWriteOps;
    // Every thread's context switches, the ended ones' included (SystemProcessInformation).
    std::optional<double> contextSwitches, handles, threads;
    // PDH; none without its GPU counters (WARP). Engine time sums each engine's own increase.
    std::optional<double> gpuDedicatedBytes, gpuSharedBytes, gpuRunningMs;
};

struct Snapshot {
    int64_t qpc = 0;
    uint64_t fileTime = 0;  // the same moment as a FILETIME
    std::vector<ProcessSample> processes;  // Kite's
    std::optional<double> dwmCpuMs, dwmGpuMs;
    // GetSystemTimes, in ms: idle, and kernel + user (kernel includes idle).
    std::optional<double> systemIdleMs, systemTotalMs;
    // What the window manager shows of Kite (filled in by the run): how much of its window no
    // other window covers, whether the real pointer is over it, and whether it's in front.
    std::optional<double> kiteVisiblePct;
    bool pointerOverKite = false, kiteInFront = false;
};

// Job notifications: a process came or went (nearly exact, unlike the 1 Hz sampling: a full
// completion port can drop one).
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
    // One thread at a time.
    Snapshot Take();
    // Every process start and exit in the job so far.
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
        std::map<uintptr_t, double> threadSwitches;  // each live thread's count, by id
        double endedThreadSwitches = 0;              // the last counts of threads that ended
    };
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
    // PDH, and each GPU engine instance's last running time (so one that comes or goes mid-run
    // counts from 0 and never takes the sum backwards).
    void* query_ = nullptr;
    void* dedicated_ = nullptr;
    void* shared_ = nullptr;
    void* engine_ = nullptr;
    bool gpuCounters_ = false;
    std::map<std::wstring, double> engineLast_;
    std::map<DWORD, double> engineMs_;
    std::vector<unsigned char> ntBuffer_;
};

double QpcFrequency();

}  // namespace kiteperf
