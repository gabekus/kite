// Kite.exe's command line, checked against Chromium's reading of it (core/CommandLine.h): the
// cases from base/command_line.cc's rules on Windows. Windows-only: the Mac's CEF gets its own
// argument list (KCRuntime.mm).

#include "Check.h"
#include "core/CommandLine.h"

using namespace kite::command_line;

namespace {

Spec Kite() {
    Spec spec;
    spec.flags = {"--smoke-test", "--backdrop-test"};
    spec.valueOptions = {"--capture", "--window-size", "--frame-log"};
    return spec;
}

bool Accepted(const std::vector<std::string>& arguments) { return !Check(arguments, Kite()).has_value(); }

}  // namespace

TEST(chromiumReadsTheSwitchesItsOwnWay) {
    CHECK(IsChromiumSwitch("--remote-debugging-port=9222"));
    CHECK(IsChromiumSwitch("-remote-debugging-port=9222"));
    CHECK(IsChromiumSwitch("/remote-debugging-port=9222"));
    // Trimmed of Unicode whitespace first: a space, a tab, U+00A0, U+3000.
    CHECK(IsChromiumSwitch(" /remote-debugging-pipe"));
    CHECK(IsChromiumSwitch("\t--x"));
    CHECK(IsChromiumSwitch("\xC2\xA0/remote-debugging-pipe"));
    CHECK(IsChromiumSwitch("\xE3\x80\x80-x "));
    // A prefix with nothing after it isn't a switch ("--" ends them).
    CHECK(!IsChromiumSwitch("--"));
    CHECK(!IsChromiumSwitch("-"));
    CHECK(!IsChromiumSwitch("/"));
    CHECK(!IsChromiumSwitch("out.png"));
    CHECK(!IsChromiumSwitch("C:\\out.png"));
}

TEST(kiteTakesOnlyItsOwnFlagsAndTheirValues) {
    CHECK(Accepted({}));
    CHECK(Accepted({"--smoke-test"}));
    CHECK(Accepted({"--capture", "C:\\out.png", "--window-size", "1280,820"}));
    // Anything else is refused, switch-shaped or not (Kite has no plain arguments yet).
    CHECK(!Accepted({"--smoketest"}));
    CHECK(!Accepted({"/remote-debugging-port=9222"}));
    CHECK(!Accepted({"-remote-debugging-port=9222"}));
    CHECK(!Accepted({" /remote-debugging-pipe"}));
    CHECK(!Accepted({"\xC2\xA0/remote-debugging-pipe"}));
    CHECK(!Accepted({"--smoke-test", "--"}));
    CHECK(!Accepted({"https://example.com"}));
    // CommandLineToArgvW has taken the quotes off "/x" by now: it's /x.
    CHECK(!Accepted({"/x"}));
    // Flags are exact: no whitespace, no other case, no other prefix.
    CHECK(!Accepted({" --smoke-test"}));
    CHECK(!Accepted({"--SMOKE-TEST"}));
    CHECK(!Accepted({"/smoke-test"}));
}

TEST(aValueIsNeverASwitchChromiumWouldRead) {
    CHECK(Check({"--capture"}, Kite()) == std::optional<std::string>("--capture takes a value"));
    CHECK(!Accepted({"--capture", "--smoke-test"}));
    CHECK(!Accepted({"--frame-log", "/x"}));
    CHECK(!Accepted({"--frame-log", "-x"}));
    CHECK(!Accepted({"--frame-log", " /remote-debugging-pipe"}));
    CHECK(!Accepted({"--frame-log", "\xC2\xA0-x"}));
    CHECK(!Accepted({"--frame-log", "--"}));
    CHECK(Accepted({"--frame-log", "C:\\frames.jsonl"}));
}

TEST(chromehtmlIsRefusedAnywhere) {
    // Chromium acts on an argument with chromehtml: in it before Kite's code runs.
    CHECK(!Accepted({"chromehtml:x"}));
    CHECK(!Accepted({"--capture", "C:\\a chromehtml:b.png"}));
    CHECK(!Accepted({"--capture", "ChromeHTML:x"}));
}

TEST(theProcessTypeIsChromiumsOwnSpelling) {
    CHECK(!ChromiumProcessType({"--smoke-test"}));
    auto type = ChromiumProcessType({"--type=renderer", "--lang=en"});
    CHECK(type && type->value == "renderer" && type->canonical);
    // Any other spelling Chromium also reads: not one of its own launches.
    type = ChromiumProcessType({"/type=renderer"});
    CHECK(type && type->value == "renderer" && !type->canonical);
    type = ChromiumProcessType({" --type=renderer"});
    CHECK(type && !type->canonical);
    type = ChromiumProcessType({"--TYPE=crashpad-handler", "--database=C:\\x"});
    CHECK(type && type->value == "crashpad-handler" && !type->canonical);
    // Chromium keeps the last one; two are never Chromium's.
    type = ChromiumProcessType({"--type=renderer", "--type=crashpad-handler"});
    CHECK(type && type->value == "crashpad-handler" && !type->canonical);
    // After "--" nothing is a switch.
    CHECK(!ChromiumProcessType({"--", "--type=renderer"}));
}
