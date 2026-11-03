#include "Check.h"
#include "core/Json.h"

using namespace kite::json;

namespace {
Value P(const char* text) {
    auto parsed = Parse(text);
    CHECK(std::holds_alternative<Value>(parsed));
    return std::holds_alternative<Value>(parsed) ? std::get<Value>(parsed) : Value();
}
bool Fails(const char* text) { return std::holds_alternative<ParseError>(Parse(text)); }
}  // namespace

TEST(parsesScalarsAndContainers) {
    CHECK(P("null").IsNull());
    CHECK(P(" true ").AsBool() == true);
    CHECK(P("-12.5e1").AsNumber() == -125.0);
    CHECK(P("783000000.5").AsNumber() == 783000000.5);
    CHECK(*P(R"("a\"b\\c\/d\n")").AsString() == "a\"b\\c/d\n");
    Value v = P(R"({"b":[1,2,{"c":null}],"a":"x"})");
    CHECK(v.Find("b")->AsArray()->size() == 3);
    CHECK(*v.Find("a")->AsString() == "x");
}

TEST(decodesUnicodeEscapesAndSurrogates) {
    CHECK(*P(R"("é")").AsString() == "\xC3\xA9");
    CHECK(*P(R"("🏠")").AsString() == "\xF0\x9F\x8F\xA0");  // 🏠
    CHECK(Fails(R"("\ud83c")"));
    CHECK(Fails(R"("\udfe0")"));
}

TEST(rejectsInvalidJSON) {
    CHECK(Fails(""));
    CHECK(Fails("{nope"));
    CHECK(Fails("[1,]"));
    CHECK(Fails("01"));
    CHECK(Fails("1 2"));
    CHECK(Fails("\"tab\there\""));
    CHECK(Fails("{\"a\" 1}"));
    CHECK(Fails("nul"));
}

TEST(writesSortedCompactJSON) {
    Value v = P(R"({"b":1,"a":[true,null,"\u0001"],"c":0.1})");
    CHECK(Write(v) == R"({"a":[true,null,"\u0001"],"b":1,"c":0.1})");
}

TEST(roundTripsNumbersExactly) {
    for (double d : {0.0, -1.0, 0.1, 783000100.25, 1e-7, 123456789012345.0}) {
        Value back = P(Write(Value(d)).c_str());
        CHECK(back.AsNumber() == d);
    }
}

TEST(copiesAreIndependent) {
    Value a = P(R"({"x":[1]})");
    Value b = a;
    b.AsObject()->insert_or_assign("y", Value(2));
    CHECK(a.Find("y") == nullptr);
    CHECK(b.Find("y") != nullptr);
}
