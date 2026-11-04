// See Json.h.

#include "core/Json.h"

#include <charconv>
#include <cmath>
#include <cstring>

namespace kite::json {

std::optional<bool> Value::AsBool() const {
    if (auto* b = std::get_if<bool>(&data_)) return *b;
    return std::nullopt;
}

std::optional<double> Value::AsNumber() const {
    if (auto* d = std::get_if<double>(&data_)) return *d;
    return std::nullopt;
}

std::optional<int64_t> Value::AsInt() const {
    auto d = AsNumber();
    if (!d || std::floor(*d) != *d || std::fabs(*d) > 9007199254740992.0) return std::nullopt;
    return static_cast<int64_t>(*d);
}

const std::string* Value::AsString() const { return std::get_if<std::string>(&data_); }

const Array* Value::AsArray() const {
    auto* p = std::get_if<std::shared_ptr<Array>>(&data_);
    return p ? p->get() : nullptr;
}

const Object* Value::AsObject() const {
    auto* p = std::get_if<std::shared_ptr<Object>>(&data_);
    return p ? p->get() : nullptr;
}

Array* Value::AsArray() {
    auto* p = std::get_if<std::shared_ptr<Array>>(&data_);
    if (!p) return nullptr;
    if (p->use_count() > 1) *p = std::make_shared<Array>(**p);
    return p->get();
}

Object* Value::AsObject() {
    auto* p = std::get_if<std::shared_ptr<Object>>(&data_);
    if (!p) return nullptr;
    if (p->use_count() > 1) *p = std::make_shared<Object>(**p);
    return p->get();
}

const Value* Value::Find(std::string_view key) const {
    const Object* object = AsObject();
    if (!object) return nullptr;
    auto it = object->find(key);
    return it == object->end() ? nullptr : &it->second;
}

const Value* Member(const Value* object, std::string_view key) { return object ? object->Find(key) : nullptr; }

const Value* ObjectMember(const Value* object, std::string_view key) {
    const Value* v = Member(object, key);
    return v && v->AsObject() ? v : nullptr;
}

const std::string* StringMember(const Value* object, std::string_view key) {
    const Value* v = Member(object, key);
    return v ? v->AsString() : nullptr;
}

std::optional<Value> ParseValue(std::string_view text) {
    auto parsed = Parse(text);
    if (auto* value = std::get_if<Value>(&parsed)) return std::move(*value);
    return std::nullopt;
}

bool Value::operator==(const Value& other) const {
    if (data_.index() != other.data_.index()) return false;
    if (auto* a = AsArray()) return *a == *other.AsArray();
    if (auto* o = AsObject()) return *o == *other.AsObject();
    return data_ == other.data_;
}

// MARK: Parsing

namespace {

constexpr int kMaxDepth = 512;

// Length of the well-formed UTF-8 sequence starting `s` (non-ASCII lead byte), or 0. Rejects
// overlong forms, surrogates (ED A0..BF) and code points above U+10FFFF.
size_t ValidUtf8Length(std::string_view s) {
    auto at = [&](size_t i) { return i < s.size() ? static_cast<unsigned char>(s[i]) : 0u; };
    unsigned c = at(0);
    auto cont = [&](size_t i, unsigned lo = 0x80, unsigned hi = 0xBF) { unsigned b = at(i); return b >= lo && b <= hi; };
    if (c >= 0xC2 && c <= 0xDF) return cont(1) ? 2 : 0;
    if (c == 0xE0) return cont(1, 0xA0) && cont(2) ? 3 : 0;
    if (c == 0xED) return cont(1, 0x80, 0x9F) && cont(2) ? 3 : 0;
    if (c >= 0xE1 && c <= 0xEF) return cont(1) && cont(2) ? 3 : 0;
    if (c == 0xF0) return cont(1, 0x90) && cont(2) && cont(3) ? 4 : 0;
    if (c >= 0xF1 && c <= 0xF3) return cont(1) && cont(2) && cont(3) ? 4 : 0;
    if (c == 0xF4) return cont(1, 0x80, 0x8F) && cont(2) && cont(3) ? 4 : 0;
    return 0;
}

class Parser {
public:
    explicit Parser(std::string_view text) : text_(text) {}

    std::variant<Value, ParseError> Run() {
        // Foundation accepts a UTF-8 byte order mark (PowerShell 5 and old Notepad write one).
        if (text_.substr(0, 3) == "\xEF\xBB\xBF") pos_ = 3;
        SkipWhitespace();
        Value value;
        if (!ParseValue(value, 0)) return error_;
        SkipWhitespace();
        if (pos_ != text_.size()) return Fail("unexpected text after the value");
        return value;
    }

private:
    ParseError Fail(const char* message) {
        if (error_.message.empty()) error_ = ParseError{message, pos_};
        return error_;
    }

    void SkipWhitespace() {
        while (pos_ < text_.size() && (text_[pos_] == ' ' || text_[pos_] == '\t' || text_[pos_] == '\n' || text_[pos_] == '\r')) ++pos_;
    }

    bool Consume(std::string_view word) {
        if (text_.substr(pos_, word.size()) != word) return false;
        pos_ += word.size();
        return true;
    }

    bool ParseValue(Value& out, int depth) {
        if (depth > kMaxDepth) return Fail("nested too deeply"), false;
        if (pos_ >= text_.size()) return Fail("unexpected end of input"), false;
        switch (text_[pos_]) {
        case '{': return ParseObject(out, depth);
        case '[': return ParseArray(out, depth);
        case '"': {
            std::string s;
            if (!ParseString(s)) return false;
            out = Value(std::move(s));
            return true;
        }
        case 't': if (Consume("true")) { out = Value(true); return true; } break;
        case 'f': if (Consume("false")) { out = Value(false); return true; } break;
        case 'n': if (Consume("null")) { out = Value(); return true; } break;
        default: return ParseNumber(out);
        }
        return Fail("invalid literal"), false;
    }

    bool ParseNumber(Value& out) {
        size_t start = pos_;
        if (pos_ < text_.size() && text_[pos_] == '-') ++pos_;
        if (pos_ >= text_.size() || !IsDigit(text_[pos_])) return Fail("invalid value"), false;
        if (text_[pos_] == '0') {
            ++pos_;
        } else {
            while (pos_ < text_.size() && IsDigit(text_[pos_])) ++pos_;
        }
        if (pos_ < text_.size() && text_[pos_] == '.') {
            ++pos_;
            if (pos_ >= text_.size() || !IsDigit(text_[pos_])) return Fail("invalid number"), false;
            while (pos_ < text_.size() && IsDigit(text_[pos_])) ++pos_;
        }
        if (pos_ < text_.size() && (text_[pos_] == 'e' || text_[pos_] == 'E')) {
            ++pos_;
            if (pos_ < text_.size() && (text_[pos_] == '+' || text_[pos_] == '-')) ++pos_;
            if (pos_ >= text_.size() || !IsDigit(text_[pos_])) return Fail("invalid number"), false;
            while (pos_ < text_.size() && IsDigit(text_[pos_])) ++pos_;
        }
        double d = 0;
        auto [end, ec] = std::from_chars(text_.data() + start, text_.data() + pos_, d);
        if (ec != std::errc() || end != text_.data() + pos_ || !std::isfinite(d)) return Fail("number out of range"), false;
        out = Value(d);
        return true;
    }

    static bool IsDigit(char c) { return c >= '0' && c <= '9'; }

    bool ParseHex4(uint32_t& out) {
        if (pos_ + 4 > text_.size()) return false;
        out = 0;
        for (int i = 0; i < 4; ++i) {
            char c = text_[pos_++];
            out <<= 4;
            if (c >= '0' && c <= '9') out |= static_cast<uint32_t>(c - '0');
            else if (c >= 'a' && c <= 'f') out |= static_cast<uint32_t>(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') out |= static_cast<uint32_t>(c - 'A' + 10);
            else return false;
        }
        return true;
    }

    static void AppendUtf8(std::string& s, uint32_t cp) {
        if (cp < 0x80) {
            s += static_cast<char>(cp);
        } else if (cp < 0x800) {
            s += static_cast<char>(0xC0 | (cp >> 6));
            s += static_cast<char>(0x80 | (cp & 0x3F));
        } else if (cp < 0x10000) {
            s += static_cast<char>(0xE0 | (cp >> 12));
            s += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
            s += static_cast<char>(0x80 | (cp & 0x3F));
        } else {
            s += static_cast<char>(0xF0 | (cp >> 18));
            s += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
            s += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
            s += static_cast<char>(0x80 | (cp & 0x3F));
        }
    }

    bool ParseString(std::string& out) {
        ++pos_;  // opening quote
        while (true) {
            if (pos_ >= text_.size()) return Fail("unterminated string"), false;
            unsigned char c = static_cast<unsigned char>(text_[pos_]);
            if (c == '"') {
                ++pos_;
                return true;
            }
            if (c < 0x20) return Fail("control character in string"), false;
            if (c >= 0x80) {
                // Foundation rejects invalid UTF-8, so we do too rather than re-save it.
                size_t length = ValidUtf8Length(text_.substr(pos_));
                if (length == 0) return Fail("invalid UTF-8"), false;
                out.append(text_.substr(pos_, length));
                pos_ += length;
                continue;
            }
            if (c != '\\') {
                out += static_cast<char>(c);
                ++pos_;
                continue;
            }
            ++pos_;
            if (pos_ >= text_.size()) return Fail("unterminated escape"), false;
            char e = text_[pos_++];
            switch (e) {
            case '"': out += '"'; break;
            case '\\': out += '\\'; break;
            case '/': out += '/'; break;
            case 'b': out += '\b'; break;
            case 'f': out += '\f'; break;
            case 'n': out += '\n'; break;
            case 'r': out += '\r'; break;
            case 't': out += '\t'; break;
            case 'u': {
                uint32_t cp = 0;
                if (!ParseHex4(cp)) return Fail("invalid \\u escape"), false;
                if (cp >= 0xD800 && cp <= 0xDBFF) {
                    uint32_t low = 0;
                    if (!Consume("\\u") || !ParseHex4(low) || low < 0xDC00 || low > 0xDFFF) {
                        return Fail("unpaired surrogate"), false;
                    }
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                    return Fail("unpaired surrogate"), false;
                }
                AppendUtf8(out, cp);
                break;
            }
            default: return Fail("invalid escape"), false;
            }
        }
    }

    bool ParseArray(Value& out, int depth) {
        ++pos_;
        Array array;
        SkipWhitespace();
        if (pos_ < text_.size() && text_[pos_] == ']') {
            ++pos_;
            out = Value(std::move(array));
            return true;
        }
        while (true) {
            SkipWhitespace();
            Value element;
            if (!ParseValue(element, depth + 1)) return false;
            array.push_back(std::move(element));
            SkipWhitespace();
            if (pos_ < text_.size() && text_[pos_] == ',') { ++pos_; continue; }
            if (pos_ < text_.size() && text_[pos_] == ']') { ++pos_; break; }
            return Fail("expected , or ]"), false;
        }
        out = Value(std::move(array));
        return true;
    }

    bool ParseObject(Value& out, int depth) {
        ++pos_;
        Object object;
        SkipWhitespace();
        if (pos_ < text_.size() && text_[pos_] == '}') {
            ++pos_;
            out = Value(std::move(object));
            return true;
        }
        while (true) {
            SkipWhitespace();
            if (pos_ >= text_.size() || text_[pos_] != '"') return Fail("expected a key"), false;
            std::string key;
            if (!ParseString(key)) return false;
            SkipWhitespace();
            if (pos_ >= text_.size() || text_[pos_] != ':') return Fail("expected :"), false;
            ++pos_;
            SkipWhitespace();
            Value member;
            if (!ParseValue(member, depth + 1)) return false;
            object.insert_or_assign(std::move(key), std::move(member));  // last duplicate wins, like Foundation
            SkipWhitespace();
            if (pos_ < text_.size() && text_[pos_] == ',') { ++pos_; continue; }
            if (pos_ < text_.size() && text_[pos_] == '}') { ++pos_; break; }
            return Fail("expected , or }"), false;
        }
        out = Value(std::move(object));
        return true;
    }

    std::string_view text_;
    size_t pos_ = 0;
    ParseError error_;
};

void WriteString(std::string& out, const std::string& s) {
    static const char kHex[] = "0123456789abcdef";
    out += '"';
    for (size_t i = 0; i < s.size(); ++i) {
        unsigned char c = static_cast<unsigned char>(s[i]);
        if (c >= 0x80) {
            // Never write a file the Mac can't read: invalid bytes become U+FFFD.
            size_t length = ValidUtf8Length(std::string_view(s).substr(i));
            if (length == 0) {
                out += "\xEF\xBF\xBD";
            } else {
                out.append(s, i, length);
                i += length - 1;
            }
            continue;
        }
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        case '\b': out += "\\b"; break;
        case '\f': out += "\\f"; break;
        default:
            if (c < 0x20) {
                out += "\\u00";
                out += kHex[c >> 4];
                out += kHex[c & 0xF];
            } else {
                out += static_cast<char>(c);
            }
        }
    }
    out += '"';
}

void WriteValue(std::string& out, const Value& value) {
    if (value.IsNull()) {
        out += "null";
    } else if (auto b = value.AsBool()) {
        out += *b ? "true" : "false";
    } else if (auto d = value.AsNumber()) {
        // Whole numbers (ids, counts, PR numbers) as integers, like JSONEncoder writes an Int:
        // shortest to_chars would write 1000000 as "1e+06". Everything else shortest round-trip.
        char buffer[32];
        std::to_chars_result result;
        if (!std::isfinite(*d)) {
            out += "null";  // not JSON; the Mac's encoder refuses these, and nothing here makes one
            return;
        } else if (*d == std::trunc(*d) && std::fabs(*d) < 9007199254740992.0) {  // 2^53
            result = std::to_chars(buffer, buffer + sizeof(buffer), static_cast<long long>(*d));
        } else {
            result = std::to_chars(buffer, buffer + sizeof(buffer), *d);
        }
        out.append(buffer, result.ec == std::errc() ? result.ptr : buffer);
    } else if (auto* s = value.AsString()) {
        WriteString(out, *s);
    } else if (auto* a = value.AsArray()) {
        out += '[';
        for (size_t i = 0; i < a->size(); ++i) {
            if (i) out += ',';
            WriteValue(out, (*a)[i]);
        }
        out += ']';
    } else if (auto* o = value.AsObject()) {
        out += '{';
        bool first = true;
        for (const auto& [key, member] : *o) {
            if (!first) out += ',';
            first = false;
            WriteString(out, key);
            out += ':';
            WriteValue(out, member);
        }
        out += '}';
    }
}

}  // namespace

std::variant<Value, ParseError> Parse(std::string_view text) { return Parser(text).Run(); }

std::string Write(const Value& value) {
    std::string out;
    WriteValue(out, value);
    return out;
}

}  // namespace kite::json
