// See OneShotFlags.h. The binary property list format is Apple's (CFBinaryPList.c): "bplist00",
// the objects, a table of their offsets, and a 32-byte trailer giving the table's place and
// integer sizes.

#include "core/OneShotFlags.h"

#include <algorithm>
#include <cstdint>
#include <fstream>
#include <iterator>
#include <system_error>
#include <vector>

#include "core/Unicode.h"

namespace kite {

namespace {

constexpr std::string_view kMagic = "bplist00";
constexpr size_t kTrailer = 32;

uint64_t ReadInt(std::string_view bytes, size_t at, size_t size) {
    uint64_t value = 0;
    for (size_t i = 0; i < size; ++i) value = (value << 8) | static_cast<uint8_t>(bytes[at + i]);
    return value;
}

// An object's count: its marker's low nibble, or the int object after the marker when that's 0xF.
// The count, and where the object's contents start.
std::optional<std::pair<uint64_t, size_t>> Count(std::string_view bytes, size_t at) {
    const uint8_t marker = static_cast<uint8_t>(bytes[at]);
    if ((marker & 0x0F) != 0x0F) return std::pair<uint64_t, size_t>{marker & 0x0F, at + 1};
    if (at + 1 >= bytes.size()) return std::nullopt;
    const uint8_t intMarker = static_cast<uint8_t>(bytes[at + 1]);
    if ((intMarker & 0xF0) != 0x10) return std::nullopt;
    const size_t size = size_t{1} << (intMarker & 0x0F);
    if (size > 8 || at + 2 + size > bytes.size()) return std::nullopt;
    return std::pair<uint64_t, size_t>{ReadInt(bytes, at + 2, size), at + 2 + size};
}

void AppendInt(std::string& out, uint64_t value, size_t size) {
    for (size_t i = size; i-- > 0;) out.push_back(static_cast<char>((value >> (8 * i)) & 0xFF));
}

// A marker with its count, extended past 14 as Apple's writer does.
void AppendMarker(std::string& out, uint8_t type, size_t count) {
    if (count < 15) {
        out.push_back(static_cast<char>(type | count));
        return;
    }
    out.push_back(static_cast<char>(type | 0x0F));
    if (count < 0x100) {
        out.push_back(static_cast<char>(0x10));
        AppendInt(out, count, 1);
    } else if (count < 0x10000) {
        out.push_back(static_cast<char>(0x11));
        AppendInt(out, count, 2);
    } else {
        out.push_back(static_cast<char>(0x12));
        AppendInt(out, count, 4);
    }
}

// A path as text for an error (u8string, as SessionStore's: string() throws outside the ANSI code page).
std::string PathText(const std::filesystem::path& path) {
    const std::u8string text = path.u8string();
    return std::string(text.begin(), text.end());
}

}  // namespace

std::optional<std::map<std::string, bool>> OneShotFlags::Parse(std::string_view bytes) {
    if (bytes.size() < kMagic.size() + kTrailer || bytes.substr(0, kMagic.size()) != kMagic) return std::nullopt;
    const size_t trailer = bytes.size() - kTrailer;
    const size_t offsetSize = static_cast<uint8_t>(bytes[trailer + 6]);
    const size_t refSize = static_cast<uint8_t>(bytes[trailer + 7]);
    const uint64_t objects = ReadInt(bytes, trailer + 8, 8);
    const uint64_t top = ReadInt(bytes, trailer + 16, 8);
    const uint64_t table = ReadInt(bytes, trailer + 24, 8);
    if (offsetSize < 1 || offsetSize > 8 || refSize < 1 || refSize > 8 || top >= objects || table < kMagic.size() || table > trailer ||
        objects > (trailer - table) / offsetSize) {
        return std::nullopt;
    }
    const auto offset = [&](uint64_t ref) -> std::optional<size_t> {
        if (ref >= objects) return std::nullopt;
        const uint64_t at = ReadInt(bytes, static_cast<size_t>(table + ref * offsetSize), offsetSize);
        if (at < kMagic.size() || at >= table) return std::nullopt;
        return static_cast<size_t>(at);
    };
    const auto string = [&](uint64_t ref) -> std::optional<std::string> {
        const auto at = offset(ref);
        if (!at) return std::nullopt;
        const uint8_t type = static_cast<uint8_t>(bytes[*at]) & 0xF0;
        const auto count = Count(bytes, *at);
        if (!count) return std::nullopt;
        const auto [length, start] = *count;
        if (type == 0x50) {  // ASCII
            if (length > table || start > table - length) return std::nullopt;
            return std::string(bytes.substr(start, static_cast<size_t>(length)));
        }
        if (type != 0x60 || length > table / 2 || start > table - 2 * length) return std::nullopt;  // UTF-16, big-endian
        std::u32string points;
        for (uint64_t i = 0; i < length; ++i) {
            char32_t c = static_cast<char32_t>(ReadInt(bytes, static_cast<size_t>(start + 2 * i), 2));
            if (c >= 0xD800 && c < 0xDC00 && i + 1 < length) {
                const char32_t low = static_cast<char32_t>(ReadInt(bytes, static_cast<size_t>(start + 2 * (i + 1)), 2));
                if (low < 0xDC00 || low >= 0xE000) return std::nullopt;
                c = 0x10000 + ((c - 0xD800) << 10) + (low - 0xDC00);
                ++i;
            } else if (c >= 0xD800 && c < 0xE000) {
                return std::nullopt;  // a lone surrogate isn't text
            }
            points.push_back(c);
        }
        return unicode::Encode(points);
    };
    const auto dict = offset(top);
    if (!dict || (static_cast<uint8_t>(bytes[*dict]) & 0xF0) != 0xD0) return std::nullopt;
    const auto count = Count(bytes, *dict);
    if (!count || count->first > table || count->second + 2 * count->first * refSize > table) return std::nullopt;
    std::map<std::string, bool> flags;
    for (uint64_t i = 0; i < count->first; ++i) {
        const uint64_t keyRef = ReadInt(bytes, static_cast<size_t>(count->second + i * refSize), refSize);
        const uint64_t valueRef = ReadInt(bytes, static_cast<size_t>(count->second + (count->first + i) * refSize), refSize);
        const auto key = string(keyRef);
        const auto value = offset(valueRef);
        if (!key || !value) return std::nullopt;
        const uint8_t marker = static_cast<uint8_t>(bytes[*value]);
        if (marker != 0x08 && marker != 0x09) return std::nullopt;  // [String: Bool] only
        flags[*key] = marker == 0x09;
    }
    return flags;
}

std::optional<std::string> OneShotFlags::Write(const std::map<std::string, bool>& flags) {
    // The dictionary, its keys, then its values.
    const size_t objects = 1 + 2 * flags.size();
    const size_t refSize = objects < 0x100 ? 1 : 2;
    std::string out(kMagic);
    std::vector<size_t> offsets;
    offsets.push_back(out.size());
    AppendMarker(out, 0xD0, flags.size());
    for (size_t i = 0; i < flags.size(); ++i) AppendInt(out, 1 + i, refSize);
    for (size_t i = 0; i < flags.size(); ++i) AppendInt(out, 1 + flags.size() + i, refSize);
    for (const auto& entry : flags) {
        const std::string& key = entry.first;
        offsets.push_back(out.size());
        if (std::all_of(key.begin(), key.end(), [](char c) { return static_cast<uint8_t>(c) < 0x80; })) {
            AppendMarker(out, 0x50, key.size());
            out += key;
            continue;
        }
        // UTF-16, big-endian; text that isn't UTF-8 (Decode's U+FFFD where it wasn't) isn't a key.
        const std::vector<char32_t> points = unicode::Decode(key);
        if (unicode::Encode(std::u32string(points.begin(), points.end())) != key) return std::nullopt;
        std::u16string wide;
        for (char32_t c : points) {
            if (c >= 0x10000) {
                c -= 0x10000;
                wide.push_back(static_cast<char16_t>(0xD800 + (c >> 10)));
                wide.push_back(static_cast<char16_t>(0xDC00 + (c & 0x3FF)));
            } else {
                wide.push_back(static_cast<char16_t>(c));
            }
        }
        AppendMarker(out, 0x60, wide.size());
        for (char16_t c : wide) AppendInt(out, c, 2);
    }
    for (const auto& entry : flags) {
        offsets.push_back(out.size());
        out.push_back(static_cast<char>(entry.second ? 0x09 : 0x08));
    }
    const size_t table = out.size();
    const size_t offsetSize = table < 0x100 ? 1 : table < 0x10000 ? 2 : 4;
    for (size_t at : offsets) AppendInt(out, at, offsetSize);
    out.append(6, '\0');
    AppendInt(out, offsetSize, 1);
    AppendInt(out, refSize, 1);
    AppendInt(out, objects, 8);
    AppendInt(out, 0, 8);
    AppendInt(out, table, 8);
    return out;
}

OneShotFlags OneShotFlags::Load(const std::filesystem::path& folder) {
    OneShotFlags flags;
    flags.file_ = folder / kFileName;
    std::ifstream in(flags.file_, std::ios::binary);
    if (!in) return flags;
    const std::string bytes{std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
    if (auto parsed = Parse(bytes)) flags.flags_ = std::move(*parsed);
    return flags;
}

bool OneShotFlags::Get(const std::string& key) const {
    const auto found = flags_.find(key);
    return found != flags_.end() && found->second;
}

std::string OneShotFlags::Set(const std::string& key, bool value) {
    flags_[key] = value;
    if (file_.empty()) return "no profile folder for the one-shot flags";
    // The Mac's set: the file as it is now, with this flag changed.
    std::map<std::string, bool> merged;
    if (std::ifstream in(file_, std::ios::binary); in) {
        const std::string bytes{std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
        if (auto parsed = Parse(bytes)) merged = std::move(*parsed);
    }
    merged[key] = value;
    const std::optional<std::string> bytes = Write(merged);
    if (!bytes) return "a one-shot flag's name isn't UTF-8";
    // As SessionStore::Save: a sibling temporary file, flushed, then moved over the file.
    std::error_code error;
    std::filesystem::create_directories(file_.parent_path(), error);
    if (error) return "couldn't create " + PathText(file_.parent_path()) + ": " + error.message();
    std::filesystem::path temporary = file_;
    temporary += ".tmp";
    {
        std::ofstream out(temporary, std::ios::binary | std::ios::trunc);
        if (!out) return "couldn't write " + PathText(temporary);
        out.write(bytes->data(), static_cast<std::streamsize>(bytes->size()));
        out.flush();
        if (!out) return "couldn't write " + PathText(temporary);
    }
    std::filesystem::rename(temporary, file_, error);
    if (error) {
        std::error_code ignored;
        std::filesystem::remove(temporary, ignored);
        return "couldn't replace " + PathText(file_) + ": " + error.message();
    }
    return {};
}

}  // namespace kite
