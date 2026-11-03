#pragma once
// A tiny test harness, so the tests need nothing beyond the C++ standard library.

#include <cstdio>
#include <functional>
#include <vector>

namespace kite::test {

struct Case {
    const char* name;
    std::function<void()> body;
};

inline std::vector<Case>& Cases() {
    static std::vector<Case> cases;
    return cases;
}

inline int& Failures() {
    static int failures = 0;
    return failures;
}

struct Register {
    Register(const char* name, std::function<void()> body) { Cases().push_back({name, std::move(body)}); }
};

}  // namespace kite::test

#define KITE_CONCAT_(a, b) a##b
#define KITE_CONCAT(a, b) KITE_CONCAT_(a, b)
#define TEST(name)                                                                              \
    static void name();                                                                         \
    static ::kite::test::Register KITE_CONCAT(register_, name)(#name, &name);                   \
    static void name()
#define CHECK(condition)                                                                        \
    do {                                                                                        \
        if (!(condition)) {                                                                     \
            std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #condition);   \
            ++::kite::test::Failures();                                                         \
        }                                                                                       \
    } while (0)
