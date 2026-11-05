// See CommandLine.h. Follows Chromium's base/command_line.cc (Windows): TrimWhitespace with
// kWhitespaceWide, then GetSwitchPrefixLength over "--", "-" and "/", and "--" alone ends the
// switches.

#include "core/CommandLine.h"

#include <algorithm>

#include "core/Unicode.h"

namespace kite::command_line {

namespace {

std::string_view Trimmed(std::string_view argument) { return unicode::Trim(argument); }

size_t SwitchPrefixLength(std::string_view s) {
    if (s.starts_with("--")) return 2;
    if (s.starts_with("-") || s.starts_with("/")) return 1;
    return 0;
}

bool Contains(const std::vector<std::string>& list, std::string_view s) { return std::find(list.begin(), list.end(), s) != list.end(); }

// An integer, nothing else: an optional "-" and ASCII digits ("-120"). Chromium reads "-120" as a
// switch, but one named "120", and none of its switches is a number; a name with a letter in it
// isn't an integer, and neither is anything with whitespace, "=", "--" or "/".
bool IsInteger(std::string_view s) {
    if (s.starts_with("-")) s.remove_prefix(1);
    return !s.empty() && std::all_of(s.begin(), s.end(), [](char c) { return c >= '0' && c <= '9'; });
}

std::string LowerAscii(std::string_view s) {
    std::string out(s);
    for (char& c : out) {
        if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    }
    return out;
}

}  // namespace

bool IsChromiumSwitch(std::string_view argument) {
    const std::string_view s = Trimmed(argument);
    const size_t prefix = SwitchPrefixLength(s);
    return prefix > 0 && prefix < s.size();
}

std::optional<std::string> Check(const std::vector<std::string>& arguments, const Spec& spec) {
    for (const std::string& a : arguments) {
        if (LowerAscii(a).find("chromehtml:") != std::string::npos) return "Kite doesn't take " + a;
    }
    for (size_t i = 0; i < arguments.size(); ++i) {
        const std::string& a = arguments[i];
        if (Contains(spec.flags, a)) continue;
        const bool takesSwitches = Contains(spec.switchValueOptions, a);
        if (Contains(spec.valueOptions, a) || takesSwitches) {
            if (i + 1 >= arguments.size()) return a + " takes a value";
            const std::string& value = arguments[++i];
            // Anything else would be a switch Chromium reads, swallowed as Kite's value. An integer
            // is the one exception: a negative number (--swipe -120) names no switch.
            if (!takesSwitches && !IsInteger(value) &&
                (IsChromiumSwitch(value) || Trimmed(value).starts_with("-") || Trimmed(value).starts_with("/"))) {
                return a + " takes a value, not " + value;
            }
            continue;
        }
        return "unknown option " + a;
    }
    return std::nullopt;
}

std::optional<ProcessType> ChromiumProcessType(const std::vector<std::string>& arguments) {
    // Chromium keeps a switch's last value; every spelling of it has to be Chromium's own.
    std::optional<ProcessType> found;
    size_t count = 0;
    bool canonical = true;
    for (const std::string& a : arguments) {
        const std::string_view s = Trimmed(a);
        if (s == "--") break;  // the end of the switches
        const size_t prefix = SwitchPrefixLength(s);
        if (prefix == 0 || prefix == s.size()) continue;
        const std::string_view rest = s.substr(prefix);
        const size_t equals = rest.find('=');
        if (LowerAscii(rest.substr(0, equals)) != "type") continue;
        const std::string value(equals == std::string_view::npos ? std::string_view() : rest.substr(equals + 1));
        ++count;
        canonical = canonical && a == "--type=" + value;
        found = ProcessType{value, false};
    }
    if (found) found->canonical = canonical && count == 1;
    return found;
}

}  // namespace kite::command_line
