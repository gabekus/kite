#pragma once
// A small JSON value, parser and writer: enough for session.json and the other files
// Kite shares with the Mac app, with no third-party dependency.
//
// Objects keep their members sorted by key and the writer emits them that way, like the Mac's
// JSONEncoder(.sortedKeys). Output is equivalent to the Mac's, not byte-identical: Swift
// also escapes "/" as "\/".

#include <concepts>
#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

namespace kite::json {

class Value;
using Array = std::vector<Value>;
// Sorted by key (std::map), which is also the order the writer uses.
using Object = std::map<std::string, Value, std::less<>>;

class Value {
public:
    Value() = default;  // null
    Value(std::nullptr_t) {}
    Value(bool b) : data_(b) {}
    Value(double d) : data_(d) {}
    // Any integer type, the same on every platform (int64_t is long on Linux, long long on Windows).
    template <std::integral T>
        requires(!std::same_as<T, bool>)
    Value(T i) : data_(static_cast<double>(i)) {}
    Value(const char* s) : data_(std::string(s)) {}
    Value(std::string s) : data_(std::move(s)) {}
    Value(Array a) : data_(std::make_shared<Array>(std::move(a))) {}
    Value(Object o) : data_(std::make_shared<Object>(std::move(o))) {}

    bool IsNull() const { return std::holds_alternative<std::monostate>(data_); }
    bool IsBool() const { return std::holds_alternative<bool>(data_); }
    bool IsNumber() const { return std::holds_alternative<double>(data_); }
    bool IsString() const { return std::holds_alternative<std::string>(data_); }
    bool IsArray() const { return std::holds_alternative<std::shared_ptr<Array>>(data_); }
    bool IsObject() const { return std::holds_alternative<std::shared_ptr<Object>>(data_); }

    // Typed reads: nullopt / nullptr when the value has another type.
    std::optional<bool> AsBool() const;
    std::optional<double> AsNumber() const;
    std::optional<int64_t> AsInt() const;  // whole numbers only
    const std::string* AsString() const;
    const Array* AsArray() const;
    const Object* AsObject() const;
    // For changing the container: unshares it first (copy-on-write), so read through a
    // const Value& instead. The pointer is valid until this Value is next copied or assigned.
    Array* AsArray();
    Object* AsObject();

    // Member lookup on an object; nullptr when absent or not an object.
    const Value* Find(std::string_view key) const;

    bool operator==(const Value& other) const;
    bool operator!=(const Value& other) const { return !(*this == other); }

private:
    // Arrays and objects are shared and copied on write (see the non-const accessors).
    std::variant<std::monostate, bool, double, std::string, std::shared_ptr<Array>, std::shared_ptr<Object>> data_;
};

struct ParseError {
    std::string message;
    size_t offset = 0;
};

// Strict RFC 8259: one value, optional surrounding whitespace, nothing else.
std::variant<Value, ParseError> Parse(std::string_view text);

// The value, or nullopt when the text isn't one value.
std::optional<Value> ParseValue(std::string_view text);

// Compact, sorted keys, UTF-8 output; numbers use the shortest round-trip form.
std::string Write(const Value& value);

// Lookups for walking loosely typed files (Arc's): a missing object passes through as nullptr.
const Value* Member(const Value* object, std::string_view key);
// The member when it's an object, else nullptr.
const Value* ObjectMember(const Value* object, std::string_view key);
// The member when it's a string, else nullptr.
const std::string* StringMember(const Value* object, std::string_view key);

}  // namespace kite::json
