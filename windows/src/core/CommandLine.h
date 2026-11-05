#pragma once
// Kite.exe's command line, checked the way Chromium would read it. Chromium reads the raw line
// itself (CEF's BasicStartupComplete, before command_line_args_disabled takes effect, and every
// helper's CefExecuteProcess), trimming each argument of Unicode whitespace and taking "--", "-"
// and "/" as switch prefixes, with switch names case-insensitive. So Kite takes only arguments it
// knows, never one Chromium could read as a switch of its own.
//
// Arguments are UTF-8 (the shell converts CommandLineToArgvW's).

#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace kite::command_line {

struct Spec {
    std::vector<std::string> flags;         // taken alone ("--smoke-test")
    std::vector<std::string> valueOptions;  // followed by their value ("--capture FILE")
    // Options whose value is itself switches (none yet; --chromium-switches, checked by its own
    // allow-list).
    std::vector<std::string> switchValueOptions;
};

// Whether Chromium would read `argument` as a switch: after trimming Unicode whitespace, it
// starts with "--", "-" or "/" and has a name after it (base::CommandLine on Windows).
bool IsChromiumSwitch(std::string_view argument);

// Nullopt when every argument is one of `spec`'s flags or options, each option has a value, no
// value is something Chromium would read as a switch, and nothing has "chromehtml:" in it (which
// Chromium handles itself, before any of Kite's code runs). Else why not.
std::optional<std::string> Check(const std::vector<std::string>& arguments, const Spec& spec);

// The --type switch Chromium would read (its last value, as Chromium keeps), if any: how
// Chromium tells its helper processes apart. `canonical` is whether it's given once, spelled
// exactly as Chromium spawns its helpers ("--type=renderer"), not with "/", "-", a capital or
// whitespace.
struct ProcessType {
    std::string value;
    bool canonical;
};
std::optional<ProcessType> ChromiumProcessType(const std::vector<std::string>& arguments);

}  // namespace kite::command_line
