// See Plist.h.

#include "core/Plist.h"

#include <charconv>
#include <string>

#include "core/Unicode.h"

namespace kite::plist {

namespace {

class Parser {
public:
    explicit Parser(std::string_view text) : text_(text) {}

    std::optional<json::Value> Document() {
        if (!Skip()) return std::nullopt;
        std::string name;
        bool empty = false;
        if (!OpenTag(name, empty) || name != "plist" || empty) return std::nullopt;
        auto value = Element(0);
        if (!value || !Skip() || !CloseTag("plist")) return std::nullopt;
        return value;
    }

private:
    // Skips whitespace, the XML declaration, a DOCTYPE and comments.
    bool Skip() {
        for (;;) {
            while (at_ < text_.size() && (text_[at_] == ' ' || text_[at_] == '\t' || text_[at_] == '\n' || text_[at_] == '\r')) ++at_;
            if (Starts("<?")) {
                if (!SkipPast("?>")) return false;
            } else if (Starts("<!--")) {
                if (!SkipPast("-->")) return false;
            } else if (Starts("<!")) {
                if (!SkipPast(">")) return false;
            } else {
                return true;
            }
        }
    }

    bool Starts(std::string_view s) const { return text_.substr(at_, s.size()) == s; }
    bool SkipPast(std::string_view s) {
        const size_t end = text_.find(s, at_);
        if (end == std::string_view::npos) return false;
        at_ = end + s.size();
        return true;
    }

    // <name ...> or <name/>; attributes are skipped.
    bool OpenTag(std::string& name, bool& empty) {
        if (!Starts("<") || Starts("</")) return false;
        const size_t end = text_.find('>', at_);
        if (end == std::string_view::npos) return false;
        std::string_view inside = text_.substr(at_ + 1, end - at_ - 1);
        empty = !inside.empty() && inside.back() == '/';
        if (empty) inside.remove_suffix(1);
        name = std::string(inside.substr(0, inside.find_first_of(" \t\r\n")));
        at_ = end + 1;
        return !name.empty();
    }

    bool CloseTag(std::string_view name) {
        if (!Starts("</")) return false;
        const size_t end = text_.find('>', at_);
        if (end == std::string_view::npos) return false;
        std::string_view inside = text_.substr(at_ + 2, end - at_ - 2);
        while (!inside.empty() && (inside.back() == ' ' || inside.back() == '\t' || inside.back() == '\r' || inside.back() == '\n')) inside.remove_suffix(1);
        at_ = end + 1;
        return inside == name;
    }

    // Character data up to the next tag, with entities and CDATA decoded.
    std::optional<std::string> Text() {
        std::string out;
        while (at_ < text_.size() && !(text_[at_] == '<' && !Starts("<![CDATA["))) {
            if (Starts("<![CDATA[")) {
                const size_t end = text_.find("]]>", at_);
                if (end == std::string_view::npos) return std::nullopt;
                out += text_.substr(at_ + 9, end - at_ - 9);
                at_ = end + 3;
            } else if (text_[at_] == '&') {
                const size_t end = text_.find(';', at_);
                if (end == std::string_view::npos) return std::nullopt;
                const std::string_view entity = text_.substr(at_ + 1, end - at_ - 1);
                if (entity == "amp") out += '&';
                else if (entity == "lt") out += '<';
                else if (entity == "gt") out += '>';
                else if (entity == "quot") out += '"';
                else if (entity == "apos") out += '\'';
                else if (entity.size() > 1 && entity[0] == '#') {
                    const bool hex = entity[1] == 'x' || entity[1] == 'X';
                    std::string_view digits = entity.substr(hex ? 2 : 1);
                    uint32_t code = 0;
                    auto [p, error] = std::from_chars(digits.data(), digits.data() + digits.size(), code, hex ? 16 : 10);
                    if (error != std::errc() || p != digits.data() + digits.size()) return std::nullopt;
                    out += unicode::Encode(std::u32string(1, static_cast<char32_t>(code)));
                } else {
                    return std::nullopt;
                }
                at_ = end + 1;
            } else {
                out += text_[at_++];
            }
        }
        return out;
    }

    std::optional<std::string> TextElement(const std::string& name, bool empty) {
        if (empty) return std::string();
        auto text = Text();
        if (!text || !CloseTag(name)) return std::nullopt;
        return text;
    }

    std::optional<json::Value> Element(int depth) {
        if (depth > 64 || !Skip()) return std::nullopt;
        std::string name;
        bool empty = false;
        if (!OpenTag(name, empty)) return std::nullopt;
        if (name == "true" || name == "false") {
            if (!empty && !(Skip() && CloseTag(name))) return std::nullopt;
            return json::Value(name == "true");
        }
        if (name == "dict" || name == "array") {
            json::Object object;
            json::Array array;
            if (!empty) {
                for (;;) {
                    if (!Skip()) return std::nullopt;
                    if (Starts("</")) break;
                    if (name == "dict") {
                        std::string keyTag;
                        bool keyEmpty = false;
                        if (!OpenTag(keyTag, keyEmpty) || keyTag != "key") return std::nullopt;
                        auto key = TextElement(keyTag, keyEmpty);
                        auto value = key ? Element(depth + 1) : std::nullopt;
                        if (!value) return std::nullopt;
                        object.insert_or_assign(*key, std::move(*value));
                    } else {
                        auto value = Element(depth + 1);
                        if (!value) return std::nullopt;
                        array.push_back(std::move(*value));
                    }
                }
                if (!CloseTag(name)) return std::nullopt;
            }
            return name == "dict" ? json::Value(std::move(object)) : json::Value(std::move(array));
        }
        auto text = TextElement(name, empty);
        if (!text) return std::nullopt;
        if (name == "string" || name == "date" || name == "data") return json::Value(std::move(*text));
        if (name == "integer" || name == "real") {
            std::string_view digits = unicode::Trim(*text);
            if (!digits.empty() && digits[0] == '+') digits.remove_prefix(1);
            double d = 0;
            auto [p, error] = std::from_chars(digits.data(), digits.data() + digits.size(), d);
            if (error != std::errc() || p != digits.data() + digits.size()) return std::nullopt;
            return json::Value(d);
        }
        return std::nullopt;
    }

    std::string_view text_;
    size_t at_ = 0;
};

}  // namespace

std::optional<json::Value> ParseXml(std::string_view text) { return Parser(text).Document(); }

}  // namespace kite::plist
