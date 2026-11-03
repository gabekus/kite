#include "core/Uuid.h"

#include <random>

namespace kite {

std::string NewUuid() {
    thread_local std::mt19937_64 generator{std::random_device{}()};
    unsigned char bytes[16];
    for (int i = 0; i < 16; i += 8) {
        uint64_t r = generator();
        for (int j = 0; j < 8; ++j) bytes[i + j] = static_cast<unsigned char>(r >> (8 * j));
    }
    bytes[6] = static_cast<unsigned char>((bytes[6] & 0x0F) | 0x40);  // version 4
    bytes[8] = static_cast<unsigned char>((bytes[8] & 0x3F) | 0x80);  // RFC 4122 variant
    static const char kHex[] = "0123456789ABCDEF";
    std::string out;
    out.reserve(36);
    for (int i = 0; i < 16; ++i) {
        if (i == 4 || i == 6 || i == 8 || i == 10) out += '-';
        out += kHex[bytes[i] >> 4];
        out += kHex[bytes[i] & 0xF];
    }
    return out;
}

bool IsUuid(const std::string& text) {
    if (text.size() != 36) return false;
    for (size_t i = 0; i < text.size(); ++i) {
        char c = text[i];
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (c != '-') return false;
        } else if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) {
            return false;
        }
    }
    return true;
}

}  // namespace kite
