#pragma once
// Reads Kite.exe's --perf-log (shell/PerfLog.h) as it grows: marks, inputs, frames and long
// dispatches, every time a raw QueryPerformanceCounter value.

#include <windows.h>

#include <cstdint>
#include <filesystem>
#include <map>
#include <string>
#include <vector>

namespace kiteperf {

struct Mark {
    std::string name, detail;
    int64_t qpc = 0;
    double presents = 0, commits = 0;
    std::map<std::string, double> draws;
};
// 0 stands for a null time.
struct InputRecord {
    std::string kind;
    int64_t inputQpc = 0, commitQpc = 0, presentQpc = 0, targetQpc = 0;
};
struct FrameRecord {
    int64_t qpc = 0, presentQpc = 0, targetQpc = 0;
    double rate = 0;
};
struct DispatchRecord {
    int64_t qpc = 0;
    double ms = 0;
    unsigned message = 0;
};

class LogReader {
public:
    explicit LogReader(std::filesystem::path path) : path_(std::move(path)) {}
    ~LogReader();
    LogReader(const LogReader&) = delete;
    LogReader& operator=(const LogReader&) = delete;

    // Reads what Kite has written since the last call.
    void Pump();
    // The first mark named `name` at or after `after` (with `detail`, when given).
    const Mark* Find(const std::string& name, int64_t after = 0, const std::string* detail = nullptr) const;

    std::vector<Mark> marks;
    std::vector<InputRecord> inputs;
    std::vector<FrameRecord> frames;
    std::vector<DispatchRecord> dispatches;
    std::vector<std::string> chromiumSwitches;  // from the header

private:
    void Parse(const std::string& line);
    std::filesystem::path path_;
    HANDLE file_ = INVALID_HANDLE_VALUE;
    std::string partial_;
};

}  // namespace kiteperf
