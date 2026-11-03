// Runs every TEST registered by the suites (tests/Check.h) and exits non-zero if any check failed.

#include <cstdio>

#include "Check.h"

int main() {
    for (const auto& c : kite::test::Cases()) {
        int before = kite::test::Failures();
        c.body();
        std::printf("%s %s\n", kite::test::Failures() == before ? "ok  " : "FAIL", c.name);
    }
    std::printf("%zu tests, %d failed checks\n", kite::test::Cases().size(), kite::test::Failures());
    return kite::test::Failures() == 0 ? 0 : 1;
}
